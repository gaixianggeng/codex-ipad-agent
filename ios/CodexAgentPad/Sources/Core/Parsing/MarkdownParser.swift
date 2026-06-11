import Foundation
import Markdown

struct MarkdownParser {
    static let shared = MarkdownParser()

    func parse(_ content: String, baseByteOffset: Int = 0) -> MarkdownParseResult {
        let lineIndex = SourceLineByteIndex(content)
        var nextID = 0
        let document = Document(parsing: content, options: [.disableSmartOpts])
        let blocks = document.children.compactMap {
            block(from: $0, lineIndex: lineIndex, baseByteOffset: baseByteOffset, nextID: &nextID)
        }

        let normalizedBlocks = blocks.isEmpty
            ? [MarkdownBlock(id: nextID, sourceByteRange: 0..<0, kind: .paragraph(.empty))]
            : blocks

        return MarkdownParseResult(
            blocks: normalizedBlocks,
            openTailByteOffset: openTailStartByteOffset(
                for: normalizedBlocks,
                in: content,
                baseByteOffset: baseByteOffset
            )
        )
    }

    private func block(
        from markup: Markup,
        lineIndex: SourceLineByteIndex,
        baseByteOffset: Int,
        nextID: inout Int
    ) -> MarkdownBlock? {
        let id = nextID
        nextID += 1
        let range = sourceByteRange(for: markup, lineIndex: lineIndex, baseByteOffset: baseByteOffset)

        if let paragraph = markup as? Paragraph {
            return MarkdownBlock(id: id, sourceByteRange: range, kind: .paragraph(inlineText(from: paragraph.children)))
        }

        if let heading = markup as? Heading {
            return MarkdownBlock(id: id, sourceByteRange: range, kind: .heading(
                level: min(max(heading.level, 1), 6),
                inlineText(from: heading.children)
            ))
        }

        if let codeBlock = markup as? CodeBlock {
            return MarkdownBlock(id: id, sourceByteRange: range, kind: .codeBlock(
                language: codeBlock.language?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                code: codeBlock.code
            ))
        }

        if let unorderedList = markup as? UnorderedList {
            let allItems = Array(unorderedList.listItems)
            let taskItems = allItems.filter { $0.checkbox != nil }
            if taskItems.count == allItems.count, !taskItems.isEmpty {
                let items = taskItems.enumerated().map { index, item in
                    MarkdownTaskListItem(
                        id: index,
                        checked: item.checkbox == .checked,
                        blocks: childBlocks(from: item.children, lineIndex: lineIndex, baseByteOffset: baseByteOffset, nextID: &nextID)
                    )
                }
                return MarkdownBlock(id: id, sourceByteRange: range, kind: .taskList(items: items))
            }

            return MarkdownBlock(id: id, sourceByteRange: range, kind: .bulletList(
                items: listItems(from: allItems, lineIndex: lineIndex, baseByteOffset: baseByteOffset, nextID: &nextID),
                tight: isTightList(unorderedList)
            ))
        }

        if let orderedList = markup as? OrderedList {
            let allItems = Array(orderedList.listItems)
            return MarkdownBlock(id: id, sourceByteRange: range, kind: .orderedList(
                start: Int(orderedList.startIndex),
                items: listItems(from: allItems, lineIndex: lineIndex, baseByteOffset: baseByteOffset, nextID: &nextID),
                tight: isTightList(orderedList)
            ))
        }

        if let blockQuote = markup as? BlockQuote {
            return MarkdownBlock(id: id, sourceByteRange: range, kind: .blockquote(
                blocks: childBlocks(from: blockQuote.children, lineIndex: lineIndex, baseByteOffset: baseByteOffset, nextID: &nextID)
            ))
        }

        if let table = markup as? Table {
            return MarkdownBlock(id: id, sourceByteRange: range, kind: .table(
                header: table.head.cells.map { inlineText(from: $0.children) },
                rows: table.body.rows.map { row in row.cells.map { inlineText(from: $0.children) } },
                alignments: table.columnAlignments.map(markdownAlignment(from:))
            ))
        }

        if markup is ThematicBreak {
            return MarkdownBlock(id: id, sourceByteRange: range, kind: .thematicBreak)
        }

        if let html = markup as? HTMLBlock {
            let inline = MarkdownInlineText(attributed: AttributedString(html.rawHTML), plain: html.rawHTML, hasFormatting: false)
            return MarkdownBlock(id: id, sourceByteRange: range, kind: .paragraph(inline))
        }

        let fallback = inlineText(from: markup.children)
        guard !fallback.plain.isEmpty else {
            return nil
        }
        return MarkdownBlock(id: id, sourceByteRange: range, kind: .paragraph(fallback))
    }

