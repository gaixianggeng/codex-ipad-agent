import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.themeSystemColorScheme) private var themeSystemColorScheme
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore

    let isInitialSetup: Bool
    var showsDoneButton = true
    var embedsNavigationStack = true

    @AppStorage("agentd.developerMode") private var developerModeEnabled = false
    @AppStorage("runtime.keepAwakeWhileRunning") private var keepAwakeWhileRunning = false

    var body: some View {
        let systemColorScheme = themeSystemColorScheme ?? colorScheme
        let resolvedColorScheme = themeStore.resolvedColorScheme(for: systemColorScheme)
        let tokens = themeStore.tokens(for: systemColorScheme)

        Group {
            if embedsNavigationStack {
                NavigationStack {
                    settingsContent(tokens: tokens, resolvedColorScheme: resolvedColorScheme)
                }
            } else {
                settingsContent(tokens: tokens, resolvedColorScheme: resolvedColorScheme)
            }
        }
    }

    @ViewBuilder
    private func settingsContent(tokens: ThemeTokens, resolvedColorScheme: ColorScheme) -> some View {
        Group {
            if isInitialSetup {
                InitialPairingView()
            } else {
                settingsForm(tokens: tokens)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .background(tokens.background.ignoresSafeArea())
            }
        }
        .navigationTitle(isInitialSetup ? "连接你的 Mac" : "设置")
        .navigationBarTitleDisplayMode(initialNavigationTitleDisplayMode)
        .toolbar {
            if !isInitialSetup && showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                    .accessibilityLabel("关闭设置")
                    .accessibilityIdentifier("settings.close")
                }
            }
        }
        .tint(tokens.accent)
        // 设置页既可作为 sheet 自持 NavigationStack，也可嵌入紧凑 Tab 的 NavigationStack。
        .preferredColorScheme(resolvedColorScheme)
        .environment(\.colorScheme, resolvedColorScheme)
    }

    private var initialNavigationTitleDisplayMode: NavigationBarItem.TitleDisplayMode {
        // 手机保留醒目的首配大标题；iPad 宽屏改用居中标题，避免标题贴左而表单居中造成断裂。
        isInitialSetup && horizontalSizeClass == .compact ? .large : .inline
    }

    private func settingsForm(tokens: ThemeTokens) -> some View {
        let codexUsage = sessionStore.accountCodexUsageWindowsDisplay
        let claudeUsage = sessionStore.accountClaudeUsageWindowsDisplay

        return Form {
            Section("Mac 连接") {
                NavigationLink {
                    ConnectionManagementView()
                } label: {
                    LabeledContent(
                        "状态",
                        value: appStore.connectionTermination?.title
                            ?? (sessionStore.isNetworkUnavailable ? "网络不可用" : appStore.connectionStatus.title)
                    )
                }
                LabeledContent("连接地址", value: appStore.endpoint)
                if appStore.isUsingLocalConnection {
                    LabeledContent("连接方式", value: "本机直连")
                }
                NavigationLink {
                    ConnectionSpeedTestView()
                } label: {
                    HStack(spacing: 12) {
                        Label("连接测速", systemImage: "bolt.horizontal.circle")
                        Spacer(minLength: 12)
                        Text(connectionSpeedTestSummary)
                            .font(themeStore.uiFont(.callout))
                            .monospacedDigit()
                            .foregroundStyle(connectionSpeedTestTone(tokens: tokens))
                            .lineLimit(1)
                    }
                }
                .accessibilityIdentifier("settings.connectionSpeedTest")
                if let termination = appStore.connectionTermination {
                    Label(termination.message, systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(tokens.warning)
                } else if sessionStore.isNetworkUnavailable {
                    Label("网络不可用，已暂停同步；恢复后会自动重连。", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(tokens.warning)
                }
            }

            Section {
                RuntimeUsageSettingsCard(runtimeProvider: "codex", display: codexUsage)
            } header: {
                Text("Codex 用量")
            }

            if sessionStore.hasClaudeRuntimeChannel {
                Section {
                    RuntimeUsageSettingsCard(runtimeProvider: "claude", display: claudeUsage)
                } header: {
                    Text("Claude 用量")
                } footer: {
                    Text("Claude Code headless 当前不提供完整使用百分比；收到官方 rate-limit 事件后会显示真实窗口与重置时间，不会估算或抓取网页数据。")
                }
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
                NavigationLink {
                    ThirdPartyNoticesView()
                } label: {
                    Label("开源许可", systemImage: "doc.text")
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
            guard !appStore.requiresRePairing else {
                return
            }
            guard await appStore.preflightConnection(), appStore.isConfigured else {
                return
            }
            // 用 channel/model 元数据判断 Claude 是否真正接入；设置页独立打开时也要刷新，
            // 不能依赖用户先进入 Conversation 才出现 Claude 用量卡。
            await sessionStore.refreshAppServerModelOptions()
            await sessionStore.refreshCodexUsage()
            if sessionStore.hasClaudeRuntimeChannel {
                await sessionStore.refreshClaudeUsage()
            }
            let hasNotLoadedInitialData = sessionStore.projects.isEmpty
                && sessionStore.statusMessage == nil
            guard sessionStore.errorMessage != nil || hasNotLoadedInitialData else {
                return
            }
            // 45 秒首配超时后凭据已经安全落盘；用户打开设置即用健康连接做一次短恢复，
            // 不要求重新扫码，也不在已有首屏数据的正常连接上额外刷新。
            _ = await sessionStore.refreshAfterConnectionCommit(maxWait: 10)
        }
    }

    private var connectionSpeedTestSummary: String {
        if case .testing = appStore.connectionStatus {
            return "测试中…"
        }
        if appStore.lastConnectionTestReport?.failedStage != nil {
            return "测试失败"
        }
        guard let milliseconds = appStore.lastConnectionTestDurationMillis else {
            return "未测试"
        }
        return AppStore.connectionTestDurationText(milliseconds: milliseconds)
    }

    private func connectionSpeedTestTone(tokens: ThemeTokens) -> Color {
        if case .testing = appStore.connectionStatus {
            return tokens.accent
        }
        if appStore.lastConnectionTestReport?.failedStage != nil {
            return tokens.warning
        }
        return appStore.lastConnectionTestDurationMillis == nil ? tokens.secondaryText : tokens.success
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
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(themeStore.tokens(for: colorScheme).background.ignoresSafeArea())
        .navigationTitle("Mac 连接")
    }
}

private struct ConnectionSpeedTestView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(resultTone(tokens: tokens).opacity(0.14))
                        Image(systemName: resultSystemImage)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(resultTone(tokens: tokens))
                    }
                    .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(resultTitle)
                            .font(themeStore.uiFont(.headline, weight: .semibold))
                            .foregroundStyle(tokens.primaryText)
                        Text(appStore.endpoint)
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)

                    if let milliseconds = appStore.lastConnectionTestDurationMillis {
                        Text(AppStore.connectionTestDurationText(milliseconds: milliseconds))
                            .font(themeStore.uiFont(.callout, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(resultTone(tokens: tokens))
                            .lineLimit(1)
                    }
                }

                Button {
                    Task {
                        await appStore.testConnection(
                            endpoint: appStore.endpoint,
                            token: appStore.token
                        )
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "bolt.horizontal.circle")
                        }
                        Text(isTesting ? "正在测速…" : appStore.lastConnectionTestReport == nil ? "开始测速" : "重新测速")
                    }
                    .font(themeStore.uiFont(.body, weight: .semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRunTest)
                .accessibilityIdentifier("settings.connectionSpeedTest.run")
            } header: {
                Text("当前连接")
            } footer: {
                Text(canRunTest || isTesting ? "依次检查 iPhone / iPad 到 Mac 助手、鉴权、Gateway 配置和 app-server 握手。" : "当前没有可用的连接凭据，请先返回 Mac 连接完成配对。")
            }

            if let report = appStore.lastConnectionTestReport {
                Section("测速结果") {
                    LabeledContent("总耗时") {
                        Text(AppStore.connectionTestDurationText(milliseconds: report.totalMillis))
                            .monospacedDigit()
                            .foregroundStyle(resultTone(tokens: tokens))
                    }
                    LabeledContent("测试时间", value: report.startedAt.formatted(date: .abbreviated, time: .shortened))
                    if let failedStage = report.failedStage {
                        LabeledContent("失败环节", value: failedStage.kind.title)
                            .foregroundStyle(tokens.warning)
                    } else if let slowestStage = report.slowestStage {
                        LabeledContent("最慢环节") {
                            Text("\(slowestStage.kind.title) · \(AppStore.connectionTestDurationText(milliseconds: slowestStage.durationMillis))")
                                .monospacedDigit()
                        }
                    }
                }

                Section("分段耗时") {
                    ForEach(report.stages) { stage in
                        ConnectionSpeedTestStageRow(stage: stage)
                    }
                }

                if let diagnostics = report.gatewayDiagnostics {
                    Section("Gateway 观测") {
                        if let connection = diagnostics.relatedConnection {
                            ConnectionSpeedMetricRow(
                                title: "Mac 上游拨号",
                                value: AppStore.connectionTestDurationText(milliseconds: connection.upstreamDialMillis)
                            )
                        }
                        if let rpc = diagnostics.latestRPC {
                            ConnectionSpeedMetricRow(
                                title: "最近 RPC",
                                value: AppStore.connectionTestDurationText(milliseconds: rpc.latencyMillis)
                            )
                        }
                        if diagnostics.writeBackMillisMax > 0 {
                            ConnectionSpeedMetricRow(
                                title: "写回设备",
                                value: AppStore.connectionTestDurationText(milliseconds: diagnostics.writeBackMillisMax)
                            )
                        }
                    }
                }
            }
        }
        .themedSettingsForm(tokens: tokens)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(tokens.background.ignoresSafeArea())
        .navigationTitle("连接测速")
        .tint(tokens.accent)
    }

    private var isTesting: Bool {
        if case .testing = appStore.connectionStatus {
            return true
        }
        return false
    }

    private var canRunTest: Bool {
        appStore.isConfigured
            && !isTesting
            && !appStore.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !appStore.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var resultTitle: String {
        if isTesting {
            return "正在测试完整链路"
        }
        if appStore.lastConnectionTestReport?.failedStage != nil {
            return "连接测试失败"
        }
        if appStore.lastConnectionTestReport != nil {
            return "连接链路正常"
        }
        return appStore.isConfigured ? "可以开始测速" : "尚未连接 Mac"
    }

    private var resultSystemImage: String {
        if isTesting {
            return "timer"
        }
        if appStore.lastConnectionTestReport?.failedStage != nil {
            return "exclamationmark.triangle.fill"
        }
        if appStore.lastConnectionTestReport != nil {
            return "checkmark.circle.fill"
        }
        return "speedometer"
    }

    private func resultTone(tokens: ThemeTokens) -> Color {
        if isTesting {
            return tokens.accent
        }
        if appStore.lastConnectionTestReport?.failedStage != nil {
            return tokens.warning
        }
        return appStore.lastConnectionTestReport == nil ? tokens.secondaryText : tokens.success
    }
}

private struct ConnectionSpeedTestStageRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let stage: ConnectionTestStageTiming

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(alignment: .center, spacing: 12) {
            Image(systemName: stage.status.isFailed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(stage.status.isFailed ? tokens.warning : tokens.success)

            VStack(alignment: .leading, spacing: 2) {
                Text(stage.kind.title)
                    .foregroundStyle(tokens.primaryText)
                Text(stage.kind.detail)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(AppStore.connectionTestDurationText(milliseconds: stage.durationMillis))
                .font(themeStore.uiFont(.callout, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(stage.status.isFailed ? tokens.warning : tokens.secondaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stage.kind.title)，\(stage.status.isFailed ? "失败" : "成功")")
        .accessibilityValue(AppStore.connectionTestDurationText(milliseconds: stage.durationMillis))
    }
}

private struct ConnectionSpeedMetricRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .monospacedDigit()
        }
    }
}

private struct RuntimeUsageSettingsCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var isRefreshing = false

    let runtimeProvider: String
    let display: CodexUsageWindowsDisplay

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                CodexUsageRingsGraphic(
                    display: display,
                    metrics: CodexUsageRingMetrics(isCompact: horizontalSizeClass == .compact)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(display.displayName)
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(display.creditText)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 8)

                Button {
                    Task { await refreshUsage() }
                } label: {
                    Group {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.accent)
                .disabled(isRefreshing)
                .accessibilityLabel(isRefreshing ? "正在刷新 \(display.displayName) 用量" : "刷新 \(display.displayName) 用量")
                .accessibilityIdentifier("settings.\(runtimeProvider)Usage.refresh")
            }

            if display.windows.isEmpty {
                Text(emptyStateText)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(display.windows.prefix(2).enumerated()), id: \.element.id) { index, window in
                            if index > 0 {
                                Divider()
                            }
                            CodexCompactUsageWindow(window: window)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(display.windows.prefix(2).enumerated()), id: \.element.id) { index, window in
                            if index > 0 {
                                Divider()
                            }
                            CodexCompactUsageWindow(window: window)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    @MainActor
    private func refreshUsage() async {
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        if runtimeProvider == "claude" {
            await sessionStore.refreshClaudeUsage()
        } else {
            await sessionStore.refreshCodexUsage()
        }
    }

    private var emptyStateText: String {
        if runtimeProvider == "claude" {
            return "Claude headless 暂未返回可展示的额度窗口"
        }
        return "刷新后显示 \(display.displayName) 返回的账号窗口"
    }
}

private struct CodexCompactUsageWindow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let window: CodexUsageWindowDisplay

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let tint = usageTint

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                Text("\(window.label) \(window.title)")
                    .font(themeStore.uiFont(.caption, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(tokens.primaryText)
            }

            Text(window.remainingText)
                .font(themeStore.uiFont(.callout, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(window.remainingProgress == nil ? tokens.secondaryText : tint)
                .lineLimit(1)

            Text(window.resetText)
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.accessibilityName)剩余用量")
        .accessibilityValue("\(window.remainingText)，\(window.resetText)")
    }

    private var usageTint: Color {
        if window.durationMinutes != nil {
            return window.isDayScaleWindow ? .pink : .cyan
        }
        return window.kind == .secondary ? .pink : .cyan
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
        // 连接是短表单而不是数据表；宽窗口里限制行长，按钮和输入框不会被拉成整屏。
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(tokens.background.ignoresSafeArea())
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

struct GatewayDiagnosticSummary {
    let title: String
    let detail: String
    let color: Color
}
