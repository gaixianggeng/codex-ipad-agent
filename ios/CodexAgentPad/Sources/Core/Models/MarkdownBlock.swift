import Foundation

struct MarkdownInlineText: Hashable {
    let attributed: AttributedString
    let plain: String
    let hasFormatting: Bool

    static let empty = MarkdownInlineText(attributed: AttributedString(""), plain: "", hasFormatting: false)
}

enum MarkdownColumnAlignment: Hashable {
    case leading
    case center
    case trailing
}

struct MarkdownListItem: Identifiable, Hashable {
    let id: Int
    let checkbox: Bool?
    let blocks: [MarkdownBlock]

    static func == (lhs: MarkdownListItem, rhs: MarkdownListItem) -> Bool {
        lhs.checkbox == rhs.checkbox && lhs.blocks == rhs.blocks
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(checkbox)
        hasher.combine(blocks)
    }
}

struct MarkdownTaskListItem: Identifiable, Hashable {
    let id: Int
    let checked: Bool
    let blocks: [MarkdownBlock]

    static func == (lhs: MarkdownTaskListItem, rhs: MarkdownTaskListItem) -> Bool {
        lhs.checked == rhs.checked && lhs.blocks == rhs.blocks
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(checked)
        hasher.combine(blocks)
    }
}

struct MarkdownBlock: Identifiable, Hashable {
    enum Kind: Hashable {
        case paragraph(MarkdownInlineText)
        case heading(level: Int, MarkdownInlineText)
        case bulletList(items: [MarkdownListItem], tight: Bool)
        case orderedList(start: Int, items: [MarkdownListItem], tight: Bool)
        case taskList(items: [MarkdownTaskListItem])
        case blockquote(blocks: [MarkdownBlock])
        case codeBlock(language: String?, code: String)
        case table(header: [MarkdownInlineText], rows: [[MarkdownInlineText]], alignments: [MarkdownColumnAlignment])
        case thematicBreak
    }

    let id: Int
    let sourceByteRange: Range<Int>?
    let kind: Kind

    static func == (lhs: MarkdownBlock, rhs: MarkdownBlock) -> Bool {
        lhs.kind == rhs.kind
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
    }
}

struct MarkdownParseResult: Hashable {
    let blocks: [MarkdownBlock]
    let openTailByteOffset: Int
}
