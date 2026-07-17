import PhotosUI
import QuickLook
import SwiftUI
import UIKit

struct AttachmentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var previewURL: URL?
    @State private var embeddedImage: UIImage?
    @State private var isLoadingEmbeddedImage = false
    @State private var previewingLocalImagePath: String?
    @State private var localImagePreviewError: String?

    let item: CodexAppServerUserInput

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    previewContent(tokens: tokens)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(tokens.surface)
            .navigationTitle("附件预览")
            .navigationBarTitleDisplayMode(.inline)
            .quickLookPreview($previewURL)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task(id: previewImageSource?.id) {
            await loadEmbeddedImageIfNeeded()
        }
    }

    @ViewBuilder
    private func previewContent(tokens: ThemeTokens) -> some View {
        switch item {
        case .image(let url, _):
            if let image = embeddedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if isLoadingEmbeddedImage {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else if let remoteURL = URL(string: url),
                      let scheme = remoteURL.scheme?.lowercased(),
                      ["http", "https"].contains(scheme) {
                AsyncImage(url: remoteURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 180)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    case .failure:
                        previewMessage("图片加载失败", detail: url, tokens: tokens)
                    @unknown default:
                        previewMessage("图片加载失败", detail: url, tokens: tokens)
                    }
                }
            } else {
                previewMessage("无法预览这个图片引用", detail: url, tokens: tokens)
            }
        case .localImage(let path, _):
            localImagePreview(path: path, tokens: tokens)
        case .text(let text, _):
            previewMessage("文本附件", detail: text, tokens: tokens)
        case .skill(let name, let path):
            previewMessage("$\(name)", detail: path, tokens: tokens)
        case .mention(let name, let path):
            previewMessage("@\(name)", detail: path, tokens: tokens)
        }
    }

    private var previewImageSource: ConversationImageSource? {
        ConversationImageSource.input(item)
    }

    @MainActor
    private func loadEmbeddedImageIfNeeded() async {
        embeddedImage = nil
        isLoadingEmbeddedImage = false
        guard case .dataURL(let value) = previewImageSource else {
            return
        }
        let expectedSourceID = previewImageSource?.id
        guard let expectedSourceID else {
            return
        }
        isLoadingEmbeddedImage = true
        let image = await DataURLImageDecoder.image(
            from: value,
            cacheKey: expectedSourceID,
            maxPixelSize: 2_400
        )
        guard !Task.isCancelled, previewImageSource?.id == expectedSourceID else {
            return
        }
        embeddedImage = image
        isLoadingEmbeddedImage = false
    }

    private func localImagePreview(path: String, tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            previewMessage(
                "本机图片路径",
                detail: path + "\n发送时由本机 agentd 读取；也可以通过 agentd 安全读取授权范围内的文件并用 QuickLook 预览。",
                tokens: tokens
            )
            Button {
                Task { await previewLocalImage(path: path) }
            } label: {
                if previewingLocalImagePath == path {
                    Label("正在预览", systemImage: "hourglass")
                } else {
                    Label("预览文件", systemImage: "eye")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(previewingLocalImagePath != nil || path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let localImagePreviewError {
                Text(localImagePreviewError)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func previewLocalImage(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            localImagePreviewError = "本机路径为空，无法预览。"
            return
        }

        previewingLocalImagePath = targetPath
        localImagePreviewError = nil
        defer {
            if previewingLocalImagePath == targetPath {
                previewingLocalImagePath = nil
            }
        }
        do {
            previewURL = try await sessionStore.previewFile(path: targetPath)
        } catch {
            localImagePreviewError = userFacingPreviewError(error)
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

    private func previewMessage(_ title: String, detail: String, tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "photo")
                .font(themeStore.uiFont(.headline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
            Text(detail)
                .font(themeStore.codeFont(.caption))
                .foregroundStyle(tokens.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

struct PhotoLibraryPickerRequest: Identifiable {
    let id = UUID()
    let selectionLimit: Int
    let targetScope: ComposerDraftScopeKey
}

enum PhotoLibraryPickerError: LocalizedError {
    case unsupportedImage
    case unreadableImage

    var errorDescription: String? {
        switch self {
        case .unsupportedImage:
            return "所选项目不是支持的图片"
        case .unreadableImage:
            return "无法读取所选图片"
        }
    }
}

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let selectionLimit: Int
    let onFinish: ([PHPickerResult]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        let configuration = Self.makeConfiguration(selectionLimit: selectionLimit)

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    static func makeConfiguration(selectionLimit: Int) -> PHPickerConfiguration {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = max(1, selectionLimit)
        configuration.selection = .ordered
        return configuration
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var onFinish: ([PHPickerResult]) -> Void

        init(onFinish: @escaping ([PHPickerResult]) -> Void) {
            self.onFinish = onFinish
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // PHPicker 只在用户点击“添加/取消”后进入这里，因此一次回传完整有序选择。
            onFinish(results)
        }
    }
}

enum AddContentPanelPage: Equatable {
    case root
    case plugins
    case skills
    case shortcuts
}

struct AddContentPanel: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: AddContentPanelPage = .root
    @State private var searchText = ""

    let skillShortcuts: [SkillCapability]
    let pluginShortcuts: [CodexPluginCapability]
    let capabilityErrorMessage: String?
    let isRefreshingCapabilities: Bool
    let onPickPhotos: () -> Void
    let onSkillShortcut: (SkillCapability) -> Void
    let onPluginShortcut: (CodexPluginCapability) -> Void
    let onRefreshCapabilities: () -> Void
    let onShortcut: (String) -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(spacing: 0) {
            panelHeader(tokens: tokens)
                .padding(.bottom, 12)

            Group {
                switch page {
                case .root:
                    rootActions(tokens: tokens)
                case .plugins:
                    pluginList(tokens: tokens)
                case .skills:
                    skillList(tokens: tokens)
                case .shortcuts:
                    shortcutList(tokens: tokens)
                }
            }
            .transition(
                reduceMotion
                    ? .opacity
                    : .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    )
            )
        }
        .padding(16)
        .frame(minWidth: 320, idealWidth: 390, maxWidth: 420)
        .background(tokens.surface)
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 1),
            value: page
        )
        // compact adaptation 默认会拉成大页；固定内容高度能消除“下半屏全空”的原始感。
        .presentationDetents([.height(page == .root ? 390 : 470)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    private func panelHeader(tokens: ThemeTokens) -> some View {
        HStack(spacing: 10) {
            if page != .root {
                Button {
                    searchText = ""
                    page = .root
                } label: {
                    Image(systemName: "chevron.left")
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(tokens.selectionFill, in: Circle())
                }
                .buttonStyle(ComposerPressButtonStyle(reduceMotion: reduceMotion))
                .accessibilityLabel("返回添加内容")
            } else {
                Image(systemName: "plus")
                    .font(themeStore.uiFont(.callout, weight: .bold))
                    .foregroundStyle(tokens.accent)
                    .frame(width: 34, height: 34)
                    .background(tokens.selectionFill, in: Circle())
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(pageTitle)
                    .font(themeStore.uiFont(.headline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(pageSubtitle)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(themeStore.uiFont(.caption, weight: .bold))
                    .foregroundStyle(tokens.secondaryText)
                    .frame(width: 32, height: 32)
                    .background(tokens.selectionFill.opacity(0.72), in: Circle())
            }
            .buttonStyle(ComposerPressButtonStyle(reduceMotion: reduceMotion))
            .accessibilityLabel("关闭添加内容")
        }
    }

    private func rootActions(tokens: ThemeTokens) -> some View {
        VStack(spacing: 8) {
            panelActionButton(
                title: "图片",
                subtitle: "从照片图库选择，可多选",
                systemImage: "photo.on.rectangle.angled",
                tokens: tokens,
                action: onPickPhotos
            )
            panelActionButton(
                title: "@ 插件",
                subtitle: pluginShortcuts.isEmpty ? "查看已安装的 Codex 插件" : "\(pluginShortcuts.count) 个已安装插件",
                systemImage: "at",
                tokens: tokens
            ) {
                page = .plugins
            }
            panelActionButton(
                title: "Skill",
                subtitle: skillShortcuts.isEmpty ? "添加结构化工作流" : "\(skillShortcuts.count) 个可用 Skill",
                systemImage: "wand.and.stars",
                tokens: tokens
            ) {
                page = .skills
            }
            panelActionButton(
                title: "快捷短语",
                subtitle: "插入常用任务模板",
                systemImage: "bolt.fill",
                tokens: tokens
            ) {
                page = .shortcuts
            }
        }
    }

    private func panelActionButton(
        title: String,
        subtitle: String,
        systemImage: String,
        tokens: ThemeTokens,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(themeStore.uiFont(size: 17, weight: .semibold))
                    .foregroundStyle(tokens.accent)
                    .frame(width: 38, height: 38)
                    .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(subtitle)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(themeStore.uiFont(.caption2, weight: .bold))
                    .foregroundStyle(tokens.tertiaryText)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(tokens.border.opacity(0.72), lineWidth: 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(ComposerPressButtonStyle(reduceMotion: reduceMotion))
    }

    private func pluginList(tokens: ThemeTokens) -> some View {
        VStack(spacing: 10) {
            searchField(placeholder: "搜索插件", tokens: tokens)
            if filteredPlugins.isEmpty {
                emptyCapabilities(
                    title: searchText.isEmpty ? "暂无已安装插件" : "没有匹配的插件",
                    detail: searchText.isEmpty ? "请先在 Mac 端安装并启用 Codex 插件" : "换个名称试试",
                    tokens: tokens
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(filteredPlugins) { plugin in
                            Button {
                                onPluginShortcut(plugin)
                            } label: {
                                HStack(spacing: 11) {
                                    pluginIcon(tokens: tokens)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("@\(plugin.presentationName)")
                                            .font(themeStore.uiFont(.callout, weight: .semibold))
                                            .foregroundStyle(tokens.primaryText)
                                            .lineLimit(1)
                                        Text(pluginSubtitle(plugin))
                                            .font(themeStore.uiFont(.caption))
                                            .foregroundStyle(tokens.secondaryText)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    if plugin.enabled {
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundStyle(tokens.accent)
                                    } else {
                                        Text("已停用")
                                            .font(themeStore.uiFont(.caption2, weight: .semibold))
                                            .foregroundStyle(tokens.tertiaryText)
                                    }
                                }
                                .padding(10)
                                .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(ComposerPressButtonStyle(reduceMotion: reduceMotion))
                            .disabled(!plugin.enabled)
                            .opacity(plugin.enabled ? 1 : 0.58)
                        }
                    }
                }
                .frame(maxHeight: 320)
                .scrollIndicators(.hidden)
            }
        }
    }

    private func skillList(tokens: ThemeTokens) -> some View {
        VStack(spacing: 10) {
            searchField(placeholder: "搜索 Skill", tokens: tokens)
            if filteredSkills.isEmpty {
                emptyCapabilities(
                    title: searchText.isEmpty ? "暂无可用 Skill" : "没有匹配的 Skill",
                    detail: searchText.isEmpty ? "刷新后仍为空时，请检查 Mac 端配置" : "换个名称试试",
                    tokens: tokens
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(filteredSkills) { skill in
                            Button {
                                onSkillShortcut(skill)
                            } label: {
                                HStack(spacing: 11) {
                                    SkillIconView(metadata: SkillVisualMetadata(capability: skill), size: 38)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("$\(skill.presentationName)")
                                            .font(themeStore.uiFont(.callout, weight: .semibold))
                                            .foregroundStyle(tokens.primaryText)
                                            .lineLimit(1)
                                        Text(skill.presentationDescription ?? "添加为结构化能力")
                                            .font(themeStore.uiFont(.caption))
                                            .foregroundStyle(tokens.secondaryText)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(tokens.accent)
                                }
                                .padding(10)
                                .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(ComposerPressButtonStyle(reduceMotion: reduceMotion))
                        }
                    }
                }
                .frame(maxHeight: 320)
                .scrollIndicators(.hidden)
            }
        }
    }

    private func shortcutList(tokens: ThemeTokens) -> some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                ForEach(Self.shortcuts, id: \.self) { shortcut in
                    Button {
                        onShortcut(shortcut)
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: "bolt.fill")
                                .font(themeStore.uiFont(.callout, weight: .semibold))
                                .foregroundStyle(tokens.accent)
                                .frame(width: 36, height: 36)
                                .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Text(shortcut)
                                .font(themeStore.uiFont(.callout, weight: .medium))
                                .foregroundStyle(tokens.primaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(tokens.accent)
                        }
                        .padding(10)
                        .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(ComposerPressButtonStyle(reduceMotion: reduceMotion))
                }
            }
        }
        .frame(maxHeight: 330)
        .scrollIndicators(.hidden)
    }

    private func searchField(placeholder: String, tokens: ThemeTokens) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(tokens.tertiaryText)
            TextField(placeholder, text: $searchText)
                .font(themeStore.uiFont(.callout))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(tokens.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 40)
        .background(tokens.selectionFill.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func emptyCapabilities(title: String, detail: String, tokens: ThemeTokens) -> some View {
        VStack(spacing: 8) {
            Image(systemName: page == .plugins ? "puzzlepiece.extension" : "wand.and.stars")
                .font(themeStore.uiFont(size: 24, weight: .medium))
                .foregroundStyle(tokens.tertiaryText)
            Text(title)
                .font(themeStore.uiFont(.callout, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
            Text(nonEmpty(capabilityErrorMessage) ?? detail)
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.secondaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if searchText.isEmpty {
                Button {
                    onRefreshCapabilities()
                } label: {
                    Label(isRefreshingCapabilities ? "刷新中" : "刷新列表", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshingCapabilities)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 230)
    }

    private func pluginIcon(tokens: ThemeTokens) -> some View {
        Image(systemName: "at")
            .font(themeStore.uiFont(size: 17, weight: .bold))
            .foregroundStyle(tokens.accent)
            .frame(width: 38, height: 38)
            .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var filteredPlugins: [CodexPluginCapability] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return pluginShortcuts }
        return pluginShortcuts.filter { plugin in
            plugin.presentationName.localizedCaseInsensitiveContains(query)
                || (plugin.description?.localizedCaseInsensitiveContains(query) ?? false)
                || plugin.marketplace.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredSkills: [SkillCapability] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return skillShortcuts }
        return skillShortcuts.filter { skill in
            skill.name.localizedCaseInsensitiveContains(query)
                || skill.presentationName.localizedCaseInsensitiveContains(query)
                || (skill.presentationDescription?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func pluginSubtitle(_ plugin: CodexPluginCapability) -> String {
        nonEmpty(plugin.description)
            ?? nonEmpty(plugin.marketplace)
            ?? "已安装插件"
    }

    private func nonEmpty(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private var pageTitle: String {
        switch page {
        case .root: return "添加内容"
        case .plugins: return "@ 插件"
        case .skills: return "选择 Skill"
        case .shortcuts: return "快捷短语"
        }
    }

    private var pageSubtitle: String {
        switch page {
        case .root: return "补充下一条消息的上下文"
        case .plugins: return "引用 Mac 端已安装的 Codex 插件"
        case .skills: return "选择后作为结构化能力发送"
        case .shortcuts: return "点按即可插入输入框"
        }
    }

    private static let shortcuts = [
        "检查这段实现并给出风险",
        "实现这个功能并补测试",
        "只做最小可运行版本，避免过度设计",
        "解释失败日志并给修复方案"
    ]
}
