import Foundation

protocol SessionWebSocketClient: AnyObject {
    var onEvent: ((AgentEvent) -> Void)? { get set }
    var onStatus: ((WebSocketStatus) -> Void)? { get set }
    var onSendFailure: ((ClientMessageID?, String) -> Void)? { get set }

    func connect(url: URL, token: String)
    func disconnect()
    func sendInput(_ text: String, clientMessageID: ClientMessageID?) -> Bool
    func sendEnter() -> Bool
    func sendCtrlC() -> Bool
    func sendResize(cols: Int, rows: Int) -> Bool
    func sendApprovalDecision(approvalID: String, decision: String, message: String?) -> Bool
    func ping() -> Bool
}

enum WebSocketMessageLimits {
    static let maximumInboundMessageBytes = 64 * 1024 * 1024

    static func apply(to task: URLSessionWebSocketTask, maximumMessageSize: Int = maximumInboundMessageBytes) {
        task.maximumMessageSize = max(1, maximumMessageSize)
    }
}

final class AgentWebSocketClient: NSObject, SessionWebSocketClient {
    private static let pendingMessageLimit = 32

    var onEvent: ((AgentEvent) -> Void)?
    var onStatus: ((WebSocketStatus) -> Void)?
    var onSendFailure: ((ClientMessageID?, String) -> Void)?

    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private let connection = WebSocketConnection(pendingMessageLimit: pendingMessageLimit)
    private var eventPumpTask: Task<Void, Never>?
    private var statusPumpTask: Task<Void, Never>?
    private var sendFailurePumpTask: Task<Void, Never>?

    override init() {
        super.init()
        startStreamPumps()
    }

    deinit {
        eventPumpTask?.cancel()
        statusPumpTask?.cancel()
        sendFailurePumpTask?.cancel()
        let connection = connection
        Task {
            await connection.finishStreams()
        }
    }

    func connect(url: URL, token: String) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        WebSocketMessageLimits.apply(to: task)
        runConnectionOperation { connection in
            await connection.connect(task: task)
        }
    }

    @discardableResult
    func sendInput(_ text: String, clientMessageID: ClientMessageID? = nil) -> Bool {
        send(ClientWebSocketMessage(type: "input", data: text, clientMessageID: clientMessageID))
    }

    @discardableResult
    func sendEnter() -> Bool {
        send(ClientWebSocketMessage(type: "input", data: "\r"))
    }

    @discardableResult
    func sendCtrlC() -> Bool {
        send(ClientWebSocketMessage(type: "signal", data: "ctrl_c"))
    }

    @discardableResult
    func sendResize(cols: Int, rows: Int) -> Bool {
        send(ClientWebSocketMessage(type: "resize", cols: cols, rows: rows))
    }

    @discardableResult
    func sendApprovalDecision(approvalID: String, decision: String, message: String? = nil) -> Bool {
        send(ClientWebSocketMessage(type: "approval_decision", data: message, approvalID: approvalID, decision: decision))
    }

    @discardableResult
    func ping() -> Bool {
        send(ClientWebSocketMessage(type: "ping"))
    }

    func disconnect() {
        runConnectionOperation { connection in
            await connection.disconnect()
        }
    }

    @discardableResult
    private func send(_ message: ClientWebSocketMessage) -> Bool {
        runConnectionOperation { connection in
            await connection.send(message).accepted
        }
    }

    private func startStreamPumps() {
        let events = runConnectionOperation { connection in
            await connection.events()
        }
        let statuses = runConnectionOperation { connection in
            await connection.statuses()
        }
        let failures = runConnectionOperation { connection in
            await connection.sendFailures()
        }

        eventPumpTask = Task { [weak self] in
            for await event in events {
                self?.onEvent?(event)
            }
        }
        statusPumpTask = Task { [weak self] in
            for await status in statuses {
                self?.onStatus?(status)
            }
        }
        sendFailurePumpTask = Task { [weak self] in
            for await failure in failures {
                self?.onSendFailure?(failure.clientMessageID, failure.message)
            }
        }
    }

    private func runConnectionOperation<Value>(_ operation: @escaping (WebSocketConnection) async -> Value) -> Value {
        let semaphore = DispatchSemaphore(value: 0)
        var output: Value?
        Task { [connection] in
            output = await operation(connection)
            semaphore.signal()
        }
        semaphore.wait()
        return output!
    }
}

