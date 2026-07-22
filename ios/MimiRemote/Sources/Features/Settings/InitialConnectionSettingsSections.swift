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
                    Text(L10n.text("ui.saved_mac"))
                } footer: {
                    Text(L10n.text("ui.only_one_mac_is_connected_at_a_time"))
                }
            }

            Section {
#if targetEnvironment(macCatalyst)
                if appStore.localAgentDetected {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(
                            appStore.isUsingLocalConnection ? L10n.text("ui.directly_connected_through_local_assistant") : L10n.text("ui.assistant_has_been_detected_on_this_mac"),
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
                        Label(L10n.text("ui.start_mimi_assistant_on_mac_first"), systemImage: "desktopcomputer")
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

                DisclosureGroup(L10n.text("ui.mac_preparation")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("ui.first_time_installation"))
                            .font(themeStore.uiFont(.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("brew install gaixianggeng/tap/mimi-remote")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Text(L10n.text("ui.start_the_assistant_and_display_the_qr_code"))
                            .font(themeStore.uiFont(.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("agentd up")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Text(L10n.text("ui.run_agentd_pair_when_the_qr_code_expires"))
                            .font(themeStore.uiFont(.footnote))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }

                DisclosureGroup(isExpanded: manualConnectionExpandedBinding) {
                    VStack(alignment: .leading, spacing: 12) {
                        if isAddingConnectionProfile {
                            connectionFieldLabel(L10n.text("ui.display_name")) {
                                TextField(L10n.text("ui.example_studio_mac"), text: $profileDisplayName)
                                    .textInputAutocapitalization(.words)
                                    .accessibilityIdentifier("settings.profileDisplayName")
                            }
                        }
                        connectionFieldLabel(L10n.text("ui.connection_address")) {
                            StableEndpointTextField(placeholder: endpointPlaceholder, text: $endpoint)
                                .frame(minHeight: 28)
                        }
                        connectionFieldLabel(L10n.text("ui.access_code")) {
                            SecureField(L10n.text("ui.enter_access_code"), text: $token)
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
                                Text(isSavingConnection ? L10n.text("ui.connecting") : manualSaveButtonTitle)
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
                Text(appStore.isConfigured ? L10n.text("ui.add_mac") : L10n.text("ui.connect_to_mac"))
            } footer: {
                Text(L10n.text("ui.it_is_recommended_to_scan_the_qr_code"))
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
                pendingRemovalConfirmation?.title ?? L10n.text("ui.confirm_to_delete_connection_credentials"),
                isPresented: removalConfirmationBinding,
                titleVisibility: .visible,
                presenting: pendingRemovalConfirmation
            ) { confirmation in
                Button(confirmation.confirmButtonTitle, role: .destructive) {
                    performCredentialRemoval(confirmation)
                }
                .accessibilityIdentifier(removalConfirmationAccessibilityIdentifier(confirmation))

                Button(L10n.text("ui.cancel"), role: .cancel) {
                    pendingRemovalConfirmation = nil
                }
            } message: { confirmation in
                Text(confirmation.message)
            }

            if shouldShowConnectionStatus {
                Section {
                    HStack {
                        Label(L10n.text("ui.connection_status"), systemImage: connectionStatusSystemImage)
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
                        DisclosureGroup(L10n.text("ui.connection_diagnostics")) {
                            if let connectionTestDurationText {
                                LabeledContent(L10n.text("ui.testing_time"), value: connectionTestDurationText)
                                    .foregroundStyle(statusColor)
                            }
                            if let report = appStore.lastConnectionTestReport {
                                if let networkPath = report.tailscaleNetworkPath {
                                    LabeledContent(L10n.text("ui.tailscale_network_path")) {
                                        Label(networkPath.localizedSummary, systemImage: networkPath.kind.settingsSystemImage)
                                    }
                                }
                                if let failedStage = report.failedStage {
                                    connectionStageSummaryRow(title: L10n.text("ui.failure_link"), stage: failedStage, color: .red)
                                } else if let slowestStage = report.slowestStage {
                                    connectionStageSummaryRow(title: L10n.text("ui.slowest_link"), stage: slowestStage, color: tokens.warning)
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
                    Text(L10n.text("ui.status"))
                }
            }

#if DEBUG
            Section {
                Button {
                    appStore.enterDebugWorkbenchWithoutPairing()
                } label: {
                    Label(L10n.text("ui.debug_enter_the_workbench"), systemImage: "wrench.and.screwdriver")
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
        appStore.isConfigured ? L10n.text("ui.scan_qr_code_to_add_mac") : L10n.text("ui.scan_the_qr_code_to_connect")
    }

    private var localAgentPairingHint: String {
        switch appStore.connectionStatus {
        case .testing:
            return L10n.text("ui.automatically_claiming_local_credentials_and_verifying_codex_connection")
        case .failed:
            return L10n.text("ui.the_automatic_connection_is_not_completed_please_upgrade")
        case .idle, .connected:
            return L10n.text("ui.the_local_assistant_will_be_automatically_connected_older")
        }
    }

    private var endpointPlaceholder: String {
#if targetEnvironment(macCatalyst)
        L10n.text("ui.native_or_tailscale_address")
#else
        L10n.text("ui.tailscale_address")
#endif
    }

    private var manualConnectionTitle: String {
        guard appStore.activeConnectionProfile != nil else {
            return L10n.text("ui.manual_connection")
        }
        if !isShowingAdvancedManualConnection || isAddingConnectionProfile {
            return L10n.text("ui.add_mac_manually")
        }
        return L10n.text("ui.manually_update_your_current_mac")
    }

    private var manualSaveButtonTitle: String {
        if isAddingConnectionProfile {
            return L10n.text("ui.add_and_connect")
        }
        return appStore.isConfigured ? L10n.text("ui.update_connection") : L10n.text("ui.connect")
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
                Label(L10n.text("ui.current_label"), systemImage: "checkmark.circle.fill")
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(themeStore.tokens(for: colorScheme).success)
            } else if profileOperationID == item.id {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(L10n.text("ui.switch")) {
                    Task { await switchConnectionProfile(id: item.id) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSavingConnection || profileOperationID != nil)
                .accessibilityIdentifier("settings.profile.switch.\(item.id)")
            }

            Menu {
                Button(L10n.text("ui.rename")) {
                    profileRenameTarget = item.profile
                }
                .accessibilityIdentifier("settings.profile.rename.\(item.id)")

                if item.isCurrent {
                    Button(L10n.text("ui.scan_the_qr_code_again_to_pair")) {
                        beginRepairingCurrentProfile()
                    }
                    Divider()
                    Button(L10n.text("ui.forget_this_mac"), role: .destructive) {
                        pendingRemovalConfirmation = .forgettingCurrent(item.profile)
                    }
                    .accessibilityIdentifier("settings.connection.forget")
                } else {
                    Button(L10n.text("ui.delete"), role: .destructive) {
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
            .accessibilityLabel(L10n.format("ui.manage_value", item.profile.displayName))
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
            Text(L10n.text("ui.recent_fluctuations"))
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
            return L10n.format(
                "ui.connection_test_stability_failure_summary",
                L10n.plural("ui.connection_test_samples_count", count: stability.sampleCount),
                L10n.plural("ui.connection_test_failures_count", count: stability.failureCount),
                max
            )
        }
        return L10n.format(
            "ui.connection_test_stability_summary",
            L10n.plural("ui.connection_test_samples_count", count: stability.sampleCount),
            spread,
            max
        )
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
            return L10n.format("ui.failure_value", duration)
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
                title: L10n.text("ui.upstream_dialup_failed"),
                detail: L10n.text("ui.this_test_failed_to_add_a_new_addition"),
                value: L10n.format(
                    "ui.connection_test_upstream_dial_failures",
                    L10n.plural("ui.upstream_dial_failures_count", count: diagnostics.failedUpstreamDialsDelta),
                    AppStore.connectionTestDurationText(milliseconds: diagnostics.upstreamDialMillisMax)
                ),
                color: .red
            )
        }

        if let connection = diagnostics.relatedConnection {
            connectionGatewayMetricRow(
                title: L10n.text("ui.mac_upstream_dialing"),
                detail: L10n.text("ui.agentd_to_local_app_server"),
                value: AppStore.connectionTestDurationText(milliseconds: connection.upstreamDialMillis),
                color: gatewayMetricColor(milliseconds: connection.upstreamDialMillis)
            )
        }

        if let rpc = diagnostics.latestRPC {
            connectionGatewayMetricRow(
                title: L10n.text("ui.recent_rpcs"),
                detail: rpc.method.isEmpty ? "app-server JSON-RPC" : rpc.method,
                value: AppStore.connectionTestDurationText(milliseconds: rpc.latencyMillis),
                color: gatewayMetricColor(milliseconds: rpc.latencyMillis)
            )
        }

        if diagnostics.rpcOutstandingRequests > 0 {
            connectionGatewayMetricRow(
                title: L10n.text("ui.waiting_for_upstream"),
                detail: L10n.text("ui.app_server_still_hasn_t_returned_a_response"),
                value: L10n.format("ui.value_value", diagnostics.rpcOutstandingRequests, AppStore.connectionTestDurationText(milliseconds: diagnostics.rpcOutstandingMillisMax)),
                color: themeStore.tokens(for: colorScheme).warning
            )
        }

        if diagnostics.writeBackMillisMax > 0 {
            connectionGatewayMetricRow(
                title: L10n.text("ui.write_back_to_ipad"),
                detail: L10n.text("ui.agentd_gateway_is_written_to_the_current_device"),
                value: AppStore.connectionTestDurationText(milliseconds: diagnostics.writeBackMillisMax),
                color: gatewayMetricColor(milliseconds: diagnostics.writeBackMillisMax)
            )
        }

        if let closeReason = diagnostics.relatedConnection?.closeReason,
           !closeReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            connectionGatewayMetricRow(
                title: L10n.text("ui.recently_disconnected"),
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
            Text(L10n.text("ui.gateway_judgment"))
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
            Text(L10n.text("ui.gateway_diagnostics"))
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
                title: L10n.text("ui.upstream_dialup_failed"),
                detail: L10n.text("ui.agentd_failed_to_connect_to_local_app_server"),
                color: .red
            )
        }
        if diagnostics.rpcOutstandingRequests > 0 && diagnostics.rpcOutstandingMillisMax >= 2_000 {
            return GatewayDiagnosticSummary(
                title: L10n.text("ui.upstream_did_not_return"),
                detail: L10n.text("ui.the_request_has_been_sent_to_app_server"),
                color: warning
            )
        }
        if let rpc = diagnostics.latestRPC,
           rpc.latencyMillis >= 1_000 {
            let method = rpc.method.isEmpty ? "app-server JSON-RPC" : rpc.method
            return GatewayDiagnosticSummary(
                title: L10n.text("ui.rpc_returns_slowly"),
                detail: L10n.format("ui.value_return_time_is_high", method),
                color: gatewayMetricColor(milliseconds: rpc.latencyMillis)
            )
        }
        if diagnostics.writeBackMillisMax >= 500 {
            return GatewayDiagnosticSummary(
                title: L10n.text("ui.write_back_link_slow"),
                detail: L10n.text("ui.prioritize_checking_ipads_and_tailscale_networks"),
                color: gatewayMetricColor(milliseconds: diagnostics.writeBackMillisMax)
            )
        }
        if let connection = diagnostics.relatedConnection,
           connection.upstreamDialMillis >= 500 {
            return GatewayDiagnosticSummary(
                title: L10n.text("ui.local_dialing_is_slow"),
                detail: L10n.text("ui.agentd_is_slow_to_establish_a_connection_to"),
                color: gatewayMetricColor(milliseconds: connection.upstreamDialMillis)
            )
        }
        if diagnostics.totalConnectionsDelta > 0 {
            return GatewayDiagnosticSummary(
                title: L10n.text("ui.there_is_a_new_connection_this_time"),
                detail: L10n.text("ui.no_obvious_gateway_bottleneck_found"),
                color: .secondary
            )
        }
        return GatewayDiagnosticSummary(
            title: L10n.text("ui.no_new_samples"),
            detail: L10n.text("ui.continue_to_reproduce_the_slow_scene_and_look"),
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
            return L10n.text("ui.the_pairing_qr_code_has_expired_please_re")
        }
        if lowercased.contains("unauthorized") || lowercased.contains("401") {
            return L10n.text("ui.this_device_has_not_been_verified_by_mac")
        }
        if lowercased.contains("timed out") || lowercased.contains("cannot connect") || raw.contains("无法连接") {
            return L10n.text("ui.the_current_device_cannot_find_this_mac_at")
        }
        if raw == L10n.text("ui.the_connection_credentials_have_been_saved_safely_but") ||
            raw.contains("连接凭据已安全保存") {
            // Old builds persisted this message in Chinese. Always return the current locale's
            // copy so an English screen never echoes that legacy raw value.
            return L10n.text("ui.the_connection_credentials_have_been_saved_safely_but")
        }
        let localizedConnectionLinkKeys = [
            "ui.invalid_connection_link",
            "ui.the_connection_link_is_missing_the_access_code",
            "ui.the_link_is_missing_an_address",
            "ui.the_connection_address_format_is_invalid",
            "ui.the_connection_address_is_invalid_please_enter_the"
        ]
        if localizedConnectionLinkKeys.contains(where: { raw == L10n.text($0) }) || raw.contains("Endpoint") {
            return raw
        }
        if raw.contains("连接链接缺少访问码") {
            return L10n.text("ui.the_connection_link_is_missing_the_access_code")
        }
        if raw.contains("连接链接缺少地址") {
            return L10n.text("ui.the_link_is_missing_an_address")
        }
        if raw.contains("连接地址格式无效") {
            return L10n.text("ui.the_connection_address_format_is_invalid")
        }
        if raw.contains("连接地址") || raw.contains("连接链接") {
            return L10n.text("ui.invalid_connection_link")
        }
        return L10n.text("ui.the_connection_was_not_completed_please_confirm_that")
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
                localError = L10n.text("ui.the_current_mac_has_changed_please_try_again")
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
                    ? L10n.text("ui.added_and_switched_to_this_mac")
                    : L10n.text("ui.this_mac_is_connected")
            )
        } catch is CancellationError {
            isSavingConnection = false
            localError = nil
            return .rejected(L10n.text("ui.the_code_scan_has_been_cancelled_please_scan"))
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
