import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.themeSystemColorScheme) private var themeSystemColorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let isInitialSetup: Bool

    @AppStorage("agentd.developerMode") private var developerModeEnabled = false
    @AppStorage("runtime.keepAwakeWhileRunning") private var keepAwakeWhileRunning = false

    var body: some View {
        let systemColorScheme = themeSystemColorScheme ?? colorScheme
        let resolvedColorScheme = themeStore.resolvedColorScheme(for: systemColorScheme)
        let tokens = themeStore.tokens(for: systemColorScheme)

        NavigationStack {
            Form {
                ConnectionSettingsSections(isInitialSetup: isInitialSetup)

                Section {
                    NavigationLink {
                        AppearanceView()
                    } label: {
                        Label("外观", systemImage: "paintpalette")
                    }

                    NavigationLink {
                        DefaultPermissionView()
                    } label: {
                        Label("默认权限", systemImage: "lock.shield")
                    }

                    NavigationLink {
                        DoctorView()
                    } label: {
                        Label("诊断", systemImage: "stethoscope")
                    }

                    NavigationLink {
                        CapabilitiesView()
                    } label: {
                        Label("能力", systemImage: "wand.and.stars")
                    }
                }

                Section {
                    Toggle(isOn: $keepAwakeWhileRunning) {
                        Label("运行中保持屏幕常亮", systemImage: "sun.max")
                    }
                } footer: {
                    Text("仅当前台选中会话处于运行或等待审批状态时生效；离开运行会话后会恢复系统默认锁屏。")
                }

                Section {
                    Toggle(isOn: $developerModeEnabled) {
                        Label("开发者模式", systemImage: "wrench.and.screwdriver")
                    }
                } footer: {
                    Text("开启后会在对话输入区显示高级运行选项。普通远程使用不需要开启。")
                }
            }
            .navigationTitle(isInitialSetup ? "连接你的 Mac" : "设置")
            .toolbar {
                if !isInitialSetup {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
            }
            .tint(tokens.accent)
            // 设置页是 sheet 内的独立 presentation；系统模式下也显式解析成当前系统深/浅色，避免从浅色切回默认时停在旧环境。
            .preferredColorScheme(resolvedColorScheme)
            .environment(\.colorScheme, resolvedColorScheme)
        }
    }
}

private struct DefaultPermissionView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    @AppStorage(ComposerPermissionMode.defaultStorageKey) private var defaultPermissionModeID = ComposerPermissionMode.defaultMode.rawValue

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            Section {
                ForEach(ComposerPermissionMode.allCases) { mode in
                    PermissionModeRow(
                        mode: mode,
                        isSelected: selectedMode == mode,
                        tokens: tokens
                    ) {
                        defaultPermissionModeID = mode.rawValue
                    }
                }
            } header: {
                Text("新对话默认权限")
            } footer: {
                Text("用于新输入区和切换会话后的默认运行权限。输入区里的权限按钮也会同步更新这个全局默认值。")
            }
        }
        .navigationTitle("默认权限")
        .tint(tokens.accent)
    }

    private var selectedMode: ComposerPermissionMode {
        ComposerPermissionMode.stored(defaultPermissionModeID)
    }
}

private struct PermissionModeRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    let mode: ComposerPermissionMode
    let isSelected: Bool
    let tokens: ThemeTokens
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? tokens.selectionFill : tokens.elevatedSurface)
                    Image(systemName: mode.systemImage)
                        .foregroundStyle(isSelected ? tokens.accent : tokens.secondaryText)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title)
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(mode.detail)
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

