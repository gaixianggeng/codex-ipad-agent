import SwiftUI

/// 首次连接只保留两个用户阶段：先在 Mac 上准备，再在当前设备扫码。
/// 命令行和手动输入由外层单独收进“其他连接方式”，避免恢复路径干扰主任务。
struct MacInstallationSetupView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let connectionFooter: String
    let isScanDisabled: Bool
    let onScan: () -> Void
    let onPasteConnectionInfo: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("ui.install_mimi_remote_mac"))
                        .font(themeStore.uiFont(.body, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)

                    Text(L10n.text("ui.mac_installer_requirements_and_instructions"))
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)

                ShareLink(item: AppExternalLinks.macInstaller) {
                    GloballyCenteredActionLabel(
                        title: L10n.text("ui.send_download_link_to_mac"),
                        systemImage: "square.and.arrow.up"
                    )
                }
                .buttonStyle(.bordered)
                .tint(tokens.primaryAction)
                .controlSize(.large)
                .accessibilityIdentifier("settings.macInstaller.share")

                Link(destination: AppExternalLinks.macRelease) {
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
                .accessibilityIdentifier("settings.macInstaller.githubRelease")
            } header: {
                Text(L10n.text("ui.prepare_on_mac"))
            } footer: {
                Text(L10n.text("ui.select_code_directory_then_mac_shows_qr"))
            }

            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.text("ui.scan_qr_code_after_mac_setup"))
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: onScan) {
                        GloballyCenteredActionLabel(
                            title: L10n.text("ui.scan_qr_code_on_mac"),
                            systemImage: "qrcode.viewfinder"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tokens.primaryAction)
                    .controlSize(.large)
                    .disabled(isScanDisabled)
                    .accessibilityIdentifier("settings.macInstaller.scan")

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
                    .accessibilityIdentifier("settings.macInstaller.pasteConnectionInfo")
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
