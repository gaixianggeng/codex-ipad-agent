import SwiftUI

enum HostSwitcherPresentation {
    case sidebar
    case toolbar
}

struct HostSwitcherMenu: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var hostStatusStore: HostStatusStore

    let presentation: HostSwitcherPresentation
    let manageConnections: () -> Void

    @State private var failedProfileID: String?
    @State private var switchErrorMessage: String?

    var body: some View {
        Menu {
            ForEach(appStore.connectionProfiles) { profile in
                Button {
                    switchToProfile(profile.id)
                } label: {
                    Label(
                        profile.displayName,
                        systemImage: menuSystemImage(for: profile)
                    )
                }
                .disabled(
                    profile.id == appStore.activeConnectionProfileID ||
                        sessionStore.isConnectionSwitchInProgress
                )
            }

            if !appStore.connectionProfiles.isEmpty {
                Divider()
            }

            Button {
                hostStatusStore.refreshIfNeeded(appStore: appStore, sessionStore: sessionStore)
            } label: {
                Label(L10n.text("ui.check_mac_status"), systemImage: "arrow.clockwise")
            }
            .disabled(sessionStore.isConnectionSwitchInProgress || sessionStore.isNetworkUnavailable)

            Button(action: manageConnections) {
                Label(L10n.text("ui.mac_connection"), systemImage: "gearshape")
            }
        } label: {
            switcherLabel
        }
        // 原生 Menu 没有 onOpen；同步手势只启动独立的一次性探测，菜单展示绝不等待网络。
        .simultaneousGesture(TapGesture().onEnded {
            hostStatusStore.refreshIfNeeded(appStore: appStore, sessionStore: sessionStore)
        })
        .accessibilityIdentifier("hostSwitcher.menu")
        .alert(L10n.text("ui.switch_failed"), isPresented: errorPresentation) {
            if let failedProfileID {
                Button(L10n.text("ui.retry")) {
                    switchToProfile(failedProfileID)
                }
            }
            Button(L10n.text("ui.manage_connections")) {
                manageConnections()
            }
            Button(L10n.text("ui.got_it"), role: .cancel) {}
        } message: {
            Text(switchErrorMessage ?? L10n.text("ui.please_try_again_later"))
        }
    }

    @ViewBuilder
    private var switcherLabel: some View {
        let profileName = appStore.activeConnectionProfile?.displayName ?? L10n.text("ui.current_mac")
        let isSwitching = sessionStore.isConnectionSwitchInProgress

        switch presentation {
        case .sidebar:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(profileName)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    if isSwitching {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Circle()
                            .fill(currentConnectionColor)
                            .frame(width: 6, height: 6)
                    }
                    Text(isSwitching ? L10n.text("ui.connecting") : currentConnectionText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 150, alignment: .leading)
        case .toolbar:
            // 顶栏只表达“当前 Mac 可切换”，完整名称/IP 和连接操作留在菜单内，
            // 避免全局连接信息占据第二行并与当前页面争夺视觉中心。
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)

                if isSwitching {
                    ProgressView()
                        .controlSize(.mini)
                        .offset(x: 3, y: 3)
                } else {
                    Circle()
                        .fill(currentConnectionColor)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: 2)
                }
            }
            .foregroundStyle(.tint)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text(
                    L10n.format(
                        "ui.connection_profile_status_value",
                        profileName,
                        isSwitching ? L10n.text("ui.connecting") : currentConnectionText
                    )
                )
            )
        }
    }

    private var errorPresentation: Binding<Bool> {
        Binding(
            get: { switchErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    switchErrorMessage = nil
                }
            }
        )
    }

    private var currentConnectionColor: Color {
        if sessionStore.isNetworkUnavailable {
            return .orange
        }
        switch appStore.connectionStatus {
        case .connected:
            return .green
        case .testing:
            return .orange
        case .failed:
            return .red
        case .idle:
            return .secondary
        }
    }

    private var currentConnectionText: String {
        if sessionStore.isNetworkUnavailable {
            return L10n.text("ui.offline")
        }
        switch appStore.connectionStatus {
        case .connected:
            return L10n.text("ui.connected")
        case .testing:
            return L10n.text("ui.connecting")
        case .failed:
            return L10n.text("ui.connection_failed")
        case .idle:
            return L10n.text("ui.connection_status")
        }
    }

    private func menuSystemImage(for profile: ConnectionProfile) -> String {
        if profile.id == appStore.activeConnectionProfileID {
            return "checkmark.circle.fill"
        }
        if sessionStore.connectionSwitchTargetProfileID == profile.id {
            return "clock"
        }
        switch hostStatusStore.status(for: profile).state {
        case .available:
            return "circle.fill"
        case .checking:
            return "clock"
        case .unavailable:
            return "wifi.slash"
        case .authenticationRequired:
            return "key.slash"
        case .identityMismatch:
            return "exclamationmark.shield"
        case .upgradeRequired:
            return "arrow.up.circle"
        case .unknown:
            return "circle"
        }
    }

    private func switchToProfile(_ profileID: String) {
        guard profileID != appStore.activeConnectionProfileID,
              !sessionStore.isConnectionSwitchInProgress else {
            return
        }
        hostStatusStore.cancel()
        switchErrorMessage = nil
        Task {
            do {
                _ = try await sessionStore.switchConnectionProfile(id: profileID)
                _ = await sessionStore.refreshAfterConnectionCommit(maxWait: 10)
                HostSwitchSignpost.event("session_index_visible")
                failedProfileID = nil
            } catch is CancellationError {
                // 退后台或用户取消时保留原 Mac，不弹失败。
            } catch {
                failedProfileID = profileID
                switchErrorMessage = error.localizedDescription
            }
        }
    }
}