private struct ConnectionSettingsSections: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore

    let isInitialSetup: Bool

    @State private var endpoint = ""
    @State private var token = ""
    @State private var didLoadInitialConnection = false
    @State private var isShowingQRCodeScanner = false
    @State private var isShowingConnectionSuccess = false
    @State private var connectionSuccessMessage = ""
    @State private var isSavingConnection = false
    @State private var isShowingAdvancedManualConnection = false
    @State private var localError: String?

    var body: some View {
        Group {
            if isInitialSetup {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("在 Mac 上准备 Mimi Mac 助手", systemImage: "desktopcomputer")
                            .font(themeStore.uiFont(.headline, weight: .semibold))
                        Text("Mimi 需要和你的 Mac 配对一次，之后会自动连接本机 Codex 和项目目录。")
                            .font(themeStore.uiFont(.callout))
                            .foregroundStyle(.secondary)
                        Text("先确认 Mac 已安装并登录 Codex CLI，然后在终端运行：")
                            .font(themeStore.uiFont(.callout, weight: .semibold))
                        Text("brew install gaixianggeng/tap/mimi-remote\nagentd up")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("Mac 上出现二维码后，回到当前设备扫码连接。二维码过期时，在 Mac 运行 agentd pair 刷新。你的代码和 Codex 凭证仍留在自己的 Mac 上。")
                }
            }

            Section {
                Button {
                    isShowingQRCodeScanner = true
                } label: {
                    Label("扫描 Mac 上的二维码", systemImage: "qrcode.viewfinder")
                }
                .disabled(isSavingConnection)
            } header: {
                Text("在当前设备上配对")
            } footer: {
                Text("扫描 Mimi Mac 助手显示的二维码后会自动测试连接；成功后直接进入工作台。")
            }

            Section {
                DisclosureGroup(isExpanded: $isShowingAdvancedManualConnection) {
                    StableEndpointTextField(placeholder: "http://IP:端口", text: $endpoint)
                        .frame(minHeight: 28)
                    SecureField("访问 Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } label: {
                    Label("高级手动连接", systemImage: "slider.horizontal.3")
                }
            } header: {
                Text("备用")
            } footer: {
                Text("只有二维码不可用时才需要手动输入地址和访问码。支持本机、局域网、Tailscale 或自建 VPS 中转。")
            }

            Section {
                Button {
                    Task { await appStore.testConnection(endpoint: endpoint, token: token) }
                } label: {
                    Label(
                        isConnectionTesting ? "正在测试" : "测试连接",
                        systemImage: isConnectionTesting ? "timer" : "bolt.horizontal.circle"
                    )
                }
                .disabled(!canSubmit)

                Button {
                    Task { await save() }
                } label: {
                    Label("保存并进入工作台", systemImage: "checkmark.circle")
                }
                .disabled(!canSubmit)
            }

            Section {
                HStack {
                    Text("连接")
                    Spacer()
                    if isConnectionTesting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(appStore.connectionStatus.title)
                        .foregroundStyle(statusColor)
                }
                if let connectionTestDurationText {
                    HStack {
                        Text("测试耗时")
                        Spacer()
                        Text(connectionTestDurationText)
                            .monospacedDigit()
                            .foregroundStyle(statusColor)
                    }
                }
                if let message = displayErrorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(themeStore.uiFont(size: 13))
                }
            } header: {
                Text("状态")
            }

            Section {
                Button(role: .destructive) {
                    clearPairing()
                } label: {
                    Label("忘记这台 Mac", systemImage: "trash")
                }
                .disabled(isSavingConnection || !appStore.isConfigured)
            }
        }
        // 连接地址/Token 是高频编辑状态，放在这个小子树里，避免每次删字都重绘整个设置页。
        .onAppear(perform: loadInitialConnectionIfNeeded)
        .sheet(isPresented: $isShowingQRCodeScanner) {
            QRCodeScannerSheet { rawValue in
                Task { await applyScannedConnection(rawValue) }
            }
        }
        .alert("已找到这台 Mac", isPresented: $isShowingConnectionSuccess) {
            Button("好", role: .cancel) {}
        } message: {
            Text(connectionSuccessMessage)
        }
    }

    private var canSubmit: Bool {
        !isSavingConnection &&
        !isConnectionTesting &&
        !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isConnectionTesting: Bool {
        if case .testing = appStore.connectionStatus {
            return true
        }
        return false
    }

    private var connectionTestDurationText: String? {
        guard let milliseconds = appStore.lastConnectionTestDurationMillis else {
            return nil
        }
        return AppStore.connectionTestDurationText(milliseconds: milliseconds)
    }

    private var statusColor: Color {
        switch appStore.connectionStatus {
        case .connected:
            return themeStore.tokens(for: colorScheme).success
        case .failed:
            return .red
        case .testing:
            return themeStore.tokens(for: colorScheme).warning
        case .idle:
            return .secondary
        }
    }

    private var displayErrorMessage: String? {
        guard let raw = appStore.lastError ?? localError else {
            return nil
        }
        return friendlyConnectionMessage(raw)
    }

    private func friendlyConnectionMessage(_ raw: String) -> String {
        let lowercased = raw.lowercased()
        if lowercased.contains("expired") || raw.contains("过期") {
            return "配对二维码已过期，请在 Mac 上重新运行 agentd pair 后扫码。"
        }
        if lowercased.contains("unauthorized") || lowercased.contains("401") {
            return "这台设备没有通过 Mac 助手验证，请重新扫码连接。"
        }
        if lowercased.contains("timed out") || lowercased.contains("cannot connect") || raw.contains("无法连接") {
            return "当前设备暂时找不到这台 Mac。请确认 Mimi Mac 助手正在运行，并且当前设备能访问局域网、Tailscale 或自建 VPS 中转地址。"
        }
        if raw.contains("Endpoint") || raw.contains("连接链接") {
            return raw
        }
        return "连接没有完成。请确认 Mac 助手正在运行，或重新扫描 Mac 上的配对二维码。"
    }

    private func loadInitialConnectionIfNeeded() {
        guard !didLoadInitialConnection else {
            return
        }
        didLoadInitialConnection = true
        endpoint = appStore.endpoint
        token = appStore.token
    }

    private func save() async {
        isSavingConnection = true
        defer { isSavingConnection = false }
        do {
            try await appStore.validateAndSave(endpoint: endpoint, token: token)
            endpoint = appStore.endpoint
            token = appStore.token
            sessionStore.resetConnectionForSettingsChange(clearData: true)
            connectionSuccessMessage = ""
            localError = nil
            await sessionStore.refreshAll(autoAttach: true)
            if !isInitialSetup {
                dismiss()
            }
        } catch {
            appStore.connectionStatus = .failed(error.localizedDescription)
            appStore.lastError = error.localizedDescription
            localError = error.localizedDescription
        }
    }

    private func applyScannedConnection(_ rawValue: String) async {
        isSavingConnection = true
        defer { isSavingConnection = false }
        do {
            let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw) else {
                throw PairingLinkError.unsupportedURL
            }
            try await appStore.validateAndSavePairingURL(url)
            endpoint = appStore.endpoint
            token = appStore.token
            sessionStore.resetConnectionForSettingsChange(clearData: true)
            connectionSuccessMessage = "已连接这台 Mac，正在进入工作台。"
            localError = nil
            await sessionStore.refreshAll(autoAttach: true)
            if !isInitialSetup {
                dismiss()
            } else {
                isShowingConnectionSuccess = true
            }
            localError = nil
        } catch {
            appStore.connectionStatus = .failed(error.localizedDescription)
            appStore.lastError = error.localizedDescription
            localError = error.localizedDescription
        }
    }

    private func clearPairing() {
        do {
            try appStore.clearPairing()
            endpoint = appStore.endpoint
            token = appStore.token
            connectionSuccessMessage = ""
            sessionStore.resetConnectionForSettingsChange(clearData: true)
            localError = nil
            if !isInitialSetup {
                dismiss()
            }
        } catch {
            localError = error.localizedDescription
        }
    }
}

