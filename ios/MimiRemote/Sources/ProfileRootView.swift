import SwiftUI
import UIKit

// 个人页独立观察其实际依赖，避免 RootView 因连接状态细节整体重建。
struct ProfileRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        ZStack {
            tokens.background.ignoresSafeArea()
            if horizontalSizeClass == .compact {
                NavigationStack {
                    profileContent(tokens: tokens)
                        .navigationTitle("我的")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .themedWorkbenchNavigationChrome(tokens: tokens, colorScheme: themeStore.resolvedColorScheme(for: colorScheme))
            } else {
                profileContent(tokens: tokens)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(tokens.accent)
    }

    private func profileContent(tokens: ThemeTokens) -> some View {
        let isCompact = horizontalSizeClass == .compact

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if isCompact {
                    Text("管理 Mac 连接、模型和工具能力。")
                        .font(themeStore.uiFont(.callout, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    WorkbenchPageHeader(
                        title: "我的",
                        subtitle: "管理 Mac 连接、模型和工具能力。",
                        tokens: tokens
                    )
                }

                MacConnectionPanel()
                CodexUsagePanel()

                VStack(alignment: .leading, spacing: 10) {
                    Text("模型与能力")
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    ProfileInfoRow(
                        systemImage: "sparkles",
                        title: "Codex",
                        value: "默认使用",
                        detail: "默认处理会话任务",
                        tone: tokens.accent
                    )
                    ProfileInfoRow(
                        systemImage: "flask",
                        title: "Claude",
                        value: sessionStore.hasClaudeRuntimeChannel ? "已发现" : "可配置",
                        detail: "配置后可用于会话任务",
                        tone: sessionStore.hasClaudeRuntimeChannel ? tokens.success : tokens.secondaryText
                    )
                    ProfileInfoRow(
                        systemImage: "cpu",
                        title: "模型",
                        value: modelSummary,
                        detail: "为新任务选择合适的模型",
                        tone: tokens.accent
                    )
                    ProfileInfoRow(
                        systemImage: "wand.and.stars",
                        title: "Skills / MCP",
                        value: "工具能力",
                        detail: "查看本机工具和扩展配置",
                        tone: tokens.accent
                    )
                }
            }
            .padding(.horizontal, isCompact ? WorkbenchPageLayout.compactPadding : WorkbenchPageLayout.regularPadding)
            .padding(.top, isCompact ? WorkbenchPageLayout.compactPadding : WorkbenchPageLayout.regularPadding)
            .padding(.bottom, isCompact ? WorkbenchPageLayout.compactBottomPadding : WorkbenchPageLayout.regularPadding)
            .frame(maxWidth: WorkbenchPageLayout.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(tokens.background.ignoresSafeArea())
    }

    private var modelSummary: String {
        let count = sessionStore.appServerModelOptions.count
        return count == 0 ? "默认模型" : "\(count) 个模型"
    }
}

struct CodexUsagePanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var isRefreshingUsage = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let display = sessionStore.accountCodexUsageWindowsDisplay

        VStack(alignment: .leading, spacing: 16) {
            header(display: display, tokens: tokens)

            VStack(alignment: .leading, spacing: 12) {
                if display.windows.isEmpty {
                    Text("刷新后显示 Codex 当前返回的账号窗口")
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                } else {
                    ForEach(Array(display.windows.enumerated()), id: \.element.id) { index, window in
                        if index > 0 {
                            Divider()
                                .overlay(tokens.border.opacity(0.72))
                        }
                        usageWindowRow(window, tokens: tokens)
                    }
                }
            }

            footer(display: display, tokens: tokens)
        }
        .padding(16)
        .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tokens.border, lineWidth: 1)
        }
    }

    private func header(display: CodexUsageWindowsDisplay, tokens: ThemeTokens) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tokens.accent.opacity(0.12))
                Image(systemName: "speedometer")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(tokens.accent)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(display.displayName) 用量")
                    .font(themeStore.uiFont(.headline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                Text(display.hasLiveData ? "Codex 当前返回：\(display.windowSummaryText)" : "点击刷新读取 Codex 账号限额")
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            refreshButton(tokens: tokens)
        }
    }

    private func usageWindowRow(_ window: CodexUsageWindowDisplay, tokens: ThemeTokens) -> some View {
        let tint = windowTint(window, tokens: tokens)
        let progress = window.progress ?? 0

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: window.systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 18)
                    Text(window.label)
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                        .monospacedDigit()
                    Text(window.title)
                        .font(themeStore.uiFont(.footnote, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                }
                .lineLimit(1)

                Spacer(minLength: 8)

                Text(window.primaryText)
                    .font(themeStore.uiFont(.callout, weight: .semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .monospacedDigit()
            }

            ProgressView(value: progress)
                .tint(tint)
                .opacity(window.progress == nil ? 0.34 : 1)
                .accessibilityLabel("\(window.accessibilityName)用量")
                .accessibilityValue(window.primaryText)

            Text(window.resetText)
                .font(themeStore.uiFont(.footnote))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
        }
    }

    private func footer(display: CodexUsageWindowsDisplay, tokens: ThemeTokens) -> some View {
        HStack(spacing: 8) {
            Image(systemName: display.hasLiveData ? "checkmark.seal" : "info.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(display.hasLiveData ? tokens.success : tokens.secondaryText)
            Text(display.creditText)
                .font(themeStore.uiFont(.footnote, weight: .medium))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func refreshButton(tokens: ThemeTokens) -> some View {
        let isWorking = isRefreshingUsage || sessionStore.isLoading

        Button {
            Task { await refreshUsage() }
        } label: {
            Group {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tokens.secondaryText)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tokens.secondaryText)
        .background(tokens.surface.opacity(0.72), in: Circle())
        .overlay {
            Circle()
                .stroke(tokens.border.opacity(0.72), lineWidth: 1)
        }
        .disabled(isWorking)
        .accessibilityLabel("刷新 Codex 用量")
    }

    private func refreshUsage() async {
        guard !isRefreshingUsage else {
            return
        }
        isRefreshingUsage = true
        defer { isRefreshingUsage = false }
        await sessionStore.refreshCodexUsage()
    }

    private func windowTint(_ window: CodexUsageWindowDisplay, tokens: ThemeTokens) -> Color {
        if window.isExhausted || window.isNearLimit {
            return tokens.warning
        }
        if window.durationMinutes != nil {
            return window.isDayScaleWindow ? tokens.success : tokens.accent
        }
        return window.kind == .secondary ? tokens.success : tokens.accent
    }
}

struct MacConnectionPanel: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var endpoint = ""
    @State private var token = ""
    @State private var didLoadInitialConnection = false
    @State private var isSavingConnection = false
    @State private var isShowingQRCodeScanner = false
    @State private var isShowingManualFields = false
    @State private var pendingRemovalConfirmation: ConnectionCredentialRemovalConfirmation?
    @State private var localError: String?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 16) {
            connectionHeaderAndActions(tokens: tokens)

            connectionDiagnostics(tokens: tokens)

            DisclosureGroup(isExpanded: $isShowingManualFields) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Tailscale 地址", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(themeStore.uiFont(.callout))
                        .padding(10)
                        .background(tokens.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    SecureField("访问码", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(themeStore.uiFont(.callout))
                        .padding(10)
                        .background(tokens.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .padding(.top, 10)
            } label: {
                Label("手动配置", systemImage: "slider.horizontal.3")
                    .font(themeStore.uiFont(.callout, weight: .semibold))
                    .foregroundStyle(appStore.isConfigured ? tokens.primaryText : tokens.secondaryText)
            }

            if let error = localError ?? appStore.lastError {
                Text(error)
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tokens.border, lineWidth: 1)
        }
        .onAppear(perform: loadInitialConnectionIfNeeded)
        .sheet(isPresented: $isShowingQRCodeScanner) {
            QRCodeScannerSheet(onDismiss: {
                isShowingQRCodeScanner = false
            }, onChooseManualConnection: {
                isShowingManualFields = true
            }) { rawValue in
                await applyScannedConnection(rawValue)
            }
        }
        .confirmationDialog(
            pendingRemovalConfirmation?.title ?? "确认删除连接凭据？",
            isPresented: removalConfirmationBinding,
            titleVisibility: .visible,
            presenting: pendingRemovalConfirmation
        ) { confirmation in
            Button(confirmation.confirmButtonTitle, role: .destructive) {
                confirmForgetCurrent(confirmation)
            }
            .accessibilityIdentifier("root.connection.forget.confirm")

            Button("取消", role: .cancel) {
                pendingRemovalConfirmation = nil
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private var removalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingRemovalConfirmation != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRemovalConfirmation = nil
                }
            }
        )
    }

    @ViewBuilder
    private func connectionHeaderAndActions(tokens: ThemeTokens) -> some View {
        if horizontalSizeClass == .compact {
            VStack(alignment: .leading, spacing: 14) {
                connectionSummaryRow(tokens: tokens)
                compactConnectionActions
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    connectionSummaryRow(tokens: tokens)
                    Spacer(minLength: 16)
                    HStack(spacing: 10) {
                        connectionActions()
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    connectionSummaryRow(tokens: tokens)
                    HStack(spacing: 10) {
                        connectionActions()
                    }
                }
            }
        }
    }

    private func connectionSummaryRow(tokens: ThemeTokens) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(connectionTone(tokens: tokens).opacity(0.14))
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(connectionTone(tokens: tokens))
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("连接 Mac")
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(appStore.connectionStatus.title)
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(connectionTone(tokens: tokens))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(connectionTone(tokens: tokens).opacity(0.12), in: Capsule())
                }
                Text(appStore.isConfigured ? appStore.endpoint : "尚未配置 Mac 连接")
                    .font(themeStore.uiFont(.callout))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private func connectionDiagnostics(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if isConnectionTesting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在测试连接")
                        .font(themeStore.uiFont(.footnote, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                }
            }
            if let milliseconds = appStore.lastConnectionTestDurationMillis {
                Text("上次测试耗时 \(AppStore.connectionTestDurationText(milliseconds: milliseconds))")
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
            }
            if let report = appStore.lastConnectionTestReport {
                if let failedStage = report.failedStage {
                    Text("失败环节：\(failedStage.kind.title) · \(AppStore.connectionTestDurationText(milliseconds: failedStage.durationMillis))")
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.warning)
                } else if let slowestStage = report.slowestStage {
                    Text("最慢环节：\(slowestStage.kind.title) · \(AppStore.connectionTestDurationText(milliseconds: slowestStage.durationMillis))")
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                }
            }
        }
    }

    @ViewBuilder
    private func connectionActions() -> some View {
        scanConnectionButton

        if appStore.isConfigured || isShowingManualFields {
            Button {
                Task {
                    await appStore.testConnection(
                        endpoint: endpoint,
                        token: token
                    )
                }
            } label: {
                Label(isConnectionTesting ? "测试中" : "测试连接", systemImage: isConnectionTesting ? "timer" : "bolt.horizontal.circle")
            }
            .buttonStyle(.bordered)
            .disabled(!canSubmit)

            Button {
                Task { await saveManualConnection() }
            } label: {
                Label(isSavingConnection ? "保存中" : "保存连接", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)
        }

        if appStore.isConfigured {
            Button(role: .destructive) {
                requestForgetCurrent()
            } label: {
                Label("忘记", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(isSavingConnection)
            .accessibilityIdentifier("root.connection.forget")
        }
    }

    private var compactConnectionActions: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: 0), spacing: 10),
                GridItem(.flexible(minimum: 0), spacing: 10)
            ],
            alignment: .leading,
            spacing: 10
        ) {
            scanConnectionCompactButton

            if appStore.isConfigured || isShowingManualFields {
                testConnectionCompactButton
                saveConnectionCompactButton
            }

            if appStore.isConfigured {
                forgetConnectionCompactButton
            }
        }
    }

    private func compactActionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(themeStore.uiFont(.callout, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
    }

    @ViewBuilder
    private var scanConnectionCompactButton: some View {
        if appStore.isConfigured {
            Button {
                isShowingQRCodeScanner = true
            } label: {
                compactActionLabel("扫码连接", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.bordered)
            .disabled(isSavingConnection)
        } else {
            Button {
                isShowingQRCodeScanner = true
            } label: {
                compactActionLabel("扫码连接", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSavingConnection)
        }
    }

    private var testConnectionCompactButton: some View {
        Button {
            Task {
                await appStore.testConnection(
                    endpoint: endpoint,
                    token: token
                )
            }
        } label: {
            compactActionLabel(isConnectionTesting ? "测试中" : "测试连接", systemImage: isConnectionTesting ? "timer" : "bolt.horizontal.circle")
        }
        .buttonStyle(.bordered)
        .disabled(!canSubmit)
    }

    private var saveConnectionCompactButton: some View {
        Button {
            Task { await saveManualConnection() }
        } label: {
            compactActionLabel(isSavingConnection ? "保存中" : "保存连接", systemImage: "checkmark.circle")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSubmit)
    }

    private var forgetConnectionCompactButton: some View {
        Button(role: .destructive) {
            requestForgetCurrent()
        } label: {
            compactActionLabel("忘记", systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .disabled(isSavingConnection)
        .accessibilityIdentifier("root.connection.forget.compact")
    }

    @ViewBuilder
    private var scanConnectionButton: some View {
        if appStore.isConfigured {
            Button {
                isShowingQRCodeScanner = true
            } label: {
                Label("扫码连接", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.bordered)
            .disabled(isSavingConnection)
        } else {
            Button {
                isShowingQRCodeScanner = true
            } label: {
                Label("扫码连接", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSavingConnection)
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

    private func connectionTone(tokens: ThemeTokens) -> Color {
        switch appStore.connectionStatus {
        case .connected:
            return tokens.success
        case .failed:
            return tokens.warning
        case .testing:
            return tokens.accent
        case .idle:
            return appStore.isConfigured ? tokens.secondaryText : tokens.warning
        }
    }

    private func loadInitialConnectionIfNeeded() {
        guard !didLoadInitialConnection else {
            return
        }
        didLoadInitialConnection = true
        endpoint = appStore.endpoint
        token = appStore.token
    }

    private func saveManualConnection() async {
        isSavingConnection = true
        defer { isSavingConnection = false }
        do {
            let wasConfigured = appStore.isConfigured
            _ = try await sessionStore.applyConnectionSettings(
                endpoint: endpoint,
                token: token
            )
            endpoint = appStore.endpoint
            token = appStore.token
            _ = await refreshCommittedConnection(maxWait: wasConfigured ? 10 : 45)
        } catch {
            appStore.connectionStatus = .failed(error.localizedDescription)
            appStore.lastError = error.localizedDescription
            localError = error.localizedDescription
        }
    }

    private func applyScannedConnection(_ rawValue: String) async -> QRCodeScannerSubmissionResult {
        isSavingConnection = true
        do {
            let wasConfigured = appStore.isConfigured
            let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw) else {
                throw PairingLinkError.unsupportedURL
            }
            _ = try await sessionStore.applyPairingURL(url)
            endpoint = appStore.endpoint
            token = appStore.token
            // 配对验证成功即可退出扫码页；工作台数据在后台继续恢复。
            Task { @MainActor in
                defer { isSavingConnection = false }
                _ = await refreshCommittedConnection(maxWait: wasConfigured ? 10 : 45)
            }
            return .accepted("已连接这台 Mac")
        } catch is CancellationError {
            isSavingConnection = false
            localError = nil
            return .rejected("扫码已取消，请重新扫描 Mac 上的二维码。")
        } catch {
            isSavingConnection = false
            appStore.connectionStatus = .failed(error.localizedDescription)
            appStore.lastError = error.localizedDescription
            localError = error.localizedDescription
            return .rejected(error.localizedDescription)
        }
    }

    private func refreshCommittedConnection(maxWait: TimeInterval) async -> Bool {
        let didLoad = await sessionStore.refreshAfterConnectionCommit(maxWait: maxWait)
        if didLoad {
            localError = nil
        } else if Task.isCancelled {
            localError = nil
        } else {
            localError = appStore.lastError ?? sessionStore.errorMessage
        }
        return didLoad
    }

    private func clearPairing() {
        do {
            try appStore.clearPairing()
            endpoint = appStore.endpoint
            token = appStore.token
            sessionStore.resetConnectionForSettingsChange(clearData: true)
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }

    private func requestForgetCurrent() {
        pendingRemovalConfirmation = .forgettingCurrent(appStore.activeConnectionProfile)
    }

    private func confirmForgetCurrent(_ confirmation: ConnectionCredentialRemovalConfirmation) {
        guard case .current(let expectedProfileID) = confirmation.target else {
            return
        }
        guard expectedProfileID == appStore.activeConnectionProfileID else {
            // 弹窗展示期间连接可能被其它入口切换；旧确认不得作用于新的当前 Mac。
            pendingRemovalConfirmation = nil
            localError = "当前 Mac 已发生变化，请重新操作。"
            return
        }
        pendingRemovalConfirmation = nil
        clearPairing()
    }
}

struct ProfileInfoRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let systemImage: String
    let title: String
    let value: String
    let detail: String
    let tone: Color
    var trailingSystemImage: String? = nil

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tone.opacity(0.12))
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tone)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        rowTitle(tokens: tokens)
                        rowValue
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        rowTitle(tokens: tokens)
                        rowValue
                    }
                }
                Text(detail)
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tokens.tertiaryText)
                    .padding(.top, 11)
            }
        }
        .padding(14)
        .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tokens.border, lineWidth: 1)
        }
    }

    private func rowTitle(tokens: ThemeTokens) -> some View {
        Text(title)
            .font(themeStore.uiFont(.headline, weight: .semibold))
            .foregroundStyle(tokens.primaryText)
            .lineLimit(1)
    }

    private var rowValue: some View {
        Text(value)
            .font(themeStore.uiFont(.footnote, weight: .semibold))
            .foregroundStyle(tone)
            .lineLimit(1)
    }
}

