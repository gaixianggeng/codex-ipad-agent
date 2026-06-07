import AVFoundation
import PhotosUI
import Speech
import SwiftUI
import UIKit

private let composerTextContentInset: CGFloat = 10

struct ComposerView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var composerState = ComposerState()
    @StateObject private var voiceInput = VoiceInputController()
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var manualInputKind: ManualInputKind = .localImage
    @State private var showsManualInputSheet = false
    @State private var showsAdvancedOptionsSheet = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(spacing: 8) {
            if let activity = sessionStore.selectedForegroundActivity {
                composerActivity(activity)
            }
            runtimeChips
            pendingApprovalAction
            optionToolbar
            voiceErrorMessage
            attachmentStrip
            ComposerTextView(
                text: $composerState.draft,
                font: composerUIFont,
                textColor: UIColor(tokens.primaryText),
                tintColor: UIColor(tokens.accent),
                onSubmit: { submitDraft() }
            )
                .frame(minHeight: composerMinHeight, maxHeight: composerMaxHeight)
                .padding(composerTextContentInset)
                .background(tokens.elevatedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tokens.border)
                )
                .overlay(alignment: .topLeading) {
                    if composerState.draft.isEmpty {
                        Text("输入任务或后续指令")
                            .font(themeStore.uiFont(.body))
                            .foregroundStyle(tokens.tertiaryText)
                            // 和 UITextView 外层 padding 保持同一个起点，避免占位文案与真实光标错位。
                            .padding(composerTextContentInset)
                            .allowsHitTesting(false)
                    }
                }

            ViewThatFits(in: .horizontal) {
                horizontalActions(showLabels: true)
                horizontalActions(showLabels: false)
                compactActions
            }
            .font(themeStore.uiFont(.callout))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(isCompactComposer ? 10 : 12)
        .background(tokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tokens.border)
        )
        .sheet(isPresented: $showsManualInputSheet) {
            ManualUserInputSheet(kind: manualInputKind) { input in
                composerState.addAttachment(input)
            }
        }
        .sheet(isPresented: $showsAdvancedOptionsSheet) {
            AdvancedTurnOptionsSheet(options: composerState.turnOptions) { options in
                composerState.turnOptions = options
            }
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else {
                return
            }
            loadPhotoAttachment(item)
        }
        .task {
            await sessionStore.refreshAppServerModelOptions()
        }
        .onDisappear {
            voiceInput.stop()
            composerState.endVoiceInput()
        }
    }

    @discardableResult
    private func submitDraft() -> Bool {
        guard let submitted = composerState.takeDraftForSubmit(isLoading: sessionStore.isLoading) else {
            return false
        }
        Task {
            let accepted = await sessionStore.sendTurn(submitted.payload)
            if !accepted {
                await MainActor.run {
                    composerState.restore(submitted)
                }
            }
        }
        return true
    }

    private var canSubmitDraft: Bool {
        composerState.canSubmit(isLoading: sessionStore.isLoading)
    }

    private var isCompactComposer: Bool {
        horizontalSizeClass == .compact
    }

    private func horizontalActions(showLabels: Bool) -> some View {
        HStack(spacing: 10) {
            terminalControls(showLabels: showLabels)
            Spacer(minLength: 12)
            sendButton(showLabels: showLabels)
        }
    }

    private var compactActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            terminalControls(showLabels: false)
            HStack {
                Spacer()
                sendButton(showLabels: !isCompactComposer)
            }
        }
    }

    private func terminalControls(showLabels: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                composerState.toggleExpanded()
            } label: {
                controlLabel(
                    composerState.isExpanded ? "收起" : "展开",
                    systemImage: composerState.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    showLabels: showLabels
                )
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(composerState.isExpanded ? "收起输入框" : "展开输入框")

            Button {
                sessionStore.sendCtrlC()
            } label: {
                controlLabel("Ctrl-C", systemImage: "stop.circle", showLabels: showLabels)
            }
            .buttonStyle(.bordered)
            .disabled(sessionStore.selectedSession?.isRunning != true)
            .accessibilityLabel("发送 Ctrl-C")

            Button {
                submitDraft()
            } label: {
                controlLabel("Enter", systemImage: "return", showLabels: showLabels)
            }
            .buttonStyle(.bordered)
            .disabled(!canSubmitDraft)
            .accessibilityLabel("发送回车")

            Button(role: .destructive) {
                Task { await sessionStore.stopSelectedSession() }
            } label: {
                controlLabel("停止", systemImage: "xmark.circle", showLabels: showLabels)
            }
            .buttonStyle(.bordered)
            .disabled(sessionStore.selectedSession?.isRunning != true)
            .accessibilityLabel("停止当前会话")
        }
        .controlSize(isCompactComposer || !showLabels ? .small : .regular)
    }

    private var optionToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Label("图片", systemImage: "photo")
                }
                .buttonStyle(.bordered)

                Button {
                    toggleVoiceInput()
                } label: {
                    Label(voiceInput.isRecording ? "停止录音" : "语音", systemImage: voiceInput.isRecording ? "waveform.circle.fill" : "mic")
                }
                .buttonStyle(.bordered)
                .tint(voiceInput.isRecording ? .red : nil)

                Menu {
                    Button("图片 URL") {
                        manualInputKind = .imageURL
                        showsManualInputSheet = true
                    }
                    Button("本机图片") {
                        manualInputKind = .localImage
                        showsManualInputSheet = true
                    }
                    Button("Skill") {
                        manualInputKind = .skill
                        showsManualInputSheet = true
                    }
                    Button("Mention") {
                        manualInputKind = .mention
                        showsManualInputSheet = true
                    }
                } label: {
                    Label("引用", systemImage: "paperclip")
                }
                .buttonStyle(.bordered)

                shortcutsMenu
                modelMenu
                reasoningMenu
                serviceTierMenu
                permissionMenu
                moreOptionsMenu

                Button {
                    showsAdvancedOptionsSheet = true
                } label: {
                    Label("高级", systemImage: "ellipsis.circle")
                }
                .buttonStyle(.bordered)
            }
            .font(themeStore.uiFont(.caption, weight: .medium))
            .controlSize(.small)
        }
    }

    private var shortcutsMenu: some View {
        Menu {
            Button("检查这段实现并给出风险") { composerState.insertShortcut("检查这段实现并给出风险") }
            Button("实现这个功能并补测试") { composerState.insertShortcut("实现这个功能并补测试") }
            Button("只做最小可运行版本") { composerState.insertShortcut("只做最小可运行版本，避免过度设计") }
            Button("解释失败日志并给修复方案") { composerState.insertShortcut("解释失败日志并给修复方案") }
        } label: {
            Label("快捷", systemImage: "bolt")
        }
        .buttonStyle(.bordered)
    }

    private var modelMenu: some View {
        Menu {
            Button("默认") {
                composerState.turnOptions.model = nil
                composerState.turnOptions.modelProvider = nil
            }
            ForEach(modelOptionsForMenu) { option in
                Button(option.menuTitle) {
                    composerState.turnOptions.model = option.model
                    composerState.turnOptions.modelProvider = option.provider
                }
            }
            Divider()
            Button {
                Task { await sessionStore.refreshAppServerModelOptions(force: true) }
            } label: {
                Label(sessionStore.isRefreshingAppServerModels ? "刷新中" : "刷新模型列表", systemImage: "arrow.clockwise")
            }
            .disabled(sessionStore.isRefreshingAppServerModels)
        } label: {
            Label(composerState.turnOptions.model ?? "默认模型", systemImage: "cpu")
        }
        .buttonStyle(.bordered)
    }

    private var modelOptionsForMenu: [CodexAppServerModelOption] {
        sessionStore.appServerModelOptions.isEmpty ? CodexAppServerModelOption.builtInFallback : sessionStore.appServerModelOptions
    }

    private var reasoningMenu: some View {
        Menu {
            Button("默认") { composerState.turnOptions.reasoningEffort = nil }
            ForEach(CodexAppServerReasoningEffort.allCases) { effort in
                Button(effort.rawValue) { composerState.turnOptions.reasoningEffort = effort }
            }
        } label: {
            Label(composerState.turnOptions.reasoningEffort?.rawValue ?? "推理默认", systemImage: "brain.head.profile")
        }
        .buttonStyle(.bordered)
    }

    private var serviceTierMenu: some View {
        Menu {
            Button("默认") { composerState.turnOptions.serviceTier = nil }
            Button("auto") { composerState.turnOptions.serviceTier = "auto" }
            Button("priority") { composerState.turnOptions.serviceTier = "priority" }
            Button("flex") { composerState.turnOptions.serviceTier = "flex" }
        } label: {
            Label(composerState.turnOptions.serviceTier ?? "速度默认", systemImage: "speedometer")
        }
        .buttonStyle(.bordered)
    }

    private var permissionMenu: some View {
        Menu {
            Button("on-request") { composerState.turnOptions.approvalPolicy = .onRequest }
            Button("on-failure") { composerState.turnOptions.approvalPolicy = .onFailure }
            Button("untrusted") { composerState.turnOptions.approvalPolicy = .untrusted }
            Divider()
            Button("只读") { composerState.turnOptions.sandboxMode = .readOnly }
            Button("工作区写入") { composerState.turnOptions.sandboxMode = .workspaceWrite }
        } label: {
            Label(permissionTitle, systemImage: "lock.shield")
        }
        .buttonStyle(.bordered)
    }

    private var moreOptionsMenu: some View {
        Menu {
            Button("summary 默认") { composerState.turnOptions.reasoningSummary = nil }
            ForEach(CodexAppServerReasoningSummary.allCases) { summary in
                Button(summary.rawValue) { composerState.turnOptions.reasoningSummary = summary }
            }
            Divider()
            Button("人格默认") { composerState.turnOptions.personality = nil }
            Button("none") { composerState.turnOptions.personality = CodexAppServerPersonality.none }
            Button("friendly") { composerState.turnOptions.personality = .friendly }
            Button("pragmatic") { composerState.turnOptions.personality = .pragmatic }
        } label: {
            Label("更多", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var attachmentStrip: some View {
        if !composerState.attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(composerState.attachments.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: 6) {
                            Image(systemName: attachmentSymbol(for: item))
                            Text(item.previewText)
                                .lineLimit(1)
                            Button {
                                composerState.removeAttachment(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .accessibilityLabel("移除")
                            }
                            .buttonStyle(.plain)
                        }
                        .font(themeStore.uiFont(.caption))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(themeStore.tokens(for: colorScheme).elevatedSurface, in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(themeStore.tokens(for: colorScheme).border)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var voiceErrorMessage: some View {
        if let errorMessage = voiceInput.errorMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text(errorMessage)
                    .lineLimit(2)
            }
            .font(themeStore.uiFont(.caption))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var runtimeChips: some View {
        if !runtimeChipItems.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(runtimeChipItems, id: \.text) { item in
                        Label(item.text, systemImage: item.symbol)
                            .font(themeStore.uiFont(.caption, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(item.tint.opacity(0.12), in: Capsule())
                            .foregroundStyle(item.tint)
                    }
                }
            }
        }
    }

    private var runtimeChipItems: [(text: String, symbol: String, tint: Color)] {
        guard let session = sessionStore.selectedSession else {
            return []
        }
        var items: [(text: String, symbol: String, tint: Color)] = []
        if session.activeTurnID != nil {
            items.append(("active turn", "bolt.fill", .green))
        }
        if let lastSeq = session.lastSeq {
            items.append(("seq \(lastSeq)", "number", .secondary))
        }
        if let usage = session.usage?.compactText {
            items.append((usage, "gauge.with.dots.needle.33percent", .secondary))
        }
        if let rateLimit = session.rateLimit?.compactText {
            items.append((rateLimit, "speedometer", .secondary))
        }
        return items
    }

    @ViewBuilder
    private var pendingApprovalAction: some View {
        if let approval = sessionStore.selectedSession?.pendingApproval {
            PendingApprovalActionCard(
                approval: approval,
                onApprove: { sessionStore.decideApproval(approval, accept: true) },
                onDecline: { sessionStore.decideApproval(approval, accept: false) }
            )
        }
    }

    private func sendButton(showLabels: Bool) -> some View {
        Button {
            submitDraft()
        } label: {
            controlLabel("发送", systemImage: "paperplane.fill", showLabels: showLabels)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(isCompactComposer || !showLabels ? .small : .regular)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canSubmitDraft)
        .accessibilityLabel("发送")
    }

    @ViewBuilder
    private func controlLabel(_ title: String, systemImage: String, showLabels: Bool) -> some View {
        if showLabels {
            Label(title, systemImage: systemImage)
        } else {
            Image(systemName: systemImage)
        }
    }

    private var permissionTitle: String {
        "\(composerState.turnOptions.approvalPolicy.rawValue) · \(composerState.turnOptions.sandboxMode.title)"
    }

    private var composerMinHeight: CGFloat {
        if isCompactComposer {
            return composerState.isExpanded ? 118 : 60
        }
        return composerState.isExpanded ? 150 : 72
    }

    private var composerMaxHeight: CGFloat {
        if isCompactComposer {
            return composerState.isExpanded ? 190 : 108
        }
        return composerState.isExpanded ? 260 : 130
    }

    private var composerUIFont: UIFont {
        let size = themeStore.scaledFontSize(17)
        let base = UIFont.systemFont(ofSize: size)
        let design: UIFontDescriptor.SystemDesign
        switch themeStore.uiFontPreset {
        case .system:
            design = .default
        case .rounded:
            design = .rounded
        case .serif:
            design = .serif
        }
        guard let descriptor = base.fontDescriptor.withDesign(design) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    private func composerActivity(_ activity: SessionForegroundActivity) -> some View {
        HStack(spacing: 7) {
            if activity.showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .tint(.green)
            } else {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
            }
            Text(activity.title)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(themeStore.uiFont(.caption, weight: .medium))
        .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
    }

    private func toggleVoiceInput() {
        if voiceInput.isRecording {
            voiceInput.stop()
            composerState.endVoiceInput()
            return
        }
        composerState.beginVoiceInput()
        voiceInput.start(
            onTranscript: { transcript in
                composerState.applyVoiceTranscript(transcript)
            },
            onFinish: {
                composerState.endVoiceInput()
            }
        )
    }

    private func loadPhotoAttachment(_ item: PhotosPickerItem) {
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    return
                }
                let url = await Task.detached(priority: .userInitiated) {
                    let encoded = Self.compressedImageData(from: data) ?? data
                    return "data:image/jpeg;base64,\(encoded.base64EncodedString())"
                }.value
                await MainActor.run {
                    composerState.addAttachment(.image(url: url, detail: .auto))
                    selectedPhotoItem = nil
                }
            } catch {
                await MainActor.run {
                    selectedPhotoItem = nil
                }
            }
        }
    }

    nonisolated private static func compressedImageData(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else {
            return nil
        }
        let maxDimension: CGFloat = 1_280
        let largestSide = max(image.size.width, image.size.height)
        let scale = largestSide > maxDimension ? maxDimension / largestSide : 1
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        // iPad 侧只负责把截图/照片作为上下文传给 app-server；先降采样再 JPEG 编码，
        // 避免原图 base64 把 SwiftUI state、WebSocket payload 和内存峰值一起撑大。
        return resized.jpegData(compressionQuality: 0.82)
    }

    private func attachmentSymbol(for item: CodexAppServerUserInput) -> String {
        switch item {
        case .image, .localImage:
            return "photo"
        case .skill:
            return "wand.and.stars"
        case .mention:
            return "at"
        case .text:
            return "text.alignleft"
        }
    }
}

private struct ManualUserInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ManualInputKind
    @State private var name = ""
    @State private var pathOrURL = ""

    let onAdd: (CodexAppServerUserInput) -> Void

    init(kind: ManualInputKind, onAdd: @escaping (CodexAppServerUserInput) -> Void) {
        _kind = State(initialValue: kind)
        self.onAdd = onAdd
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $kind) {
                    ForEach(ManualInputKind.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                if kind.requiresName {
                    TextField("名称", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                TextField(kind.valuePlaceholder, text: $pathOrURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle("添加引用")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        if let input {
                            onAdd(input)
                            dismiss()
                        }
                    }
                    .disabled(input == nil)
                }
            }
        }
    }

    private var input: CodexAppServerUserInput? {
        let value = pathOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .imageURL:
            return .image(url: value, detail: .auto)
        case .localImage:
            return .localImage(path: value, detail: .auto)
        case .skill:
            guard !title.isEmpty else {
                return nil
            }
            return .skill(name: title, path: value)
        case .mention:
            guard !title.isEmpty else {
                return nil
            }
            return .mention(name: title, path: value)
        }
    }
}

