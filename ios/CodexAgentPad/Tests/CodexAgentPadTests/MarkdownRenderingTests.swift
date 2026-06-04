import XCTest
@testable import CodexAgentPad

@MainActor
final class MarkdownRenderingTests: XCTestCase {
    func testMarkdownParserBuildsGFMBlocks() {
        let result = MarkdownParser.shared.parse("""
        # 标题

        这是 **粗体**、`代码`、[链接](https://example.com) 和 ~~删除~~。

        - [x] 已完成
        - [ ] 待处理

        | 名称 | 数量 |
        |:---|---:|
        | Token | 42 |

        > 引用内容

        ```swift
        let value = 1
        ```
        """)

        XCTAssertTrue(result.blocks.contains { block in
            if case let .heading(level, inline) = block.kind {
                return level == 1 && inline.plain == "标题"
            }
            return false
        })
        XCTAssertTrue(result.blocks.contains { block in
            if case let .taskList(items) = block.kind {
                return items.map(\.checked) == [true, false]
            }
            return false
        })
        XCTAssertTrue(result.blocks.contains { block in
            if case let .table(header, rows, alignments) = block.kind {
                return header.map(\.plain) == ["名称", "数量"]
                    && rows.first?.map(\.plain) == ["Token", "42"]
                    && alignments == [.leading, .trailing]
            }
            return false
        })
        XCTAssertTrue(result.blocks.contains { block in
            if case let .codeBlock(language, code) = block.kind {
                return language == "swift" && code.contains("let value = 1")
            }
            return false
        })
    }

    func testDisallowedLinksRenderAsPlainText() {
        let result = MarkdownParser.shared.parse("[危险](javascript:alert(1)) 和 [安全](mailto:hello@example.com)")
        let paragraph = result.blocks.compactMap { block -> MarkdownInlineText? in
            if case let .paragraph(inline) = block.kind {
                return inline
            }
            return nil
        }.first

        let inline = try! XCTUnwrap(paragraph)
        XCTAssertEqual(inline.plain, "危险 和 安全")
        XCTAssertTrue(inline.hasFormatting)
        XCTAssertTrue(inline.attributed.runs.contains { $0.link?.scheme == "mailto" })
        XCTAssertFalse(inline.attributed.runs.contains { $0.link?.scheme == "javascript" })
    }

    func testMixedAndOrderedTaskItemsKeepCheckboxState() {
        let result = MarkdownParser.shared.parse("""
        - [x] 已完成
        - 普通项

        1. [ ] 有序待办
        2. 普通有序
        """)

        let bulletList = result.blocks.compactMap { block -> [MarkdownListItem]? in
            if case let .bulletList(items, _) = block.kind {
                return items
            }
            return nil
        }.first
        let orderedList = result.blocks.compactMap { block -> [MarkdownListItem]? in
            if case let .orderedList(_, items, _) = block.kind {
                return items
            }
            return nil
        }.first

        XCTAssertEqual(bulletList?.map(\.checkbox), [true, nil])
        XCTAssertEqual(orderedList?.map(\.checkbox), [false, nil])
    }

    func testStreamingCacheConvergesToFullMarkdownParse() {
        let target = """
        ## 步骤

        1. 准备 **输入**
        2. 输出表格

        | Key | Value |
        |---|---:|
        | latency | 12 |

        ```go
        fmt.Println("ok")
        ```
        """
        let streamingCache = MessageRenderPlanCache(limit: 8)
        var streamingMessage = ConversationMessage(
            stableID: "assistant:streaming-markdown",
            role: .assistant,
            content: "",
            sendStatus: .sending
        )
        var streamingPlan = streamingCache.plan(for: streamingMessage)

        for character in target {
            streamingMessage.content.append(character)
            streamingPlan = streamingCache.plan(for: streamingMessage)
        }

        let fullMessage = ConversationMessage(
            stableID: "assistant:full-markdown",
            role: .assistant,
            content: target
        )
        let fullPlan = MessageRenderPlanCache(limit: 8).plan(for: fullMessage)

        XCTAssertGreaterThan(streamingCache.incrementalReuseCountForTesting, 0)
        XCTAssertEqual(streamingPlan.blocks, fullPlan.blocks)
    }

