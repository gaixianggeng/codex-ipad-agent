import XCTest
import Combine
@testable import CodexAgentPad

@MainActor
final class LogStoreTests: XCTestCase {
    func testLogStoreKeepsOnlyBoundedBuffer() async {
        let store = LogStore()
        let sessionID = "sess_test"
        let oversized = String(repeating: "x", count: 140_000)

        store.append(oversized, sessionID: sessionID)
        try? await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertLessThanOrEqual(store.log(for: sessionID).count, 120_000)
    }

    func testVisibleLogKeepsTailWindowAfterFlush() async {
        let store = LogStore()
        let sessionID = "sess_tail"
        let oversized = "drop-prefix-" + String(repeating: "x", count: 90_000) + "tail-suffix"

        store.append(oversized, sessionID: sessionID)
        try? await Task.sleep(nanoseconds: 220_000_000)

        let log = store.log(for: sessionID)
        XCTAssertLessThanOrEqual(log.count, 80_000)
        XCTAssertTrue(log.hasSuffix("tail-suffix"))
        XCTAssertFalse(log.contains("drop-prefix-"))
    }

    func testPendingFlushQueueKeepsLatestTailWhenBacklogged() async {
        let store = LogStore()
        let sessionID = "sess_pending_tail"
        let prefix = "drop-pending-prefix-" + String(repeating: "x", count: 120_000)
        let suffix = "pending-tail-suffix"

        store.append(prefix, sessionID: sessionID)
        for index in 0..<30 {
            store.append("chunk-\(index)-" + String(repeating: "y", count: 2_000), sessionID: sessionID)
        }
        store.append(suffix, sessionID: sessionID)
        try? await Task.sleep(nanoseconds: 260_000_000)

        let log = store.log(for: sessionID)
        XCTAssertLessThanOrEqual(log.count, 80_000)
        XCTAssertTrue(log.hasSuffix(suffix))
        XCTAssertFalse(log.contains("drop-pending-prefix-"))
    }

    func testPendingFlushQueueTrimsManySmallChunksWithoutDroppingTail() async {
        let store = LogStore()
        let sessionID = "sess_many_pending_chunks"

        for index in 0..<1_800 {
            store.append("old-\(index)-" + String(repeating: "x", count: 96), sessionID: sessionID)
        }
        let suffix = "many-small-chunks-tail"
        store.append(suffix, sessionID: sessionID)
        try? await Task.sleep(nanoseconds: 300_000_000)

        let log = store.log(for: sessionID)
        XCTAssertLessThanOrEqual(log.count, 80_000)
        XCTAssertTrue(log.hasSuffix(suffix))
        XCTAssertFalse(log.contains("old-0-"))
    }

    func testLogStoreMaintainsIndependentSessionBuffers() async {
        let store = LogStore()

        store.append("session-a", sessionID: "sess_a")
        store.append("session-b", sessionID: "sess_b")
        try? await Task.sleep(nanoseconds: 220_000_000)

        XCTAssertEqual(store.log(for: "sess_a"), "session-a")
        XCTAssertEqual(store.log(for: "sess_b"), "session-b")
    }

    func testLogStoreStripsAnsiTerminalSequences() async {
        let store = LogStore()
        let sessionID = "sess_ansi"

        store.append("\u{001B}[?1049h\u{001B}[32mhello\u{001B}[0m", sessionID: sessionID)
        try? await Task.sleep(nanoseconds: 220_000_000)

        let log = store.log(for: sessionID)
        XCTAssertEqual(log, "hello")
        XCTAssertFalse(log.contains("1049"))
    }

    func testAnsiOnlyChunkDoesNotPublishUnchangedLogState() async {
        let store = LogStore()
        let sessionID = "sess_ansi_noop"
        var publishCount = 0
        var cancellables: Set<AnyCancellable> = []

        store.objectWillChange
            .sink { _ in publishCount += 1 }
            .store(in: &cancellables)

        store.append("hello", sessionID: sessionID)
        try? await Task.sleep(nanoseconds: 220_000_000)
        let publishCountAfterVisibleText = publishCount

        store.append("\u{001B}[?1049h\u{001B}[?25l\u{001B}[0m", sessionID: sessionID)
        try? await Task.sleep(nanoseconds: 220_000_000)

        // 纯控制序列被清洗成空字符串时，日志内容和渲染行都没变化，不应触发 SwiftUI 刷新。
        XCTAssertEqual(store.log(for: sessionID), "hello")
        XCTAssertEqual(store.lines(for: sessionID).map(\.text), ["hello"])
        XCTAssertEqual(publishCount, publishCountAfterVisibleText)
    }