private struct CapabilitiesView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
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

            if let error = sessionStore.capabilityErrorMessage {
                Section("错误") {
                    Text(error)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(.red)
                }
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
        }
        .navigationTitle("能力")
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

private struct CapabilityValueRow: View {
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

private struct CapabilityItemRow: View {
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

                ForEach(ThemeMode.allCases) { mode in
                    ThemeModeRow(
                        mode: mode,
                        isSelected: themeStore.mode == mode,
                        tokens: tokens
                    ) {
                        themeStore.mode = mode
                    }
                }
            } header: {
                Text("深浅色")
            } footer: {
                Text("系统模式会跟随当前设备外观；浅色和深色会固定 App 外观。")
            }

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

            Section {
                AppearanceConversationPreview()
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } header: {
                Text("聊天预览")
            }

            Section {
                Button(role: .destructive) {
                    themeStore.reset()
                } label: {
                    Label("恢复默认外观", systemImage: "arrow.counterclockwise")
                }
            }
        }
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

private struct ThemeModeRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    let mode: ThemeMode
    let isSelected: Bool
    let tokens: ThemeTokens
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? tokens.selectionFill : tokens.elevatedSurface)
                    Image(systemName: iconName)
                        .foregroundStyle(isSelected ? tokens.accent : tokens.secondaryText)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title)
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(mode.subtitle)
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(tokens.accent)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
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

private struct ThemePresetRow: View {
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

private struct AppearanceConversationPreview: View {
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

private struct StableEndpointTextField: UIViewRepresentable {
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

private struct PreviewBubble: View {
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