    func testStreamingCacheReparsesLooseListTailUntilSealed() {
        let prefix = """
        说明

        - 第一项

        """
        let suffix = """
          续写内容
        - 第二项
        """
        let target = prefix + suffix
        let cache = MessageRenderPlanCache(limit: 8)
        var message = ConversationMessage(
            stableID: "assistant:streaming-loose-list",
            role: .assistant,
            content: prefix,
            sendStatus: .sending
        )

        var streamingPlan = cache.plan(for: message)
        XCTAssertEqual(streamingPlan.openTailByteOffset, "说明\n\n".utf8.count)

        for character in suffix {
            message.content.append(character)
            streamingPlan = cache.plan(for: message)
        }

        let fullMessage = ConversationMessage(
            stableID: "assistant:full-loose-list",
            role: .assistant,
            content: target
        )
        let fullPlan = MessageRenderPlanCache(limit: 8).plan(for: fullMessage)

        XCTAssertEqual(streamingPlan.blocks, fullPlan.blocks)
        XCTAssertTrue(streamingPlan.blocks.contains { block in
            guard case let .bulletList(items, _) = block.kind else {
                return false
            }
            guard items.count == 2 else {
                return false
            }
            let firstItemText = items[0].blocks.map(\.plainTextForTesting).joined(separator: "\n")
            return firstItemText.contains("第一项")
                && firstItemText.contains("续写内容")
        })
    }

    func testMarkdownStyleKeepsConversationTypographyCompactAndScaled() {
        let style = MarkdownStyle.make(role: .assistant, colorScheme: .light, fontScale: 1.2)

        XCTAssertEqual(style.blockSpacing, 7)
        XCTAssertEqual(style.textLineSpacing, 2)
        XCTAssertEqual(style.scaled(15), 18, accuracy: 0.001)
    }

    func testStreamingMarkdownPerformanceStaysBoundedForLargeOpenBlocks() {
        let scenarios: [(name: String, content: String, maxSeconds: TimeInterval)] = [
            (
                "long paragraph",
                String(repeating: "这是一段用于模拟长回复的中文说明，包含 **强调** 和 `inline code`。", count: 22),
                4
            ),
            (
                "open code fence",
                "```swift\n" + (0..<32).map { "let value\($0) = \($0)" }.joined(separator: "\n"),
                4
            ),
            (
                "streaming table",
                """
                | 指标 | 数值 | 状态 |
                |---|---:|---|
                """ + "\n" + (0..<18).map { "| latency_\($0) | \($0) | ok |" }.joined(separator: "\n"),
                4
            )
        ]

        for scenario in scenarios {
            let elapsed = elapsedStreamingParseTime(for: scenario.content)
            XCTAssertLessThan(elapsed, scenario.maxSeconds, "\(scenario.name) took \(elapsed)s")
        }
    }

    private func elapsedStreamingParseTime(for content: String) -> TimeInterval {
        let cache = MessageRenderPlanCache(limit: 4)
        var message = ConversationMessage(
            stableID: "assistant:perf:\(UUID().uuidString)",
            role: .assistant,
            content: "",
            sendStatus: .sending
        )

        let start = Date()
        for character in content {
            message.content.append(character)
            _ = cache.plan(for: message)
        }
        return Date().timeIntervalSince(start)
    }
}

private extension MarkdownBlock {
    var plainTextForTesting: String {
        switch kind {
        case let .paragraph(inline), let .heading(_, inline):
            return inline.plain
        case let .bulletList(items, _), let .orderedList(_, items, _):
            return items.flatMap(\.blocks).map(\.plainTextForTesting).joined(separator: "\n")
        case let .taskList(items):
            return items.flatMap(\.blocks).map(\.plainTextForTesting).joined(separator: "\n")
        case let .blockquote(blocks):
            return blocks.map(\.plainTextForTesting).joined(separator: "\n")
        case let .codeBlock(_, code):
            return code
        case let .table(header, rows, _):
            return (header.map(\.plain) + rows.flatMap { $0.map(\.plain) }).joined(separator: "\n")
        case .thematicBreak:
            return ""
        }
    }
}
