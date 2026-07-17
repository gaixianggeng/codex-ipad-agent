import SwiftUI
import UIKit

// 设置详情组件保持值、Binding 与回调输入，不额外引入状态层。
struct ConnectionProfileRenameSheet: View {
    @Environment(\.dismiss) private var dismiss

    let profile: ConnectionProfile
    let onRename: (String) throws -> Void
    @State private var displayName: String
    @State private var submitError: String?

    init(profile: ConnectionProfile, onRename: @escaping (String) throws -> Void) {
        self.profile = profile
        self.onRename = onRename
        _displayName = State(initialValue: profile.displayName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Mac 名称", text: $displayName)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit(rename)
                        .accessibilityIdentifier("settings.profile.rename.name")
                } footer: {
                    Text(validationMessage ?? "最多 \(AppStore.connectionProfileDisplayNameLimit) 个字符，只修改本机显示名称。")
                        .foregroundStyle(validationMessage == nil ? Color.secondary : Color.red)
                }

                if let submitError {
                    Section {
                        Text(submitError)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("settings.profile.rename.error")
                    }
                }
            }
            .navigationTitle("重命名 Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: rename)
                        .disabled(validationMessage != nil)
                        .accessibilityIdentifier("settings.profile.rename.save")
                }
            }
            .onChange(of: displayName) { _, _ in
                submitError = nil
            }
        }
        .presentationDetents([.medium])
    }

    private var normalizedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationMessage: String? {
        if normalizedDisplayName.isEmpty {
            return ConnectionProfileError.invalidDisplayName.localizedDescription
        }
        if normalizedDisplayName.count > AppStore.connectionProfileDisplayNameLimit {
            return ConnectionProfileError.displayNameTooLong(
                maximum: AppStore.connectionProfileDisplayNameLimit
            ).localizedDescription
        }
        return nil
    }

    private func rename() {
        guard validationMessage == nil else { return }
        do {
            try onRename(displayName)
            dismiss()
        } catch {
            // 档案若在 Sheet 展示期间被其它操作移除，保留输入并明确展示失败原因。
            submitError = error.localizedDescription
        }
    }
}

struct EndpointTransportNotice: View {
    let assessment: EndpointTransportAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(assessment.title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
            Text(assessment.guidance)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.endpointTransportNotice")
    }

    private var systemImage: String {
        switch assessment.status {
        case .empty:
            return "network"
        case .invalid, .blockedPublicHTTP:
            return "exclamationmark.shield.fill"
        case .allowedPrivateHTTP:
            return "lock.shield"
        case .allowedHTTPS:
            return "lock.fill"
        }
    }

    private var tint: Color {
        switch assessment.status {
        case .empty:
            return .secondary
        case .invalid, .blockedPublicHTTP:
            return .red
        case .allowedPrivateHTTP:
            return .orange
        case .allowedHTTPS:
            return .green
        }
    }
}

