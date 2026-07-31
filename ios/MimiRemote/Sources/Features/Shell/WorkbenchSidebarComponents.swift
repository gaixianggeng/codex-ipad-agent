import SwiftUI

/// 顶层导航只维护语义与 outline / fill 配对，避免 iPhone Tab 与 iPad 侧栏各自挑选图标。
enum WorkbenchNavigationIcon {
    case sessions
    case workspaces
    case me

    var normalSystemName: String {
        switch self {
        case .sessions: return "bubble.left.and.bubble.right"
        case .workspaces: return "folder"
        case .me: return "person.crop.circle"
        }
    }

    var selectedSystemName: String {
        switch self {
        case .sessions: return "bubble.left.and.bubble.right.fill"
        case .workspaces: return "folder.fill"
        case .me: return "person.crop.circle.fill"
        }
    }

    func systemName(isSelected: Bool) -> String {
        isSelected ? selectedSystemName : normalSystemName
    }
}

/// 固定导航入口自绘选中态，避免 iOS 26 SidebarListStyle 自动套用过圆的胶囊背景。
struct WorkbenchSidebarDestinationButton: View {
    @EnvironmentObject private var themeStore: ThemeStore

    let title: String
    let icon: WorkbenchNavigationIcon
    let isSelected: Bool
    let tokens: ThemeTokens
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon.systemName(isSelected: isSelected))
                    .font(themeStore.uiFont(size: 18, weight: isSelected ? .semibold : .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tokens.primaryAction)
                    .frame(width: 24)

                Text(title)
                    .font(themeStore.uiFont(.body, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(tokens.primaryText)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(
                isSelected ? tokens.selectionFill : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(tokens.primaryAction)
                        .frame(width: 3, height: 22)
                        .padding(.leading, 3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .listRowInsets(.init(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? L10n.text("ui.selected") : L10n.text("ui.not_selected"))
    }
}

/// 宽屏浮动侧栏让列表铺满整列，底部操作只作为局部玻璃控件叠加；
/// 其他布局仍保留稳定 Footer，避免改变 iPhone 与覆盖式侧栏行为。
struct WorkbenchSidebarContentLayout<Content: View, Footer: View>: View {
    let usesFloatingSurface: Bool
    private let content: Content
    private let footer: Footer

    init(
        usesFloatingSurface: Bool,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.usesFloatingSurface = usesFloatingSurface
        self.content = content()
        self.footer = footer()
    }

    @ViewBuilder
    var body: some View {
        if usesFloatingSurface {
            content
                // 最后一行可以滚到按钮上方，但列表视口与背景仍完整延伸到底部。
                .contentMargins(.bottom, 64, for: .scrollContent)
                .overlay(alignment: .bottom) {
                    footer
                }
        } else {
            VStack(spacing: 0) {
                content
                footer
            }
        }
    }
}

/// 全局配置放左侧，主创建动作放右侧；两端布局在侧栏高度变化时保持稳定。
struct WorkbenchSidebarFooter: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let tokens: ThemeTokens
    let usesFloatingSurface: Bool
    let bottomSafeAreaInset: CGFloat
    let isMeSelected: Bool
    let onOpenSettings: () -> Void
    let onNewSession: () -> Void

    init(
        tokens: ThemeTokens,
        usesFloatingSurface: Bool = false,
        bottomSafeAreaInset: CGFloat = 0,
        isMeSelected: Bool = false,
        onOpenSettings: @escaping () -> Void,
        onNewSession: @escaping () -> Void
    ) {
        self.tokens = tokens
        self.usesFloatingSurface = usesFloatingSurface
        self.bottomSafeAreaInset = bottomSafeAreaInset
        self.isMeSelected = isMeSelected
        self.onOpenSettings = onOpenSettings
        self.onNewSession = onNewSession
    }

    var body: some View {
        // footer 下方还包含系统安全区；向下补偿其一半（最多 10pt），让控件在整块可见底栏中视觉居中，
        // 同时仍把完整触控区域留在安全区之上。
        let safeAreaVisualOffset = min(max(bottomSafeAreaInset, 0) / 2, 10)

        Group {
            if usesFloatingSurface, !reduceTransparency {
                // 两个按钮由系统统一合成，但间距足够大，不会在静止状态下粘连成一整块玻璃。
                GlassEffectContainer(spacing: 16) {
                    footerButtonRow
                }
            } else {
                footerButtonRow
            }
        }
        .offset(y: safeAreaVisualOffset)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            if !usesFloatingSurface {
                Rectangle()
                    .fill(tokens.border.opacity(0.55))
                    .frame(height: 1)
            }
        }
    }

    private var footerButtonRow: some View {
        HStack {
            meButton

            Spacer(minLength: 0)

            newSessionButton
        }
    }

    @ViewBuilder
    private var meButton: some View {
        Group {
            if usesFloatingSurface, !reduceTransparency {
                Button(action: onOpenSettings) {
                    meButtonLabel
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .foregroundStyle(isMeSelected ? tokens.primaryAction : tokens.secondaryText)
                .contentShape(Capsule())
            } else {
                Button(action: onOpenSettings) {
                    meButtonLabel
                }
                .buttonStyle(.plain)
                .foregroundStyle(isMeSelected ? tokens.primaryAction : tokens.secondaryText)
                .background(
                    isMeSelected ? tokens.selectionFill : tokens.surface.opacity(0.72),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .stroke(tokens.border.opacity(0.6), lineWidth: 1)
                }
            }
        }
        .accessibilityLabel(L10n.text("ui.me"))
        .accessibilityValue(
            isMeSelected ? L10n.text("ui.selected") : L10n.text("ui.not_selected")
        )
        .accessibilityAddTraits(isMeSelected ? .isSelected : [])
        .accessibilityIdentifier("sidebar.me")
    }

    private var meButtonLabel: some View {
        Label {
            Text(L10n.text("ui.me"))
        } icon: {
            Image(
                systemName: WorkbenchNavigationIcon.me.systemName(
                    isSelected: isMeSelected
                )
            )
            .symbolRenderingMode(.hierarchical)
        }
        .font(themeStore.uiFont(.subheadline, weight: .medium))
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    @ViewBuilder
    private var newSessionButton: some View {
        Group {
            if usesFloatingSurface, !reduceTransparency {
                Button(action: onNewSession) {
                    Image(systemName: "plus")
                        .font(themeStore.uiFont(size: 15, weight: .semibold))
                }
                // 只让系统 ButtonStyle 绘制一层主题色玻璃，不再在 label 内叠材质和白色描边。
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                // 视觉尺寸交给系统控件，44pt 仅作为可点击区域，避免玻璃圆面被二次放大。
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Circle())
                .tint(tokens.primaryAction)
                .foregroundStyle(tokens.primaryActionForeground)
            } else {
                Button(action: onNewSession) {
                    Image(systemName: "plus")
                        .font(themeStore.uiFont(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(tokens.primaryAction, in: Circle())
                        .overlay {
                            Circle()
                                .stroke(tokens.primaryAction.opacity(0.72), lineWidth: 1)
                        }
                        .contentShape(Circle())
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.primaryActionForeground)
            }
        }
        .accessibilityLabel(L10n.text("ui.new_session_3da224c4"))
        .accessibilityIdentifier("sidebar.newSession")
    }
}