struct WebSocketSendFailure {
    let clientMessageID: ClientMessageID?
    let message: String
}

struct WebSocketSendResult {
    let accepted: Bool
}

actor WebSocketConnection {
    private let encoder = JSONEncoder()
    private let decoder: JSONDecoder
    private var task: URLSessionWebSocketTask?
    private var isConnected = false
    private var isConnecting = false
    private var isDisconnecting = false
    private var pendingMessages: PendingWebSocketMessageQueue
    private var eventContinuation: AsyncStream<AgentEvent>.Continuation?
    private var statusContinuation: AsyncStream<WebSocketStatus>.Continuation?
    private var sendFailureContinuation: AsyncStream<WebSocketSendFailure>.Continuation?

    init(decoder: JSONDecoder = AgentAPIClient.decoder, pendingMessageLimit: Int = 32) {
        self.decoder = decoder
        self.pendingMessages = PendingWebSocketMessageQueue(maxMessages: pendingMessageLimit)
    }

    func events() -> AsyncStream<AgentEvent> {
        var continuation: AsyncStream<AgentEvent>.Continuation?
        let stream = AsyncStream<AgentEvent>(bufferingPolicy: .bufferingNewest(512)) {
            continuation = $0
        }
        eventContinuation = continuation
        return stream
    }

    func statuses() -> AsyncStream<WebSocketStatus> {
        var continuation: AsyncStream<WebSocketStatus>.Continuation?
        let stream = AsyncStream<WebSocketStatus>(bufferingPolicy: .bufferingNewest(64)) {
            continuation = $0
        }
        statusContinuation = continuation
        return stream
    }

    func sendFailures() -> AsyncStream<WebSocketSendFailure> {
        var continuation: AsyncStream<WebSocketSendFailure>.Continuation?
        let stream = AsyncStream<WebSocketSendFailure>(bufferingPolicy: .bufferingNewest(64)) {
            continuation = $0
        }
        sendFailureContinuation = continuation
        return stream
    }

    func connect(task nextTask: URLSessionWebSocketTask) {
        closeCurrentTask(emitStatus: false)
        task = nextTask
        isConnected = false
        isConnecting = true
        isDisconnecting = false
        statusContinuation?.yield(.connecting)
        nextTask.resume()
    }

    func disconnect() {
        closeCurrentTask(emitStatus: true)
    }

    func send(_ message: ClientWebSocketMessage) -> WebSocketSendResult {
        guard let task else {
            statusContinuation?.yield(.failed("WebSocket 未连接"))
            return WebSocketSendResult(accepted: false)
        }
        guard isConnected else {
            if isConnecting {
                // 移动端重连期间允许先接住少量用户输入，等 didOpen 后再统一发给 agentd。
                // 队列有上限，弱网/服务端卡住时不会把输入和 resize/ping 一直堆在内存里。
                guard pendingMessages.append(message) else {
                    let reason = "WebSocket 正在连接，待发送队列已满"
                    sendFailureContinuation?.yield(WebSocketSendFailure(clientMessageID: message.clientMessageID, message: reason))
                    statusContinuation?.yield(.failed(reason))
                    return WebSocketSendResult(accepted: false)
                }
                statusContinuation?.yield(.connecting)
                return WebSocketSendResult(accepted: true)
            }
            statusContinuation?.yield(.failed("WebSocket 未连接"))
            return WebSocketSendResult(accepted: false)
        }
        return WebSocketSendResult(accepted: sendNow(message, task: task))
    }

    func didOpen(task openedTask: URLSessionWebSocketTask) {
        guard openedTask === task else {
            return
        }
        isConnecting = false
        isConnected = true
        isDisconnecting = false
        statusContinuation?.yield(.connected)
        receiveNext(from: openedTask)
        flushPendingMessages()
    }

    func didClose(task closedTask: URLSessionWebSocketTask) {
        guard closedTask === task else {
            return
        }
        isConnecting = false
        isConnected = false
        task = nil
        if !isDisconnecting {
            statusContinuation?.yield(.disconnected)
        }
    }

    func ingest(_ message: URLSessionWebSocketTask.Message) {
        handle(message)
    }

    func finishStreams() {
        closeCurrentTask(emitStatus: false)
        eventContinuation?.finish()
        statusContinuation?.finish()
        sendFailureContinuation?.finish()
    }

    private func closeCurrentTask(emitStatus: Bool) {
        isDisconnecting = true
        isConnecting = false
        isConnected = false
        pendingMessages.removeAll()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        if emitStatus {
            statusContinuation?.yield(.disconnected)
        }
    }

    private func receiveNext(from task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else {
                return
            }
            Task {
                await self.handleReceive(result, task: task)
            }
        }
    }

    private func handleReceive(
        _ result: Result<URLSessionWebSocketTask.Message, Error>,
        task receivedTask: URLSessionWebSocketTask
    ) {
        guard receivedTask === task else {
            return
        }
        switch result {
        case .success(let message):
            handle(message)
            receiveNext(from: receivedTask)
        case .failure(let error):
            isConnected = false
            isConnecting = false
            guard !isDisconnecting else {
                return
            }
            statusContinuation?.yield(.failed(error.localizedDescription))
        }
    }

    @discardableResult
    private func sendNow(_ message: ClientWebSocketMessage, task: URLSessionWebSocketTask) -> Bool {
        do {
            let data = try encoder.encode(message)
            let text = String(decoding: data, as: UTF8.self)
            task.send(.string(text)) { [weak self] error in
                guard let error else {
                    return
                }
                Task {
                    await self?.handleSendError(message: message, error: error)
                }
            }
            return true
        } catch {
            isConnected = false
            isConnecting = false
            sendFailureContinuation?.yield(WebSocketSendFailure(clientMessageID: message.clientMessageID, message: error.localizedDescription))
            statusContinuation?.yield(.failed(error.localizedDescription))
            return false
        }
    }

    private func handleSendError(message: ClientWebSocketMessage, error: Error) {
        isConnected = false
        isConnecting = false
        sendFailureContinuation?.yield(WebSocketSendFailure(clientMessageID: message.clientMessageID, message: error.localizedDescription))
        statusContinuation?.yield(.failed(error.localizedDescription))
    }

    private func flushPendingMessages() {
        guard let task, isConnected else {
            return
        }
        for message in pendingMessages.drain() {
            _ = sendNow(message, task: task)
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let value):
            data = value
        @unknown default:
            return
        }
        do {
            let event = try decoder.decode(AgentEvent.self, from: data)
            eventContinuation?.yield(event)
        } catch {
            statusContinuation?.yield(.failed("WebSocket 消息解析失败：\(error.localizedDescription)"))
        }
    }
}

