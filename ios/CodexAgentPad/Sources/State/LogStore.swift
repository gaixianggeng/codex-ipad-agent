import Foundation

@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var visibleLogs: [String: String] = [:]
    @Published var autoScroll = true

    private var buffers: [String: String] = [:]
    private var pendingChunks: [String: [String]] = [:]
    private var flushTasks: [String: Task<Void, Never>] = [:]
    private let maxBufferCharacters = 120_000
    private let maxVisibleCharacters = 80_000
    private let flushDelayNanoseconds: UInt64 = 120_000_000

    func log(for sessionID: String?) -> String {
        guard let sessionID else {
            return ""
        }
        return visibleLogs[sessionID] ?? buffers[sessionID] ?? ""
    }

    func append(_ chunk: String, sessionID: String) {
        guard !chunk.isEmpty else {
            return
        }

        // 日志只维护自己的缓冲区；输入框和对话解析都不会反向触发这里。
        pendingChunks[sessionID, default: []].append(chunk)
        scheduleFlush(sessionID: sessionID)
    }

    func reset(sessionID: String) {
        flushTasks[sessionID]?.cancel()
        flushTasks[sessionID] = nil
        pendingChunks[sessionID] = []
        buffers[sessionID] = ""
        visibleLogs[sessionID] = ""
    }

    private func scheduleFlush(sessionID: String) {
        guard flushTasks[sessionID] == nil else {
            return
        }
        let delay = flushDelayNanoseconds
        flushTasks[sessionID] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            await MainActor.run {
                guard let self else {
                    return
                }
                let chunk = AnsiCleaner.clean(self.pendingChunks[sessionID, default: []].joined())
                self.pendingChunks[sessionID] = []
                if !chunk.isEmpty {
                    let current = (self.buffers[sessionID] ?? "") + chunk
                    self.buffers[sessionID] = String(current.suffix(self.maxBufferCharacters))
                }
                let buffer = self.buffers[sessionID] ?? ""
                self.visibleLogs[sessionID] = String(buffer.suffix(self.maxVisibleCharacters))
                self.flushTasks[sessionID] = nil
            }
        }
    }
}
