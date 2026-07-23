import SwiftUI

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
    @AppStorage(VoiceInputProvider.storageKey) private var voiceInputProviderRawValue = VoiceInputProvider.apple.rawValue

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
            Section(L10n.text("ui.mac_connection")) {
                NavigationLink {
                    ConnectionManagementView()
                } label: {
                    LabeledContent(
                        L10n.text("ui.status"),
                        value: appStore.connectionTermination?.title
                            ?? (sessionStore.isNetworkUnavailable ? L10n.text("ui.network_is_unavailable") : appStore.connectionStatus.title)
                    )
                }
                LabeledContent(L10n.text("ui.connection_address"), value: appStore.endpoint)
                if appStore.isUsingLocalConnection {
                    LabeledContent(L10n.text("ui.connection_method"), value: L10n.text("ui.direct_connection_to_this_machine"))
                }
                NavigationLink {
                    ConnectionSpeedTestView()
                } label: {
                    HStack(spacing: 12) {
                        Label(L10n.text("ui.connection_speed_test"), systemImage: "bolt.horizontal.circle")
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
                    Label(L10n.text("ui.the_network_is_unavailable_and_synchronization_has_been"), systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(tokens.warning)
                }
            }

            Section(L10n.text("ui.ai_usage")) {
                RuntimeUsageSettingsCard(runtimeProvider: "codex", display: codexUsage)
                if sessionStore.hasClaudeRuntimeChannel {
                    RuntimeUsageSettingsCard(runtimeProvider: "claude", display: claudeUsage)
                }
            }

            Section {
                Picker(selection: appLanguageSelection) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName)
                            .tag(language)
                    }
                } label: {
                    Label(L10n.text("ui.language"), systemImage: "globe")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.language")
                NavigationLink {
                    AppearanceView()
                } label: {
                    Label(L10n.text("ui.appearance"), systemImage: "paintpalette")
                }
                NavigationLink {
                    DefaultPermissionView()
                } label: {
                    Label(L10n.text("ui.default_permissions"), systemImage: "lock.shield")
                }
            } header: {
                Text(L10n.text("ui.preference"))
            }

            Section {
                ForEach(VoiceInputProvider.storeAvailableCases) { provider in
                    VoiceInputProviderRow(
                        provider: provider,
                        isSelected: voiceInputProviderSelection.wrappedValue == provider,
                        tokens: tokens
                    ) {
                        voiceInputProviderSelection.wrappedValue = provider
                    }
                }
            } header: {
                Text(L10n.text("ui.voice_input"))
            }

            Section {
                Toggle(L10n.text("ui.developer_mode"), isOn: $developerModeEnabled)
                NavigationLink {
                    DoctorView(showsHistoryDiagnostics: developerModeEnabled)
                } label: {
                    Label(L10n.text("ui.diagnosis_and_support"), systemImage: "stethoscope")
                }
                NavigationLink {
                    CapabilitiesView()
                } label: {
                    Label(L10n.text("ui.competency_checklist"), systemImage: "wand.and.stars")
                }
                NavigationLink {
                    ThirdPartyNoticesView()
                } label: {
                    Label(L10n.text("ui.open_source_license"), systemImage: "doc.text")
                }
            } header: {
                Text(L10n.text("ui.advanced"))
            } footer: {
                Text(developerModeEnabled ? L10n.text("ui.historical_diagnostics_may_display_the_local_machine_path") : L10n.text("ui.turn_on_to_use_advanced_operating_options_and"))
            }

            Section {
                NavigationLink {
                    LegalDocumentView(document: .privacyPolicy)
                } label: {
                    Label(L10n.text("ui.privacy_policy"), systemImage: "hand.raised")
                }
                .accessibilityIdentifier("settings.privacyPolicy")

                NavigationLink {
                    LegalDocumentView(document: .termsOfUse)
                } label: {
                    Label(L10n.text("ui.terms_of_use"), systemImage: "doc.text")
                }
                .accessibilityIdentifier("settings.termsOfUse")

                NavigationLink {
                    LegalDocumentView(document: .support)
                } label: {
                    Label(L10n.text("ui.support_and_contact"), systemImage: "questionmark.circle")
                }
                .accessibilityIdentifier("settings.support")
            } header: {
                Text(L10n.text("ui.legal_and_support"))
            } footer: {
                Text(L10n.text("ui.legal_documents_are_included_in_the_app"))
            }
        }
        .themedSettingsForm(tokens: tokens)
        .task {
            // 升级用户可能仍保留旧的远端转写偏好；进入设置时明确迁移到设备端。
            voiceInputProviderRawValue = VoiceInputProvider.apple.rawValue
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

    private func connectionSpeedTestTone(tokens: ThemeTokens) -> Color {
        if case .testing = appStore.connectionStatus {
            return tokens.accent
        }
        if appStore.lastConnectionTestReport?.failedStage != nil {
            return tokens.warning
        }
        return appStore.lastConnectionTestDurationMillis == nil ? tokens.secondaryText : tokens.success
    }

    private var appLanguageSelection: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: appLanguageRawValue) ?? .system },
            set: { appLanguageRawValue = $0.rawValue }
        )
    }

    private var voiceInputProviderSelection: Binding<VoiceInputProvider> {
        Binding(
            get: { .apple },
            set: { provider in
                voiceInputProviderRawValue = provider.rawValue
            }
        )
    }
}

