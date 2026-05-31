import XCTest
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

    func testResetCancelsPendingFlushForSession() async {
        let store = LogStore()
        let sessionID = "sess_reset"

        // reset 必须取消尚未 flush 的批量写入，避免切换会话后旧日志回灌到新视图。
        store.append("should be dropped", sessionID: sessionID)
        store.reset(sessionID: sessionID)
        try? await Task.sleep(nanoseconds: 220_000_000)

        XCTAssertEqual(store.log(for: sessionID), "")
    }

    func testInputPathDoesNotTouchLogStore() async {
        let store = LogStore()
        let sessionID = "sess_test"

        // 输入框由 ComposerView 本地 @State 维护；没有任何按键路径会调用 LogStore。
        XCTAssertEqual(store.log(for: sessionID), "")
    }
}