private enum ManualInputKind: String, CaseIterable, Identifiable {
    case imageURL
    case localImage
    case skill
    case mention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .imageURL:
            return "图片 URL"
        case .localImage:
            return "本机图片"
        case .skill:
            return "Skill"
        case .mention:
            return "Mention"
        }
    }

    var requiresName: Bool {
        switch self {
        case .skill, .mention:
            return true
        case .imageURL, .localImage:
            return false
        }
    }

    var valuePlaceholder: String {
        switch self {
        case .imageURL:
            return "https://... 或 data:image/..."
        case .localImage:
            return "Mac 上 app-server 可读取的绝对路径"
        case .skill, .mention:
            return "Mac 上 allowlist 内的路径"
        }
    }
}

private struct AdvancedTurnOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CodexAppServerTurnOptions
    @State private var configText: String
    @State private var outputSchemaText: String
    @State private var errorMessage: String?

    let onSave: (CodexAppServerTurnOptions) -> Void

    init(options: CodexAppServerTurnOptions, onSave: @escaping (CodexAppServerTurnOptions) -> Void) {
        _draft = State(initialValue: options)
        _configText = State(initialValue: Self.jsonText(from: options.config))
        _outputSchemaText = State(initialValue: Self.jsonText(from: options.outputSchema))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("模型") {
                    TextField("Model", text: optionalStringBinding(\.model))
                    TextField("Model Provider", text: optionalStringBinding(\.modelProvider))
                    TextField("Service Name", text: optionalStringBinding(\.serviceName))
                }

                Section("线程来源") {
                    TextField("Session Start Source", text: optionalStringBinding(\.sessionStartSource))
                    TextField("Thread Source", text: optionalStringBinding(\.threadSource))
                }

                Section("指令") {
                    TextEditor(text: optionalStringBinding(\.baseInstructions))
                        .frame(minHeight: 90)
                    TextEditor(text: optionalStringBinding(\.developerInstructions))
                        .frame(minHeight: 90)
                }

                Section("JSON") {
                    TextEditor(text: $configText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 110)
                    TextEditor(text: $outputSchemaText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 130)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("高级选项")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("清空") { clearAdvancedOptions() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") { apply() }
                }
            }
        }
    }

    private func optionalStringBinding(_ keyPath: WritableKeyPath<CodexAppServerTurnOptions, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                draft[keyPath: keyPath] = trimmed.isEmpty ? nil : value
            }
        )
    }

    private func apply() {
        do {
            draft.config = try parseOptionalJSON(configText, requireObject: true, label: "config")
            draft.outputSchema = try parseOptionalJSON(outputSchemaText, requireObject: false, label: "outputSchema")
            onSave(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearAdvancedOptions() {
        draft.modelProvider = nil
        draft.config = nil
        draft.baseInstructions = nil
        draft.developerInstructions = nil
        draft.outputSchema = nil
        draft.serviceName = nil
        draft.sessionStartSource = nil
        draft.threadSource = nil
        configText = ""
        outputSchemaText = ""
        errorMessage = nil
    }

    private func parseOptionalJSON(_ text: String, requireObject: Bool, label: String) throws -> CodexAppServerJSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let value = try JSONDecoder().decode(CodexAppServerJSONValue.self, from: Data(trimmed.utf8))
        if requireObject, value.objectValue == nil {
            throw AdvancedTurnOptionsError.invalidJSON(label + " 必须是 JSON object")
        }
        return value
    }

    private static func jsonText(from value: CodexAppServerJSONValue?) -> String {
        guard let value else {
            return ""
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private enum AdvancedTurnOptionsError: LocalizedError {
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let message):
            return message
        }
    }
}

@MainActor
private final class VoiceInputController: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var errorMessage: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh_CN"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var finishHandler: (() -> Void)?

    func start(onTranscript: @escaping (String) -> Void, onFinish: @escaping () -> Void) {
        guard !isRecording else {
            return
        }
        finishHandler = onFinish
        errorMessage = nil

        Task {
            guard await requestPermissions() else {
                errorMessage = "语音权限未开启"
                finish()
                return
            }
            do {
                try startRecognition(onTranscript: onTranscript)
            } catch {
                errorMessage = error.localizedDescription
                finish()
            }
        }
    }

    func stop() {
        recognitionRequest?.endAudio()
        finish()
    }

    private func startRecognition(onTranscript: @escaping (String) -> Void) throws {
        guard let recognizer, recognizer.isAvailable else {
            throw VoiceInputError.unavailable
        }
        recognitionTask?.cancel()
        recognitionTask = nil

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { [weak self] in
                await MainActor.run {
                    guard let self else {
                        return
                    }
                    if let result {
                        onTranscript(result.bestTranscription.formattedString)
                    }
                    if result?.isFinal == true || error != nil {
                        if let error {
                            self.errorMessage = error.localizedDescription
                        }
                        self.finish()
                    }
                }
            }
        }
    }

    private func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speech == .authorized else {
            return false
        }
        if #available(iOS 17.0, *) {
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func finish() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRecording = false
        finishHandler?()
        finishHandler = nil
    }
}

