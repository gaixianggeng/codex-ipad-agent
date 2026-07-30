import SwiftUI

enum HostInstallationPlatform: String, CaseIterable, Identifiable {
    case mac
    case windows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mac:
            "Mac"
        case .windows:
            "Windows"
        }
    }

    var installTitle: String {
        switch self {
        case .mac:
            L10n.text("ui.install_mimi_remote_mac")
        case .windows:
            L10n.text("ui.install_mimi_remote_windows")
        }
    }

    var installationDetail: String {
        switch self {
        case .mac:
            L10n.text("ui.mac_installer_requirements_and_instructions")
        case .windows:
            L10n.text("ui.windows_installer_requirements_and_instructions")
        }
    }

    var shareTitle: String {
        switch self {
        case .mac:
            L10n.text("ui.send_download_link_to_mac")
        case .windows:
            L10n.text("ui.send_download_link_to_windows")
        }
    }

    var installerURL: URL {
        switch self {
        case .mac:
            AppExternalLinks.macInstaller
        case .windows:
            AppExternalLinks.windowsRelease
        }
    }

    var releaseURL: URL {
        switch self {
        case .mac:
            AppExternalLinks.macRelease
        case .windows:
            AppExternalLinks.windowsRelease
        }
    }
}

/// 首次连接只保留两个用户阶段：先在电脑上准备，再在当前设备扫码。
/// 平台选择只改变远端安装入口；配对和凭据处理继续复用同一条安全链路。
struct HostInstallationSetupView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var selectedPlatform: HostInstallationPlatform = .mac

    let connectionFooter: String
    let isScanDisabled: Bool
    let onScan: () -> Void
    let onPasteConnectionInfo: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            Section {
                Picker(L10n.text("ui.computer_platform"), selection: $selectedPlatform) {
                    ForEach(HostInstallationPlatform.allCases) { platform in
                        Text(platform.title).tag(platform)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.hostInstaller.platform")

                VStack(alignment: .leading, spacing: 6) {
                    Text(selectedPlatform.installTitle)
                        .font(themeStore.uiFont(.body, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)

                    Text(selectedPlatform.installationDetail)
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.hostInstaller.installationDetail")

                Link(destination: selectedPlatform.releaseURL) {
                    HStack(spacing: 12) {
                        // 品牌资源保持官方黑白原色，不跟随 App 的主题色染色。
                        Image("GitHubInvertocat")
                            .renderingMode(.original)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)

                        Text(L10n.text("ui.view_releases_on_github"))
                            .font(themeStore.uiFont(.body))
                            .foregroundStyle(tokens.primaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 8)

                        Image(systemName: "arrow.up.right")
                            .font(themeStore.uiFont(.caption, weight: .semibold))
                            .foregroundStyle(tokens.secondaryText)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("ui.view_releases_on_github"))
                .accessibilityHint(L10n.text("ui.github_release_accessibility_hint"))
                .accessibilityIdentifier("settings.hostInstaller.githubRelease")

                ShareLink(item: selectedPlatform.installerURL) {
                    GloballyCenteredActionLabel(
                        title: selectedPlatform.shareTitle,
                        systemImage: "square.and.arrow.up"
                    )
                }
                .buttonStyle(.bordered)
                .tint(tokens.primaryAction)
                .controlSize(.large)
                .accessibilityIdentifier("settings.hostInstaller.share")
            } header: {
                Text(L10n.text("ui.computer_platform"))
            } footer: {
                Text(L10n.text("ui.select_code_directory_then_computer_shows_qr"))
            }

            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.text("ui.scan_qr_code_to_connect"))
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: onScan) {
                        GloballyCenteredActionLabel(
                            title: L10n.text("ui.scan_qr_code_on_computer"),
                            systemImage: "qrcode.viewfinder"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tokens.primaryAction)
                    .controlSize(.large)
                    .disabled(isScanDisabled)
                    .accessibilityIdentifier("settings.hostInstaller.scan")

                    Button(action: onPasteConnectionInfo) {
                        GloballyCenteredActionLabel(
                            title: L10n.text("ui.paste_connection_info"),
                            systemImage: "doc.on.clipboard"
                        )
                    }
                    .buttonStyle(.bordered)
                    .tint(tokens.primaryAction)
                    .controlSize(.large)
                    .disabled(isScanDisabled)
                    .accessibilityHint(L10n.text("ui.paste_connection_info_hint"))
                    .accessibilityIdentifier("settings.hostInstaller.pasteConnectionInfo")
                }
                .padding(.vertical, 4)
            } header: {
                Text(L10n.text("ui.connect_on_this_device"))
            } footer: {
                Text(connectionFooter)
            }
        }
        .listRowBackground(tokens.elevatedSurface)
    }
}

/// 满宽操作按钮的图标不应把标题挤离整条按钮的中心线。
/// 两侧使用等宽占位，让标题始终相对按钮全局居中，并给大字体留出对称的换行空间。
private struct GloballyCenteredActionLabel: View {
    @ScaledMetric(relativeTo: .body) private var accessorySlotWidth = 28.0

    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: systemImage)
                .frame(width: accessorySlotWidth, alignment: .leading)
                .accessibilityHidden(true)

            Text(title)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            Color.clear
                .frame(width: accessorySlotWidth)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}