struct CapabilitiesView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            Section {
                if let path = sessionStore.capabilityList?.path, !path.isEmpty {
                    CapabilityValueRow(title: "工作区", value: path)
                } else {
                    CapabilityValueRow(title: "工作区", value: sessionStore.selectedCommandActionPath ?? "仅用户级配置")
                }
                Button {
                    Task { await sessionStore.refreshCapabilities() }
                } label: {
                    if sessionStore.isRefreshingCapabilities {
                        Label("正在刷新", systemImage: "arrow.clockwise")
                    } else {
                        Label("刷新能力", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(sessionStore.isRefreshingCapabilities)
            } footer: {
                Text("这里只读展示 agentd 可发现的本地 Skills 和 MCP 配置，不会启动 MCP server，也不会读取或显示环境变量值。")
            }
            .listRowBackground(tokens.elevatedSurface)

            if let error = sessionStore.capabilityErrorMessage {
                Section("错误") {
                    Text(error)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(.red)
                }
                .listRowBackground(tokens.elevatedSurface)
            }

            Section("Skills") {
                let skills = sessionStore.capabilityList?.skills ?? []
                if skills.isEmpty {
                    ContentUnavailableView("未发现 Skills", systemImage: "wand.and.stars")
                        .font(themeStore.uiFont(.caption))
                } else {
                    ForEach(skills) { skill in
                        CapabilityItemRow(
                            symbolName: "wand.and.stars",
                            title: skill.name,
                            subtitle: skill.description,
                            detail: "\(scopeText(skill.scope)) · \(skill.path)",
                            isEnabled: skill.enabled
                        )
                    }
                }
            }
            .listRowBackground(tokens.elevatedSurface)

            Section("MCP") {
                let servers = sessionStore.capabilityList?.mcpServers ?? []
                if servers.isEmpty {
                    ContentUnavailableView("未发现 MCP server", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(themeStore.uiFont(.caption))
                } else {
                    ForEach(servers) { server in
                        CapabilityItemRow(
                            symbolName: "point.3.connected.trianglepath.dotted",
                            title: serverTitle(server),
                            subtitle: serverSubtitle(server),
                            detail: serverDetail(server),
                            isEnabled: serverIsUsable(server),
                            statusText: serverStatusText(server),
                            statusColor: serverStatusColor(server)
                        )
                    }
                }
            }
            .listRowBackground(tokens.elevatedSurface)
        }
        .themedSettingsForm(tokens: tokens)
        .navigationTitle("能力")
        .tint(tokens.accent)
        .task {
            if sessionStore.capabilityList == nil {
                await sessionStore.refreshCapabilities()
            }
        }
    }

    private func serverTitle(_ server: MCPCapability) -> String {
        if let plugin = server.plugin, !plugin.isEmpty {
            return "\(server.name) · \(plugin)"
        }
        return server.name
    }

    private func serverSubtitle(_ server: MCPCapability) -> String? {
        if let url = server.url, !url.isEmpty {
            return url
        }
        if let command = server.command, !command.isEmpty {
            return command
        }
        return server.transport
    }

    private func serverDetail(_ server: MCPCapability) -> String {
        let base = "\(scopeText(server.scope)) · \(server.configPath)"
        guard let note = server.statusNote, !note.isEmpty else {
            return base
        }
        return "\(base)\n\(note)"
    }

    private func serverStatusText(_ server: MCPCapability) -> String? {
        switch server.status {
        case "ready":
            return "可用"
        case "configured":
            return "已配置"
        case "missing_command":
            return "缺少命令"
        case "invalid":
            return "配置异常"
        case "disabled":
            return "已停用"
        default:
            return server.enabled ? nil : "已停用"
        }
    }

    private func serverStatusColor(_ server: MCPCapability) -> Color {
        switch server.status {
        case "ready":
            return themeStore.tokens(for: colorScheme).success
        case "missing_command", "invalid":
            return themeStore.tokens(for: colorScheme).warning
        default:
            return .secondary
        }
    }

    private func serverIsUsable(_ server: MCPCapability) -> Bool {
        server.enabled && server.status != "missing_command" && server.status != "invalid"
    }

    private func scopeText(_ scope: String) -> String {
        switch scope {
        case "repo":
            return "项目"
        case "user":
            return "用户"
        case "admin":
            return "系统"
        default:
            return scope
        }
    }
}

struct CapabilityValueRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(themeStore.uiFont(.caption, weight: .medium))
            Text(value)
                .font(themeStore.codeFont(.caption2))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

struct CapabilityItemRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let symbolName: String
    let title: String
    let subtitle: String?
    let detail: String
    let isEnabled: Bool
    let statusText: String?
    let statusColor: Color

