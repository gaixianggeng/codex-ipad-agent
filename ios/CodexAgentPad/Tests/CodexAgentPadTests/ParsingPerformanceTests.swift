import XCTest
@testable import CodexAgentPad

final class ParsingPerformanceTests: XCTestCase {
    func testAnsiCleanerRemovesTerminalEscapeSequences() {
        let raw = "\u{001B}[31mhello\u{001B}[0m\r\nworld\u{001B}]0;title\u{0007}"
        let clean = AnsiCleaner.clean(raw)

        XCTAssertFalse(clean.contains("\u{001B}"))
        XCTAssertTrue(clean.contains("hello"))
        XCTAssertTrue(clean.contains("world"))
    }

    func testParserFindsLatestAssistantBubble() {
        let transcript = """
        model: gpt
        │ • 第一条回复
        › 用户输入
        │ • 第二条回复
        继续内容
        """

        let parsed = CodexOutputParser().latestAssistantBlock(from: transcript)

        XCTAssertTrue(parsed.contains("第二条回复"))
        XCTAssertTrue(parsed.contains("继续内容"))
        XCTAssertFalse(parsed.contains("第一条回复"))
    }

    func testParserPerformanceWithLargeTerminalTranscript() {
        let chunk = """
        model: gpt-5
        directory: ~/code
        │ • 收到，正在处理这个请求。
        这里是一段较长的输出内容，用来模拟 Codex TUI 的流式日志。
        """
        let transcript = String(repeating: chunk, count: 600)
        let parser = CodexOutputParser()

        measure {
            _ = parser.latestAssistantBlock(from: transcript)
        }
    }
}
