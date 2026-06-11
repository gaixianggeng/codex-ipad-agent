import Foundation

@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var visibleLogs: [String: String] = [:]
    // 已渲染的日志行：在后台线程算好再发布，避免 LogPanelView 在 body 里对 8 万字符做 split+正则。
    @Published private(set) var renderedLinesBySession: [String: [LogDisplayLine]] = [:]
    @Published var autoScroll = true

    private var buffers: [String: String] = [:]
    private var bufferStartLineBySessionID: [String: Int] = [:]
    private var pendingChunks: [String: [String]] = [:]
    private var pendingChunkCharacters: [String: Int] = [:]
    private var flushTasks: [String: Task<Void, Never>] = [:]
    private var lastSeenSeqBySessionID: [String: EventSequence] = [:]
    private var sessionAccessTickBySessionID: [String: UInt64] = [:]
    private var sessionAccessCounter: UInt64 = 0
    private let maxPendingCharacters = 160_000
    private let maxBufferCharacters = 120_000
    private let maxVisibleCharacters = 80_000
    private let flushDelayNanoseconds: UInt64 = 120_000_000
    static let retainedSessionLimit = 16

    func log(for sessionID: String?) -> String {
        guard let sessionID else {
            return ""
        }
        return visibleLogs[sessionID] ?? buffers[sessionID] ?? ""
    }

    func lines(for sessionID: String?) -> [LogDisplayLine] {
        guard let sessionID else {
            return []
        }
        return renderedLinesBySession[sessionID] ?? []
    }

    func lastSeq(for sessionID: String?) -> EventSequence? {
        guard let sessionID else {
            return nil
        }
        return lastSeenSeqBySessionID[sessionID]
    }

    func retainSessionCache(sessionID: String) {
        guard hasCacheState(sessionID: sessionID) else {
            return
        }
        touchLogSession(sessionID)
    }

    func append(_ chunk: String, sessionID: String, seq: EventSequence? = nil) {
        guard !chunk.isEmpty else {
            return
        }
        guard shouldAccept(seq: seq, sessionID: sessionID) else {
            return
        }

        // 日志只维护自己的缓冲区；输入框和对话解析都不会反向触发这里。
        pendingChunks[sessionID, default: []].append(chunk)
        pendingChunkCharacters[sessionID, default: 0] += chunk.count
        trimPendingChunksIfNeeded(sessionID: sessionID)
        touchLogSession(sessionID)
        trimLogSessionCachesIfNeeded()
        scheduleFlush(sessionID: sessionID)
    }

    func reset(sessionID: String) {
        clearLogSessionState(sessionID: sessionID, publishEmptyState: true)
    }

    private func shouldAccept(seq: EventSequence?, sessionID: String) -> Bool {
        guard let seq else {
            return true
        }
        if let last = lastSeenSeqBySessionID[sessionID], seq <= last {
            return false
        }
        // 结构化日志可能在重连后 bounded replay；按 Codex/Litter 的单调 seq 思路，
        // Store 层先做轻量去重，避免旧块再次触发布局和行解析。
        lastSeenSeqBySessionID[sessionID] = seq
        return true
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

            // 取出待清洗的原始分片（主线程，仅做缓冲区搬运）。
            let raw = await MainActor.run { [weak self] () -> String in
                guard let self else {
                    return ""
                }
                let joined = self.pendingChunks[sessionID, default: []].joined()
                self.pendingChunks[sessionID] = []
                self.pendingChunkCharacters[sessionID] = 0
                return joined
            }

            // ANSI 清洗可能要扫一大段终端控制序列，放到后台线程，避免每 120ms 卡主线程。
            let chunk = await Task.detached(priority: .utility) {
                AnsiCleaner.clean(raw)
            }.value
            guard !Task.isCancelled else {
                return
            }

            // 追加缓冲并取出最新可见窗口（主线程，仅做字符串搬运）。
            let visibleSnapshot = await MainActor.run { [weak self] () -> (text: String, startLineID: Int) in
                guard let self else {
                    return ("", 0)
                }
                if !chunk.isEmpty {
                    let current = (self.buffers[sessionID] ?? "") + chunk
                    let trimmed = self.trimmedLogBuffer(current, sessionID: sessionID)
                    self.buffers[sessionID] = trimmed
                }
                let visible = self.visibleLogWindow(sessionID: sessionID)
                self.setVisibleLogIfChanged(visible, sessionID: sessionID)
                return (visible, self.visibleStartLineID(sessionID: sessionID, visible: visible))
            }

            // 行解析（split + 逐行正则 + 去噪）是最重的一步，放到后台线程算好再发布。
            let lines = await Task.detached(priority: .utility) {
                LogPanelFormatter().renderedLines(from: visibleSnapshot.text, startLineID: visibleSnapshot.startLineID)
            }.value
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard let self else {
                    return
                }
                self.setRenderedLinesIfChanged(lines, sessionID: sessionID)
                self.flushTasks[sessionID] = nil
                // 后台处理期间可能又有分片落入 pendingChunks，补一次调度避免漏刷。
                if self.pendingChunks[sessionID]?.isEmpty == false {
                    self.scheduleFlush(sessionID: sessionID)
                }
            }
        }
    }

    private func setVisibleLogIfChanged(_ visible: String, sessionID: String) {
        guard visibleLogs[sessionID] != visible else {
            return
        }
        visibleLogs[sessionID] = visible
    }

    private func setRenderedLinesIfChanged(_ lines: [LogDisplayLine], sessionID: String) {
        guard renderedLinesBySession[sessionID] != lines else {
            return
        }
        renderedLinesBySession[sessionID] = lines
    }

    private func trimmedLogBuffer(_ current: String, sessionID: String) -> String {
        guard current.count > maxBufferCharacters else {
            return current
        }
        let dropCount = current.count - maxBufferCharacters
        let dropIndex = current.index(current.startIndex, offsetBy: dropCount)
        let droppedPrefix = current[..<dropIndex]
        // 缓冲区裁剪时累加被丢弃的换行数，后续渲染行继续使用绝对行号，避免 SwiftUI 把尾部行全部当成新行。
        bufferStartLineBySessionID[sessionID, default: 0] += newlineCount(in: droppedPrefix)
        return String(current[dropIndex...])
    }

    private func visibleLogWindow(sessionID: String) -> String {
        let buffer = buffers[sessionID] ?? ""
        guard buffer.count > maxVisibleCharacters else {
            return buffer
        }
        return String(buffer.suffix(maxVisibleCharacters))
    }

    private func visibleStartLineID(sessionID: String, visible: String) -> Int {
        let buffer = buffers[sessionID] ?? ""
        var startLineID = bufferStartLineBySessionID[sessionID] ?? 0
        guard buffer.count > visible.count else {
            return startLineID
        }
        let dropCount = buffer.count - visible.count
        let dropIndex = buffer.index(buffer.startIndex, offsetBy: dropCount)
        startLineID += newlineCount(in: buffer[..<dropIndex])
        return startLineID
    }

    private func newlineCount<S: StringProtocol>(in text: S) -> Int {
        text.reduce(0) { count, character in
            character == "\n" ? count + 1 : count
        }
    }

    private func hasCacheState(sessionID: String) -> Bool {
        buffers[sessionID] != nil
            || visibleLogs[sessionID] != nil
            || renderedLinesBySession[sessionID] != nil
            || pendingChunks[sessionID]?.isEmpty == false
            || pendingChunkCharacters[sessionID, default: 0] > 0
            || lastSeenSeqBySessionID[sessionID] != nil
    }

    private func trimPendingChunksIfNeeded(sessionID: String) {
        guard let total = pendingChunkCharacters[sessionID],
              total > maxPendingCharacters,
              let chunks = pendingChunks[sessionID]
        else {
            return
        }

        let trimmed = trimPendingChunkWindow(chunks: chunks, total: total, maxCharacters: maxPendingCharacters)
        pendingChunks[sessionID] = trimmed.chunks
        pendingChunkCharacters[sessionID] = trimmed.total
    }

    private func trimPendingChunkWindow(
        chunks: [String],
        total: Int,
        maxCharacters: Int
    ) -> (chunks: [String], total: Int) {
        var overflow = total - maxCharacters
        guard overflow > 0 else {
            return (chunks, total)
        }
        var keptTotal = total
        var firstKeptIndex = 0

        // 后台清洗/渲染慢于输出时，未 flush 队列也必须有界；保留尾部最新输出。
        // 这里参考 Litter 的 bounded queue 思路：一次扫描定位保留窗口，避免 removeFirst
        // 在大量小分片积压时反复搬数组。
        while firstKeptIndex < chunks.count {
            let chunkCount = chunks[firstKeptIndex].count
            if chunkCount > overflow {
                break
            }
            overflow -= chunkCount
            keptTotal -= chunkCount
            firstKeptIndex += 1
        }

        var keptChunks: [String] = []
        keptChunks.reserveCapacity(chunks.count - firstKeptIndex)
        if firstKeptIndex < chunks.count {
            let firstKept = chunks[firstKeptIndex]
            if overflow > 0 {
                let keepCount = firstKept.count - overflow
                let keepStart = firstKept.index(firstKept.endIndex, offsetBy: -keepCount)
                keptChunks.append(String(firstKept[keepStart...]))
                keptTotal -= overflow
                firstKeptIndex += 1
            }
            if firstKeptIndex < chunks.count {
                keptChunks.append(contentsOf: chunks[firstKeptIndex...])
            }
        }

        return (keptChunks, keptTotal)
    }

    private func touchLogSession(_ sessionID: String) {
        // 日志分片可能高频到达；touch 只更新时间戳，避免数组 firstIndex/removeFirst 在多会话下反复搬移。
        sessionAccessCounter &+= 1
        sessionAccessTickBySessionID[sessionID] = sessionAccessCounter
    }

    private func trimLogSessionCachesIfNeeded() {
        // 日志缓存比对话缓存更重（原始缓冲、可见窗口、渲染行各一份）。
        // 参考 Codex/Litter 的有界状态思路，只保留最近访问的会话，避免长期运行后内存线性增长。
        while sessionAccessTickBySessionID.count > Self.retainedSessionLimit,
              let oldest = sessionAccessTickBySessionID.min(by: { $0.value < $1.value }) {
            clearLogSessionState(sessionID: oldest.key, publishEmptyState: false)
        }
    }

    private func clearLogSessionState(sessionID: String, publishEmptyState: Bool) {
        flushTasks[sessionID]?.cancel()
        flushTasks[sessionID] = nil
        pendingChunks[sessionID] = publishEmptyState ? [] : nil
        pendingChunkCharacters[sessionID] = nil
        buffers[sessionID] = publishEmptyState ? "" : nil
        bufferStartLineBySessionID[sessionID] = publishEmptyState ? 0 : nil
        visibleLogs[sessionID] = publishEmptyState ? "" : nil
        renderedLinesBySession[sessionID] = publishEmptyState ? [] : nil
        lastSeenSeqBySessionID[sessionID] = nil
        sessionAccessTickBySessionID[sessionID] = nil
    }
}