    init(
        symbolName: String,
        title: String,
        subtitle: String?,
        detail: String,
        isEnabled: Bool,
        statusText: String? = nil,
        statusColor: Color = .secondary
    ) {
        self.symbolName = symbolName
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.isEnabled = isEnabled
        self.statusText = statusText
        self.statusColor = statusColor
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbolName)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(isEnabled ? tokens.accent : Color.secondary)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .lineLimit(2)
                    if let statusText {
                        Text(statusText)
                            .font(themeStore.uiFont(.caption2, weight: .medium))
                            .foregroundStyle(statusColor)
                    } else if !isEnabled {
                        Text("已停用")
                            .font(themeStore.uiFont(.caption2, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(themeStore.uiFont(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(detail)
                    .font(themeStore.codeFont(.caption2))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
    }
}

struct AppearanceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.themeSystemColorScheme) private var themeSystemColorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        let systemColorScheme = themeSystemColorScheme ?? colorScheme
        let resolvedColorScheme = themeStore.resolvedColorScheme(for: systemColorScheme)
        let tokens = themeStore.tokens(for: systemColorScheme)

        Form {
            Section {
                Picker("外观", selection: $themeStore.mode) {
                    ForEach(ThemeMode.allCases) { mode in
                        Label(mode.title, systemImage: iconName(for: mode))
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("深浅色")
            } footer: {
                Text("系统模式会跟随当前设备外观；浅色和深色会固定 App 外观。")
            }
            .listRowBackground(tokens.elevatedSurface)

            Section {
                ForEach(ThemePreset.allCases) { preset in
                    ThemePresetRow(
                        preset: preset,
                        isSelected: themeStore.preset == preset,
                        tokens: tokens
                    ) {
                        themeStore.preset = preset
                    }
                }
            } header: {
                Text("主题")
            }
            .listRowBackground(tokens.elevatedSurface)

            Section {
                Picker("UI 字体", selection: $themeStore.uiFontPreset) {
                    ForEach(ThemeUIFontPreset.allCases) { font in
                        Text(font.title).tag(font)
                    }
                }

                Picker("代码字体", selection: $themeStore.codeFontPreset) {
                    ForEach(ThemeCodeFontPreset.allCases) { font in
                        Text(font.title).tag(font)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("字体大小")
                        Spacer()
                        Text(fontScaleText)
                            .foregroundStyle(tokens.secondaryText)
                    }
                    .font(themeStore.uiFont(size: 15, weight: .medium))

                    Slider(
                        value: Binding(
                            get: { themeStore.fontScale },
                            set: { themeStore.setFontScale($0) }
                        ),
                        in: ThemeStore.minimumFontScale...ThemeStore.maximumFontScale,
                        step: 0.05
                    )

                    HStack(alignment: .firstTextBaseline) {
                        Text("Aa")
                            .font(themeStore.uiFont(size: 13, weight: .medium))
                        Spacer()
                        Text("Aa")
                            .font(themeStore.uiFont(size: 22, weight: .semibold))
                    }
                    .foregroundStyle(tokens.secondaryText)
                }
                .padding(.vertical, 4)
            } header: {
                Text("字体")
            }
            .listRowBackground(tokens.elevatedSurface)

            Section {
                AppearanceConversationPreview()
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } header: {
                Text("聊天预览")
            }
            .listRowBackground(tokens.elevatedSurface)

            Section {
                Button(role: .destructive) {
                    themeStore.reset()
                } label: {
                    Label("恢复默认外观", systemImage: "arrow.counterclockwise")
                }
            }
            .listRowBackground(tokens.elevatedSurface)
        }
        .themedSettingsForm(tokens: tokens)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(tokens.background.ignoresSafeArea())
        .navigationTitle("外观")
        .preferredColorScheme(resolvedColorScheme)
        .environment(\.colorScheme, resolvedColorScheme)
        .tint(tokens.accent)
    }

    private var fontScaleText: String {
        "\(Int((themeStore.fontScale * 100).rounded()))%"
    }

    private func iconName(for mode: ThemeMode) -> String {
        switch mode {
        case .system:
            return "circle.lefthalf.filled"
        case .light:
            return "sun.max"
        case .dark:
            return "moon"
        }
    }
}

struct ThemePresetRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    let preset: ThemePreset
    let isSelected: Bool
    let tokens: ThemeTokens
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(preset.swatchBackground)
                    Text("Aa")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(preset.swatchForeground)
                }
                .frame(width: 42, height: 42)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? tokens.accent : tokens.border, lineWidth: isSelected ? 2 : 1)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.title)
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(preset.subtitle)
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(tokens.accent)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

