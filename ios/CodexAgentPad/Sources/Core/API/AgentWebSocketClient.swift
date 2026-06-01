import Foundation

final class AgentWebSocketClient: NSObject {
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
    private var pendingMessages: [ClientWebSocketMessage] = []

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
                // 移动端重连期间允许先接住用户输入，等 didOpen 后再统一发给 agentd。
                pendingMessages.append(message)
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
        let messages = pendingMessages
        pendingMessages.removeAll()
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
