import SwiftUI
import UIKit

struct ComposerSkillQuery: Equatable {
    let query: String
    let replacementRange: NSRange

    static func match(text: String, selectedRange: NSRange) -> ComposerSkillQuery? {
        let source = text as NSString
        guard selectedRange.length == 0,
              selectedRange.location >= 0,
              selectedRange.location <= source.length
        else {
            return nil
        }

        let prefixRange = NSRange(location: 0, length: selectedRange.location)
        let whitespace = source.rangeOfCharacter(
            from: .whitespacesAndNewlines,
            options: .backwards,
            range: prefixRange
        )
        let tokenStart = whitespace.location == NSNotFound ? 0 : NSMaxRange(whitespace)
        let tokenRange = NSRange(location: tokenStart, length: selectedRange.location - tokenStart)
        guard tokenRange.length > 0 else {
            return nil
        }
        let token = source.substring(with: tokenRange)
        guard token.hasPrefix("$") else {
            return nil
        }
        return ComposerSkillQuery(
            query: String(token.dropFirst()),
            replacementRange: tokenRange
        )
    }
}

struct SkillVisualMetadata: Hashable {
    let name: String
    let displayName: String
    let description: String?
    let scope: String?
    let path: String
    let brandColor: String?

    init(capability: SkillCapability) {
        name = capability.name
        displayName = capability.presentationName
        description = capability.presentationDescription
        scope = capability.scope
        path = capability.path
        brandColor = capability.brandColor
    }

    init(name: String, path: String, capability: SkillCapability? = nil) {
        self.name = name
        displayName = capability?.presentationName ?? name
        description = capability?.presentationDescription
        scope = capability?.scope
        self.path = path
        brandColor = capability?.brandColor
    }

    var scopeTitle: String? {
        switch scope?.lowercased() {
        case "repo": return "项目"
        case "user": return "个人"
        case "system": return "系统"
        case "admin": return "管理"
        default: return scope?.uppercased()
        }
    }
}

struct SkillIconView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let metadata: SkillVisualMetadata
    var size: CGFloat = 32

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let tint = SkillBrandColor.color(metadata.brandColor) ?? tokens.accent
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)

        Image(systemName: "wand.and.stars")
            .font(themeStore.uiFont(size: size * 0.43, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: shape)
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
            }
            .shadow(color: tint.opacity(0.2), radius: 5, y: 2)
            .accessibilityHidden(true)
    }
}