private enum VoiceInputError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "当前设备不可用语音识别"
    }
}

private struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let font: UIFont
    let textColor: UIColor
    let tintColor: UIColor
    let onSubmit: () -> Bool

    func makeUIView(context: Context) -> CommandSubmitTextView {
        let textView = CommandSubmitTextView()
        textView.delegate = context.coordinator
        textView.onCommandSubmit = onSubmit
        textView.backgroundColor = .clear
        textView.font = font
        textView.textColor = textColor
        textView.tintColor = tintColor
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = false
        textView.showsVerticalScrollIndicator = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.accessibilityLabel = "输入任务或后续指令"
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ uiView: CommandSubmitTextView, context: Context) {
        context.coordinator.parent = self
        uiView.onCommandSubmit = onSubmit

        // 字体/颜色只在真正变化时赋值：UITextView 的 font setter 会让 TextKit 对整段文本重新排版，
        // 打字时（尤其是中文 marked text 合成期间）每次按键都重设会打断输入法合成并造成可感知卡顿。
        if uiView.font != font {
            uiView.font = font
        }
        if uiView.textColor != textColor {
            uiView.textColor = textColor
        }
        if uiView.tintColor != tintColor {
            uiView.tintColor = tintColor
        }

        guard uiView.text != text else {
            return
        }

        // 外部清空/恢复草稿时才同步 UIKit 文本；用户正常输入由 delegate 单向写回，
        // 避免中文 marked text 和光标位置在 SwiftUI 重算时被反复重置。
        let selectedRange = uiView.selectedRange
        uiView.text = text
        uiView.selectedRange = clampedRange(selectedRange, in: uiView.text)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func clampedRange(_ range: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(range.location, length)
        let remaining = max(0, length - location)
        return NSRange(location: location, length: min(range.length, remaining))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard parent.text != textView.text else {
                return
            }
            parent.text = textView.text
        }
    }
}