struct AppearanceConversationPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.themeSystemColorScheme) private var themeSystemColorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        let tokens = themeStore.tokens(for: themeSystemColorScheme ?? colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(themeStore.preset.title, systemImage: "sparkles")
                    .font(themeStore.uiFont(size: 13, weight: .semibold))
                    .foregroundStyle(tokens.accent)
                Spacer()
                Text(themeStore.mode.title)
                    .font(themeStore.uiFont(size: 12, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
            }

            PreviewBubble(
                text: "帮我检查这个 PR 的风险点。",
                alignment: .trailing,
                fill: tokens.userBubble,
                textColor: tokens.primaryText,
                font: themeStore.uiFont(size: 15)
            )

            PreviewBubble(
                text: "已开始检查。发现 2 个需要确认的改动，完整日志在 Inspector。",
                alignment: .leading,
                fill: tokens.assistantBubble,
                textColor: tokens.primaryText,
                font: themeStore.uiFont(size: 15)
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                    Text("命令摘要")
                    Spacer()
                    Text("go test ./...")
                        .lineLimit(1)
                }
                .font(themeStore.uiFont(size: 13, weight: .medium))

                Text("let theme = ThemePreset.\(themeStore.preset.rawValue)")
                    .font(themeStore.codeFont(size: 13))
                    .foregroundStyle(tokens.codeText)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(tokens.codeBlock, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .foregroundStyle(tokens.secondaryText)
            .padding(10)
            .background(tokens.systemBubble)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(tokens.border, lineWidth: 1)
            }
        }
        .padding(12)
        .background(tokens.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(tokens.border, lineWidth: 1)
        }
    }
}

struct StableEndpointTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField()
        textField.placeholder = placeholder
        textField.text = text
        context.coordinator.lastSyncedText = text
        textField.delegate = context.coordinator
        textField.keyboardType = .URL
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.clearButtonMode = .whileEditing
        textField.returnKeyType = .done
        textField.addTarget(context.coordinator, action: #selector(Coordinator.textDidChange(_:)), for: .editingChanged)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textField
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.parent = self
        uiView.placeholder = placeholder

        guard context.coordinator.lastSyncedText != text else {
            return
        }

        let previousText = uiView.text ?? ""
        let selectedRange = context.coordinator.selectedRange(in: uiView)
        uiView.text = text
        context.coordinator.lastSyncedText = text
        context.coordinator.setSelectedRange(
            TextSelectionPolicy.rangeAfterExternalTextSync(
                previousText: previousText,
                nextText: text,
                previousRange: selectedRange
            ),
            in: uiView
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: StableEndpointTextField
        var lastSyncedText = ""

        init(_ parent: StableEndpointTextField) {
            self.parent = parent
        }

        @objc func textDidChange(_ textField: UITextField) {
            let next = textField.text ?? ""
            guard next != lastSyncedText else {
                return
            }
            lastSyncedText = next
            parent.text = next
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }

        func selectedRange(in textField: UITextField) -> NSRange {
            guard let selectedTextRange = textField.selectedTextRange else {
                let length = ((textField.text ?? "") as NSString).length
                return NSRange(location: length, length: 0)
            }
            let location = textField.offset(from: textField.beginningOfDocument, to: selectedTextRange.start)
            let length = textField.offset(from: selectedTextRange.start, to: selectedTextRange.end)
            return NSRange(location: location, length: length)
        }

        func setSelectedRange(_ range: NSRange, in textField: UITextField) {
            guard
                let start = textField.position(from: textField.beginningOfDocument, offset: range.location),
                let end = textField.position(from: start, offset: range.length)
            else {
                return
            }
            textField.selectedTextRange = textField.textRange(from: start, to: end)
        }
    }
}

struct PreviewBubble: View {
    enum AlignmentSide {
        case leading
        case trailing
    }

    let text: String
    let alignment: AlignmentSide
    let fill: Color
    let textColor: Color
    let font: Font

    var body: some View {
        HStack {
            if alignment == .trailing {
                Spacer(minLength: 36)
            }

            Text(text)
                .font(font)
                .foregroundStyle(textColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(fill)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if alignment == .leading {
                Spacer(minLength: 36)
            }
        }
    }
}

extension View {
    func themedSettingsForm(tokens: ThemeTokens) -> some View {
        scrollContentBackground(.hidden)
            .background(tokens.background.ignoresSafeArea())
    }
}