struct SkillPickerPanel: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let skills: [SkillCapability]
    let selectedPaths: Set<String>
    let errorMessage: String?
    let isRefreshing: Bool
    let onToggle: (SkillCapability) -> Void
    let onRefresh: () -> Void
    let onManualAdd: () -> Void

    @State private var searchText = ""

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SkillIconView(
                    metadata: SkillVisualMetadata(name: "skill", path: "skill"),
                    size: 38
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skills")
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text("选择后会作为结构化能力随消息发送")
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.secondaryText)
                }
                Spacer(minLength: 8)
                Button(action: onRefresh) {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .accessibilityLabel("刷新 Skill 列表")
            }

            if skills.count > 7 {
                TextField("搜索 Skill", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }

            Group {
                if filteredSkills.isEmpty {
                    emptyState(tokens: tokens)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(filteredSkills) { skill in
                                skillRow(skill, tokens: tokens)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .frame(maxHeight: 390)
                }
            }

            Button(action: onManualAdd) {
                Label("手动添加 Skill", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(width: 410)
        .background(tokens.surface)
    }

    private var filteredSkills: [SkillCapability] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return skills }
        return skills.filter { skill in
            skill.name.localizedCaseInsensitiveContains(query)
                || skill.presentationName.localizedCaseInsensitiveContains(query)
                || (skill.presentationDescription?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func skillRow(_ skill: SkillCapability, tokens: ThemeTokens) -> some View {
        let selected = selectedPaths.contains(skill.path)
        let metadata = SkillVisualMetadata(capability: skill)
        let tint = SkillBrandColor.color(skill.brandColor) ?? tokens.accent

        return Button {
            onToggle(skill)
        } label: {
            HStack(spacing: 11) {
                SkillIconView(metadata: metadata, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("$\(metadata.displayName)")
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(1)
                    if let description = metadata.description {
                        Text(description)
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let scope = metadata.scopeTitle {
                    Text(scope)
                        .font(themeStore.uiFont(.caption2, weight: .semibold))
                        .foregroundStyle(selected ? tint : tokens.tertiaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background((selected ? tint : tokens.border).opacity(0.12), in: Capsule())
                }
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(themeStore.uiFont(size: 18, weight: .semibold))
                    .foregroundStyle(selected ? tint : tokens.tertiaryText)
            }
            .padding(10)
            .background(
                selected ? tint.opacity(0.11) : tokens.elevatedSurface,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? tint.opacity(0.52) : tokens.border.opacity(0.82), lineWidth: selected ? 1.25 : 1)
            }
            .scaleEffect(selected && !reduceMotion ? 1.012 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.86), value: selected)
        .accessibilityLabel("Skill \(metadata.displayName)")
        .accessibilityValue(selected ? "已选择" : "未选择")
    }

    private func emptyState(tokens: ThemeTokens) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "wand.and.stars.inverse")
                .font(themeStore.uiFont(size: 26, weight: .medium))
                .foregroundStyle(tokens.tertiaryText)
            Text(searchText.isEmpty ? "暂无可用 Skill" : "没有匹配的 Skill")
                .font(themeStore.uiFont(.callout, weight: .medium))
                .foregroundStyle(tokens.secondaryText)
            if searchText.isEmpty, let error = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                Text(error)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.tertiaryText)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }
}

struct SkillAttachmentToken: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let metadata: SkillVisualMetadata
    let onOpen: (() -> Void)?
    let onRemove: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let tint = SkillBrandColor.color(metadata.brandColor) ?? tokens.accent
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)

        HStack(spacing: 8) {
            Button {
                onOpen?()
            } label: {
                HStack(spacing: 8) {
                    SkillIconView(metadata: metadata, size: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("$\(metadata.displayName)")
                            .font(themeStore.uiFont(.caption, weight: .semibold))
                            .foregroundStyle(tokens.primaryText)
                            .lineLimit(1)
                        Text("SKILL")
                            .font(themeStore.uiFont(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(tint)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(onOpen == nil)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(themeStore.uiFont(size: 16, weight: .semibold))
                    .foregroundStyle(tokens.tertiaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除 Skill \(metadata.displayName)")
        }
        .padding(.leading, 7)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(tint.opacity(0.09), in: shape)
        .overlay {
            shape.strokeBorder(tint.opacity(0.38), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

struct SkillInvocationCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let metadata: SkillVisualMetadata
    let sendStatus: MessageSendStatus
    var usesUserBubbleContrast = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let tint = SkillBrandColor.color(metadata.brandColor) ?? tokens.accent
        let primary = usesUserBubbleContrast ? Color.white : tokens.primaryText
        let secondary = usesUserBubbleContrast ? Color.white.opacity(0.76) : tokens.secondaryText
        let statusTint = usesUserBubbleContrast ? Color.white.opacity(0.9) : tint
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        HStack(alignment: .top, spacing: 10) {
            SkillIconView(metadata: metadata, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text("$\(metadata.displayName)")
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .foregroundStyle(primary)
                        .lineLimit(1)
                    statusSymbol(tint: statusTint)
                }
                if let description = metadata.description {
                    Text(description)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(secondary)
                        .lineLimit(2)
                } else {
                    Text("已随本轮调用")
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("SKILL")
                .font(themeStore.uiFont(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(usesUserBubbleContrast ? Color.white.opacity(0.82) : tint)
                .padding(.top, 2)
        }
        .padding(10)
        .background(usesUserBubbleContrast ? Color.white.opacity(0.1) : tint.opacity(0.08), in: shape)
        .overlay {
            shape.strokeBorder(
                sendStatus == .failed
                    ? Color.red.opacity(0.7)
                    : (usesUserBubbleContrast ? Color.white.opacity(0.22) : tint.opacity(0.32)),
                lineWidth: 1
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("已调用 Skill \(metadata.displayName)")
    }

    @ViewBuilder
    private func statusSymbol(tint: Color) -> some View {
        switch sendStatus {
        case .sending, .local:
            ProgressView()
                .controlSize(.mini)
                .tint(tint)
                .transition(.opacity)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .sent, .confirmed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(tint)
                .symbolEffect(.appear, options: reduceMotion ? .nonRepeating : .nonRepeating)
        }
    }
}

struct SkillAutocompletePanel: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let skills: [SkillCapability]
    let selectedIndex: Int
    let onSelect: (SkillCapability) -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("选择 Skill", systemImage: "wand.and.stars")
                Spacer()
                Text("↑↓ 选择  ↩︎ 确认  esc 关闭")
            }
            .font(themeStore.uiFont(.caption2, weight: .semibold))
            .foregroundStyle(tokens.secondaryText)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)

            ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
                Button {
                    onSelect(skill)
                } label: {
                    HStack(spacing: 9) {
                        SkillIconView(metadata: SkillVisualMetadata(capability: skill), size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("$\(skill.presentationName)")
                                .font(themeStore.uiFont(.caption, weight: .semibold))
                                .foregroundStyle(tokens.primaryText)
                            if let description = skill.presentationDescription {
                                Text(description)
                                    .font(themeStore.uiFont(.caption2))
                                    .foregroundStyle(tokens.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        if index == selectedIndex {
                            Image(systemName: "return")
                                .foregroundStyle(tokens.accent)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        index == selectedIndex ? tokens.selectionFill : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tokens.border.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 16, y: 7)
    }
}

private enum SkillBrandColor {
    static func color(_ rawValue: String?) -> Color? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else {
            return nil
        }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
