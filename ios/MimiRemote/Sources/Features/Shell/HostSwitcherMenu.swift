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
                Label(L10n.text("ui.check_host_status"), systemImage: "arrow.clockwise")
            }
            .disabled(sessionStore.isConnectionSwitchInProgress || sessionStore.isNetworkUnavailable)

            Button(action: manageConnections) {
                Label(L10n.text("ui.manage_connections"), systemImage: "gearshape")
            }
        } label: {
            switcherLabel
        }
        // 原生 Menu 没有 onOpen；同步手势只启动独立的一次性探测，菜单展示绝不等待网络。
        .simultaneousGesture(TapGesture().onEnded {
            hostStatusStore.refreshIfNeeded(appStore: appStore, sessionStore: sessionStore)
        })
        .task(id: platformRefreshTrigger) {
            guard appStore.connectionProfiles.count > 1,
                  appStore.connectionProfiles.contains(where: { $0.hostPlatform == .unknown }) else {
                return
            }
            hostStatusStore.refreshIfNeeded(appStore: appStore, sessionStore: sessionStore)
        }
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
                    if appStore.connectionProfiles.count > 1 {
                        // 侧栏把平台降为状态行的小型辅助信息，避免与额度入口和主机名称争抢视觉。
                        HostPlatformGlyph(kind: currentHostIconKind, size: 11)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(switcherAccessibilityLabel(
                profileName: profileName,
                connectionText: isSwitching ? L10n.text("ui.connecting") : currentConnectionText
            )))
        case .toolbar:
            // 多设备时用服务端真实平台增强辨识度；单设备和未知平台继续使用通用电脑，
            // 避免客户端根据名称或地址猜测系统。
            ZStack(alignment: .bottomTrailing) {
                HostPlatformGlyph(kind: currentHostIconKind)
                    .frame(width: 18, height: 18)

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
            // 顶栏保留当前栏目这一处紫色导航提示；主机入口保持中性，
            // 连接状态继续由右下角语义色圆点表达。
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(switcherAccessibilityLabel(
                profileName: profileName,
                connectionText: isSwitching ? L10n.text("ui.connecting") : currentConnectionText
            )))
        }
    }

    private var currentHostIconKind: HostPlatformIconKind {
        guard appStore.connectionProfiles.count > 1 else {
            return .genericComputer
        }
        return appStore.activeConnectionProfile?.hostPlatform.iconKind ?? .genericComputer
    }

    private var platformRefreshTrigger: String {
        let profiles = appStore.connectionProfiles.map {
            "\($0.id):\($0.revision):\($0.hostPlatform.rawValue)"
        }.joined(separator: "|")
        return [
            profiles,
            String(sessionStore.isLoading),
            String(sessionStore.isNetworkUnavailable),
            String(sessionStore.isAppInBackground)
        ].joined(separator: ":")
    }

    private func switcherAccessibilityLabel(
        profileName: String,
        connectionText: String
    ) -> String {
        var components = [profileName]
        if appStore.connectionProfiles.count > 1,
           let platformName = appStore.activeConnectionProfile?.hostPlatform.displayName {
            components.append(platformName)
        }
        components.append(connectionText)
        return components.joined(separator: ", ")
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

/// 三个平台图标保持相同的视觉盒，连接状态由调用方独立表达。
/// Windows 使用 Windows 11 的正视四格造型；Linux 使用模板渲染的经典 Tux 矢量图。
struct HostPlatformGlyph: View {
    let kind: HostPlatformIconKind
    let size: CGFloat

    init(kind: HostPlatformIconKind, size: CGFloat = 18) {
        self.kind = kind
        self.size = size
    }

    @ViewBuilder
    private var glyph: some View {
        switch kind {
        case .apple:
            Image(systemName: "apple.logo")
                .font(.system(size: size * 8 / 9, weight: size < 14 ? .medium : .semibold))
                .symbolRenderingMode(.hierarchical)
        case .windows11:
            Windows11Mark(spacing: size / 12)
                .frame(width: size * 5 / 6, height: size * 5 / 6)
        case .linuxTux:
            Image("LinuxTux")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: size * 17 / 18, height: size)
        case .genericComputer:
            Image(systemName: "desktopcomputer")
                .font(.system(size: size * 8 / 9, weight: size < 14 ? .medium : .semibold))
                .symbolRenderingMode(.hierarchical)
        }
    }

    var body: some View {
        glyph
            .frame(width: size, height: size)
    }
}

private struct Windows11Mark: View {
    let spacing: CGFloat

    var body: some View {
        VStack(spacing: spacing) {
            HStack(spacing: spacing) {
                Rectangle()
                Rectangle()
            }
            HStack(spacing: spacing) {
                Rectangle()
                Rectangle()
            }
        }
    }
}