    func testLogStoreIgnoresReplayedSequencedChunks() async {
        let store = LogStore()
        let sessionID = "sess_seq"

        store.append("one", sessionID: sessionID, seq: 10)
        store.append("-duplicate", sessionID: sessionID, seq: 10)
        store.append("-old", sessionID: sessionID, seq: 9)
        store.append("-two", sessionID: sessionID, seq: 11)
        try? await Task.sleep(nanoseconds: 220_000_000)

        // 重连 bounded replay 可能带回已处理过的日志块；相同或更旧 seq 不应再次进入渲染队列。
        XCTAssertEqual(store.log(for: sessionID), "one-two")
        XCTAssertEqual(store.lastSeq(for: sessionID), 11)
    }

    func testResetClearsLogSequenceWatermark() async {
        let store = LogStore()
        let sessionID = "sess_seq_reset"

        store.append("before", sessionID: sessionID, seq: 7)
        try? await Task.sleep(nanoseconds: 220_000_000)
        store.reset(sessionID: sessionID)
        store.append("after", sessionID: sessionID, seq: 7)
        try? await Task.sleep(nanoseconds: 220_000_000)

        XCTAssertEqual(store.log(for: sessionID), "after")
        XCTAssertEqual(store.lastSeq(for: sessionID), 7)
    }

    func testResetCancelsPendingFlushForSession() async {
        let store = LogStore()
        let sessionID = "sess_reset"

        // reset 必须取消尚未 flush 的批量写入，避免切换会话后旧日志回灌到新视图。
        store.append("should be dropped", sessionID: sessionID)
        store.reset(sessionID: sessionID)
        try? await Task.sleep(nanoseconds: 220_000_000)

        XCTAssertEqual(store.log(for: sessionID), "")
    }

    func testLogStoreTrimsLeastRecentlyUsedSessionCaches() async {
        let store = LogStore()
        let retainedLimit = LogStore.retainedSessionLimit

        for index in 0..<retainedLimit {
            store.append("log \(index)", sessionID: "sess_\(index)")
        }
        store.retainSessionCache(sessionID: "sess_0")
        store.append("new log", sessionID: "sess_new")
        try? await Task.sleep(nanoseconds: 220_000_000)

        // 日志缓存按最近使用会话保留，避免多会话长期运行后 buffers/renderedLines 无上限增长。
        XCTAssertEqual(store.log(for: "sess_0"), "log 0")
        XCTAssertEqual(store.log(for: "sess_1"), "")
        XCTAssertEqual(store.log(for: "sess_new"), "new log")
    }

    func testInputPathDoesNotTouchLogStore() async {
        let store = LogStore()
        let sessionID = "sess_test"

        // 输入框由 ComposerView 本地 @State 维护；没有任何按键路径会调用 LogStore。
        XCTAssertEqual(store.log(for: sessionID), "")
    }

    func testLogFormatterKeepsAbsoluteLineIDsAfterTailLimit() {
        let log = (0..<365).map { "line \($0)" }.joined(separator: "\n")

        let lines = LogPanelFormatter().renderedLines(from: log, startLineID: 100)

        XCTAssertEqual(lines.count, 360)
        XCTAssertEqual(lines.first?.id, 105)
        XCTAssertEqual(lines.first?.text, "line 5")
        XCTAssertEqual(lines.last?.id, 464)
        XCTAssertEqual(lines.last?.text, "line 364")
    }

    func testLogFormatterCollapsesInlineRepeatedSentences() {
        // Codex TUI 在同一行里把整句重画两遍，旧逻辑会原样展示重复内容。
        let log = "● 他说：\"那你得放松。\" 他说：\"那你得放松。\"\n"

        let lines = LogPanelFormatter().renderedLines(from: log)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.text, "他说：\"那你得放松。\"")
    }

    func testLogFormatterDedupsAdjacentRedrawWithPromptChrome() {
        // 相邻两行只差尾部输入框占位符（"… ›Implement {feature} …"），应被视为同一行。
        let log = [
            "● 数据库管理员去看病。",
            "● 数据库管理员去看病。 ›Implement {feature} gpt-5.5 xhigh fast · ~/code",
        ].joined(separator: "\n")

        let lines = LogPanelFormatter().renderedLines(from: log)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.text, "数据库管理员去看病。")
    }

    func testLogFormatterDoesNotTruncatePlainOutputWithPromptLikeChars() {
        // 普通终端 output 里的 "›" / ">Implement" / "•" 不是 TUI 残影，不应被 prompt 清洗截断。
        let log = [
            "build a › b done",
            "note: > Implement later",
            "data: • item one",
        ].joined(separator: "\n")

        let lines = LogPanelFormatter().renderedLines(from: log)

        XCTAssertEqual(
            lines.map(\.text),
            ["build a › b done", "note: > Implement later", "data: • item one"]
        )
    }

    func testLogFormatterKeepsDistinctOutputLinesSharingPromptPrefix() {
        // 两行只是恰好都含 "›"，内容不同，不能因为 prompt 截断后 key 相同被误合并。
        let log = ["Step › one", "Step › two"].joined(separator: "\n")

        let lines = LogPanelFormatter().renderedLines(from: log)

        XCTAssertEqual(lines.map(\.text), ["Step › one", "Step › two"])
    }
}