    private func childBlocks(
        from children: MarkupChildren,
        lineIndex: SourceLineByteIndex,
        baseByteOffset: Int,
        nextID: inout Int
    ) -> [MarkdownBlock] {
        children.compactMap { block(from: $0, lineIndex: lineIndex, baseByteOffset: baseByteOffset, nextID: &nextID) }
    }

    private func listItems(
        from items: [ListItem],
        lineIndex: SourceLineByteIndex,
        baseByteOffset: Int,
        nextID: inout Int
    ) -> [MarkdownListItem] {
        items.enumerated().map { index, item in
            MarkdownListItem(
                id: index,
                checkbox: item.checkbox.map { $0 == .checked },
                blocks: childBlocks(from: item.children, lineIndex: lineIndex, baseByteOffset: baseByteOffset, nextID: &nextID)
            )
        }
    }

    private func isTightList(_ markup: Markup) -> Bool {
        // cmark 没有直接暴露 tight/loose 标志；这里用“列表项内没有多块内容”做渲染层近似。
        markup.children.allSatisfy { item in
            guard let listItem = item as? ListItem else {
                return true
            }
            return listItem.childCount <= 1
        }
    }

    private func inlineText(from children: MarkupChildren) -> MarkdownInlineText {
        var builder = InlineTextBuilder()
        children.forEach { builder.append($0) }
        return builder.build()
    }

    private func sourceByteRange(
        for markup: Markup,
        lineIndex: SourceLineByteIndex,
        baseByteOffset: Int
    ) -> Range<Int>? {
        guard let range = markup.range else {
            return nil
        }

        let lower = lineIndex.byteOffset(for: range.lowerBound)
        let upper = lineIndex.byteOffset(for: range.upperBound)
        return (baseByteOffset + lower)..<(baseByteOffset + max(lower, upper))
    }

    private func markdownAlignment(from alignment: Table.ColumnAlignment?) -> MarkdownColumnAlignment {
        switch alignment {
        case .center:
            return .center
        case .right:
            return .trailing
        default:
            return .leading
        }
    }

    private func openTailStartByteOffset(
        for blocks: [MarkdownBlock],
        in content: String,
        baseByteOffset: Int
    ) -> Int {
        // Markdown 的列表、引用、setext 标题会被后续行“回头改写”。
        // 增量解析只冻结最后一个顶层块之前的内容，最后一个块始终随流式尾部重算，换取正确性和稳定性能。
        let rangedBlocks = blocks.compactMap { block -> (block: MarkdownBlock, range: Range<Int>)? in
            guard let range = block.sourceByteRange, range.upperBound > range.lowerBound else {
                return nil
            }
            return (block, range)
        }

        guard let last = rangedBlocks.last,
              let lastRange = last.block.sourceByteRange,
              lastRange.upperBound > lastRange.lowerBound else {
            return baseByteOffset
        }

        if let previous = rangedBlocks.dropLast().last,
           shouldReparsePreviousBlock(previous.block, before: last.block, in: content, baseByteOffset: baseByteOffset) {
            return max(baseByteOffset, previous.range.lowerBound)
        }

        return max(baseByteOffset, lastRange.lowerBound)
    }

    private func shouldReparsePreviousBlock(
        _ previous: MarkdownBlock,
        before last: MarkdownBlock,
        in content: String,
        baseByteOffset: Int
    ) -> Bool {
        guard case .table = previous.kind,
              case .paragraph = last.kind,
              let previousRange = previous.sourceByteRange,
              let lastRange = last.sourceByteRange else {
            return false
        }

        let bytes = Array(content.utf8)
        let gapStart = min(max(previousRange.upperBound - baseByteOffset, 0), bytes.count)
        let gapEnd = min(max(lastRange.lowerBound - baseByteOffset, 0), bytes.count)
        guard gapStart < gapEnd else {
            return true
        }

        // GFM 表格行逐字输出时，半行经常会短暂变成 table 后面的 paragraph；
        // 如果两者之间没有空行，说明这段 paragraph 仍可能并回 table。
        return !containsBlankLine(in: bytes[gapStart..<gapEnd])
    }