private final class CommandSubmitTextView: UITextView {
    var onCommandSubmit: (() -> Bool)?

    override var keyCommands: [UIKeyCommand]? {
        let submit = UIKeyCommand(
            title: "发送",
            action: #selector(handleCommandReturn),
            input: "\r",
            modifierFlags: .command,
            discoverabilityTitle: "发送"
        )
        return (super.keyCommands ?? []) + [submit]
    }

    @objc private func handleCommandReturn() {
        // 普通回车仍由 UITextView 插入换行；只有 Command + Return 走发送。
        _ = onCommandSubmit?()
    }
}

private struct PendingApprovalActionCard: View {
    let approval: ApprovalSummary
    let onApprove: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text("等待审批")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(approval.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    approvalMeta
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    approvalButtons
                }

                VStack(alignment: .leading, spacing: 8) {
                    approvalButtons
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 审批是当前 turn 的阻塞点，放在输入框上方比放在 Inspector 更接近用户决策动作。
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.30), lineWidth: 1)
        }
    }

    private var approvalMeta: some View {
        HStack(spacing: 8) {
            Label(approval.kind, systemImage: "tag")
            if let count = approval.count {
                Label("\(count) 项", systemImage: "number")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var approvalButtons: some View {
        Group {
            Button(role: .destructive, action: onDecline) {
                Label("拒绝", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)

            Button(action: onApprove) {
                Label("批准", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .controlSize(.small)
        .font(.caption.weight(.semibold))
    }
}
