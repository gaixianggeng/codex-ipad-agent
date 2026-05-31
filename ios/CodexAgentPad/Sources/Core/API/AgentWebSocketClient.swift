import Foundation

final class AgentWebSocketClient {
    var onEvent: ((AgentEvent) -> Void)?
    var onStatus: ((WebSocketStatus) -> Void)?

    private var task: URLSessionWebSocketTask?
    private let encoder = JSONEncoder()
    private let decoder = AgentAPIClient.decoder
    private var isConnected = false

    func connect(url: URL, token: String) {
        disconnect()

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        onStatus?(.connecting)
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        self.isConnected = true
        task.resume()
        onStatus?(.connected)
        receiveLoop()
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
        isConnected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        onStatus?(.disconnected)
    }

    @discardableResult
    private func send(_ message: ClientWebSocketMessage) -> Bool {
        guard let task, isConnected else {
            onStatus?(.failed("WebSocket 未连接"))
            return false
        }
        do {
            let data = try encoder.encode(message)
            let text = String(decoding: data, as: UTF8.self)
            task.send(.string(text)) { [weak self] error in
                if let error {
                    self?.isConnected = false
                    self?.onStatus?(.failed(error.localizedDescription))
                }
            }
            return true
        } catch {
            isConnected = false
            onStatus?(.failed(error.localizedDescription))
            return false
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self, self.isConnected else {
                return
            }
            switch result {
            case .success(let message):
                self.handle(message)
                self.receiveLoop()
            case .failure(let error):
                self.isConnected = false
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
