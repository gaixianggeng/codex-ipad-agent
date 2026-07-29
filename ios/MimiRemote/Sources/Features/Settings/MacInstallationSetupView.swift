import SwiftUI

/// 首次连接的普通用户路径。安装、首次设置和扫码按真实任务顺序排列，
/// Homebrew 与手动输入仍由外层设置页保留为高级恢复入口。
struct MacInstallationSetupView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let isScanDisabled: Bool
    let onScan: () -> Void
    let onPasteConnectionInfo: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 18) {
            setupStep(
                number: 1,
                title: L10n.text("ui.install_mimi_remote_mac"),
                detail: L10n.text("ui.mac_installer_requirements_and_instructions")
            ) {
                VStack(alignment: .leading, spacing: 10) {
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
                        HStack(spacing: 10) {
                            // 品牌资源保持官方黑白原色，不跟随 App 的主题色染色。
                            Image("GitHubInvertocat")
                                .renderingMode(.original)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 28, height: 28)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.text("ui.view_releases_on_github"))
                                    .font(themeStore.uiFont(.callout, weight: .semibold))
                                    .foregroundStyle(tokens.primaryText)
                                Text(AppExternalLinks.macRelease.absoluteString)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(tokens.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 8)

                            Image(systemName: "arrow.up.right")
                                .font(themeStore.uiFont(.caption, weight: .semibold))
                                .foregroundStyle(tokens.secondaryText)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("ui.view_releases_on_github"))
                    .accessibilityHint(L10n.text("ui.github_release_accessibility_hint"))
                    .accessibilityIdentifier("settings.macInstaller.githubRelease")
                }
            }

            Divider()

            setupStep(
                number: 2,
                title: L10n.text("ui.open_and_finish_initial_setup"),
                detail: L10n.text("ui.select_code_directory_then_mac_shows_qr")
            ) {
                EmptyView()
            }

            Divider()

            setupStep(
                number: 3,
                title: L10n.text("ui.scan_qr_code_to_connect"),
                detail: nil
            ) {
                VStack(spacing: 10) {
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
            }
        }
        .padding(.vertical, 6)
    }

    private func setupStep<Actions: View>(
        number: Int,
        title: String,
        detail: String?,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return HStack(alignment: .top, spacing: 12) {
            Text(number.formatted())
                .font(themeStore.uiFont(.caption, weight: .bold))
                .foregroundStyle(tokens.primaryActionForeground)
                .frame(width: 26, height: 26)
                .background(tokens.primaryAction, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(themeStore.uiFont(.body, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)

                if let detail {
                    Text(detail)
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                actions()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
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
