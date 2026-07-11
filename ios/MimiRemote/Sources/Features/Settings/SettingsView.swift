import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.themeSystemColorScheme) private var themeSystemColorScheme
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore

    let isInitialSetup: Bool
    var showsDoneButton = true

    @AppStorage("agentd.developerMode") private var developerModeEnabled = false
    @AppStorage("runtime.keepAwakeWhileRunning") private var keepAwakeWhileRunning = false

    var body: some View {
        let systemColorScheme = themeSystemColorScheme ?? colorScheme
        let resolvedColorScheme = themeStore.resolvedColorScheme(for: systemColorScheme)
        let tokens = themeStore.tokens(for: systemColorScheme)

        NavigationStack {
            Group {
                if isInitialSetup {
                    InitialPairingView()
                } else {
                    settingsForm(tokens: tokens)
                }
            }
            .navigationTitle(isInitialSetup ? "连接你的 Mac" : "设置")
            .navigationBarTitleDisplayMode(isInitialSetup ? .automatic : .inline)
            .toolbar {
                if !isInitialSetup && showsDoneButton {
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

    private func settingsForm(tokens: ThemeTokens) -> some View {
        let usage = sessionStore.accountCodexUsageWindowsDisplay

        return Form {
            Section("Mac 连接") {
                NavigationLink {
                    ConnectionManagementView()
                } label: {
                    LabeledContent("状态", value: appStore.connectionStatus.title)
                }
                LabeledContent("当前链路", value: appStore.activeConnectionRouteTitle)
            }

            Section("Codex 用量") {
                LabeledContent("账户", value: usage.displayName)
                ForEach(usage.windows) { window in
                    CodexUsageWindowRow(window: window, tint: tokens.accent)
                }
                LabeledContent("额度", value: usage.creditText)
            }

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
                Toggle("运行中保持屏幕常亮", isOn: $keepAwakeWhileRunning)
            } header: {
                Text("偏好")
            } footer: {
                Text("仅在前台选中会话运行或等待审批时生效。")
            }

            Section {
                Toggle("开发者模式", isOn: $developerModeEnabled)
                NavigationLink {
                    DoctorView(showsHistoryDiagnostics: developerModeEnabled)
                } label: {
                    Label("诊断与支持", systemImage: "stethoscope")
                }
                NavigationLink {
                    CapabilitiesView()
                } label: {
                    Label("能力清单", systemImage: "wand.and.stars")
                }
            } header: {
                Text("高级")
            } footer: {
                Text(developerModeEnabled ? "历史诊断可能显示本机路径和会话标题，仅用于排障。" : "开启后可使用高级运行选项和历史诊断。")
            }
        }
        .themedSettingsForm(tokens: tokens)
        .task {
            // 设置页也作为失败后的自然重试入口；成功态会直接复用，不产生重复请求。
            await appStore.preflightConnection()
        }
    }
}

private struct ConnectionManagementView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        Form {
            InitialConnectionSettingsSections()
        }
        .themedSettingsForm(tokens: themeStore.tokens(for: colorScheme))
        .navigationTitle("Mac 连接")
    }
}

private struct CodexUsageWindowRow: View {
    let window: CodexUsageWindowDisplay
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.kind.title)
                Spacer()
                Text(window.primaryText)
                    .foregroundStyle(.secondary)
            }
            Gauge(value: window.progress ?? 0) {
                EmptyView()
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(tint)
            Text("重置：\(window.resetText)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.kind.title) 用量")
        .accessibilityValue("\(window.primaryText)，\(window.resetText)")
    }
}

private struct InitialPairingView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            InitialConnectionSettingsSections()
        }
        .themedSettingsForm(tokens: tokens)
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
            .listRowBackground(tokens.elevatedSurface)
        }
        .themedSettingsForm(tokens: tokens)
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

private struct SettingsDashboardSection<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    let title: String
    let footer: String
    let content: Content

    init(title: String, footer: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(themeStore.uiFont(.headline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .padding(.horizontal, 2)

            VStack(spacing: 0) {
                content
            }
            .background(tokens.elevatedSurface.opacity(0.82), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tokens.border, lineWidth: 1)
            }

            Text(footer)
                .font(themeStore.uiFont(.footnote))
                .foregroundStyle(tokens.secondaryText)
                .padding(.horizontal, 2)
        }
    }
}

