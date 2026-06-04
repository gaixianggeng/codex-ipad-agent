import SwiftUI
import UIKit

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let style: MarkdownStyle

    var body: some View {
        blockView(block)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case let .paragraph(inline):
            inlineText(inline)
        case let .heading(level, inline):
            inlineText(inline, font: style.headingFont(level: level))
                .padding(.top, level <= 2 ? 4 : 2)
        case let .bulletList(items, tight):
            listStack(items: items, tight: tight) { _, item in
                if let checked = item.checkbox {
                    taskCheckbox(checked)
                } else {
                    Text("•")
                        .font(style.bodyFont.weight(.semibold))
                        .foregroundStyle(style.secondaryColor)
                        .frame(width: 20, alignment: .trailing)
                }
            }
        case let .orderedList(start, items, tight):
            listStack(items: items, tight: tight) { index, item in
                if let checked = item.checkbox {
                    taskCheckbox(checked, width: 30)
                } else {
                    Text("\(start + index).")
                        .font(style.bodyFont)
                        .foregroundStyle(style.secondaryColor)
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                }
            }
        case let .taskList(items):
            taskList(items)
        case let .blockquote(blocks):
            blockquote(blocks)
        case let .codeBlock(language, code):
            codeBlock(language: language, code: code)
        case let .table(header, rows, alignments):
            table(header: header, rows: rows, alignments: alignments)
        case .thematicBreak:
            Divider()
                .overlay(style.dividerColor)
        }
    }

    @ViewBuilder
    private func inlineText(_ inline: MarkdownInlineText, font: Font? = nil, expand: Bool = false) -> some View {
        let text = Text(inline.attributed)
            .font(font ?? style.bodyFont)
            .foregroundStyle(style.textColor)
            .tint(style.linkColor)
            .lineSpacing(style.textLineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)

        if expand {
            text.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            text
        }
    }

    private func listStack<Marker: View>(
        items: [MarkdownListItem],
        tight: Bool,
        @ViewBuilder marker: @escaping (Int, MarkdownListItem) -> Marker
    ) -> some View {
        VStack(alignment: .leading, spacing: tight ? 4 : 8) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: 8) {
                    marker(index, item)
                    VStack(alignment: .leading, spacing: tight ? 3 : style.blockSpacing) {
                        ForEach(item.blocks) { child in
                            MarkdownBlockView(block: child, style: style)
                        }
                    }
                }
            }
        }
    }

    private func taskList(_ items: [MarkdownTaskListItem]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    taskCheckbox(item.checked)

                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(item.blocks) { child in
                            MarkdownBlockView(block: child, style: style)
                        }
                    }
                }
            }
        }
    }

    private func taskCheckbox(_ checked: Bool, width: CGFloat = 20) -> some View {
        Image(systemName: checked ? "checkmark.square.fill" : "square")
            .font(style.bodyFont)
            .foregroundStyle(checked ? style.linkColor : style.secondaryColor)
            .frame(width: width, alignment: .trailing)
    }

    private func blockquote(_ blocks: [MarkdownBlock]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(style.quoteBar)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: style.blockSpacing) {
                ForEach(blocks) { child in
                    MarkdownBlockView(block: child, style: style)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func codeBlock(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if let language {
                    Text(language)
                        .font(style.captionFont)
                        .foregroundStyle(style.codeForeground.opacity(0.72))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(style.codeForeground.opacity(0.72))
                .help("复制代码")
                .accessibilityLabel("复制代码")
            }

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(style.codeFont)
                    .foregroundStyle(style.codeForeground)
                    .lineSpacing(1.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(style.codeBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func table(
        header: [MarkdownInlineText],
        rows: [[MarkdownInlineText]],
        alignments: [MarkdownColumnAlignment]
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { index, cell in
                        inlineText(cell, font: style.bodyFont.weight(.semibold), expand: true)
                            .frame(minWidth: 96, alignment: alignment(for: alignments, index: index))
                    }
                }

                Divider()
                    .overlay(style.dividerColor)
                    .gridCellColumns(max(header.count, 1))

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<max(header.count, row.count), id: \.self) { index in
                            inlineText(index < row.count ? row[index] : .empty, expand: true)
                                .frame(minWidth: 96, alignment: alignment(for: alignments, index: index))
                        }
                    }
                }
            }
            .padding(8)
            .background(style.tableBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func alignment(for alignments: [MarkdownColumnAlignment], index: Int) -> Alignment {
        guard index < alignments.count else {
            return .leading
        }

        switch alignments[index] {
        case .leading:
            return .leading
        case .center:
            return .center
        case .trailing:
            return .trailing
        }
    }
}
