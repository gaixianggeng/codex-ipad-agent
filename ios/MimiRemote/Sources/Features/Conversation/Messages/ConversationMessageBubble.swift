import QuickLook
import SwiftUI

struct MessageBubble: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let message: ConversationMessage
    let layout: ConversationLayout
    let skills: [SkillCapability]
    let retry: (ConversationMessage) -> Void
    let stop: () -> Void
    let previewFile: (String) async throws -> URL
    @State private var previewURL: URL?
    @State private var previewingPath: String?
    @State private var previewError: String?

    var body: some View {
        Group {
            if shouldRenderUserImages {
                userImageBubbleSurface
            } else {
                bubbleSurface
            }
        }
            .frame(maxWidth: maxBubbleWidth, alignment: bubbleAlignment)
            .opacity(message.sendStatus == .sending ? 0.72 : 1)
            .quickLookPreview($previewURL)
    }

    private var userImageBubbleSurface: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let style = MarkdownStyle.make(
            role: message.role,
            colorScheme: colorScheme,
            fontScale: themeStore.fontScale,
            tokens: tokens
        )
        return userImageContent(style: style)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .messageContextMenu(
                for: message,
                retry: {
                    retry(message)
                },
                stop: stop
            )
    }

    private var bubbleSurface: some View {
        bubbleChrome
            // 长按菜单必须锚定在实际气泡上，不能挂到外层全宽行，否则 iPad 上菜单预览会撑满整行。
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .messageContextMenu(
                for: message,
                retry: {
                    retry(message)
                },
                stop: stop
            )
    }

    private var bubbleChrome: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return contentWithTimestamp
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(background, in: shape)
            .overlay {
                shape.strokeBorder(bubbleBorder, lineWidth: 1)
            }
            .shadow(color: bubbleShadowColor, radius: message.role == .user ? 2 : 6, y: message.role == .user ? 1 : 2)
    }

    private var contentWithTimestamp: some View {
        ZStack(alignment: .bottomTrailing) {
            renderContent
                .padding(.bottom, 16)
            MessageTimestampCaption(text: message.timestampCaptionText, isFallback: message.isTimestampFallback, foreground: timestampForeground)
        }
    }

    @ViewBuilder
    private var renderContent: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let style = MarkdownStyle.make(
            role: message.role,
            colorScheme: colorScheme,
            fontScale: themeStore.fontScale,
            tokens: tokens
        )
        if shouldRenderUserImages {
            userImageContent(style: style)
        } else if shouldRenderStructuredUserPayload {
            structuredUserContent(style: style)
        } else if shouldRenderMarkdown {
            let plan = MessageRenderPlanCache.shared.plan(for: message)
            let references = fileReferences
            if references.isEmpty {
                markdownContent(plan: plan, style: style)
            } else {
                VStack(alignment: .leading, spacing: style.blockSpacing) {
                    markdownContent(plan: plan, style: style)
                    FileReferencePreviewStrip(
                        references: references,
                        previewingPath: previewingPath,
                        previewError: previewError,
                        onPreview: { reference in
                            Task { await preview(reference) }
                        }
                    )
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(message.content)
                .font(themeStore.uiFont(.body))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func userImageContent(style: MarkdownStyle) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        return VStack(alignment: .trailing, spacing: 8) {
            let text = userImageText
            if !text.isEmpty {
                Text(text)
                    .font(style.bodyFont)
                    .foregroundStyle(userBubbleForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(tokens.userBubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            userImageGallery(style: style)

            userPayloadAccessories(style: style)

            MessageTimestampCaption(
                text: message.timestampCaptionText,
                isFallback: message.isTimestampFallback,
                foreground: tokens.secondaryText
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func userImageGallery(style: MarkdownStyle) -> some View {
        if userImageSources.count > 1 {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                alignment: .trailing,
                spacing: 8
            ) {
                ForEach(userImageSources) { source in
                    ConversationImagePreview(
                        source: source,
                        title: nil,
                        style: style,
                        maxHeight: 208,
                        showsCaption: false,
                        fillsAvailableWidth: true
                    )
                    .frame(height: 220, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            ForEach(userImageSources) { source in
                ConversationImagePreview(
                    source: source,
                    title: nil,
                    style: style,
                    maxHeight: 320,
                    showsCaption: false,
                    fillsAvailableWidth: true
                )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func markdownContent(plan: MessageRenderPlan, style: MarkdownStyle) -> some View {
        if plan.isSinglePlainParagraph, case let .paragraph(inline) = plan.blocks.first?.kind {
            Text(inline.plain)
                .font(style.bodyFont)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: style.blockSpacing) {
                ForEach(plan.blocks) { block in
                    MarkdownBlockView(block: block, style: style)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shouldRenderMarkdown: Bool {
        message.role == .assistant && message.kind == .message
    }

    private var shouldRenderUserImages: Bool {
        message.role == .user
            && message.kind == .message
            && (!payloadImageItems.isEmpty || !contentImageReferences.isEmpty)
    }

    private var shouldRenderStructuredUserPayload: Bool {
        message.role == .user
            && message.kind == .message
            && (!payloadSkillItems.isEmpty || !payloadMentionItems.isEmpty)
    }

    private func structuredUserContent(style: MarkdownStyle) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            let text = structuredPayloadText
            if !text.isEmpty {
                Text(text)
                    .font(style.bodyFont)
                    .foregroundStyle(userBubbleForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            userPayloadAccessories(style: style)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var structuredPayloadText: String {
        if !payloadText.isEmpty {
            return payloadText
        }
        var text = message.content
        for item in payloadSkillItems + payloadMentionItems {
            text = text.replacingOccurrences(of: item.previewText, with: "")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func userPayloadAccessories(style: MarkdownStyle) -> some View {
        ForEach(payloadSkillItems) { item in
            if case .skill(let name, let path) = item {
                let capability = skills.first { $0.path == path || $0.name == name }
                SkillInvocationCard(
                    metadata: SkillVisualMetadata(name: name, path: path, capability: capability),
                    sendStatus: message.sendStatus,
                    usesUserBubbleContrast: true
                )
                .environmentObject(themeStore)
            }
        }

        let accessoryText = payloadAccessoryText
        if !accessoryText.isEmpty {
            Text(accessoryText)
                .font(style.captionFont)
                .foregroundStyle(style.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var payloadImageItems: [CodexAppServerUserInput] {
        guard let payload = message.turnPayload else {
            return []
        }
        return payload.input.filter { ConversationImageSource.input($0) != nil }
    }

    private var contentImageReferences: [ConversationFileReference] {
        guard message.turnPayload == nil || payloadImageItems.isEmpty else {
            return []
        }
        return ConversationFileReferenceDetector.imageReferences(in: message.content)
    }

    private var userImageSources: [ConversationImageSource] {
        let payloadSources = payloadImageItems.compactMap(ConversationImageSource.input)
        if !payloadSources.isEmpty {
            return payloadSources
        }
        return contentImageReferences.map { .localPath($0.path) }
    }

    private var userImageText: String {
        if !payloadImageItems.isEmpty {
            return payloadText
        }
        return contentTextWithoutImagePaths
    }

    private var payloadText: String {
        guard let payload = message.turnPayload else {
            return ""
        }
        return payload.input.compactMap { item in
            if case .text(let text, _) = item {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private var contentTextWithoutImagePaths: String {
        var text = message.content
        for reference in contentImageReferences {
            let fileURL = URL(fileURLWithPath: reference.path).absoluteString
            let variants = [
                reference.path,
                reference.path.replacingOccurrences(of: " ", with: "\\ "),
                fileURL,
                fileURL.removingPercentEncoding ?? fileURL,
                L10n.format("ui.image_value", reference.name),
                L10n.text("ui.image_attachment")
            ]
            for variant in variants where !variant.isEmpty {
                text = text.replacingOccurrences(of: variant, with: "")
            }
        }
        text = strippedUserFileMentionPrompt(from: text)
        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "：:，,。.；;"))
    }

    private func strippedUserFileMentionPrompt(from text: String) -> String {
        for marker in ["## My request for Codex:", "## My request for Codex："] {
            if let range = text.range(of: marker, options: [.caseInsensitive]) {
                return String(text[range.upperBound...])
            }
        }
        return text
    }

    private var payloadAccessoryText: String {
        guard let payload = message.turnPayload else {
            return ""
        }
        return payload.input.compactMap { item in
            switch item {
            case .mention:
                return item.previewText
            case .text, .image, .localImage, .skill:
                return nil
            }
        }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var payloadSkillItems: [CodexAppServerUserInput] {
        message.turnPayload?.input.filter { item in
            if case .skill = item { return true }
            return false
        } ?? []
    }

    private var payloadMentionItems: [CodexAppServerUserInput] {
        message.turnPayload?.input.filter { item in
            if case .mention = item { return true }
            return false
        } ?? []
    }

    private var fileReferences: [ConversationFileReference] {
        guard shouldRenderMarkdown, message.sendStatus != .sending else {
            return []
        }
        return ConversationFileReferenceDetector.references(in: message.content)
    }

    private func preview(_ reference: ConversationFileReference) async {
        previewingPath = reference.path
        previewError = nil
        defer {
            if previewingPath == reference.path {
                previewingPath = nil
            }
        }
        do {
            previewURL = try await previewFile(reference.path)
        } catch {
            previewError = userFacingPreviewError(error)
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

    private var bubbleAlignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private var maxBubbleWidth: CGFloat {
        message.role == .user ? layout.userBubbleMaxWidth : layout.assistantBubbleMaxWidth
    }

    private var background: Color {
        let tokens = themeStore.tokens(for: colorScheme)
        switch message.role {
        case .user:
            return tokens.userBubble
        default:
            return tokens.assistantBubble
        }
    }

    private var bubbleBorder: Color {
        let tokens = themeStore.tokens(for: colorScheme)
        if message.role == .user, tokens.preset == .codex {
            return Color.white.opacity(tokens.resolvedScheme == .light ? 0.12 : 0.08)
        }
        return tokens.border.opacity(message.role == .assistant ? 0.58 : 0.42)
    }

    private var bubbleShadowColor: Color {
        let tokens = themeStore.tokens(for: colorScheme)
        let opacity: Double
        if message.role == .user {
            opacity = tokens.resolvedScheme == .light ? 0.05 : 0.12
        } else {
            opacity = tokens.resolvedScheme == .light ? 0.045 : 0.16
        }
        return Color.black.opacity(opacity)
    }

    private var foreground: Color {
        let tokens = themeStore.tokens(for: colorScheme)
        if message.role == .user, tokens.preset == .codex {
            return userBubbleForeground
        }
        return tokens.primaryText
    }

    private var timestampForeground: Color? {
        let tokens = themeStore.tokens(for: colorScheme)
        guard message.role == .user, tokens.preset == .codex else {
            return nil
        }
        return userBubbleForeground.opacity(0.72)
    }

    private var userBubbleForeground: Color {
        themeStore.tokens(for: colorScheme).userBubbleForeground
    }
}