struct PendingWebSocketMessageQueue {
    private let maxMessages: Int
    private var messages: [ClientWebSocketMessage] = []

    init(maxMessages: Int) {
        self.maxMessages = max(1, maxMessages)
    }

    var count: Int {
        messages.count
    }

    var isEmpty: Bool {
        messages.isEmpty
    }

    @discardableResult
    mutating func append(_ message: ClientWebSocketMessage) -> Bool {
        guard messages.count < maxMessages else {
            return false
        }
        messages.append(message)
        return true
    }

    mutating func drain() -> [ClientWebSocketMessage] {
        let snapshot = messages
        messages.removeAll(keepingCapacity: true)
        return snapshot
    }

    mutating func removeAll() {
        messages.removeAll(keepingCapacity: false)
    }
}

extension AgentWebSocketClient: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol selectedProtocol: String?
    ) {
        Task { [connection] in
            await connection.didOpen(task: webSocketTask)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { [connection] in
            await connection.didClose(task: webSocketTask)
        }
    }
}

protocol CodexAppServerTransport: AnyObject {
    func connect(url: URL, token: String) async throws
    func send(_ text: String) async throws
    func receive() async throws -> String?
    func close() async
}

final class URLSessionCodexAppServerTransport: CodexAppServerTransport {
    private let session: URLSession
    private let maximumMessageSize: Int
    private var task: URLSessionWebSocketTask?

