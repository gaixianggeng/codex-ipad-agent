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
            .navigationTitle(L10n.text("ui.attachment_preview"))
            .navigationBarTitleDisplayMode(.inline)
            .quickLookPreview($previewURL)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.close")) { dismiss() }
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
                        previewMessage(L10n.text("ui.image_loading_failed"), detail: url, tokens: tokens)
                    @unknown default:
                        previewMessage(L10n.text("ui.image_loading_failed"), detail: url, tokens: tokens)
                    }
                }
            } else {
                previewMessage(L10n.text("ui.unable_to_preview_this_image_reference"), detail: url, tokens: tokens)
            }
        case .localImage(let path, _):
            localImagePreview(path: path, tokens: tokens)
        case .text(let text, _):
            previewMessage(L10n.text("ui.text_attachment"), detail: text, tokens: tokens)
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
                L10n.text("ui.native_image_path"),
                detail: path + L10n.text("ui.it_is_read_by_the_local_agentd_when"),
                tokens: tokens
            )
            Button {
                Task { await previewLocalImage(path: path) }
            } label: {
                if previewingLocalImagePath == path {
                    Label(L10n.text("ui.previewing"), systemImage: "hourglass")
                } else {
                    Label(L10n.text("ui.preview_file"), systemImage: "eye")
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
            localImagePreviewError = L10n.text("ui.the_local_path_is_empty_and_cannot_be")
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
            return L10n.text("ui.the_selected_item_is_not_a_supported_image")
        case .unreadableImage:
            return L10n.text("ui.unable_to_read_selected_image")
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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
        .frame(minWidth: 320, idealWidth: 390, maxWidth: 420, maxHeight: .infinity, alignment: .top)
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 1),
            value: page
        )
        // 整个 Sheet 只使用一层材质，避免内容区和底部留白分别落到不同的不透明背景上。
        // “降低透明度”开启时改回主题实色，保证文字与控件对比度。
        .presentationBackground {
            if reduceTransparency {
                tokens.surface
            } else {
                Rectangle()
                    .fill(.thinMaterial)
                    .overlay(tokens.surface.opacity(colorScheme == .light ? 0.28 : 0.20))
            }
        }
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
                .accessibilityLabel(L10n.text("ui.return_to_add_content"))
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
            .accessibilityLabel(L10n.text("ui.close_adding_content"))
        }
    }

    private func rootActions(tokens: ThemeTokens) -> some View {
        VStack(spacing: 8) {
            panelActionButton(
                title: L10n.text("ui.pictures"),
                subtitle: L10n.text("ui.select_from_photo_gallery_multiple_selections_possible"),
                systemImage: "photo.on.rectangle.angled",
                tokens: tokens,
                action: onPickPhotos
            )
            panelActionButton(
                title: L10n.text("ui.plugin"),
                subtitle: pluginShortcuts.isEmpty ? L10n.text("ui.view_installed_codex_plugins") : L10n.plural("ui.plugins_installed_count", count: pluginShortcuts.count),
                systemImage: "at",
                tokens: tokens
            ) {
                page = .plugins
            }
            panelActionButton(
                title: "Skill",
                subtitle: skillShortcuts.isEmpty ? L10n.text("ui.add_structured_workflow") : L10n.plural("ui.skills_available_count", count: skillShortcuts.count),
                systemImage: "wand.and.stars",
                tokens: tokens
            ) {
                page = .skills
            }
            panelActionButton(
                title: L10n.text("ui.shortcut_phrase"),
                subtitle: L10n.text("ui.insert_frequently_used_task_templates"),
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
            searchField(placeholder: L10n.text("ui.search_plugin"), tokens: tokens)
            if filteredPlugins.isEmpty {
                emptyCapabilities(
                    title: searchText.isEmpty ? L10n.text("ui.no_plugins_installed_yet") : L10n.text("ui.no_matching_plugin"),
                    detail: searchText.isEmpty ? L10n.text("ui.please_install_and_enable_the_codex_plug_in") : L10n.text("ui.try_another_name"),
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
                                        Text(L10n.text("ui.deactivated"))
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
            searchField(placeholder: L10n.text("ui.search_skill"), tokens: tokens)
            if filteredSkills.isEmpty {
                emptyCapabilities(
                    title: searchText.isEmpty ? L10n.text("ui.no_skills_available_yet") : L10n.text("ui.no_matching_skill"),
                    detail: searchText.isEmpty ? L10n.text("ui.if_it_is_still_empty_after_refreshing_please") : L10n.text("ui.try_another_name"),
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
                                        Text(skill.presentationDescription ?? L10n.text("ui.added_as_structured_capability"))
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
                .accessibilityLabel(L10n.text("ui.clear_search"))
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
                    Label(isRefreshingCapabilities ? L10n.text("ui.refreshing") : L10n.text("ui.refresh_list"), systemImage: "arrow.clockwise")
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
            ?? L10n.text("ui.plugin_installed")
    }

    private func nonEmpty(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private var pageTitle: String {
        switch page {
        case .root: return L10n.text("ui.add_content")
        case .plugins: return L10n.text("ui.plugin")
        case .skills: return L10n.text("ui.select_skill")
        case .shortcuts: return L10n.text("ui.shortcut_phrase")
        }
    }

    private var pageSubtitle: String {
        switch page {
        case .root: return L10n.text("ui.add_context_for_the_next_message")
        case .plugins: return L10n.text("ui.reference_the_installed_codex_plug_in_on_mac")
        case .skills: return L10n.text("ui.selected_and_sent_as_structured_capabilities")
        case .shortcuts: return L10n.text("ui.click_to_insert_input_box")
        }
    }

    private static let shortcuts = [
        L10n.text("ui.check_this_implementation_and_give_the_risks"),
        L10n.text("ui.implement_this_function_and_add_tests"),
        L10n.text("ui.only_make_the_smallest_runnable_version_to_avoid"),
        L10n.text("ui.explain_the_failure_log_and_provide_repair_solutions")
    ]
}
