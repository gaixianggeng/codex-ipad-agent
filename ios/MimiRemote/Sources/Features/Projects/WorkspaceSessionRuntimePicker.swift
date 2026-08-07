import SwiftUI

/// 工作区会话只浏览一个 Runtime；这里集中维护上游 provider、品牌资源和可用性映射。
enum WorkspaceSessionRuntimeChoice: String, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var runtimeProvider: String {
        switch self {
        case .codex:
            return "codex"
        case .claude:
            return "claude"
        }
    }

    var listTitle: String {
        switch self {
        case .codex:
            return L10n.text("ui.runtime_default")
        case .claude:
            return L10n.text("ui.runtime_claude_short")
        }
    }

    var title: String {
        switch self {
        case .codex:
            return L10n.text("ui.create_a_new_codex_session")
        case .claude:
            return L10n.text("ui.create_a_new_claude_code_session")
        }
    }

    var brandAssetName: String {
        switch self {
        case .codex:
            return "ChatGPT"
        case .claude:
            return "Claude"
        }
    }

    static func available(claudeChannelAvailable: Bool) -> [Self] {
        claudeChannelAvailable ? [.codex, .claude] : [.codex]
    }
}

/// 独立子视图保持 Runtime 选择的布局、命中区和辅助功能语义稳定。
struct WorkspaceRuntimePicker: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    @Binding var selection: WorkspaceSessionRuntimeChoice
    let claudeChannelAvailable: Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(spacing: 2) {
            ForEach(WorkspaceSessionRuntimeChoice.allCases) { choice in
                let isSelected = selection == choice
                let isAvailable = choice != .claude || claudeChannelAvailable

                Button {
                    guard isAvailable else { return }
                    selection = choice
                } label: {
                    HStack(spacing: 6) {
                        Image(choice.brandAssetName)
                            .resizable()
                            .renderingMode(.original)
                            .scaledToFit()
                            .frame(width: 17, height: 17)
                            .accessibilityHidden(true)

                        Text(choice.listTitle)
                            .font(themeStore.uiFont(.subheadline, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    // 三态同时使用层级、字重和透明度：灰度或 Increase Contrast 下，
                    // 选中项仍靠 semibold，未选中可用项仍是可操作的 secondary，而非 disabled。
                    .foregroundStyle(
                        isSelected
                            ? tokens.primaryAction
                            : (isAvailable ? tokens.secondaryText : tokens.tertiaryText)
                    )
                    .opacity(
                        isSelected
                            ? 1
                            : (isAvailable ? 0.60 : 0.42)
                    )
                    // 未选中项只是文字，不带任何容器；运行时的切换频率远低于切工作区，
                    // 不该在顶部占一个胶囊的重量。
                    .padding(.horizontal, 8)
                    .frame(minHeight: WorkbenchChromeIconMetrics.minimumHitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isAvailable)
                .accessibilityLabel(choice.listTitle)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityHint(
                    isAvailable
                        ? L10n.text("ui.show_runtime_sessions_hint")
                        : L10n.text("ui.runtime_unavailable_hint")
                )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("ui.runtime_provider"))
        .accessibilityIdentifier("workspace.sessions.runtimePicker")
    }
}
