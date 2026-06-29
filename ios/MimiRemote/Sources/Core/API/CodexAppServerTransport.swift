import Foundation

protocol SessionWebSocketClient: AnyObject {
    var onEvent: ((AgentEvent) -> Void)? { get set }
    var onStatus: ((WebSocketStatus) -> Void)? { get set }
    var onSendAccepted: ((ClientMessageID?) -> Void)? { get set }
    var onSendFailure: ((ClientMessageID?, String) -> Void)? { get set }
    var onApprovalDecisionFailure: ((String, String) -> Void)? { get set }
    var onUserInputResponseFailure: ((String, String) -> Void)? { get set }
    var onControlFailure: ((String) -> Void)? { get set }

    func connect(sessionID: SessionID)
    func connect(sessionID: SessionID, replayBufferedEvents: Bool)
    func disconnect()
    func sendInput(_ text: String, clientMessageID: ClientMessageID?) -> Bool
    func sendTurn(_ payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?) -> Bool
    func sendGuidance(_ payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?, expectedTurnID: TurnID) -> Bool
    func sendCtrlC() -> Bool
    func sendApprovalDecision(approvalID: String, decision: String, message: String?) -> Bool
    func sendUserInputResponse(requestID: String, answers: [String: [String]]) -> Bool
}

extension SessionWebSocketClient {
    func connect(sessionID: SessionID, replayBufferedEvents: Bool) {
        connect(sessionID: sessionID)
    }
}

enum WebSocketMessageLimits {
    static let maximumInboundMessageBytes = 64 * 1024 * 1024

    static func apply(to task: URLSessionWebSocketTask, maximumMessageSize: Int = maximumInboundMessageBytes) {
        task.maximumMessageSize = max(1, maximumMessageSize)
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
        // app-server 通知包含 delta、完成态和审批状态，任何一条被丢都会让 iPad 时间线和真实
        // thread 状态不一致；这里宁可让连接级队列短暂增大，也不静默丢旧事件。
        let stream = AsyncStream<CodexAppServerNotification>(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        notificationContinuation = continuation
        return stream
    }

    func serverRequests() -> AsyncStream<CodexAppServerServerRequest> {
        var continuation: AsyncStream<CodexAppServerServerRequest>.Continuation?
        // 审批 request 必须逐条处理，丢掉旧 request 会导致 app-server 一直等待移动端响应。
        let stream = AsyncStream<CodexAppServerServerRequest>(bufferingPolicy: .unbounded) {
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
                "name": .string("mimi_remote"),
                "title": .string("Mimi Remote"),
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

    func send(_ request: CodexAppServerRequestSpec, timeout: TimeInterval? = nil) async throws -> CodexAppServerJSONValue? {
        guard isConnected else {
            throw CodexAppServerConnectionError.disconnected
        }
        guard isInitialized else {
            throw CodexAppServerConnectionError.notInitialized
        }
        return try await sendRequestEnvelope(
            request.request(id: nextRequestID()),
            allowBeforeInitialized: false,
            timeout: timeout
        )
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
        allowBeforeInitialized: Bool,
        timeout: TimeInterval? = nil
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

        let timeoutNanoseconds = timeout.map { UInt64(max(0.1, $0) * 1_000_000_000) } ?? requestTimeoutNanoseconds
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [timeoutNanoseconds] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
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
