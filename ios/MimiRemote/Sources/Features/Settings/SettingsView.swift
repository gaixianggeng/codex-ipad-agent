import SwiftUI

/// 设置首页只使用这一套尺寸基线，避免 NavigationLink、Picker、Toggle 和自定义摘要
/// 各自决定行高与图标尺寸，导致真机滚动时出现不一致的视觉节奏。
enum SettingsLayoutMetrics {
    static let standardRowHeight: CGFloat = 52
    static let accessibilityRowHeight: CGFloat = 76
    static let rowHorizontalInset: CGFloat = 16
    static let iconSlot: CGFloat = 28
    static let symbolPointSize: CGFloat = 18
    static let sectionSpacing: CGFloat = 24
    static let statusModuleCornerRadius: CGFloat = 20
    static let quotaSummaryMinimumHeight: CGFloat = 104
}

/// Token 摘要按真实可用宽度选择尺寸，而不是把 iPhone / iPad 名称写进布局。
/// 固定候选宽度交给 ViewThatFits 判断，也能自然覆盖分屏和 Stage Manager。
struct SettingsQuotaLayoutMetrics: Equatable {
    let candidateWidth: CGFloat
    let ringDiameter: CGFloat
    let ringLineWidth: CGFloat
    let informationWidth: CGFloat
    let clusterSpacing: CGFloat
    let rowHeight: CGFloat

    static let wide = SettingsQuotaLayoutMetrics(
        candidateWidth: 420,
        ringDiameter: 82,
        ringLineWidth: 5.5,
        informationWidth: 230,
        clusterSpacing: 18,
        rowHeight: 22
    )

    static let compact = SettingsQuotaLayoutMetrics(
        candidateWidth: 290,
        ringDiameter: 68,
        ringLineWidth: 5,
        informationWidth: 210,
        clusterSpacing: 12,
        rowHeight: 22
    )
}

private extension View {
    func settingsStandardListRow() -> some View {
        listRowInsets(
            EdgeInsets(
                top: 0,
                leading: SettingsLayoutMetrics.rowHorizontalInset,
                bottom: 0,
                trailing: SettingsLayoutMetrics.rowHorizontalInset
            )
        )
    }

    func settingsInlinePickerStyle() -> some View {
        modifier(SettingsInlinePickerStyleModifier())
    }
}

private struct SettingsInlinePickerStyleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    func body(content: Content) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)

        content
            .pickerStyle(.menu)
            // Picker 的选中值属于说明层级：与 NavigationLink 的右侧值使用同一
            // subheadline 和 secondaryText，不能跟随页面强调色抢过左侧标题。
            .font(themeStore.uiFont(.subheadline))
            .foregroundStyle(tokens.secondaryText)
            .tint(tokens.secondaryText)
    }
}

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
    @AppStorage(AppLanguage.preferenceKey) private var appLanguageRawValue = AppLanguage.system.rawValue
    @AppStorage(VoiceInputProvider.storageKey) private var voiceInputProviderRawValue = VoiceInputProvider.codex.rawValue
    @AppStorage(ComposerPermissionMode.defaultStorageKey) private var defaultPermissionModeID = ComposerPermissionMode.defaultMode.rawValue
    @StateObject private var qrScannerPresentation = ConnectionQRCodeScannerPresentation()

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
        // 扫码 Cover 固定挂在 SettingsView 根层。首次系统相机权限弹窗会触发 Form
        // 重建，但不会再销毁负责呈现相机的宿主。
        .fullScreenCover(
            item: $qrScannerPresentation.intent,
            onDismiss: qrScannerPresentation.didDismiss
        ) { intent in
            QRCodeScannerSheet(
                onDismiss: qrScannerPresentation.dismiss,
                onChooseManualConnection: {
                    qrScannerPresentation.chooseManualConnection(for: intent)
                },
                onCode: { rawValue in
                    await qrScannerPresentation.submit(rawValue, intent: intent)
                }
            )
        }
    }

    @ViewBuilder
    private func settingsContent(tokens: ThemeTokens, resolvedColorScheme: ColorScheme) -> some View {
        Group {
            if isInitialSetup {
                InitialPairingView(qrScannerPresentation: qrScannerPresentation)
            } else {
                settingsForm(tokens: tokens)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .background(tokens.background.ignoresSafeArea())
            }
        }
        .navigationTitle(isInitialSetup ? L10n.text("ui.connect_your_mac") : L10n.text("ui.settings"))
        .navigationBarTitleDisplayMode(initialNavigationTitleDisplayMode)
        .toolbar {
            if !isInitialSetup && showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("ui.complete")) {
                        dismiss()
                    }
                    .accessibilityLabel(L10n.text("ui.close_settings"))
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
            Section {
                settingsOverview(
                    codexUsage: codexUsage,
                    claudeUsage: claudeUsage,
                    tokens: tokens
                )
                // 自定义状态卡直接占满 Form 分配给 Section 的行宽，外边界才能与
                // 下方系统分组一致；卡片内部仍由 rowHorizontalInset 控制内容留白。
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } header: {
                Text(L10n.text("ui.status"))
            }

            Section {
                NavigationLink {
                    AppearanceView(profileID: appStore.activeHostScope.profileID)
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.personalization"),
                        value: themeStore.mode.title,
                        systemImage: "circle.lefthalf.filled",
                        symbolPointSize: 16
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.appearance")

                Picker(selection: appLanguageSelection) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName)
                            .tag(language)
                    }
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.language"),
                        systemImage: "globe"
                    )
                }
                .settingsInlinePickerStyle()
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.language")

                Picker(selection: voiceInputProviderSelection) {
                    ForEach(VoiceInputProvider.allCases) { provider in
                        Text(provider.title)
                            .tag(provider)
                    }
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.voice_input"),
                        systemImage: "waveform"
                    )
                }
                .settingsInlinePickerStyle()
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.voiceInput")

                Picker(selection: defaultPermissionModeSelection) {
                    ForEach(ComposerPermissionMode.allCases) { mode in
                        Text(mode.title)
                            .tag(mode)
                    }
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.default_permissions"),
                        systemImage: "lock.shield"
                    )
                }
                .settingsInlinePickerStyle()
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.defaultPermissions")
            } header: {
                Text(L10n.text("ui.preference"))
            }

            Section {
                NavigationLink {
                    DoctorView(showsHistoryDiagnostics: developerModeEnabled)
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.diagnosis_and_support"),
                        systemImage: "stethoscope"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.diagnostics")

                NavigationLink {
                    CapabilitiesView()
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.competency_checklist"),
                        systemImage: "wand.and.stars"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.capabilities")

                Toggle(isOn: $developerModeEnabled) {
                    SettingsValueLabel(
                        title: L10n.text("ui.developer_mode"),
                        systemImage: "hammer"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.developerMode")
            } header: {
                Text(L10n.text("ui.advanced"))
            } footer: {
                Text(developerModeEnabled ? L10n.text("ui.historical_diagnostics_may_display_the_local_machine_path") : L10n.text("ui.turn_on_to_use_advanced_operating_options_and"))
            }

            Section {
                NavigationLink {
                    LegalDocumentView(document: .support)
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.support_and_contact"),
                        systemImage: "questionmark.circle"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.support")

                NavigationLink {
                    LegalDocumentView(document: .privacyPolicy)
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.privacy_policy"),
                        systemImage: "hand.raised"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.privacyPolicy")

                NavigationLink {
                    LegalDocumentView(document: .termsOfUse)
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.terms_of_use"),
                        systemImage: "doc.text"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.termsOfUse")

                NavigationLink {
                    ThirdPartyNoticesView()
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.open_source_license"),
                        systemImage: "chevron.left.forwardslash.chevron.right"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.openSourceLicense")
            } header: {
                Text(L10n.text("ui.legal_and_support"))
            } footer: {
                Text(L10n.text("ui.legal_documents_are_included_in_the_app"))
            }
        }
        .listSectionSpacing(SettingsLayoutMetrics.sectionSpacing)
        .themedSettingsForm(tokens: tokens)
        .task {
            // 设置页也作为失败后的自然重试入口；成功态会直接复用，不产生重复请求。
            guard !appStore.requiresRePairing else {
                return
            }
            let preflightSucceeded = await appStore.preflightConnection()
            _ = await appStore.testConnectionOnFirstSettingsAppearanceIfNeeded()
            let hasConnectedStatus: Bool
            if case .connected = appStore.connectionStatus {
                hasConnectedStatus = true
            } else {
                hasConnectedStatus = false
            }
            guard (preflightSucceeded || hasConnectedStatus), appStore.isConfigured else {
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

    @ViewBuilder
    private func settingsOverview(
        codexUsage: CodexUsageWindowsDisplay,
        claudeUsage: CodexUsageWindowsDisplay,
        tokens: ThemeTokens
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 额度、设备和连接健康属于同一个状态摘要。始终保持纵向阅读路径，
            // 避免 iPad Sheet 只有约 548pt 时再次被拆成两张拥挤的仪表盘卡片。
            VStack(spacing: 0) {
                CombinedUsageSettingsCard(
                    codexDisplay: codexUsage,
                    claudeDisplay: claudeUsage,
                    includesClaude: sessionStore.hasClaudeRuntimeChannel
                )
                .padding(.horizontal, SettingsLayoutMetrics.rowHorizontalInset)
                .accessibilityIdentifier("settings.tokenQuota")

                Divider()
                    .overlay(tokens.border.opacity(0.72))
                    .padding(.horizontal, SettingsLayoutMetrics.rowHorizontalInset)

                NavigationLink {
                    ConnectionManagementView(qrScannerPresentation: qrScannerPresentation)
                } label: {
                    SettingsMacDevicesSummaryLabel(
                        currentDevice: currentMacDisplayName,
                        status: compactConnectionStatusText,
                        savedDeviceCount: appStore.connectionProfileSettingsModel.savedCount,
                        statusTint: connectionStatusTone(tokens: tokens)
                    )
                }
                .padding(.horizontal, SettingsLayoutMetrics.rowHorizontalInset)
                .accessibilityIdentifier("settings.connectionManagement")

                Divider()
                    .overlay(tokens.border.opacity(0.72))
                    .padding(.leading, 56)
                    .padding(.trailing, SettingsLayoutMetrics.rowHorizontalInset)

                NavigationLink {
                    ConnectionSpeedTestView()
                } label: {
                    SettingsStatusSummaryLabel(
                        title: L10n.text("ui.connection_speed_test"),
                        detail: connectionSpeedTestSummary,
                        systemImage: "gauge.with.dots.needle.67percent",
                        detailTint: connectionSpeedTestTone(tokens: tokens)
                    )
                }
                .padding(.horizontal, SettingsLayoutMetrics.rowHorizontalInset)
                .accessibilityIdentifier("settings.connectionSpeedTest")
            }
            .background(
                tokens.surface,
                in: RoundedRectangle(
                    cornerRadius: SettingsLayoutMetrics.statusModuleCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: SettingsLayoutMetrics.statusModuleCornerRadius,
                    style: .continuous
                )
                    .stroke(tokens.border.opacity(0.42), lineWidth: 0.5)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.statusModule")

            if let warningText = connectionWarningText {
                Label(warningText, systemImage: "exclamationmark.triangle")
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }
        }
    }

    private var connectionSpeedTestSummary: String {
        if case .testing = appStore.connectionStatus {
            return L10n.text("ui.testing")
        }
        if appStore.lastConnectionTestReport?.failedStage != nil {
            return L10n.text("ui.test_failed")
        }
        guard let milliseconds = appStore.lastConnectionTestDurationMillis else {
            return L10n.text("ui.not_tested")
        }
        return AppStore.connectionTestDurationText(milliseconds: milliseconds)
    }

    private var compactConnectionStatusText: String {
        if let termination = appStore.connectionTermination {
            return termination.title
        }
        if sessionStore.isNetworkUnavailable {
            return L10n.text("ui.network_is_unavailable")
        }
        if case .connected = appStore.connectionStatus {
            return L10n.text("ui.connected")
        }
        return appStore.connectionStatus.title
    }

    private var connectionWarningText: String? {
        if let termination = appStore.connectionTermination {
            return termination.message
        }
        if sessionStore.isNetworkUnavailable {
            return L10n.text("ui.the_network_is_unavailable_and_synchronization_has_been")
        }
        return nil
    }

    private func connectionStatusTone(tokens: ThemeTokens) -> Color {
        if appStore.connectionTermination != nil || sessionStore.isNetworkUnavailable {
            return tokens.warning
        }
        switch appStore.connectionStatus {
        case .connected:
            return tokens.success
        case .testing:
            return tokens.accent
        case .failed:
            return tokens.warning
        case .idle:
            return tokens.secondaryText
        }
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

    private var currentMacDisplayName: String {
        appStore.connectionProfileSettingsModel.current?.profile.displayName
            ?? L10n.text("ui.current_mac")
    }

    private var appLanguageSelection: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: appLanguageRawValue) ?? .system },
            set: { appLanguageRawValue = $0.rawValue }
        )
    }

    private var voiceInputProviderSelection: Binding<VoiceInputProvider> {
        Binding(
            get: { VoiceInputProvider(rawValue: voiceInputProviderRawValue) ?? .codex },
            set: { voiceInputProviderRawValue = $0.rawValue }
        )
    }

    private var defaultPermissionModeSelection: Binding<ComposerPermissionMode> {
        Binding(
            get: { ComposerPermissionMode.stored(defaultPermissionModeID) },
            set: { defaultPermissionModeID = $0.rawValue }
        )
    }
}

private struct SettingsMacDevicesSummaryLabel: View {
    let currentDevice: String
    let status: String
    let savedDeviceCount: Int
    let statusTint: Color

    var body: some View {
        SettingsStatusSummaryLabel(
            title: L10n.text("ui.mac_devices"),
            detail: "\(currentDevice) · \(status) · \(savedCount)",
            systemImage: "desktopcomputer",
            statusDotTint: statusTint,
            symbolPointSize: 17
        )
    }

    private var savedCount: String {
        L10n.plural("ui.saved_macs_count", count: savedDeviceCount)
    }
}

/// 状态模块的两个入口共享同一套双行结构，避免设备行、测速行因内容不同
/// 产生不一致的高度、图标大小和基线。
private struct SettingsStatusSummaryLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var themeStore: ThemeStore

    let title: String
    let detail: String
    let systemImage: String
    var detailTint: Color? = nil
    var statusDotTint: Color? = nil
    var symbolPointSize: CGFloat = SettingsLayoutMetrics.symbolPointSize

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: symbolPointSize, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.accent)
                .frame(
                    width: SettingsLayoutMetrics.iconSlot,
                    height: SettingsLayoutMetrics.iconSlot
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(themeStore.uiFont(.body))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                HStack(spacing: 5) {
                    if let statusDotTint {
                        Circle()
                            .fill(statusDotTint)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }

                    Text(detail)
                        .font(themeStore.uiFont(.footnote))
                        .monospacedDigit()
                        .foregroundStyle(detailTint ?? tokens.secondaryText)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .minimumScaleFactor(0.82)
                        .truncationMode(.tail)
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: rowHeight,
            maxHeight: rowHeight,
            alignment: .leading
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var rowHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize
            ? SettingsLayoutMetrics.accessibilityRowHeight
            : SettingsLayoutMetrics.standardRowHeight
    }
}

private struct SettingsValueLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var themeStore: ThemeStore

    let title: String
    var value: String? = nil
    let systemImage: String
    var valueTint: Color? = nil
    var symbolPointSize: CGFloat = SettingsLayoutMetrics.symbolPointSize

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: symbolPointSize, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.accent)
                .frame(
                    width: SettingsLayoutMetrics.iconSlot,
                    height: SettingsLayoutMetrics.iconSlot
                )
                .accessibilityHidden(true)

            if dynamicTypeSize.isAccessibilitySize, let value {
                VStack(alignment: .leading, spacing: 2) {
                    titleText(tokens: tokens)
                    valueText(value, tokens: tokens)
                }
            } else if let value {
                HStack(alignment: .center, spacing: 12) {
                    titleText(tokens: tokens)
                    Spacer(minLength: 12)
                    valueText(value, tokens: tokens)
                }
            } else {
                titleText(tokens: tokens)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: rowHeight,
            maxHeight: rowHeight,
            alignment: .leading
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func titleText(tokens: ThemeTokens) -> some View {
        Text(title)
            .font(themeStore.uiFont(.body))
            .foregroundStyle(tokens.primaryText)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            .layoutPriority(1)
    }

    private func valueText(_ value: String, tokens: ThemeTokens) -> some View {
        Text(value)
            .font(themeStore.uiFont(.subheadline))
            .monospacedDigit()
            .foregroundStyle(valueTint ?? tokens.secondaryText)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            .minimumScaleFactor(0.82)
            .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
    }

    private var rowHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize
            ? SettingsLayoutMetrics.accessibilityRowHeight
            : SettingsLayoutMetrics.standardRowHeight
    }
}

private struct ConnectionManagementView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    @ObservedObject var qrScannerPresentation: ConnectionQRCodeScannerPresentation

    var body: some View {
        Form {
            InitialConnectionSettingsSections(qrScannerPresentation: qrScannerPresentation)
        }
        .themedSettingsForm(tokens: themeStore.tokens(for: colorScheme))
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(themeStore.tokens(for: colorScheme).background.ignoresSafeArea())
        .navigationTitle(L10n.text("ui.mac_connection"))
    }
}

private struct ConnectionSpeedTestView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                        Text(isTesting ? L10n.text("ui.testing_speed") : appStore.lastConnectionTestReport == nil ? L10n.text("ui.start_speed_test") : L10n.text("ui.retest_speed"))
                    }
                    .font(themeStore.uiFont(.body, weight: .semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRunTest)
                .accessibilityIdentifier("settings.connectionSpeedTest.run")
            } header: {
                Text(L10n.text("ui.current_connection"))
            } footer: {
                Text(canRunTest || isTesting ? L10n.text("ui.check_iphone_ipad_to_mac_assistant_authentication_gateway") : L10n.text("ui.there_are_currently_no_connection_credentials_available_please"))
            }

            if let report = appStore.lastConnectionTestReport {
                Section(L10n.text("ui.speed_test_results")) {
                    connectionSpeedResultSummary(report: report, tokens: tokens)
                        // 把结果概览作为一个内容自适应的 Form 行，避免系统 LabeledContent
                        // 在部分 iOS 26/27 布局中把最后一行拉伸到整屏高度。
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }

                Section(L10n.text("ui.segmentation_takes_time")) {
                    ForEach(report.stages) { stage in
                        ConnectionSpeedTestStageRow(stage: stage)
                    }
                }

                if let diagnostics = report.gatewayDiagnostics {
                    Section(L10n.text("ui.gateway_observation")) {
                        if let connection = diagnostics.relatedConnection {
                            ConnectionSpeedMetricRow(
                                title: L10n.text("ui.mac_upstream_dialing"),
                                value: AppStore.connectionTestDurationText(milliseconds: connection.upstreamDialMillis)
                            )
                        }
                        if let rpc = diagnostics.latestRPC {
                            ConnectionSpeedMetricRow(
                                title: L10n.text("ui.recent_rpcs"),
                                value: AppStore.connectionTestDurationText(milliseconds: rpc.latencyMillis)
                            )
                        }
                        if diagnostics.writeBackMillisMax > 0 {
                            ConnectionSpeedMetricRow(
                                title: L10n.text("ui.write_back_to_device"),
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
        .navigationTitle(L10n.text("ui.connection_speed_test"))
        .tint(tokens.accent)
    }

    private func connectionSpeedResultSummary(
        report: ConnectionTestReport,
        tokens: ThemeTokens
    ) -> some View {
        VStack(spacing: 0) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 14) {
                        connectionSpeedTotalMetric(report: report, tokens: tokens)
                        Divider()
                            .overlay(tokens.border.opacity(0.72))
                        connectionSpeedBottleneckMetric(report: report, tokens: tokens)
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        connectionSpeedTotalMetric(report: report, tokens: tokens)

                        Divider()
                            .overlay(tokens.border.opacity(0.72))
                            .frame(height: 68)

                        connectionSpeedBottleneckMetric(report: report, tokens: tokens)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)

            Divider()
                .overlay(tokens.border.opacity(0.72))

            connectionSpeedResultDetailRow(
                title: L10n.text("ui.test_time"),
                tokens: tokens
            ) {
                Text(report.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(tokens.secondaryText)
            }

            if let networkPath = report.tailscaleNetworkPath {
                Divider()
                    .overlay(tokens.border.opacity(0.72))
                    .padding(.leading, 16)

                connectionSpeedResultDetailRow(
                    title: L10n.text("ui.tailscale_network_path"),
                    tokens: tokens
                ) {
                    connectionSpeedNetworkPathBadge(
                        networkPath: networkPath,
                        tokens: tokens
                    )
                }
            }
        }
        .background(tokens.surface)
    }

    private func connectionSpeedTotalMetric(
        report: ConnectionTestReport,
        tokens: ThemeTokens
    ) -> some View {
        connectionSpeedHighlightMetric(
            title: L10n.text("ui.total_time_spent"),
            systemImage: "timer",
            value: AppStore.connectionTestDurationText(milliseconds: report.totalMillis),
            detail: nil,
            tone: resultTone(tokens: tokens),
            tokens: tokens
        )
    }

    @ViewBuilder
    private func connectionSpeedBottleneckMetric(
        report: ConnectionTestReport,
        tokens: ThemeTokens
    ) -> some View {
        if let failedStage = report.failedStage {
            connectionSpeedHighlightMetric(
                title: L10n.text("ui.failure_link"),
                systemImage: "exclamationmark.triangle.fill",
                value: failedStage.kind.title,
                detail: AppStore.connectionTestDurationText(milliseconds: failedStage.durationMillis),
                tone: tokens.warning,
                tokens: tokens
            )
        } else if let slowestStage = report.slowestStage {
            connectionSpeedHighlightMetric(
                title: L10n.text("ui.slowest_link"),
                systemImage: "gauge.with.dots.needle.67percent",
                value: AppStore.connectionTestDurationText(milliseconds: slowestStage.durationMillis),
                detail: slowestStage.kind.title,
                tone: tokens.warning,
                tokens: tokens
            )
        }
    }

    private func connectionSpeedHighlightMetric(
        title: String,
        systemImage: String,
        value: String,
        detail: String?,
        tone: Color,
        tokens: ThemeTokens
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(themeStore.uiFont(.caption, weight: .medium))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)

            Text(value)
                .font(themeStore.uiFont(.title3, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tone)
                .lineLimit(1)

            if let detail {
                Text(detail)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func connectionSpeedResultDetailRow<Value: View>(
        title: String,
        tokens: ThemeTokens,
        @ViewBuilder value: () -> Value
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(themeStore.uiFont(.callout))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 12)

                value()
                    .font(themeStore.uiFont(.callout))
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: true, vertical: false)
            }

            // 窄屏或大字号时让右侧状态整体换到下一行，避免状态文字被挤成逐字换行。
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(themeStore.uiFont(.callout))
                    .foregroundStyle(tokens.primaryText)

                value()
                    .font(themeStore.uiFont(.callout))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func connectionSpeedNetworkPathBadge(
        networkPath: TailscaleNetworkPathResponse,
        tokens: ThemeTokens
    ) -> some View {
        let tone = tailscaleNetworkPathTone(networkPath.kind, tokens: tokens)

        return HStack(spacing: 6) {
            Image(systemName: networkPath.kind.settingsSystemImage)
                .font(.system(size: 13, weight: .semibold))

            Text(networkPath.localizedSummary)
                .font(themeStore.uiFont(.footnote, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(tone)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tone.opacity(0.11), in: Capsule())
        .overlay {
            Capsule()
                .stroke(tone.opacity(0.18), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
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
            return L10n.text("ui.testing_full_link")
        }
        if appStore.lastConnectionTestReport?.failedStage != nil {
            return L10n.text("ui.connection_test_failed")
        }
        if appStore.lastConnectionTestReport != nil {
            return L10n.text("ui.the_connection_link_is_normal")
        }
        return appStore.isConfigured ? L10n.text("ui.you_can_start_speed_measurement") : L10n.text("ui.not_connected_to_mac_yet")
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

    private func tailscaleNetworkPathTone(
        _ kind: TailscaleNetworkPathResponse.Kind,
        tokens: ThemeTokens
    ) -> Color {
        switch kind {
        case .direct:
            return tokens.success
        case .peerRelay, .derp:
            return tokens.warning
        case .notTailscale, .unknown, .unavailable:
            return tokens.secondaryText
        }
    }
}

extension TailscaleNetworkPathResponse {
    var localizedSummary: String {
        switch kind {
        case .direct:
            return L10n.text("ui.tailscale_path_direct")
        case .peerRelay:
            return L10n.text("ui.tailscale_path_peer_relay")
        case .derp:
            let title = L10n.text("ui.tailscale_path_derp")
            guard let relayRegion,
                  !relayRegion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return title
            }
            return "\(title) · \(relayRegion.uppercased())"
        case .notTailscale:
            return L10n.text("ui.tailscale_path_not_tailscale")
        case .unknown:
            return L10n.text("ui.tailscale_path_unknown")
        case .unavailable:
            return L10n.text("ui.tailscale_path_unavailable")
        }
    }
}

extension TailscaleNetworkPathResponse.Kind {
    var settingsSystemImage: String {
        switch self {
        case .direct:
            return "bolt.horizontal.circle.fill"
        case .peerRelay:
            return "arrow.left.arrow.right.circle"
        case .derp:
            return "network"
        case .notTailscale:
            return "wifi"
        case .unknown, .unavailable:
            return "questionmark.circle"
        }
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
        .accessibilityLabel(L10n.format("ui.connection_test_stage_accessibility", stage.kind.title, stage.status.isFailed ? L10n.text("ui.failed_status") : L10n.text("ui.success")))
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

/// 刷新入口属于“Token 额度”分区，而不是某一条额度数据；放在标题右侧可避免压缩卡片内容。
private struct AIUsageRefreshButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore

    let includesClaude: Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let isRefreshing = sessionStore.isRefreshingUsage(runtimeProvider: "codex")
            || (includesClaude && sessionStore.isRefreshingUsage(runtimeProvider: "claude"))

        Button {
            Task {
                await sessionStore.refreshCodexUsage()
                if includesClaude {
                    await sessionStore.refreshClaudeUsage()
                }
            }
        } label: {
            Group {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tokens.secondaryText)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .frame(width: 34, height: 34)
            .background(tokens.secondaryText.opacity(0.08), in: Circle())
            .overlay {
                Circle()
                    .stroke(tokens.border.opacity(0.72), lineWidth: 1)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tokens.secondaryText)
        .disabled(isRefreshing)
        .accessibilityLabel(
            isRefreshing
                ? L10n.format("ui.refreshing_value_usage", L10n.text("ui.token_quota"))
                : L10n.format("ui.refresh_value_usage", L10n.text("ui.token_quota"))
        )
        .accessibilityIdentifier("settings.aiUsage.refresh")
    }
}

private struct CombinedUsageSettingsCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var themeStore: ThemeStore

    let codexDisplay: CodexUsageWindowsDisplay
    let claudeDisplay: CodexUsageWindowsDisplay
    let includesClaude: Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            if dynamicTypeSize.isAccessibilitySize {
                verticalLayout(tokens: tokens)
            } else {
                // 从宽到窄依次尝试：普通 iPad 使用 82pt，iPhone 与窄分屏
                // 使用 68pt；再窄时才改为上下结构，避免文字被挤压。
                ViewThatFits(in: .horizontal) {
                    horizontalLayout(tokens: tokens, metrics: .wide)
                        .frame(width: SettingsQuotaLayoutMetrics.wide.candidateWidth)

                    horizontalLayout(tokens: tokens, metrics: .compact)
                        .frame(width: SettingsQuotaLayoutMetrics.compact.candidateWidth)

                    verticalLayout(tokens: tokens)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func horizontalLayout(
        tokens: ThemeTokens,
        metrics: SettingsQuotaLayoutMetrics
    ) -> some View {
        HStack(alignment: .center, spacing: metrics.clusterSpacing) {
            usageRings(
                diameter: metrics.ringDiameter,
                lineWidth: metrics.ringLineWidth
            )
            .frame(width: metrics.ringDiameter, height: metrics.ringDiameter)

            // 标题、刷新和三条额度共享一个固定宽度的信息组。这样刷新操作
            // 靠近它影响的内容，百分比也只在组内贴右，不会漂到卡片边缘。
            VStack(alignment: .leading, spacing: 0) {
                quotaHeader(tokens: tokens)
                usageRows(rowHeight: metrics.rowHeight)
            }
            .frame(width: metrics.informationWidth)
        }
        .padding(.vertical, 4)
        .frame(minHeight: SettingsLayoutMetrics.quotaSummaryMinimumHeight)
    }

    private func verticalLayout(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            quotaHeader(tokens: tokens)

            usageRings(
                diameter: SettingsQuotaLayoutMetrics.compact.ringDiameter,
                lineWidth: SettingsQuotaLayoutMetrics.compact.ringLineWidth
            )
            .frame(maxWidth: .infinity)

            usageRows(rowHeight: dynamicTypeSize.isAccessibilitySize ? 44 : 28)
        }
        .padding(.vertical, 10)
    }

    private func quotaHeader(tokens: ThemeTokens) -> some View {
        HStack(spacing: 8) {
            Text(L10n.text("ui.token_quota"))
                .font(themeStore.uiFont(.subheadline, weight: .medium))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(1)

            Spacer(minLength: 8)

            AIUsageRefreshButton(includesClaude: includesClaude)
        }
        // 刷新按钮的视觉圆只有 34pt，但仍保留 44pt 点击区；让点击区轻微
        // 溢出标题行，不增加整个 Token 模块的高度。
        .frame(height: 34)
    }

    private func usageRings(diameter: CGFloat, lineWidth: CGFloat) -> some View {
        CombinedUsageRingsGraphic(
            items: usageItems,
            expectedRingCount: 3,
            diameter: diameter,
            lineWidth: lineWidth
        )
    }

    @ViewBuilder
    private func usageRows(rowHeight: CGFloat) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let items = usageItems

        if items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(codexDisplay.creditText)
                if includesClaude {
                    Text(claudeDisplay.creditText)
                }
            }
            .font(themeStore.uiFont(.caption))
            .foregroundStyle(tokens.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    CombinedUsageWindowRow(item: item, minimumHeight: rowHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 产品只需要 Codex 的长窗口，以及 Claude 的长、短两个窗口。
    /// 服务端的 primary/secondary 槽位并不稳定，因此按真实时长选择而不是写死槽位。
    private var usageItems: [CombinedUsageItem] {
        CombinedUsageItem.make(
            codexDisplay: codexDisplay,
            claudeDisplay: claudeDisplay,
            includesClaude: includesClaude,
            claudeShortTint: themeStore.tokens(for: colorScheme).accent
        )
    }
}

private struct CombinedUsageWindowRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let item: CombinedUsageItem
    let minimumHeight: CGFloat

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .center, spacing: 6) {
                Circle()
                    .fill(item.tint)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 0) {
                    Text("\(item.providerName) · \(item.window.label)")
                        .font(themeStore.uiFont(.footnote, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Text(resetText)
                        .font(themeStore.uiFont(.caption2))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                }
            }

            Spacer(minLength: 12)

            Text(item.window.remainingPercentText ?? "—")
                .font(themeStore.uiFont(.footnote, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(
                    item.window.remainingProgress == nil ? tokens.secondaryText : item.tint
                )
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, minHeight: minimumHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.format("ui.value_remaining_usage", item.window.accessibilityName)
        )
        .accessibilityValue(
            L10n.format(
                "ui.usage_window_accessibility_value",
                item.window.remainingText,
                resetText
            )
        )
    }

    private var resetText: String {
        guard let resetDate = item.window.resetDate else {
            return item.window.resetText
        }

        let formatter = DateFormatter()
        formatter.locale = AppLanguage.stored().locale
        formatter.setLocalizedDateFormatFromTemplate(
            Calendar.current.isDate(resetDate, inSameDayAs: Date()) ? "Hm" : "MdHm"
        )
        return L10n.format("ui.value_reset_english", formatter.string(from: resetDate))
    }
}

private struct InitialPairingView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    @ObservedObject var qrScannerPresentation: ConnectionQRCodeScannerPresentation

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            InitialConnectionSettingsSections(qrScannerPresentation: qrScannerPresentation)
        }
        .themedSettingsForm(tokens: tokens)
        // 连接是短表单而不是数据表；宽窗口里限制行长，按钮和输入框不会被拉成整屏。
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(tokens.background.ignoresSafeArea())
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
