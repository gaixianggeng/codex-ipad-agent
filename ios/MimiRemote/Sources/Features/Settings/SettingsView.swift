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
}

struct TokenActivityDay: Identifiable, Equatable {
    let date: Date
    let tokens: Int64
    let intensity: Int
    let isFuture: Bool

    var id: Date { date }
}

struct TokenActivityWeek: Identifiable, Equatable {
    let startDate: Date
    let days: [TokenActivityDay]

    var id: Date { startDate }
}

enum TokenActivityCalendar {
    static func weeks(
        buckets: [AccountTokenUsageDailyBucket],
        endingAt: Date = Date(),
        weekCount: Int = 53
    ) -> [TokenActivityWeek] {
        guard weekCount > 0 else { return [] }
        let calendar = utcCalendar
        let endDay = calendar.startOfDay(for: endingAt)
        let weekday = calendar.component(.weekday, from: endDay)
        let daysSinceMonday = (weekday - calendar.firstWeekday + 7) % 7
        let currentWeekStart = calendar.date(
            byAdding: .day,
            value: -daysSinceMonday,
            to: endDay
        ) ?? endDay
        let firstWeekStart = calendar.date(
            byAdding: .weekOfYear,
            value: -(weekCount - 1),
            to: currentWeekStart
        ) ?? currentWeekStart

        var tokensByDate: [Date: Int64] = [:]
        for bucket in buckets {
            guard let date = date(from: bucket.startDate, calendar: calendar),
                  date >= firstWeekStart,
                  date <= endDay
            else {
                continue
            }
            let current = tokensByDate[date, default: 0]
            let incoming = max(bucket.tokens, 0)
            let (sum, overflowed) = current.addingReportingOverflow(incoming)
            // 服务端可能返回同一天的多个桶；累计时饱和到 Int64.max，
            // 避免异常大数让“我的”页面在渲染点格图时崩溃。
            tokensByDate[date] = overflowed ? .max : sum
        }
        let maximum = tokensByDate.values.max() ?? 0

        return (0..<weekCount).map { weekOffset in
            let weekStart = calendar.date(
                byAdding: .weekOfYear,
                value: weekOffset,
                to: firstWeekStart
            ) ?? firstWeekStart
            let days = (0..<7).map { dayOffset in
                let date = calendar.date(
                    byAdding: .day,
                    value: dayOffset,
                    to: weekStart
                ) ?? weekStart
                let tokens = tokensByDate[date] ?? 0
                return TokenActivityDay(
                    date: date,
                    tokens: tokens,
                    intensity: intensity(tokens: tokens, maximum: maximum),
                    isFuture: date > endDay
                )
            }
            return TokenActivityWeek(startDate: weekStart, days: days)
        }
    }

    static func date(from dayKey: String, calendar: Calendar = utcCalendar) -> Date? {
        let components = dayKey.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day))
        else {
            return nil
        }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else {
            return nil
        }
        return date
    }

    private static func intensity(tokens: Int64, maximum: Int64) -> Int {
        guard tokens > 0, maximum > 0 else { return 0 }
        // 平方根尺度既能压住偶发超大日，又不会像 log 尺度那样把常用日期全部挤到最深一档。
        let normalized = sqrt(Double(tokens) / Double(maximum))
        switch normalized {
        case ..<0.20: return 1
        case ..<0.45: return 2
        case ..<0.70: return 3
        default: return 4
        }
    }

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
}

enum TokenCountFormatter {
    static func string(_ value: Int64?, language: AppLanguage = .stored()) -> String {
        guard let value else { return "—" }
        let isChinese = language == .simplifiedChinese
            || (language == .system && Locale.preferredLanguages.first?.hasPrefix("zh") == true)
        if isChinese {
            if value >= 100_000_000 {
                return compact(Double(value) / 100_000_000)
                    + L10n.text(
                        "ui.compact_number_hundred_million_suffix",
                        language: .simplifiedChinese
                    )
            }
            if value >= 10_000 {
                return compact(Double(value) / 10_000)
                    + L10n.text(
                        "ui.compact_number_ten_thousand_suffix",
                        language: .simplifiedChinese
                    )
            }
            return decimal(value, locale: Locale(identifier: "zh-Hans"))
        }
        if value >= 1_000_000_000 {
            return compact(Double(value) / 1_000_000_000) + "B"
        }
        if value >= 1_000_000 {
            return compact(Double(value) / 1_000_000) + "M"
        }
        if value >= 1_000 {
            return compact(Double(value) / 1_000) + "K"
        }
        return decimal(value, locale: Locale(identifier: "en"))
    }