    init(
        session: URLSession = .shared,
        maximumMessageSize: Int = WebSocketMessageLimits.maximumInboundMessageBytes
    ) {
        self.session = session
        self.maximumMessageSize = max(1, maximumMessageSize)
    }

    func connect(url: URL, token: String) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let nextTask = session.webSocketTask(with: request)
        WebSocketMessageLimits.apply(to: nextTask, maximumMessageSize: maximumMessageSize)
        task = nextTask
        nextTask.resume()
    }

    func send(_ text: String) async throws {
        guard let task else {
            throw CodexAppServerConnectionError.disconnected
        }
        try await task.send(.string(text))
    }

    func receive() async throws -> String? {
        guard let task else {
            throw CodexAppServerConnectionError.disconnected
        }
        let message = try await task.receive()
        switch message {
        case .string(let text):
            return text
        case .data(let data):
            return String(data: data, encoding: .utf8)
        @unknown default:
            return nil
        }
    }

    func close() async {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}

enum CodexAppServerConnectionError: LocalizedError {
    case disconnected
    case notInitialized
    case duplicateRequestID(CodexAppServerRequestID)
    case timeout(method: String, id: CodexAppServerRequestID)
    case appServer(CodexAppServerError)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .disconnected:
            return "app-server WebSocket 未连接"
        case .notInitialized:
            return "app-server 尚未完成 initialize/initialized"
        case .duplicateRequestID(let id):
            return "JSON-RPC request id 重复：\(id)"
        case .timeout(let method, let id):
            return "app-server 请求超时：\(method)#\(id)"
        case .appServer(let error):
            return error.localizedDescription
        case .decoding(let error):
            return "app-server 消息解析失败：\(error.localizedDescription)"
        case .transport(let error):
            return "app-server WebSocket 传输失败：\(error.localizedDescription)"
        }
    }
}

private struct PendingCodexAppServerResponse {
    let method: String
    let continuation: CheckedContinuation<CodexAppServerJSONValue?, Error>
    let timeoutTask: Task<Void, Never>
}