private struct VoiceInputProviderRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var themeStore: ThemeStore

    let provider: VoiceInputProvider
    let isSelected: Bool
    let tokens: ThemeTokens
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? tokens.selectionFill : tokens.elevatedSurface)
                    Image(systemName: provider.systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isSelected ? tokens.accent : tokens.secondaryText)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.title)
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(provider.subtitle)
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isSelected ? tokens.accent : tokens.tertiaryText)
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 1),
                        value: isSelected
                    )
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(provider.title)
        .accessibilityValue(isSelected ? L10n.text("ui.selected") : L10n.text("ui.not_selected"))
        .accessibilityHint(provider.subtitle)
        .accessibilityIdentifier("settings.voiceInputProvider.\(provider.rawValue)")
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
                    Label(networkPath.localizedSummary, systemImage: networkPath.kind.settingsSystemImage)
                        .foregroundStyle(tailscaleNetworkPathTone(networkPath.kind, tokens: tokens))
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
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(themeStore.uiFont(.callout))
                .foregroundStyle(tokens.primaryText)

            Spacer(minLength: 12)

            value()
                .font(themeStore.uiFont(.callout))
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

private struct RuntimeUsageSettingsCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore

    let runtimeProvider: String
    let display: CodexUsageWindowsDisplay

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            // 常规 iPad 宽度把身份、窗口和操作收进同一基线，消除旧布局第二行产生的大块留白。
            // 无障碍大字号主动回退到上下结构，避免用缩放字体换取表面的“一行”。
            if usesRegularUsageLayout {
                regularUsageRow(tokens: tokens)
            } else {
                compactUsageRows(tokens: tokens)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private var usesRegularUsageLayout: Bool {
        horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    }

    private func regularUsageRow(tokens: ThemeTokens) -> some View {
        HStack(alignment: .center, spacing: 14) {
            usageRings

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(providerDisplayName)
                    .font(themeStore.uiFont(.headline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(display.creditText)
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(width: 152, alignment: .leading)

            Divider()
                .frame(height: 30)

            usageWindows(tokens: tokens)
                .frame(maxWidth: .infinity, alignment: .leading)

            refreshButton(tokens: tokens)
        }
        .frame(minHeight: 44)
    }

    private func compactUsageRows(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                usageRings

                VStack(alignment: .leading, spacing: 2) {
                    Text(providerDisplayName)
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(display.creditText)
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 8)
                refreshButton(tokens: tokens)
            }

            usageWindows(tokens: tokens)
        }
    }

    private var usageRings: some View {
        CodexUsageRingsGraphic(
            display: display,
            metrics: CodexUsageRingMetrics(isCompact: horizontalSizeClass == .compact)
        )
    }

    @ViewBuilder
    private func usageWindows(tokens: ThemeTokens) -> some View {
        if display.windows.isEmpty {
            Text(emptyStateText)
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(2)
        } else if usesRegularUsageLayout {
            HStack(alignment: .center, spacing: 12) {
                ForEach(Array(display.windows.prefix(2).enumerated()), id: \.element.id) { index, window in
                    if index > 0 {
                        Divider()
                            .frame(height: 28)
                    }
                    CodexCompactUsageWindow(window: window)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(display.windows.prefix(2).enumerated()), id: \.element.id) { index, window in
                    if index > 0 {
                        Divider()
                    }
                    CodexCompactUsageWindow(window: window)
                        .padding(.vertical, 9)
                }
            }
        }
    }

    private func refreshButton(tokens: ThemeTokens) -> some View {
        let isRefreshing = sessionStore.isRefreshingUsage(runtimeProvider: runtimeProvider)

        return Button {
            // 刷新状态由长生命周期 SessionStore 按 provider 隔离；视图消失后
            // 不再有局部 @State 的迟到回写，Codex 和其他设置操作也不会被连带禁用。
            Task { await sessionStore.refreshUsage(runtimeProvider: runtimeProvider) }
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
            // 可见控件保持克制，外层触控区仍遵循 iOS 最低 44pt。
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tokens.secondaryText)
        .disabled(isRefreshing)
        .accessibilityLabel(isRefreshing ? L10n.format("ui.refreshing_value_usage", display.displayName) : L10n.format("ui.refresh_value_usage", display.displayName))
        .accessibilityIdentifier("settings.\(runtimeProvider)Usage.refresh")
    }

    /// 服务端名称可能是全小写；已知产品名在界面层统一品牌大小写，不改协议原值。
    private var providerDisplayName: String {
        switch runtimeProvider.lowercased() {
        case "codex":
            return "Codex"
        case "claude":
            return "Claude"
        default:
            return display.displayName
        }
    }

    private var emptyStateText: String {
        if runtimeProvider == "claude" {
            return L10n.text("ui.claude_headless_has_not_yet_returned_to_the")
        }
        return L10n.format("ui.after_refreshing_the_account_window_returned_by_value", display.displayName)
    }
}

