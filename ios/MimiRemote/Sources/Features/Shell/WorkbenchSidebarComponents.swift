import SwiftUI

/// 固定导航入口自绘选中态，避免 iOS 26 SidebarListStyle 自动套用过圆的胶囊背景。
struct WorkbenchSidebarDestinationButton: View {
    @EnvironmentObject private var themeStore: ThemeStore

    let title: String
    let systemImage: String
    let isSelected: Bool
    let tokens: ThemeTokens
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(themeStore.uiFont(size: 18, weight: isSelected ? .semibold : .medium))
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
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

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

        HStack {
            meButton

            Spacer(minLength: 0)

            newSessionButton
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

    @ViewBuilder
    private var meButton: some View {
        Group {
            if usesFloatingSurface, !reduceTransparency {
                Button(action: onOpenSettings) {
                    meButtonLabel
                }
                .buttonStyle(.plain)
                .foregroundStyle(isMeSelected ? tokens.primaryAction : tokens.secondaryText)
                .background(
                    isMeSelected ? tokens.selectionFill.opacity(0.42) : Color.clear,
                    in: Capsule()
                )
                .glassEffect(.clear.interactive(), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(
                            tokens.border.opacity(colorSchemeContrast == .increased ? 1 : 0.42),
                            lineWidth: colorSchemeContrast == .increased ? 1 : 0.75
                        )
                }
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
        Label(L10n.text("ui.me"), systemImage: "person.crop.circle")
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
                        .foregroundStyle(tokens.primaryActionForeground)
                        .frame(width: 44, height: 44)
                        // 不使用 glassProminent：它会为圆形按钮追加系统外边距，
                        // 在 iPad mini 上把 44pt 控件膨胀成过强的主视觉。
                        // 让主题紫成为玻璃本身的 tint，避免实色底板盖住折射与动态高光。
                        .glassEffect(
                            .regular.tint(tokens.primaryAction).interactive(),
                            in: .circle
                        )
                        .overlay {
                            Circle()
                                .stroke(Color.white.opacity(0.22), lineWidth: 0.75)
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
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
