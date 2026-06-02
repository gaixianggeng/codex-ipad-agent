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
    func ping() -> Bool
}

final class AgentWebSocketClient: NSObject, SessionWebSocketClient {
    private static let pendingMessageLimit = 32

    var onEvent: ((AgentEvent) -> Void)?
    var onStatus: ((WebSocketStatus) -> Void)?
    var onSendFailure: ((ClientMessageID?, String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private let encoder = JSONEncoder()
    private let decoder = AgentAPIClient.decoder
    private var isConnected = false
    private var isConnecting = false
    private var isDisconnecting = false
    private var pendingMessages = PendingWebSocketMessageQueue(maxMessages: pendingMessageLimit)

    func connect(url: URL, token: String) {
        disconnect()

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        onStatus?(.connecting)
        isConnecting = true
        isDisconnecting = false
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
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
    func ping() -> Bool {
        send(ClientWebSocketMessage(type: "ping"))
    }

    func disconnect() {
        isDisconnecting = true
        isConnecting = false
        isConnected = false
        pendingMessages.removeAll()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        onStatus?(.disconnected)
    }

    @discardableResult
    private func send(_ message: ClientWebSocketMessage) -> Bool {
        guard let task else {
            onStatus?(.failed("WebSocket 未连接"))
            return false
        }
        guard isConnected else {
            if isConnecting {
                // 移动端重连期间允许先接住少量用户输入，等 didOpen 后再统一发给 agentd。
                // 队列必须有上限，否则弱网/服务端卡住时会把输入和 resize/ping 一直堆在内存里。
                guard pendingMessages.append(message) else {
                    let reason = "WebSocket 正在连接，待发送队列已满"
                    onSendFailure?(message.clientMessageID, reason)
                    onStatus?(.failed(reason))
                    return false
                }
                onStatus?(.connecting)
                return true
            }
            onStatus?(.failed("WebSocket 未连接"))
            return false
        }
        return sendNow(message, task: task)
    }

    @discardableResult
    private func sendNow(_ message: ClientWebSocketMessage, task: URLSessionWebSocketTask) -> Bool {
        do {
            let data = try encoder.encode(message)
            let text = String(decoding: data, as: UTF8.self)
            task.send(.string(text)) { [weak self] error in
                if let error {
                    self?.isConnected = false
                    self?.isConnecting = false
                    self?.onSendFailure?(message.clientMessageID, error.localizedDescription)
                    self?.onStatus?(.failed(error.localizedDescription))
                }
            }
            return true
        } catch {
            isConnected = false
            isConnecting = false
            onSendFailure?(message.clientMessageID, error.localizedDescription)
            onStatus?(.failed(error.localizedDescription))
            return false
        }
    }

    private func flushPendingMessages() {
        guard let task, isConnected else {
            return
        }
        let messages = pendingMessages.drain()
        for message in messages {
            _ = sendNow(message, task: task)
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self, self.task != nil else {
                return
            }
            switch result {
            case .success(let message):
                self.handle(message)
                self.receiveLoop()
            case .failure(let error):
                self.isConnected = false
                self.isConnecting = false
                guard !self.isDisconnecting else {
                    return
                }
                self.onStatus?(.failed(error.localizedDescription))
            }
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
            onEvent?(event)
        } catch {
            onStatus?(.failed("WebSocket 消息解析失败：\(error.localizedDescription)"))
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
        guard webSocketTask == task else {
            return
        }
        isConnecting = false
        isConnected = true
        onStatus?(.connected)
        receiveLoop()
        flushPendingMessages()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard webSocketTask == task else {
            return
        }
        isConnecting = false
        isConnected = false
        task = nil
        if !isDisconnecting {
            onStatus?(.disconnected)
        }
    }
}