    private static func compact(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded.rounded() == rounded
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
    }

    private static func decimal(_ value: Int64, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
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
                    .frame(maxWidth: 920)
                    .frame(maxWidth: .infinity)
                    .background(tokens.background.ignoresSafeArea())
            }
        }
        .navigationTitle(isInitialSetup ? L10n.text("ui.connect_your_mac") : L10n.text("ui.me"))
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
        // iPhone 的一级“我的”保留系统大标题；iPad detail 使用紧凑标题，避免与居中内容断裂。
        horizontalSizeClass == .compact ? .large : .inline
    }

    private func settingsForm(tokens: ThemeTokens) -> some View {
        let codexUsage = sessionStore.accountCodexUsageWindowsDisplay
        let claudeUsage = sessionStore.accountClaudeUsageWindowsDisplay

        return Form {
            Section {
                AccountTokenUsageCard(
                    codexDisplay: codexUsage,
                    claudeDisplay: claudeUsage,
                    includesClaude: sessionStore.hasClaudeRuntimeChannel,
                    snapshot: sessionStore.accountTokenUsage,
                    isRefreshing: sessionStore.isRefreshingAccountTokenUsage
                        || sessionStore.isRefreshingUsage(runtimeProvider: "codex")
                        || (
                            sessionStore.hasClaudeRuntimeChannel
                                && sessionStore.isRefreshingUsage(runtimeProvider: "claude")
                        ),
                    isUnavailable: sessionStore.isAccountTokenUsageUnavailable,
                    onRefresh: refreshAccountUsage
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("settings.tokenUsage")
            } header: {
                Text(L10n.text("ui.token_usage"))
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
                Text(L10n.text("ui.my_preferences"))
            }

            Section {
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
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.connectionManagement")

                NavigationLink {
                    DiagnosticsAndSupportSettingsView(
                        showsHistoryDiagnostics: developerModeEnabled
                    )
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.diagnosis_and_support"),
                        systemImage: "stethoscope"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.diagnostics")

                NavigationLink {
                    AdvancedDevelopmentSettingsView(
                        developerModeEnabled: $developerModeEnabled
                    )
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.advanced_and_development"),
                        systemImage: "hammer"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.advancedDevelopment")

                NavigationLink {
                    AboutAndLegalSettingsView()
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.about_and_legal"),
                        systemImage: "info.circle"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.aboutLegal")
            } header: {
                Text(L10n.text("ui.more"))
            } footer: {
                if let connectionWarningText {
                    Text(connectionWarningText)
                }
            }
        }
        .listSectionSpacing(SettingsLayoutMetrics.sectionSpacing)
        .themedSettingsForm(tokens: tokens)
        .task(id: appStore.activeHostScope) {
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
            await sessionStore.refreshAccountTokenUsage()
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

    private func refreshAccountUsage() async {
        async let codexQuota: Void = sessionStore.refreshCodexUsage()
        async let tokenActivity: Void = sessionStore.refreshAccountTokenUsage()
        if sessionStore.hasClaudeRuntimeChannel {
            await sessionStore.refreshClaudeUsage()
        }
        _ = await (codexQuota, tokenActivity)
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

private struct AccountTokenUsageCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var themeStore: ThemeStore

    let codexDisplay: CodexUsageWindowsDisplay
    let claudeDisplay: CodexUsageWindowsDisplay
    let includesClaude: Bool
    let snapshot: AccountTokenUsageSnapshot?
    let isRefreshing: Bool
    let isUnavailable: Bool
    let onRefresh: () async -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        ViewThatFits(in: .horizontal) {
            if !dynamicTypeSize.isAccessibilitySize {
                wideLayout(tokens: tokens)
                    .frame(minWidth: 620)
            }
            compactLayout(tokens: tokens)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
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
            .stroke(tokens.border.opacity(0.48), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private func wideLayout(tokens: ThemeTokens) -> some View {
        HStack(alignment: .top, spacing: 20) {
            quotaPanel(tokens: tokens)
                .frame(width: 236)

            Divider()
                .overlay(tokens.border.opacity(0.72))

            activityPanel(tokens: tokens)
                .frame(maxWidth: .infinity)
        }
        .frame(minHeight: 156)
    }

    private func compactLayout(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            quotaPanel(tokens: tokens)

            Divider()
                .overlay(tokens.border.opacity(0.72))

            activityPanel(tokens: tokens)
        }
    }

    private func quotaPanel(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("ui.current_remaining"))
                .font(themeStore.uiFont(.subheadline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 14) {
                    usageRings
                    usageLegend(tokens: tokens)
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    usageRings
                    usageLegend(tokens: tokens)
                }
            }
        }
    }

    private var usageRings: some View {
        CombinedUsageRingsGraphic(
            items: usageItems,
            expectedRingCount: 3,
            diameter: dynamicTypeSize.isAccessibilitySize ? 104 : 92,
            lineWidth: 6
        )
        .frame(
            width: dynamicTypeSize.isAccessibilitySize ? 104 : 92,
            height: dynamicTypeSize.isAccessibilitySize ? 104 : 92
        )
        .accessibilityLabel(L10n.text("ui.current_remaining"))
    }

    @ViewBuilder
    private func usageLegend(tokens: ThemeTokens) -> some View {
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
            VStack(alignment: .leading, spacing: 7) {
                ForEach(items) { item in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(item.tint)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)

                        Text("\(item.providerName) · \(item.window.label)")
                            .font(themeStore.uiFont(.caption, weight: .medium))
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        Text(item.window.remainingPercentText ?? "—")
                            .font(themeStore.uiFont(.caption, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(
                                item.window.remainingProgress == nil
                                    ? tokens.secondaryText
                                    : item.tint
                            )
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func activityPanel(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    activityTitle(tokens: tokens)

                    Spacer(minLength: 4)

                    lifetimeTokenLabel(tokens: tokens)
                        .fixedSize(horizontal: true, vertical: false)

                    AccountUsageRefreshButton(
                        isRefreshing: isRefreshing,
                        onRefresh: onRefresh
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        activityTitle(tokens: tokens)
                        Spacer(minLength: 4)
                        AccountUsageRefreshButton(
                            isRefreshing: isRefreshing,
                            onRefresh: onRefresh
                        )
                    }
                    lifetimeTokenLabel(tokens: tokens)
                }
            }

            if let buckets = snapshot?.dailyUsageBuckets {
                TokenActivityDotGrid(buckets: buckets)
            } else {
                HStack(spacing: 10) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "chart.dots.scatter")
                            .foregroundStyle(tokens.tertiaryText)
                    }
                    Text(activityUnavailableText)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 74, alignment: .center)
                .accessibilityIdentifier("settings.tokenActivity.unavailable")
            }
        }
    }

    private func activityTitle(tokens: ThemeTokens) -> some View {
        Text(L10n.text("ui.token_activity"))
            .font(themeStore.uiFont(.subheadline, weight: .semibold))
            .foregroundStyle(tokens.primaryText)
    }

    private func lifetimeTokenLabel(tokens: ThemeTokens) -> some View {
        Text(
            L10n.format(
                "ui.lifetime_token_value",
                TokenCountFormatter.string(snapshot?.summary.lifetimeTokens)
            )
        )
        .font(themeStore.uiFont(.caption))
        .foregroundStyle(tokens.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var activityUnavailableText: String {
        if isRefreshing {
            return L10n.text("ui.loading_token_activity")
        }
        if isUnavailable {
            return L10n.text("ui.token_activity_unavailable")
        }
        return L10n.text("ui.token_activity_waiting")
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

private struct AccountUsageRefreshButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let isRefreshing: Bool
    let onRefresh: () async -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Button {
            Task { await onRefresh() }
        } label: {
            Group {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(width: 32, height: 32)
            .background(tokens.secondaryText.opacity(0.08), in: Circle())
            .overlay {
                Circle().stroke(tokens.border.opacity(0.72), lineWidth: 1)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tokens.secondaryText)
        .disabled(isRefreshing)
        .accessibilityLabel(
            isRefreshing
                ? L10n.format("ui.refreshing_value_usage", "Token")
                : L10n.format("ui.refresh_value_usage", "Token")
        )
        .accessibilityIdentifier("settings.tokenUsage.refresh")
    }
}

private struct TokenActivityDotGrid: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let buckets: [AccountTokenUsageDailyBucket]

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let weeks = TokenActivityCalendar.weeks(buckets: buckets)
        let activeDayCount = weeks
            .flatMap(\.days)
            .filter { !$0.isFuture && $0.tokens > 0 }
            .count

        GeometryReader { proxy in
            let spacing: CGFloat = 3
            let availableCell = (proxy.size.width - spacing * 52) / 53
            // 固定卡片高度内最多使用 7pt 点格；更宽的 iPad 只增加留白，
            // 不放大到裁掉第七行或破坏左右模块的视觉平衡。
            let cellSize = min(max(availableCell, 4), 7)
            let contentWidth = cellSize * 53 + spacing * 52
            let gridHeight = cellSize * 7 + spacing * 6

            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(weeks) { week in
                            VStack(spacing: spacing) {
                                ForEach(week.days) { day in
                                    RoundedRectangle(
                                        cornerRadius: min(2.2, cellSize * 0.3),
                                        style: .continuous
                                    )
                                    .fill(fill(for: day, tokens: tokens))
                                    .frame(width: cellSize, height: cellSize)
                                }
                            }
                        }
                    }
                    .offset(y: 19)

                    ForEach(Array(weeks.enumerated()), id: \.element.id) { index, week in
                        if let monthDate = week.days.first(where: isFirstDayOfMonth)?.date {
                            Text(monthText(monthDate))
                                .font(themeStore.uiFont(size: 9, weight: .medium))
                                .foregroundStyle(tokens.tertiaryText)
                                .fixedSize()
                                .offset(x: CGFloat(index) * (cellSize + spacing))
                        }
                    }
                }
                .frame(width: contentWidth, height: gridHeight + 19, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.trailing)
        }
        .frame(height: 86)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("ui.token_activity"))
        .accessibilityValue(
            L10n.format(
                "ui.token_activity_accessibility_value",
                activeDayCount
            )
        )
        .accessibilityIdentifier("settings.tokenActivity.grid")
    }

    private func fill(for day: TokenActivityDay, tokens: ThemeTokens) -> Color {
        guard !day.isFuture else { return .clear }
        let contrastBoost = colorSchemeContrast == .increased ? 0.12 : 0
        switch day.intensity {
        case 1: return tokens.accent.opacity(0.24 + contrastBoost)
        case 2: return tokens.accent.opacity(0.42 + contrastBoost)
        case 3: return tokens.accent.opacity(0.64 + contrastBoost)
        case 4: return tokens.accent.opacity(0.92)
        default: return tokens.secondaryText.opacity(0.09 + contrastBoost)
        }
    }

    private func isFirstDayOfMonth(_ day: TokenActivityDay) -> Bool {
        TokenActivityCalendar.utcCalendar.component(.day, from: day.date) == 1
    }

    private func monthText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = TokenActivityCalendar.utcCalendar
        formatter.timeZone = TokenActivityCalendar.utcCalendar.timeZone
        formatter.locale = AppLanguage.stored().locale
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter.string(from: date)
    }
}

private struct DiagnosticsAndSupportSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let showsHistoryDiagnostics: Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            Section {
                NavigationLink {
                    ConnectionSpeedTestView()
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.connection_speed_test"),
                        systemImage: "gauge.with.dots.needle.67percent"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.connectionSpeedTest")

                NavigationLink {
                    DoctorView(showsHistoryDiagnostics: showsHistoryDiagnostics)
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.diagnosis_and_support"),
                        systemImage: "stethoscope"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.doctor")

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
            }
        }
        .themedSettingsForm(tokens: tokens)
        .navigationTitle(L10n.text("ui.diagnosis_and_support"))
    }
}

private struct AdvancedDevelopmentSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    @Binding var developerModeEnabled: Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            Section {
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
            } footer: {
                Text(
                    developerModeEnabled
                        ? L10n.text("ui.historical_diagnostics_may_display_the_local_machine_path")
                        : L10n.text("ui.turn_on_to_use_advanced_operating_options_and")
                )
            }
        }
        .themedSettingsForm(tokens: tokens)
        .navigationTitle(L10n.text("ui.advanced_and_development"))
    }
}

private struct AboutAndLegalSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            Section {
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
            } footer: {
                Text(L10n.text("ui.legal_documents_are_included_in_the_app"))
            }
        }
        .themedSettingsForm(tokens: tokens)
        .navigationTitle(L10n.text("ui.about_and_legal"))
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
