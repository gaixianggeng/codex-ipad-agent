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
        case let .image(reference):
            ConversationImagePreview(
                source: .markdown(reference.source),
                title: reference.displayText,
                style: style
            )
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

enum ConversationImageSource: Hashable, Identifiable {
    case dataURL(String)
    case remoteURL(URL)
    case localPath(String)
    case unsupported(String)

    var id: String {
        switch self {
        case .dataURL(let value):
            return "data:\(Self.stableDigest(value))"
        case .remoteURL(let url):
            return "remote:\(url.absoluteString)"
        case .localPath(let path):
            return "local:\(path)"
        case .unsupported(let value):
            return "unsupported:\(value)"
        }
    }

    static func input(_ item: CodexAppServerUserInput) -> ConversationImageSource? {
        switch item {
        case .image(let url, _):
            return markdown(url)
        case .localImage(let path, _):
            return .localPath(path.trimmingCharacters(in: .whitespacesAndNewlines))
        case .text, .skill, .mention:
            return nil
        }
    }

    static func markdown(_ source: String) -> ConversationImageSource {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .unsupported(source)
        }
        if trimmed.range(of: "data:image/", options: [.anchored, .caseInsensitive]) != nil {
            return .dataURL(trimmed)
        }
        if let localPath = localFilePath(from: trimmed) {
            return .localPath(localPath)
        }
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return .remoteURL(url)
        }
        return .unsupported(trimmed)
    }

    private static func localFilePath(from value: String) -> String? {
        if value.hasPrefix("/") {
            return value
        }
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "file",
              !url.path.isEmpty
        else {
            return nil
        }
        return url.path
    }

    private static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

struct ConversationImagePreview: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @State private var localImage: UIImage?
    @State private var localFileURL: URL?
    @State private var quickLookURL: URL?
    @State private var isLoadingLocalImage = false
    @State private var loadError: String?

    let source: ConversationImageSource
    let title: String?
    let style: MarkdownStyle
    var maxHeight: CGFloat = 280
    var showsCaption = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
            if showsCaption, let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                Text(title)
                    .font(style.captionFont)
                    .foregroundStyle(style.secondaryColor)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .quickLookPreview($quickLookURL)
    }

    @ViewBuilder
    private var content: some View {
        switch source {
        case .dataURL(let value):
            if let image = Self.image(fromDataURL: value) {
                imageView(Image(uiImage: image))
            } else {
                fallback("图片数据无法解码", detail: "data:image/...")
            }
        case .remoteURL(let url):
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    loadingPlaceholder
                case .success(let image):
                    imageView(image)
                case .failure:
                    fallback("图片加载失败", detail: url.absoluteString)
                @unknown default:
                    fallback("图片加载失败", detail: url.absoluteString)
                }
            }
        case .localPath(let path):
            localImageContent(path: path)
                .task(id: path) {
                    await loadLocalImage(path: path)
                }
        case .unsupported(let value):
            fallback("暂不支持这个图片地址", detail: compactSource(value))
        }
    }

    private func localImageContent(path: String) -> some View {
        Group {
            if let localImage {
                Button {
                    quickLookURL = localFileURL
                } label: {
                    imageView(Image(uiImage: localImage))
                }
                .buttonStyle(.plain)
                .disabled(localFileURL == nil)
                .accessibilityLabel("预览图片")
            } else if isLoadingLocalImage {
                loadingPlaceholder
            } else {
                fallback(loadError ?? "图片尚未加载", detail: URL(fileURLWithPath: path).lastPathComponent)
            }
        }
    }

    private func imageView(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(style.dividerColor, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var loadingPlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("图片加载中")
                .font(style.captionFont)
        }
        .foregroundStyle(style.secondaryColor)
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(style.tableBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(style.dividerColor, lineWidth: 1)
        }
    }

    private func fallback(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "photo")
                .font(style.captionFont.weight(.semibold))
            Text(detail)
                .font(style.captionFont)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .foregroundStyle(style.secondaryColor)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.tableBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(style.dividerColor, lineWidth: 1)
        }
    }

    @MainActor
    private func loadLocalImage(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            loadError = "本机路径为空，无法加载图片。"
            return
        }

        localImage = nil
        localFileURL = nil
        loadError = nil
        isLoadingLocalImage = true
        defer { isLoadingLocalImage = false }

        do {
            // 本机路径只代表 Mac/agentd 可读文件，iPad 端必须走 agentd 的授权文件读取接口；
            // 这样既能内嵌展示，也不会绕过后端的 projects/browse_roots 边界检查。
            let url = try await sessionStore.previewFile(path: targetPath)
            guard !Task.isCancelled else {
                return
            }
            guard let image = UIImage(contentsOfFile: url.path) else {
                loadError = "文件已读取，但无法按图片解码。"
                return
            }
            localFileURL = url
            localImage = image
        } catch {
            loadError = userFacingPreviewError(error)
        }
    }

    private func userFacingPreviewError(_ error: Error) -> String {
        if case AgentAPIError.server(let status, _) = error, status == 404 || status == 405 {
            return "当前 agentd 版本还不支持文件预览，请升级 agentd。"
        }
        if case AgentAPIError.server(let status, _) = error, status == 403 {
            return "该文件不在授权范围内或不可访问。"
        }
        if case AgentAPIError.server(let status, _) = error, status == 413 {
            return "文件过大，暂不支持预览。"
        }
        return error.localizedDescription
    }

    private func compactSource(_ value: String) -> String {
        if value.range(of: "data:image/", options: [.anchored, .caseInsensitive]) != nil {
            return "data:image/..."
        }
        return value
    }

    private static func image(fromDataURL value: String) -> UIImage? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "data:image/", options: [.anchored, .caseInsensitive]) != nil,
              let comma = trimmed.firstIndex(of: ",")
        else {
            return nil
        }
        let payload = trimmed[trimmed.index(after: comma)...]
        guard let data = Data(base64Encoded: String(payload), options: [.ignoreUnknownCharacters]) else {
            return nil
        }
        return UIImage(data: data)
    }
}