private struct SettingsDashboardNavigationRow<Destination: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    let systemImage: String
    let title: String
    let value: String
    let showsSeparator: Bool
    let destination: Destination

    init(
        systemImage: String,
        title: String,
        value: String,
        showsSeparator: Bool = true,
        @ViewBuilder destination: () -> Destination
    ) {
        self.systemImage = systemImage
        self.title = title
        self.value = value
        self.showsSeparator = showsSeparator
        self.destination = destination()
    }

    var body: some View {
        NavigationLink {
            destination
        } label: {
            SettingsDashboardRowContent(
                systemImage: systemImage,
                title: title,
                value: value,
                showsSeparator: showsSeparator,
                trailing: Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsDashboardToggleRow: View {
    @Binding var isOn: Bool
    let systemImage: String
    let title: String
    let value: String
    let showsSeparator: Bool

    init(
        systemImage: String,
        title: String,
        value: String,
        isOn: Binding<Bool>,
        showsSeparator: Bool = true
    ) {
        self.systemImage = systemImage
        self.title = title
        self.value = value
        self.showsSeparator = showsSeparator
        self._isOn = isOn
    }

    var body: some View {
        SettingsDashboardRowContent(
            systemImage: systemImage,
            title: title,
            value: value,
            showsSeparator: showsSeparator,
            trailing: Toggle("", isOn: $isOn)
                .labelsHidden()
        )
    }
}

private struct SettingsDashboardRowContent<Trailing: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    let systemImage: String
    let title: String
    let value: String
    let showsSeparator: Bool
    let trailing: Trailing

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tokens.accent.opacity(0.12))
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tokens.accent)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(themeStore.uiFont(.callout, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                Text(value)
                    .font(themeStore.uiFont(.footnote, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 10)

            trailing
                .foregroundStyle(tokens.tertiaryText)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 62)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if showsSeparator {
                Rectangle()
                    .fill(tokens.border.opacity(0.72))
                    .frame(height: 1)
                    .padding(.leading, 70)
            }
        }
    }
}

private struct GatewayDiagnosticSummary {
    let title: String
    let detail: String
    let color: Color
}

