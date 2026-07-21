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
        case let .proposedPlan(blocks, isComplete):
            proposedPlan(blocks: blocks, isComplete: isComplete)
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
                .help(L10n.text("ui.copy_code"))
                .accessibilityLabel(L10n.text("ui.copy_code"))
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

    private func proposedPlan(blocks: [MarkdownBlock], isComplete: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "list.clipboard")
                    .font(style.captionFont.weight(.semibold))
                    .foregroundStyle(style.linkColor)
                Text(L10n.text("ui.plan"))
                    .font(style.captionFont.weight(.semibold))
                    .foregroundStyle(style.secondaryColor)
                if !isComplete {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(style.linkColor)
                }
            }

            VStack(alignment: .leading, spacing: style.blockSpacing) {
                ForEach(blocks) { child in
                    MarkdownBlockView(block: child, style: style)
                }
            }
        }
        .padding(9)
        .background(style.planCardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(style.planCardBorder)
        }
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
    case dataURL(value: String, digest: String)
    case remoteURL(URL)
    case localPath(String)
    case historyMedia(id: String)
    case unsupported(String)

    var id: String {
        switch self {
        case .dataURL(_, let digest):
            return "data:\(digest)"
        case .remoteURL(let url):
            return "remote:\(url.absoluteString)"
        case .localPath(let path):
            return "local:\(path)"
        case .historyMedia(let id):
            return "historyMedia:\(id)"
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
            return .dataURL(value: trimmed, digest: stableDigest(trimmed))
        }
        if let id = historyMediaID(from: trimmed) {
            return .historyMedia(id: id)
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

    private static func historyMediaID(from value: String) -> String? {
        let prefix = "agentd-history-media://"
        guard value.hasPrefix(prefix) else {
            return nil
        }
        let id = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
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
    @State private var embeddedImage: UIImage?
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
    var fillsAvailableWidth = false

    init(
        source: ConversationImageSource,
        title: String?,
        style: MarkdownStyle,
        maxHeight: CGFloat = 280,
        showsCaption: Bool = true,
        fillsAvailableWidth: Bool = false
    ) {
        self.source = source
        self.title = title
        self.style = style
        self.maxHeight = maxHeight
        self.showsCaption = showsCaption
        self.fillsAvailableWidth = fillsAvailableWidth
        _embeddedImage = State(
            initialValue: DataURLImageDecoder.cachedImage(
                cacheKey: source.id,
                maxPixelSize: 1_600
            )
        )
    }

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
        .task(id: source.id) {
            await loadSourceIfNeeded()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch source {
        case .dataURL:
            if let image = embeddedImage {
                imageView(Image(uiImage: image))
            } else if isLoadingLocalImage {
                loadingPlaceholder
            } else {
                fallback(L10n.text("ui.image_data_cannot_be_decoded"), detail: "data:image/...")
            }
        case .remoteURL(let url):
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    loadingPlaceholder
                case .success(let image):
                    imageView(image)
                case .failure:
                    fallback(L10n.text("ui.image_loading_failed"), detail: url.absoluteString)
                @unknown default:
                    fallback(L10n.text("ui.image_loading_failed"), detail: url.absoluteString)
                }
            }
        case .localPath(let path):
            localImageContent(path: path)
                .task(id: path) {
                    await loadLocalImage(path: path)
                }
        case .historyMedia(let id):
            historyMediaContent(id: id)
        case .unsupported(let value):
            fallback(L10n.text("ui.this_image_address_is_not_supported_yet"), detail: compactSource(value))
        }
    }

    @MainActor
    private func loadSourceIfNeeded() async {
        let expectedSourceID = source.id
        switch source {
        case .dataURL(let value, _):
            loadError = nil
            if let cached = DataURLImageDecoder.cachedImage(
                cacheKey: expectedSourceID,
                maxPixelSize: 1_600
            ) {
                embeddedImage = cached
                isLoadingLocalImage = false
                return
            }
            embeddedImage = nil
            isLoadingLocalImage = true
            let image = await DataURLImageDecoder.image(
                from: value,
                cacheKey: expectedSourceID,
                maxPixelSize: 1_600
            )
            guard !Task.isCancelled, source.id == expectedSourceID else {
                return
            }
            embeddedImage = image
            isLoadingLocalImage = false
        case .historyMedia(let id):
            embeddedImage = nil
            isLoadingLocalImage = false
            // history-media 默认接口返回 1600px 内的派生图；只在图片进入可见区域时加载。
            await loadHistoryMedia(id: id)
        case .remoteURL, .localPath, .unsupported:
            embeddedImage = nil
            isLoadingLocalImage = false
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
                .accessibilityLabel(L10n.text("ui.preview_picture"))
            } else if isLoadingLocalImage {
                loadingPlaceholder
            } else {
                fallback(loadError ?? L10n.text("ui.image_not_loaded_yet"), detail: URL(fileURLWithPath: path).lastPathComponent)
            }
        }
    }

    private func historyMediaContent(id: String) -> some View {
        Group {
            if let localImage {
                Button {
                    quickLookURL = localFileURL
                } label: {
                    imageView(Image(uiImage: localImage))
                }
                .buttonStyle(.plain)
                .disabled(localFileURL == nil)
                .accessibilityLabel(L10n.text("ui.preview_historical_pictures"))
            } else if isLoadingLocalImage {
                loadingPlaceholder
            } else {
                Button {
                    Task {
                        await loadHistoryMedia(id: id)
                    }
                } label: {
                    fallback(loadError == nil ? L10n.text("ui.historical_images_not_loaded") : L10n.text("ui.failed_to_load_historical_images"), detail: loadError ?? L10n.text("ui.click_to_load"))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("ui.load_historical_images"))
            }
        }
    }

    private func imageView(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            // 普通 Markdown 图片保持自然宽度；用户多图消息使用统一的中性画布，
            // 避免不同宽高比让紫色消息底色露出一大块不对称空白。
            .frame(
                maxWidth: fillsAvailableWidth ? .infinity : nil,
                maxHeight: maxHeight,
                alignment: fillsAvailableWidth ? .center : .leading
            )
            .padding(fillsAvailableWidth ? 4 : 0)
            .background(
                fillsAvailableWidth ? style.tableBackground : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
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
            Text(L10n.text("ui.picture_loading"))
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
            loadError = L10n.text("ui.the_local_path_is_empty_and_the_image")
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
            guard let image = await DataURLImageDecoder.image(
                fromFileURL: url,
                cacheKey: "local:\(targetPath)",
                maxPixelSize: 1_600
            ) else {
                loadError = L10n.text("ui.the_file_was_read_but_could_not_be")
                return
            }
            localFileURL = url
            localImage = image
        } catch {
            loadError = userFacingPreviewError(error)
        }
    }

    @MainActor
    private func loadHistoryMedia(id: String) async {
        let targetID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetID.isEmpty else {
            loadError = L10n.text("ui.the_historical_image_id_is_empty_and_cannot")
            return
        }

        localImage = nil
        localFileURL = nil
        loadError = nil
        isLoadingLocalImage = true
        defer { isLoadingLocalImage = false }

        do {
            // 历史图片首屏只保留短 ID；用户点按时再从 agentd 短期缓存取回原始二进制。
            let url = try await sessionStore.previewHistoryMedia(id: targetID)
            guard !Task.isCancelled else {
                return
            }
            guard let image = await DataURLImageDecoder.image(
                fromFileURL: url,
                cacheKey: "historyMedia:\(targetID)",
                maxPixelSize: 1_600
            ) else {
                loadError = L10n.text("ui.historical_pictures_were_read_but_could_not_be")
                return
            }
            localFileURL = url
            localImage = image
        } catch is CancellationError {
            return
        } catch {
            loadError = userFacingHistoryMediaError(error)
        }
    }

    private func userFacingPreviewError(_ error: Error) -> String {
        if case AgentAPIError.server(let status, _) = error, status == 404 || status == 405 {
            return L10n.text("ui.the_current_agentd_version_does_not_support_file")
        }
        if case AgentAPIError.server(let status, _) = error, status == 403 {
            return L10n.text("ui.the_file_is_not_within_authorization_or_is")
        }
        if case AgentAPIError.server(let status, _) = error, status == 413 {
            return L10n.text("ui.the_file_is_too_large_and_preview_is")
        }
        return error.localizedDescription
    }

    private func userFacingHistoryMediaError(_ error: Error) -> String {
        if case AgentAPIError.server(let status, _) = error, status == 404 {
            return L10n.text("ui.the_historical_image_cache_has_expired_please_refresh")
        }
        if case AgentAPIError.server(let status, _) = error, status == 405 {
            return L10n.text("ui.the_current_agentd_version_does_not_support_on")
        }
        return userFacingPreviewError(error)
    }

    private func compactSource(_ value: String) -> String {
        if value.range(of: "data:image/", options: [.anchored, .caseInsensitive]) != nil {
            return "data:image/..."
        }
        if ConversationImageSource.markdown(value).id.hasPrefix("historyMedia:") {
            return "agentd-history-media://..."
        }
        return value
    }

}