actor CodexAppServerConnection {
    private let transport: CodexAppServerTransport
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let requestTimeoutNanoseconds: UInt64
    private var nextRequestNumber: Int64 = 1
    private var pendingResponses: [CodexAppServerRequestID: PendingCodexAppServerResponse] = [:]
    private var receiveTask: Task<Void, Never>?
    private var isConnected = false
    private var isInitialized = false
    private var notificationContinuation: AsyncStream<CodexAppServerNotification>.Continuation?
    private var serverRequestContinuation: AsyncStream<CodexAppServerServerRequest>.Continuation?

    init(
        transport: CodexAppServerTransport = URLSessionCodexAppServerTransport(),
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = AgentAPIClient.decoder,
        requestTimeout: TimeInterval = 20
    ) {
        self.transport = transport
        self.encoder = encoder
        self.decoder = decoder
        self.requestTimeoutNanoseconds = UInt64(max(0.1, requestTimeout) * 1_000_000_000)
    }

    deinit {
        receiveTask?.cancel()
        notificationContinuation?.finish()
        serverRequestContinuation?.finish()
    }

    func notifications() -> AsyncStream<CodexAppServerNotification> {
        var continuation: AsyncStream<CodexAppServerNotification>.Continuation?
        let stream = AsyncStream<CodexAppServerNotification>(bufferingPolicy: .bufferingNewest(512)) {
            continuation = $0
        }
        notificationContinuation = continuation
        return stream
    }

    func serverRequests() -> AsyncStream<CodexAppServerServerRequest> {
        var continuation: AsyncStream<CodexAppServerServerRequest>.Continuation?
        let stream = AsyncStream<CodexAppServerServerRequest>(bufferingPolicy: .bufferingNewest(128)) {
            continuation = $0
        }
        serverRequestContinuation = continuation
        return stream
    }

    func isReadyForRequests() -> Bool {
        guard let receiveTask else {
            return false
        }
        return isConnected && isInitialized && !receiveTask.isCancelled
    }

    func connect(url: URL, token: String) async throws {
        receiveTask?.cancel()
        receiveTask = nil
        isConnected = false
        isInitialized = false
        failAllPending(with: CodexAppServerConnectionError.disconnected)
        try await transport.connect(url: url, token: token)
        isConnected = true
        isInitialized = false
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        let initializeParams = CodexAppServerJSONValue.objectValue([
            "clientInfo": .object([
                "name": .string("codex_ipad_agent"),
                "title": .string("Codex iPad Agent"),
                "version": .string("0.1.0")
            ]),
            // app-server 要求客户端声明能力；这里保持最小能力集，避免移动端误触实验外的鉴权路径。
            "capabilities": .object([
                "experimentalApi": .bool(true),
                "requestAttestation": .bool(false)
            ])
        ])
        do {
            _ = try await sendRequestEnvelope(
                CodexAppServerRequest(id: nextRequestID(), method: "initialize", params: initializeParams),
                allowBeforeInitialized: true
            )
            try await sendNotification(CodexAppServerNotification(method: "initialized", params: .object([:])))
            isInitialized = true
        } catch {
            receiveTask?.cancel()
            receiveTask = nil
            markDisconnected(with: error)
            await transport.close()
            throw error
        }
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        isConnected = false
        isInitialized = false
        await transport.close()
        failAllPending(with: CodexAppServerConnectionError.disconnected)
        finishInboundStreams()
    }

    func send(_ request: CodexAppServerRequestSpec) async throws -> CodexAppServerJSONValue? {
        guard isConnected else {
            throw CodexAppServerConnectionError.disconnected
        }
        guard isInitialized else {
            throw CodexAppServerConnectionError.notInitialized
        }
        return try await sendRequestEnvelope(request.request(id: nextRequestID()), allowBeforeInitialized: false)
    }

    func sendNotification(_ notification: CodexAppServerNotification) async throws {
        guard isConnected else {
            throw CodexAppServerConnectionError.disconnected
        }
        let data = try encoder.encode(notification)
        do {
            try await transport.send(String(decoding: data, as: UTF8.self))
        } catch {
            let wrapped = CodexAppServerConnectionError.transport(error)
            markDisconnected(with: wrapped)
            throw wrapped
        }
    }

    func respond(to request: CodexAppServerServerRequest, result: CodexAppServerJSONValue? = .object([:])) async throws {
        try await sendResponse(CodexAppServerResponse(id: request.id, result: result, error: nil))
    }

    func respond(to request: CodexAppServerServerRequest, error: CodexAppServerError) async throws {
        try await sendResponse(CodexAppServerResponse(id: request.id, result: nil, error: error))
    }

    func ingestTextForTesting(_ text: String) {
        handleInboundText(text)
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            do {
                guard let text = try await transport.receive() else {
                    guard !Task.isCancelled else {
                        return
                    }
                    markDisconnected(with: CodexAppServerConnectionError.disconnected)
                    return
                }
                handleInboundText(text)
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                markDisconnected(with: CodexAppServerConnectionError.transport(error))
                return
            }
        }
    }

    private func sendRequestEnvelope(
        _ request: CodexAppServerRequest,
        allowBeforeInitialized: Bool
    ) async throws -> CodexAppServerJSONValue? {
        guard isConnected else {
            throw CodexAppServerConnectionError.disconnected
        }
        guard allowBeforeInitialized || isInitialized else {
            throw CodexAppServerConnectionError.notInitialized
        }
        guard pendingResponses[request.id] == nil else {
            throw CodexAppServerConnectionError.duplicateRequestID(request.id)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [requestTimeoutNanoseconds] in
                try? await Task.sleep(nanoseconds: requestTimeoutNanoseconds)
                self.timeoutRequest(id: request.id)
            }
            pendingResponses[request.id] = PendingCodexAppServerResponse(
                method: request.method,
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            Task {
                do {
                    try await self.sendEncodedRequest(request)
                } catch {
                    let wrapped = CodexAppServerConnectionError.transport(error)
                    self.failPendingRequest(id: request.id, error: wrapped)
                    self.markDisconnected(with: wrapped)
                }
            }
        }
    }

    private func sendEncodedRequest(_ request: CodexAppServerRequest) async throws {
        let data = try encoder.encode(request)
        try await transport.send(String(decoding: data, as: UTF8.self))
    }

    private func sendResponse(_ response: CodexAppServerResponse) async throws {
        guard isConnected else {
            throw CodexAppServerConnectionError.disconnected
        }
        let data = try encoder.encode(response)
        do {
            try await transport.send(String(decoding: data, as: UTF8.self))
        } catch {
            let wrapped = CodexAppServerConnectionError.transport(error)
            markDisconnected(with: wrapped)
            throw wrapped
        }
    }

    private func handleInboundText(_ text: String) {
        do {
            let message = try decoder.decode(CodexAppServerMessage.self, from: Data(text.utf8))
            switch message {
            case .response(let response):
                resolve(response)
            case .notification(let notification):
                notificationContinuation?.yield(notification)
            case .serverRequest(let request):
                serverRequestContinuation?.yield(request)
            }
        } catch {
            // 单个坏帧不能拖垮整条 JSON-RPC 连接；真正丢失的响应会由对应请求的超时兜底。
            return
        }
    }

    private func resolve(_ response: CodexAppServerResponse) {
        guard let pending = pendingResponses.removeValue(forKey: response.id) else {
            return
        }
        pending.timeoutTask.cancel()
        if let error = response.error {
            pending.continuation.resume(throwing: CodexAppServerConnectionError.appServer(error))
        } else {
            pending.continuation.resume(returning: response.result)
        }
    }

    private func timeoutRequest(id: CodexAppServerRequestID) {
        guard let pending = pendingResponses.removeValue(forKey: id) else {
            return
        }
        pending.continuation.resume(throwing: CodexAppServerConnectionError.timeout(method: pending.method, id: id))
    }

    private func failPendingRequest(id: CodexAppServerRequestID, error: Error) {
        guard let pending = pendingResponses.removeValue(forKey: id) else {
            return
        }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func failAllPending(with error: Error) {
        let pending = pendingResponses
        pendingResponses.removeAll(keepingCapacity: false)
        for item in pending.values {
            item.timeoutTask.cancel()
            item.continuation.resume(throwing: error)
        }
    }

    private func markDisconnected(with error: Error) {
        isConnected = false
        isInitialized = false
        failAllPending(with: error)
        finishInboundStreams()
    }

    private func finishInboundStreams() {
        notificationContinuation?.finish()
        notificationContinuation = nil
        serverRequestContinuation?.finish()
        serverRequestContinuation = nil
    }

    private func nextRequestID() -> CodexAppServerRequestID {
        defer {
            nextRequestNumber += 1
        }
        return .int(nextRequestNumber)
    }
}