private struct InitialConnectionSettingsSections: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var endpoint = ""
    @State private var fallbackEndpoint = ""
    @State private var token = ""
    @State private var didLoadInitialConnection = false
    @State private var isShowingQRCodeScanner = false
    @State private var isShowingConnectionSuccess = false
    @State private var connectionSuccessMessage = ""
    @State private var isSavingConnection = false
    @State private var isShowingAdvancedManualConnection = false
    @State private var localError: String?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
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
                    StableEndpointTextField(placeholder: "首选地址（Tailscale）", text: $endpoint)
                        .frame(minHeight: 28)
                    StableEndpointTextField(placeholder: "备用公网地址（可选）", text: $fallbackEndpoint)
                        .frame(minHeight: 28)
                    SecureField("访问码", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } label: {
                    Label("手动连接", systemImage: "slider.horizontal.3")
                }
            } header: {
                Text("其他方式")
            } footer: {
                Text("优先连接 Tailscale 地址；首选链路不可用时自动切到备用公网 VPS。")
            }

            Section {
                Button {
                    Task {
                        await appStore.testConnection(
                            endpoint: endpoint,
                            fallbackEndpoint: fallbackEndpoint,
                            token: token
                        )
                    }
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

#if DEBUG
            Section {
                Button {
                    appStore.enterDebugWorkbenchWithoutPairing()
                } label: {
                    Label("Debug 进入工作台", systemImage: "wrench.and.screwdriver")
                }
            } footer: {
                Text("仅 Debug 编译可见；只跳过首屏配对，不保存访问码，也不改变 Release 流程。")
            }
#endif

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
                if let report = appStore.lastConnectionTestReport {
                    if let failedStage = report.failedStage {
                        connectionStageSummaryRow(title: "失败环节", stage: failedStage, color: .red)
                    } else if let slowestStage = report.slowestStage {
                        connectionStageSummaryRow(title: "最慢环节", stage: slowestStage, color: themeStore.tokens(for: colorScheme).warning)
                    }
                    if appStore.recentConnectionTestReports.count > 1,
                       let unstableStage = appStore.mostUnstableConnectionTestStage {
                        connectionStabilityRow(unstableStage)
                    }
                    ForEach(report.stages) { stage in
                        connectionStageRow(stage)
                    }
                    if let diagnostics = report.gatewayDiagnostics {
                        connectionGatewayDiagnosticsRows(diagnostics)
                    } else if let diagnosticsError = report.gatewayDiagnosticsError {
                        connectionGatewayDiagnosticsErrorRow(diagnosticsError)
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
        .listRowBackground(tokens.elevatedSurface)
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

    private func connectionStageSummaryRow(title: String, stage: ConnectionTestStageTiming, color: Color) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(stage.kind.title) · \(AppStore.connectionTestDurationText(milliseconds: stage.durationMillis))")
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }

    private func connectionStabilityRow(_ stability: ConnectionTestStageStability) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("最近波动")
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(stability.kind.title)
                    .foregroundStyle(themeStore.tokens(for: colorScheme).warning)
                Text(connectionStabilityDetailText(stability))
                    .font(themeStore.uiFont(.footnote))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func connectionStabilityDetailText(_ stability: ConnectionTestStageStability) -> String {
        let spread = AppStore.connectionTestDurationText(milliseconds: stability.spreadMillis)
        let max = AppStore.connectionTestDurationText(milliseconds: stability.maxMillis)
        if stability.failureCount > 0 {
            return "\(stability.sampleCount) 次 · 失败 \(stability.failureCount) 次 · 最大 \(max)"
        }
        return "\(stability.sampleCount) 次 · 波动 \(spread) · 最大 \(max)"
    }

    private func connectionStageRow(_ stage: ConnectionTestStageTiming) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(stage.kind.title)
                    if case .failed = stage.status {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(themeStore.uiFont(.caption2, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                }
                Text(stage.kind.detail)
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(stageDurationText(stage))
                .font(themeStore.uiFont(.footnote, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(connectionStageColor(stage))
                .lineLimit(1)
        }
    }

    private func stageDurationText(_ stage: ConnectionTestStageTiming) -> String {
        let duration = AppStore.connectionTestDurationText(milliseconds: stage.durationMillis)
        switch stage.status {
        case .succeeded:
            return duration
        case .failed:
            return "失败 · \(duration)"
        }
    }

    private func connectionStageColor(_ stage: ConnectionTestStageTiming) -> Color {
        switch stage.status {
        case .succeeded:
            return .secondary
        case .failed:
            return .red
        }
    }

    @ViewBuilder
    private func connectionGatewayDiagnosticsRows(_ diagnostics: ConnectionTestGatewayDiagnostics) -> some View {
        connectionGatewaySummaryRow(diagnostics)

        if diagnostics.failedUpstreamDialsDelta > 0 {
            connectionGatewayMetricRow(
                title: "上游拨号失败",
                detail: "本次测试新增失败，累计最大耗时",
                value: "\(diagnostics.failedUpstreamDialsDelta) 次 · \(AppStore.connectionTestDurationText(milliseconds: diagnostics.upstreamDialMillisMax))",
                color: .red
            )
        }

        if let connection = diagnostics.relatedConnection {
            connectionGatewayMetricRow(
                title: "Mac 上游拨号",
                detail: "agentd 到本机 app-server",
                value: AppStore.connectionTestDurationText(milliseconds: connection.upstreamDialMillis),
                color: gatewayMetricColor(milliseconds: connection.upstreamDialMillis)
            )
        }

        if let rpc = diagnostics.latestRPC {
            connectionGatewayMetricRow(
                title: "最近 RPC",
                detail: rpc.method.isEmpty ? "app-server JSON-RPC" : rpc.method,
                value: AppStore.connectionTestDurationText(milliseconds: rpc.latencyMillis),
                color: gatewayMetricColor(milliseconds: rpc.latencyMillis)
            )
        }

        if diagnostics.rpcOutstandingRequests > 0 {
            connectionGatewayMetricRow(
                title: "等待上游",
                detail: "app-server 仍未返回响应",
                value: "\(diagnostics.rpcOutstandingRequests) 个 · \(AppStore.connectionTestDurationText(milliseconds: diagnostics.rpcOutstandingMillisMax))",
                color: themeStore.tokens(for: colorScheme).warning
            )
        }

        if diagnostics.writeBackMillisMax > 0 {
            connectionGatewayMetricRow(
                title: "写回 iPad",
                detail: "agentd gateway 写给当前设备",
                value: AppStore.connectionTestDurationText(milliseconds: diagnostics.writeBackMillisMax),
                color: gatewayMetricColor(milliseconds: diagnostics.writeBackMillisMax)
            )
        }

        if let closeReason = diagnostics.relatedConnection?.closeReason,
           !closeReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            connectionGatewayMetricRow(
                title: "最近断开",
                detail: closeReason,
                value: nil,
                color: .secondary
            )
        }

        if let hint = diagnostics.hints.first {
            Text(hint)
                .font(themeStore.uiFont(.footnote))
                .foregroundStyle(.secondary)
        }
    }

    private func connectionGatewaySummaryRow(_ diagnostics: ConnectionTestGatewayDiagnostics) -> some View {
        let summary = gatewayDiagnosticSummary(diagnostics)
        return HStack(alignment: .top, spacing: 12) {
            Text("Gateway 判断")
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(summary.title)
                    .foregroundStyle(summary.color)
                    .lineLimit(1)
                Text(summary.detail)
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func connectionGatewayMetricRow(title: String, detail: String, value: String?, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            if let value {
                Text(value)
                    .font(themeStore.uiFont(.footnote, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
    }

    private func connectionGatewayDiagnosticsErrorRow(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("Gateway 诊断")
            Spacer(minLength: 12)
            Text(error)
                .font(themeStore.uiFont(.footnote))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    private func gatewayMetricColor(milliseconds: Int) -> Color {
        if milliseconds >= 2_000 {
            return .red
        }
        if milliseconds >= 500 {
            return themeStore.tokens(for: colorScheme).warning
        }
        return .secondary
    }

    private func gatewayDiagnosticSummary(_ diagnostics: ConnectionTestGatewayDiagnostics) -> GatewayDiagnosticSummary {
        let warning = themeStore.tokens(for: colorScheme).warning
        if diagnostics.failedUpstreamDialsDelta > 0 {
            return GatewayDiagnosticSummary(
                title: "上游拨号失败",
                detail: "agentd 连本机 app-server 失败",
                color: .red
            )
        }
        if diagnostics.rpcOutstandingRequests > 0 && diagnostics.rpcOutstandingMillisMax >= 2_000 {
            return GatewayDiagnosticSummary(
                title: "上游未返回",
                detail: "请求已进 app-server，响应还没回来",
                color: warning
            )
        }
        if let rpc = diagnostics.latestRPC,
           rpc.latencyMillis >= 1_000 {
            let method = rpc.method.isEmpty ? "app-server JSON-RPC" : rpc.method
            return GatewayDiagnosticSummary(
                title: "RPC 返回慢",
                detail: "\(method) 返回耗时偏高",
                color: gatewayMetricColor(milliseconds: rpc.latencyMillis)
            )
        }
        if diagnostics.writeBackMillisMax >= 500 {
            return GatewayDiagnosticSummary(
                title: "写回链路慢",
                detail: "优先看 iPad/VPS/公网转发",
                color: gatewayMetricColor(milliseconds: diagnostics.writeBackMillisMax)
            )
        }
        if let connection = diagnostics.relatedConnection,
           connection.upstreamDialMillis >= 500 {
            return GatewayDiagnosticSummary(
                title: "本机拨号慢",
                detail: "agentd 到 app-server 建连偏慢",
                color: gatewayMetricColor(milliseconds: connection.upstreamDialMillis)
            )
        }
        if diagnostics.totalConnectionsDelta > 0 {
            return GatewayDiagnosticSummary(
                title: "本次有新连接",
                detail: "未见明显 gateway 瓶颈",
                color: .secondary
            )
        }
        return GatewayDiagnosticSummary(
            title: "无新增样本",
            detail: "继续复现慢场景再看快照",
            color: .secondary
        )
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
        fallbackEndpoint = appStore.fallbackEndpoint
        token = appStore.token
    }

    private func save() async {
        isSavingConnection = true
        defer { isSavingConnection = false }
        do {
            _ = try await sessionStore.applyConnectionSettings(
                endpoint: endpoint,
                fallbackEndpoint: fallbackEndpoint,
                token: token
            )
            endpoint = appStore.endpoint
            fallbackEndpoint = appStore.fallbackEndpoint
            token = appStore.token
            connectionSuccessMessage = ""
            localError = nil
            await sessionStore.refreshAll(autoAttach: true)
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
            _ = try await sessionStore.applyPairingURL(url)
            endpoint = appStore.endpoint
            fallbackEndpoint = appStore.fallbackEndpoint
            token = appStore.token
            connectionSuccessMessage = "已连接这台 Mac，正在进入工作台。"
            localError = nil
            await sessionStore.refreshAll(autoAttach: true)
            isShowingConnectionSuccess = true
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
            fallbackEndpoint = appStore.fallbackEndpoint
            token = appStore.token
            connectionSuccessMessage = ""
            sessionStore.resetConnectionForSettingsChange(clearData: true)
            localError = nil
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

private extension View {
    func themedSettingsForm(tokens: ThemeTokens) -> some View {
        scrollContentBackground(.hidden)
            .background(tokens.background.ignoresSafeArea())
    }
}
