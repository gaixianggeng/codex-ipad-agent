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