    private func containsBlankLine(in bytes: ArraySlice<UInt8>) -> Bool {
        var sawLineBreak = false
        var onlyWhitespaceAfterLineBreak = true

        for byte in bytes {
            if byte == UInt8(ascii: "\n") {
                if sawLineBreak && onlyWhitespaceAfterLineBreak {
                    return true
                }
                sawLineBreak = true
                onlyWhitespaceAfterLineBreak = true
            } else if sawLineBreak, byte != UInt8(ascii: " "), byte != UInt8(ascii: "\t"), byte != UInt8(ascii: "\r") {
                onlyWhitespaceAfterLineBreak = false
            }
        }

        return false
    }
}

private struct SourceLineByteIndex {
    private let lineStartByteOffsets: [Int]

    init(_ content: String) {
        var offsets = [0]
        var byteOffset = 0
        for byte in content.utf8 {
            byteOffset += 1
            if byte == UInt8(ascii: "\n") {
                offsets.append(byteOffset)
            }
        }
        lineStartByteOffsets = offsets
    }

    func byteOffset(for location: SourceLocation) -> Int {
        let lineIndex = max(0, min(location.line - 1, lineStartByteOffsets.count - 1))
        let lineStart = lineStartByteOffsets[lineIndex]
        return lineStart + max(0, location.column - 1)
    }
}

private struct InlineTextBuilder {
    private var attributed = AttributedString("")
    private var plain = ""
    private var hasFormatting = false

    mutating func append(_ markup: Markup, intent: InlinePresentationIntent = [], link: URL? = nil) {
        switch markup {
        case let text as Markdown.Text:
            append(text.string, intent: intent, link: link)
        case let code as InlineCode:
            var nextIntent = intent
            nextIntent.insert(.code)
            append(code.code, intent: nextIntent, link: link)
        case let softBreak as SoftBreak:
            append(softBreak.plainText, intent: intent, link: link)
        case let lineBreak as LineBreak:
            append(lineBreak.plainText, intent: intent, link: link)
        case let strong as Strong:
            var nextIntent = intent
            nextIntent.insert(.stronglyEmphasized)
            strong.children.forEach { append($0, intent: nextIntent, link: link) }
        case let emphasis as Emphasis:
            var nextIntent = intent
            nextIntent.insert(.emphasized)
            emphasis.children.forEach { append($0, intent: nextIntent, link: link) }
        case let strikethrough as Strikethrough:
            var nextIntent = intent
            nextIntent.insert(.strikethrough)
            strikethrough.children.forEach { append($0, intent: nextIntent, link: link) }
        case let markdownLink as Link:
            let safeLink = markdownLink.destination.flatMap(URL.init(string:)).flatMap { url in
                MarkdownLinkPolicy.isAllowed(url) ? url : nil
            }
            markdownLink.children.forEach { append($0, intent: intent, link: safeLink ?? link) }
        case let image as Markdown.Image:
            image.children.forEach { append($0, intent: intent, link: link) }
        case let html as InlineHTML:
            append(html.rawHTML, intent: intent, link: link)
        case let symbol as SymbolLink:
            var nextIntent = intent
            nextIntent.insert(.code)
            append(symbol.destination ?? "", intent: nextIntent, link: link)
        default:
            markup.children.forEach { append($0, intent: intent, link: link) }
        }
    }

    func build() -> MarkdownInlineText {
        MarkdownInlineText(attributed: attributed, plain: plain, hasFormatting: hasFormatting)
    }

    private mutating func append(_ text: String, intent: InlinePresentationIntent, link: URL?) {
        guard !text.isEmpty else {
            return
        }

        var fragment = AttributedString(text)
        if !intent.isEmpty {
            fragment.inlinePresentationIntent = intent
        }
        if let link {
            fragment.link = link
        }

        hasFormatting = hasFormatting || !intent.isEmpty || link != nil
        attributed += fragment
        plain += text
    }
}

private enum MarkdownLinkPolicy {
    static func isAllowed(_ url: URL) -> Bool {
        // 原生端不承担任意 scheme 跳转能力，Markdown 链接只开放常规网页与邮件入口。
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https" || scheme == "mailto"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