private struct CodexCompactUsageWindow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let window: CodexUsageWindowDisplay

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let tint = usageTint

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle()
                            .fill(tint)
                            .frame(width: 7, height: 7)
                            .alignmentGuide(.firstTextBaseline) { dimensions in
                                dimensions[VerticalAlignment.center]
                            }
                        Text(window.label)
                            .font(themeStore.uiFont(.callout, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(tokens.primaryText)
                        Text(window.title)
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(1)
                    }

                    Text(window.resetText)
                        .font(themeStore.uiFont(.caption2))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(window.remainingPercentText ?? "—")
                        .font(themeStore.uiFont(.title3, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(window.remainingProgress == nil ? tokens.secondaryText : tint)
                        .lineLimit(1)
                    Text(L10n.text("ui.remaining_quota"))
                        .font(themeStore.uiFont(.caption2, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                        .alignmentGuide(.firstTextBaseline) { dimensions in
                            dimensions[VerticalAlignment.center]
                        }
                    Text(window.label)
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(tokens.primaryText)
                    Text(window.title)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.secondaryText)
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(window.remainingText)
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(window.remainingProgress == nil ? tokens.secondaryText : tint)
                    Spacer(minLength: 4)
                    Text(window.resetText)
                        .font(themeStore.uiFont(.caption2))
                        .foregroundStyle(tokens.secondaryText)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format("ui.value_remaining_usage", window.accessibilityName))
        .accessibilityValue(L10n.format("ui.usage_window_accessibility_value", window.remainingText, window.resetText))
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
                Text(L10n.text("ui.default_permissions_for_new_conversations"))
            } footer: {
                Text(L10n.text("ui.default_run_permissions_for_new_input_areas_and"))
            }
            .listRowBackground(tokens.elevatedSurface)
        }
        .themedSettingsForm(tokens: tokens)
        .navigationTitle(L10n.text("ui.default_permissions"))
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
