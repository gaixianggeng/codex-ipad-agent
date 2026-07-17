import SwiftUI

// 首次连接流程按功能区拆出，主设置页只负责导航和页面编排。
struct InitialConnectionSettingsSections: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var endpoint = ""
    @State private var token = ""
    @State private var didLoadInitialConnection = false
    @State private var isShowingQRCodeScanner = false
    @State private var isSavingConnection = false
    @State private var isAddingConnectionProfile = false
    @State private var profileDisplayName = ""
    @State private var profileOperationID: String?
    @State private var profileRenameTarget: ConnectionProfile?
    @State private var pendingRemovalConfirmation: ConnectionCredentialRemovalConfirmation?
    @State private var isShowingAdvancedManualConnection = false
    @State private var localError: String?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            if !appStore.connectionProfiles.isEmpty {
                Section {
                    if let current = appStore.connectionProfileSettingsModel.current {
                        connectionProfileRow(current)
                    }
                    ForEach(appStore.connectionProfileSettingsModel.others) { item in
                        connectionProfileRow(item)
                    }
                } header: {
                    Text("已保存的 Mac")
                } footer: {
                    Text("同一时间只连接一台 Mac。切换前会先验证连接，访问码保存在系统钥匙串。")
                }
            }

            Section {
#if targetEnvironment(macCatalyst)
                if appStore.localAgentDetected {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(
                            appStore.isUsingLocalConnection ? "已通过本机助手直连" : "已检测到这台 Mac 上的助手",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(themeStore.uiFont(.body, weight: .semibold))
                        .foregroundStyle(tokens.success)
                        if !appStore.isConfigured {
                            Text(localAgentPairingHint)
                                .font(themeStore.uiFont(.footnote))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
#endif
                if !appStore.isConfigured && !appStore.localAgentDetected {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("先在 Mac 启动 Mimi 助手", systemImage: "desktopcomputer")
                            .font(themeStore.uiFont(.body, weight: .semibold))
                        Text("agentd up")
                            .font(.system(.callout, design: .monospaced, weight: .medium))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }

                Button {
                    beginScanningMac()
                } label: {
                    Label(primaryScanButtonTitle, systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(tokens.primaryAction)
                .controlSize(.large)
                .disabled(isSavingConnection)

                DisclosureGroup("Mac 端准备") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("首次安装")
                            .font(themeStore.uiFont(.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("brew install gaixianggeng/tap/mimi-remote")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Text("启动助手并显示二维码")
                            .font(themeStore.uiFont(.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("agentd up")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Text("二维码过期时运行 `agentd pair`。")
                            .font(themeStore.uiFont(.footnote))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }

                DisclosureGroup(isExpanded: manualConnectionExpandedBinding) {
                    VStack(alignment: .leading, spacing: 12) {
                        if isAddingConnectionProfile {
                            connectionFieldLabel("显示名称") {
                                TextField("例如：工作室 Mac", text: $profileDisplayName)
                                    .textInputAutocapitalization(.words)
                                    .accessibilityIdentifier("settings.profileDisplayName")
                            }
                        }
                        connectionFieldLabel("连接地址") {
                            StableEndpointTextField(placeholder: endpointPlaceholder, text: $endpoint)
                                .frame(minHeight: 28)
                        }
                        connectionFieldLabel("访问码") {
                            SecureField("输入访问码", text: $token)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        EndpointTransportNotice(assessment: endpointTransportAssessment)
                        Button {
                            Task { await save() }
                        } label: {
                            HStack(spacing: 8) {
                                if isSavingConnection {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(isSavingConnection ? "正在连接…" : manualSaveButtonTitle)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(tokens.primaryAction)
                        .disabled(!canSubmit)
                    }
                    .padding(.vertical, 6)
                } label: {
                    Label(manualConnectionTitle, systemImage: "keyboard")
                }
            } header: {
                Text(appStore.isConfigured ? "添加 Mac" : "连接 Mac")
            } footer: {
                Text("推荐扫码连接；会自动验证新连接，失败时保留当前 Mac。")
            }
            // Form 会把透明 Group 展开成多个 Section。所有弹窗必须挂在这个始终存在的
            // 具体 Section 上，确保已连接时新增的“已保存/状态”Section 不会生成多个 presenter。
            .sheet(isPresented: $isShowingQRCodeScanner) {
                QRCodeScannerSheet(onDismiss: {
                    isShowingQRCodeScanner = false
                }, onChooseManualConnection: {
                    isShowingAdvancedManualConnection = true
                }) { rawValue in
                    await applyScannedConnection(rawValue)
                }
            }
            .sheet(item: $profileRenameTarget) { profile in
                ConnectionProfileRenameSheet(profile: profile) { displayName in
                    try appStore.renameConnectionProfile(id: profile.id, displayName: displayName)
                    localError = nil
                }
            }
            .confirmationDialog(
                pendingRemovalConfirmation?.title ?? "确认删除连接凭据？",
                isPresented: removalConfirmationBinding,
                titleVisibility: .visible,
                presenting: pendingRemovalConfirmation
            ) { confirmation in
                Button(confirmation.confirmButtonTitle, role: .destructive) {
                    performCredentialRemoval(confirmation)
                }
                .accessibilityIdentifier(removalConfirmationAccessibilityIdentifier(confirmation))

                Button("取消", role: .cancel) {
                    pendingRemovalConfirmation = nil
                }
            } message: { confirmation in
                Text(confirmation.message)
            }

            if shouldShowConnectionStatus {
                Section {
                    HStack {
                        Label("连接状态", systemImage: connectionStatusSystemImage)
                        Spacer()
                        if isConnectionTesting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(appStore.connectionStatus.title)
                            .foregroundStyle(statusColor)
                    }
                    if let message = displayErrorMessage {
                        Text(message)
                            .foregroundStyle(.red)
                            .font(themeStore.uiFont(size: 13))
                    }

                    if connectionTestDurationText != nil || appStore.lastConnectionTestReport != nil {
                        DisclosureGroup("连接诊断") {
                            if let connectionTestDurationText {
                                LabeledContent("测试耗时", value: connectionTestDurationText)
                                    .foregroundStyle(statusColor)
                            }
                            if let report = appStore.lastConnectionTestReport {
                                if let failedStage = report.failedStage {
                                    connectionStageSummaryRow(title: "失败环节", stage: failedStage, color: .red)
                                } else if let slowestStage = report.slowestStage {
                                    connectionStageSummaryRow(title: "最慢环节", stage: slowestStage, color: tokens.warning)
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
                        }
                    }
                } header: {
                    Text("状态")
                }
            }

#if DEBUG
            Section {
                Button {
                    appStore.enterDebugWorkbenchWithoutPairing()
                } label: {
                    Label("Debug 进入工作台", systemImage: "wrench.and.screwdriver")
                }
            }
#endif
        }
        .listRowBackground(tokens.elevatedSurface)
        // 连接地址/Token 是高频编辑状态，放在这个小子树里，避免每次删字都重绘整个设置页。
        .onAppear(perform: loadInitialConnectionIfNeeded)
        .task {
            // 根启动任务负责自动配对和提交；这里与它复用同一个探测 Task，只更新设置页提示，
            // 避免两个连接事务争抢后导致 bootstrap 提前返回。
            _ = await appStore.detectLocalAgent()
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

    private var manualConnectionExpandedBinding: Binding<Bool> {
        Binding(
            get: { isShowingAdvancedManualConnection },
            set: { isExpanded in
                if isExpanded, !isShowingAdvancedManualConnection {
                    if appStore.activeConnectionProfile != nil {
                        prepareAddingConnectionProfile()
                    } else {
                        isAddingConnectionProfile = false
                        endpoint = ""
                        token = ""
                        localError = nil
                    }
                }
                isShowingAdvancedManualConnection = isExpanded
            }
        )
    }

    private var primaryScanButtonTitle: String {
        appStore.isConfigured ? "扫描二维码添加 Mac" : "扫描二维码连接"
    }

    private var localAgentPairingHint: String {
        switch appStore.connectionStatus {
        case .testing:
            return "正在自动领取本机凭据并验证 Codex 连接…"
        case .failed:
            return "自动连接未完成；请升级并重启 agentd，或通过扫码连接。"
        case .idle, .connected:
            return "将自动连接本机助手；旧版助手仍可通过扫码完成配对。"
        }
    }

    private var endpointPlaceholder: String {
#if targetEnvironment(macCatalyst)
        "本机或 Tailscale 地址"
#else
        "Tailscale 地址"
#endif
    }

    private var manualConnectionTitle: String {
        guard appStore.activeConnectionProfile != nil else {
            return "手动连接"
        }
        if !isShowingAdvancedManualConnection || isAddingConnectionProfile {
            return "手动添加 Mac"
        }
        return "手动更新当前 Mac"
    }

    private var manualSaveButtonTitle: String {
        if isAddingConnectionProfile {
            return "添加并连接"
        }
        return appStore.isConfigured ? "更新连接" : "连接"
    }

    private func connectionFieldLabel<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
            content()
        }
        .accessibilityElement(children: .contain)
    }

    private var connectionStatusSystemImage: String {
        switch appStore.connectionStatus {
        case .connected:
            return "checkmark.circle.fill"
        case .testing:
            return "arrow.trianglehead.2.clockwise.rotate.90"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .idle:
            return "circle.dashed"
        }
    }

    private var shouldShowConnectionStatus: Bool {
        appStore.isConfigured ||
        isConnectionTesting ||
        displayErrorMessage != nil ||
        connectionTestDurationText != nil ||
        appStore.lastConnectionTestReport != nil
    }

    private var canSubmit: Bool {
        !isSavingConnection &&
        !isConnectionTesting &&
        endpointTransportAssessment.isAllowed &&
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func connectionProfileRow(_ item: ConnectionProfileSettingsItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.isCurrent ? "desktopcomputer.and.macbook" : "desktopcomputer")
                .font(themeStore.uiFont(.body, weight: .semibold))
                .foregroundStyle(item.isCurrent ? themeStore.tokens(for: colorScheme).accent : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.profile.displayName)
                    .font(themeStore.uiFont(.body, weight: item.isCurrent ? .semibold : .regular))
                Text(item.profile.endpoint)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if item.isCurrent {
                Label("当前", systemImage: "checkmark.circle.fill")
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(themeStore.tokens(for: colorScheme).success)
            } else if profileOperationID == item.id {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("切换") {
                    Task { await switchConnectionProfile(id: item.id) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSavingConnection || profileOperationID != nil)
                .accessibilityIdentifier("settings.profile.switch.\(item.id)")
            }

            Menu {
                Button("重命名") {
                    profileRenameTarget = item.profile
                }
                .accessibilityIdentifier("settings.profile.rename.\(item.id)")

                if item.isCurrent {
                    Button("重新扫码配对") {
                        beginRepairingCurrentProfile()
                    }
                    Divider()
                    Button("忘记这台 Mac", role: .destructive) {
                        pendingRemovalConfirmation = .forgettingCurrent(item.profile)
                    }
                    .accessibilityIdentifier("settings.connection.forget")
                } else {
                    Button("删除", role: .destructive) {
                        pendingRemovalConfirmation = .deletingSavedProfile(item.profile)
                    }
                    .accessibilityIdentifier("settings.profile.delete.\(item.id)")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(themeStore.uiFont(.body))
                    .frame(width: 30, height: 30)
            }
            .disabled(isSavingConnection || profileOperationID != nil)
            .accessibilityLabel("管理 \(item.profile.displayName)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.profile.\(item.id)")
    }

    private var endpointTransportAssessment: EndpointTransportAssessment {
        EndpointTransportPolicy.assess(endpoint)
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
                detail: "优先检查 iPad 与 Tailscale 网络",
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
        if let termination = appStore.connectionTermination {
            return termination.message
        }
        let lowercased = raw.lowercased()
        if lowercased.contains("expired") || raw.contains("过期") {
            return "配对二维码已过期，请在 Mac 上重新运行 agentd pair 后扫码。"
        }
        if lowercased.contains("unauthorized") || lowercased.contains("401") {
            return "这台设备没有通过 Mac 助手验证，请重新扫码连接。"
        }
        if lowercased.contains("timed out") || lowercased.contains("cannot connect") || raw.contains("无法连接") {
            return "当前设备暂时找不到这台 Mac。请确认 Mimi Mac 助手正在运行，并且当前设备已连接 Tailscale。"
        }
        if raw.contains("Endpoint") || raw.contains("连接链接") {
            return raw
        }
        if raw.contains("连接凭据已安全保存") {
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

    private func prepareAddingConnectionProfile() {
        isAddingConnectionProfile = true
        profileDisplayName = ""
        endpoint = ""
        token = ""
        localError = nil
    }

    private func beginScanningMac() {
        if appStore.activeConnectionProfile != nil {
            prepareAddingConnectionProfile()
        } else {
            isAddingConnectionProfile = false
            profileDisplayName = ""
            endpoint = ""
            token = ""
            localError = nil
        }
        isShowingAdvancedManualConnection = false
        isShowingQRCodeScanner = true
    }

    private func beginRepairingCurrentProfile() {
        isAddingConnectionProfile = false
        profileDisplayName = appStore.activeConnectionProfile?.displayName ?? ""
        endpoint = appStore.endpoint
        token = ""
        localError = nil
        isShowingAdvancedManualConnection = false
        isShowingQRCodeScanner = true
    }

    private func switchConnectionProfile(id: String) async {
        profileOperationID = id
        defer { profileOperationID = nil }
        do {
            _ = try await sessionStore.switchConnectionProfile(id: id)
            endpoint = appStore.endpoint
            token = appStore.token
            isAddingConnectionProfile = false
            guard await refreshCommittedConnection(maxWait: 10) else {
                return
            }
        } catch is CancellationError {
            // App 退后台或任务被系统取消时不把仍可用的旧连接标成失败。
            localError = nil
        } catch {
            // prepare/commit 失败时 SessionStore 尚未退役旧连接，这里只展示错误。
            localError = error.localizedDescription
        }
    }

    private func deleteConnectionProfile(id: String) {
        do {
            try sessionStore.deleteConnectionProfile(id: id)
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }

    private func performCredentialRemoval(_ confirmation: ConnectionCredentialRemovalConfirmation) {
        pendingRemovalConfirmation = nil
        switch confirmation.target {
        case .current(let expectedProfileID):
            guard expectedProfileID == appStore.activeConnectionProfileID else {
                // 弹窗展示期间连接可能被 URL Scheme 或其它入口切换；不能误删后来成为当前的档案。
                localError = "当前 Mac 已发生变化，请重新操作。"
                return
            }
            clearPairing()
        case .savedProfile(let profileID):
            deleteConnectionProfile(id: profileID)
        }
    }

    private func removalConfirmationAccessibilityIdentifier(
        _ confirmation: ConnectionCredentialRemovalConfirmation
    ) -> String {
        switch confirmation.target {
        case .current:
            return "settings.connection.forget.confirm"
        case .savedProfile(let profileID):
            return "settings.profile.delete.confirm.\(profileID)"
        }
    }

    private func save() async {
        isSavingConnection = true
        defer { isSavingConnection = false }
        do {
            let wasConfigured = appStore.isConfigured
            if isAddingConnectionProfile {
                _ = try await sessionStore.addConnectionProfile(
                    endpoint: endpoint,
                    token: token,
                    displayName: profileDisplayName
                )
            } else {
                _ = try await sessionStore.applyConnectionSettings(
                    endpoint: endpoint,
                    token: token
                )
            }
            endpoint = appStore.endpoint
            token = appStore.token
            isAddingConnectionProfile = false
            guard await refreshCommittedConnection(maxWait: wasConfigured ? 10 : 45) else {
                return
            }
        } catch is CancellationError {
            localError = nil
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
            let wasAddingConnectionProfile = isAddingConnectionProfile
            if wasAddingConnectionProfile {
                _ = try await sessionStore.addConnectionProfile(
                    pairingURL: url,
                    displayName: profileDisplayName
                )
            } else {
                _ = try await sessionStore.applyPairingURL(url)
            }
            endpoint = appStore.endpoint
            token = appStore.token
            isAddingConnectionProfile = false
            // 二维码在这里已经完成真实连接验证并提交。首屏数据继续后台加载，
            // 不让扫码页额外卡住最多 45 秒，也不要求用户重复扫描一次性配对码。
            Task { @MainActor in
                defer { isSavingConnection = false }
                _ = await refreshCommittedConnection(maxWait: wasConfigured ? 10 : 45)
            }
            return .accepted(
                wasAddingConnectionProfile
                    ? "已添加并切换到这台 Mac"
                    : "已连接这台 Mac"
            )
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
}

