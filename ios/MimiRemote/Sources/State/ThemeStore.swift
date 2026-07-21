import SwiftUI

private extension Color {
    /// 产品默认主操作色 #4A144A。集中定义，避免按钮、消息和色卡分别取近似值。
    static let mimiPrimary = Color(
        red: 74.0 / 255.0,
        green: 20.0 / 255.0,
        blue: 74.0 / 255.0
    )
}

enum ThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return L10n.text("ui.system")
        case .light:
            return L10n.text("ui.light_color")
        case .dark:
            return L10n.text("ui.dark")
        }
    }

    var subtitle: String {
        switch self {
        case .system:
            return L10n.text("ui.follow_the_current_device_appearance")
        case .light:
            return L10n.text("ui.bright_reading_interface")
        case .dark:
            return L10n.text("ui.low_glare_work_surface")
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

enum ThemeResolvedScheme: String {
    case light
    case dark
}

private struct ThemeSystemColorSchemeKey: EnvironmentKey {
    static let defaultValue: ColorScheme? = nil
}

extension EnvironmentValues {
    var themeSystemColorScheme: ColorScheme? {
        get { self[ThemeSystemColorSchemeKey.self] }
        set { self[ThemeSystemColorSchemeKey.self] = newValue }
    }
}

enum ThemePreset: String, CaseIterable, Identifiable {
    case codex
    case github
    case xcode
    case gruvbox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex:
            return L10n.text("ui.warm_sun")
        case .github:
            return "GitHub"
        case .xcode:
            return "Xcode"
        case .gruvbox:
            return "Gruvbox"
        }
    }

    var subtitle: String {
        switch self {
        case .codex:
            return L10n.text("ui.neutral_warm_white_with_a_single_main_color")
        case .github:
            return L10n.text("ui.code_review_color_matching_close_to_github_primer")
        case .xcode:
            return L10n.text("ui.close_to_xcode_s_native_editing_area_and")
        case .gruvbox:
            return L10n.text("ui.warm_colors_and_low_contrast_suitable_for_night")
        }
    }

    var swatchForeground: Color {
        switch self {
        case .codex:
            return .mimiPrimary
        case .github:
            return Color(red: 0.03, green: 0.41, blue: 0.85)
        case .xcode:
            // Xcode Default (Dark) 的 keyword 粉色配合编辑器底色，比通用系统蓝更容易识别这个预设。
            return Color(red: 0.988394, green: 0.37355, blue: 0.638329)
        case .gruvbox:
            return Color(red: 0.84, green: 0.55, blue: 0.22)
        }
    }

    var swatchBackground: Color {
        switch self {
        case .codex:
            return Color(red: 0.976, green: 0.973, blue: 0.961)
        case .github:
            return Color(red: 0.96, green: 0.97, blue: 0.98)
        case .xcode:
            return Color(red: 0.120543, green: 0.122844, blue: 0.141312)
        case .gruvbox:
            return Color(red: 0.20, green: 0.19, blue: 0.16)
        }
    }
}

enum ThemeUIFontPreset: String, CaseIterable, Identifiable {
    case system
    case rounded
    case serif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return L10n.text("ui.system")
        case .rounded:
            return L10n.text("ui.round_body")
        case .serif:
            return L10n.text("ui.serif")
        }
    }

    var design: Font.Design {
        switch self {
        case .system:
            return .default
        case .rounded:
            return .rounded
        case .serif:
            return .serif
        }
    }
}

enum ThemeCodeFontPreset: String, CaseIterable, Identifiable {
    case systemMono
    case menlo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemMono:
            return "SF Mono"
        case .menlo:
            return "Menlo"
        }
    }

    func font(size: CGFloat, weight: Font.Weight) -> Font {
        switch self {
        case .systemMono:
            return .system(size: size, weight: weight, design: .monospaced)
        case .menlo:
            // Menlo 是 iOS/macOS 常见内置等宽字体，和 SF Mono 形成真正的字体族差异。
            return .custom("Menlo-Regular", size: size).weight(weight)
        }
    }
}

struct ThemeTokens {
    let preset: ThemePreset
    let resolvedScheme: ThemeResolvedScheme
    let background: Color
    let surface: Color
    let elevatedSurface: Color
    let userBubble: Color
    let assistantBubble: Color
    let systemBubble: Color
    let codeBlock: Color
    let codeText: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let accent: Color
    let warning: Color
    let success: Color
    let goalActive: Color
    let voiceRecording: Color
    let voiceWaveformGradient: [Color]
    let border: Color
    let selectionFill: Color
}

extension ThemeTokens {
    var sidebarBackground: Color {
        guard preset == .codex else {
            return background
        }
        switch resolvedScheme {
        case .light:
            return Color(red: 0.976, green: 0.973, blue: 0.961)
        case .dark:
            return Color(red: 0.090, green: 0.098, blue: 0.118)
        }
    }

    var sidebarHoverFill: Color {
        guard preset == .codex else {
            return elevatedSurface
        }
        switch resolvedScheme {
        case .light:
            return Color(red: 0.941, green: 0.937, blue: 0.929)
        case .dark:
            return Color(red: 0.137, green: 0.153, blue: 0.180)
        }
    }

    var inputBackground: Color {
        guard preset == .codex else {
            return elevatedSurface
        }
        switch resolvedScheme {
        case .light:
            return .white
        case .dark:
            return Color(red: 0.125, green: 0.137, blue: 0.165)
        }
    }

    var planCardBackground: Color {
        guard preset == .codex else {
            return elevatedSurface
        }
        switch resolvedScheme {
        case .light:
            return .white
        case .dark:
            return Color(red: 0.125, green: 0.141, blue: 0.169)
        }
    }

    var planCardBorder: Color {
        guard preset == .codex else {
            return border
        }
        switch resolvedScheme {
        case .light:
            return Color(red: 0.902, green: 0.890, blue: 0.878)
        case .dark:
            return Color(red: 0.231, green: 0.259, blue: 0.302)
        }
    }

    /// 深色主按钮使用明确的梅紫实色；亮紫只留给小面积焦点，避免大按钮呈现灰紫雾感。
    var primaryAction: Color {
        guard preset == .codex else { return accent }
        switch resolvedScheme {
        case .light:
            return .mimiPrimary
        case .dark:
            return Color(red: 0.584, green: 0.333, blue: 0.620)
        }
    }

    var livelyAccent: Color {
        guard preset == .codex else { return accent }
        return primaryAction
    }

    /// 主按钮在两种外观下都使用白字，维持一致、清晰的操作语义。
    var primaryActionForeground: Color {
        .white
    }

    var accentSoft: Color {
        guard preset == .codex else { return accent.opacity(0.12) }
        switch resolvedScheme {
        case .light:
            return Color(red: 0.949, green: 0.933, blue: 0.945)
        case .dark:
            return Color(red: 0.165, green: 0.137, blue: 0.180)
        }
    }

    var userBubbleForeground: Color {
        guard preset == .codex else { return primaryText }
        return Color(red: 0.984, green: 0.957, blue: 0.984)
    }

    func tint(for tone: AgentSessionStatusTone) -> Color {
        switch tone {
        case .active:
            // 运行态延续当前外观的主操作色；真正完成/成功仍使用 success。
            return primaryAction
        case .warning:
            return warning
        case .danger:
            return .red
        case .complete:
            return accent
        case .neutral:
            return secondaryText
        }
    }
}

@MainActor
final class ThemeStore: ObservableObject {
    @Published var mode: ThemeMode {
        didSet { persistVisualState() }
    }

    @Published var preset: ThemePreset {
        didSet { persistVisualState() }
    }

    @Published var uiFontPreset: ThemeUIFontPreset {
        didSet { persistVisualState() }
    }

    @Published var codeFontPreset: ThemeCodeFontPreset {
        didSet { persistVisualState() }
    }

    @Published var fontScale: Double {
        didSet {
            let clamped = Self.clampedFontScale(fontScale)
            guard clamped == fontScale else {
                fontScale = clamped
                return
            }
            persistVisualState()
        }
    }

    @Published private(set) var themeVersion: Int

    private let defaults: UserDefaults

    private enum Keys {
        static let mode = "appearance.theme.mode"
        static let preset = "appearance.theme.preset"
        static let uiFont = "appearance.theme.uiFont"
        static let codeFont = "appearance.theme.codeFont"
        static let fontScale = "appearance.theme.fontScale"
        static let themeVersion = "appearance.theme.version"
    }

    static let fontScaleStorageKey = Keys.fontScale
    static let minimumFontScale = 0.85
    static let maximumFontScale = 1.35
    static let defaultFontScale = 1.0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedMode = defaults.string(forKey: Keys.mode).flatMap(ThemeMode.init(rawValue:)) ?? .system
        let savedPreset = defaults.string(forKey: Keys.preset).flatMap(ThemePreset.init(rawValue:)) ?? .codex
        let savedUIFont = defaults.string(forKey: Keys.uiFont).flatMap(ThemeUIFontPreset.init(rawValue:)) ?? .system
        let savedCodeFont = defaults.string(forKey: Keys.codeFont).flatMap(ThemeCodeFontPreset.init(rawValue:)) ?? .systemMono
        let savedFontScale = defaults.object(forKey: Keys.fontScale).flatMap { $0 as? Double } ?? Self.defaultFontScale

        self.mode = savedMode
        self.preset = savedPreset
        self.uiFontPreset = savedUIFont
        self.codeFontPreset = savedCodeFont
        self.fontScale = Self.clampedFontScale(savedFontScale)
        self.themeVersion = defaults.integer(forKey: Keys.themeVersion)
    }

    var preferredColorScheme: ColorScheme? {
        mode.preferredColorScheme
    }

    func resolvedColorScheme(for systemColorScheme: ColorScheme) -> ColorScheme {
        // 系统模式不能直接依赖已打开 sheet 里的 colorScheme；它可能还停留在上一次手动浅/深色。
        switch resolvedScheme(for: systemColorScheme) {
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    func setFontScale(_ value: Double) {
        fontScale = Self.clampedFontScale(value)
    }

    func reset() {
        mode = .system
        preset = .codex
        uiFontPreset = .system
        codeFontPreset = .systemMono
        fontScale = Self.defaultFontScale
    }

    func scaledFontSize(_ baseSize: CGFloat) -> CGFloat {
        baseSize * CGFloat(fontScale)
    }

    func uiFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: scaledFontSize(size), weight: weight, design: uiFontPreset.design)
    }

    func uiFont(_ textStyle: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        uiFont(size: Self.baseSize(for: textStyle), weight: weight)
    }

    func codeFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let scaled = scaledFontSize(size)
        return codeFontPreset.font(size: scaled, weight: weight)
    }

    func codeFont(_ textStyle: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        codeFont(size: Self.baseSize(for: textStyle), weight: weight)
    }

    func tokens(for systemColorScheme: ColorScheme) -> ThemeTokens {
        // 主题只产出视觉 token，不读写消息或 session 数据，保证外观切换不影响会话状态。
        let scheme = resolvedScheme(for: systemColorScheme)
        switch (preset, scheme) {
        case (.codex, .light):
            return codexLightTokens
        case (.codex, .dark):
            return codexDarkTokens
        case (.github, .light):
            return githubLightTokens
        case (.github, .dark):
            return githubDarkTokens
        case (.xcode, .light):
            return xcodeLightTokens
        case (.xcode, .dark):
            return xcodeDarkTokens
        case (.gruvbox, .light):
            return gruvboxLightTokens
        case (.gruvbox, .dark):
            return gruvboxDarkTokens
        }
    }

    static func clampedFontScale(_ value: Double) -> Double {
        min(max(value, minimumFontScale), maximumFontScale)
    }

    private static func baseSize(for textStyle: Font.TextStyle) -> CGFloat {
        switch textStyle {
        case .largeTitle:
            return 34
        case .title:
            return 28
        case .title2:
            return 22
        case .title3:
            return 20
        case .headline:
            return 17
        case .subheadline:
            return 15
        case .callout:
            return 16
        case .caption:
            return 12
        case .caption2:
            return 11
        case .footnote:
            return 13
        default:
            return 17
        }
    }

    private func resolvedScheme(for systemColorScheme: ColorScheme) -> ThemeResolvedScheme {
        switch mode {
        case .system:
            return systemColorScheme == .dark ? .dark : .light
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    private var codexLightTokens: ThemeTokens {
        // 参考系统设置页：中性暖白、白色卡片和单一深紫；层级依靠留白与明度，不铺彩色底。
        ThemeTokens(
            preset: .codex,
            resolvedScheme: .light,
            background: Color(red: 0.976, green: 0.973, blue: 0.961),
            surface: Color(red: 1.00, green: 1.00, blue: 1.00),
            elevatedSurface: Color(red: 0.957, green: 0.953, blue: 0.941),
            userBubble: .mimiPrimary,
            assistantBubble: .white,
            systemBubble: Color(red: 0.953, green: 0.949, blue: 0.941),
            codeBlock: Color(red: 0.141, green: 0.125, blue: 0.122),
            codeText: Color(red: 1.000, green: 0.969, blue: 0.941),
            primaryText: Color(red: 0.169, green: 0.141, blue: 0.129),
            secondaryText: Color(red: 0.557, green: 0.557, blue: 0.576),
            tertiaryText: Color(red: 0.635, green: 0.635, blue: 0.651),
            accent: .mimiPrimary,
            warning: Color(red: 0.663, green: 0.376, blue: 0.000),
            success: Color(red: 0.184, green: 0.490, blue: 0.353),
            goalActive: .mimiPrimary,
            voiceRecording: .mimiPrimary,
            voiceWaveformGradient: [
                .mimiPrimary,
                Color(red: 0.478, green: 0.259, blue: 0.467),
                Color(red: 0.690, green: 0.525, blue: 0.678),
            ],
            border: Color(red: 0.898, green: 0.886, blue: 0.875),
            selectionFill: Color(red: 0.937, green: 0.925, blue: 0.929)
        )
    }

    private var codexDarkTokens: ThemeTokens {
        // 大面积区域保持中性石墨灰，只在交互和用户内容上使用明确的梅紫，避免棕色与灰紫叠加发闷。
        ThemeTokens(
            preset: .codex,
            resolvedScheme: .dark,
            background: Color(red: 0.063, green: 0.067, blue: 0.078),
            surface: Color(red: 0.098, green: 0.106, blue: 0.125),
            elevatedSurface: Color(red: 0.141, green: 0.153, blue: 0.180),
            userBubble: Color(red: 0.376, green: 0.231, blue: 0.404),
            assistantBubble: Color(red: 0.098, green: 0.106, blue: 0.125),
            systemBubble: Color(red: 0.125, green: 0.137, blue: 0.165),
            codeBlock: Color(red: 0.043, green: 0.051, blue: 0.067),
            codeText: Color(red: 0.949, green: 0.957, blue: 0.969),
            primaryText: Color(red: 0.949, green: 0.957, blue: 0.969),
            secondaryText: Color(red: 0.663, green: 0.690, blue: 0.729),
            tertiaryText: Color(red: 0.494, green: 0.529, blue: 0.576),
            accent: Color(red: 0.773, green: 0.541, blue: 0.831),
            warning: Color(red: 0.941, green: 0.702, blue: 0.353),
            success: Color(red: 0.396, green: 0.757, blue: 0.545),
            goalActive: Color(red: 0.808, green: 0.498, blue: 0.631),
            voiceRecording: Color(red: 0.773, green: 0.541, blue: 0.831),
            voiceWaveformGradient: [
                Color(red: 0.871, green: 0.682, blue: 0.914),
                Color(red: 0.773, green: 0.541, blue: 0.831),
                Color(red: 0.584, green: 0.333, blue: 0.620)
            ],
            border: Color(red: 0.204, green: 0.224, blue: 0.259),
            selectionFill: Color(red: 0.180, green: 0.149, blue: 0.196)
        )
    }

    private var githubLightTokens: ThemeTokens {
        ThemeTokens(
            preset: .github,
            resolvedScheme: .light,
            background: Color(red: 1.00, green: 1.00, blue: 1.00),
            surface: Color(red: 1.00, green: 1.00, blue: 1.00),
            elevatedSurface: Color(red: 0.96, green: 0.97, blue: 0.98),
            userBubble: Color(red: 0.03, green: 0.41, blue: 0.85).opacity(0.13),
            assistantBubble: Color(red: 1.00, green: 1.00, blue: 1.00),
            systemBubble: Color(red: 0.96, green: 0.97, blue: 0.98),
            codeBlock: Color(red: 0.96, green: 0.97, blue: 0.98),
            codeText: Color(red: 0.13, green: 0.16, blue: 0.20),
            primaryText: Color(red: 0.12, green: 0.14, blue: 0.16),
            secondaryText: Color(red: 0.35, green: 0.39, blue: 0.43),
            tertiaryText: Color(red: 0.43, green: 0.48, blue: 0.53),
            accent: Color(red: 0.03, green: 0.41, blue: 0.85),
            warning: Color(red: 0.60, green: 0.40, blue: 0.00),
            success: Color(red: 0.10, green: 0.50, blue: 0.22),
            goalActive: Color(red: 0.03, green: 0.41, blue: 0.85),
            voiceRecording: Color(red: 0.10, green: 0.48, blue: 0.78),
            voiceWaveformGradient: [
                Color(red: 0.32, green: 0.68, blue: 0.96),
                Color(red: 0.03, green: 0.41, blue: 0.85),
                Color(red: 0.02, green: 0.30, blue: 0.64)
            ],
            border: Color(red: 0.82, green: 0.84, blue: 0.87),
            selectionFill: Color(red: 0.03, green: 0.41, blue: 0.85).opacity(0.12)
        )
    }

    private var githubDarkTokens: ThemeTokens {
        ThemeTokens(
            preset: .github,
            resolvedScheme: .dark,
            background: Color(red: 0.05, green: 0.07, blue: 0.09),
            surface: Color(red: 0.09, green: 0.11, blue: 0.15),
            elevatedSurface: Color(red: 0.13, green: 0.16, blue: 0.20),
            userBubble: Color(red: 0.18, green: 0.51, blue: 0.97).opacity(0.28),
            assistantBubble: Color(red: 0.09, green: 0.11, blue: 0.15),
            systemBubble: Color(red: 0.13, green: 0.16, blue: 0.20),
            codeBlock: Color(red: 0.04, green: 0.06, blue: 0.08),
            codeText: Color(red: 0.90, green: 0.93, blue: 0.95),
            primaryText: Color(red: 0.90, green: 0.93, blue: 0.95),
            secondaryText: Color(red: 0.49, green: 0.52, blue: 0.56),
            tertiaryText: Color(red: 0.36, green: 0.39, blue: 0.44),
            accent: Color(red: 0.18, green: 0.51, blue: 0.97),
            warning: Color(red: 0.82, green: 0.60, blue: 0.13),
            success: Color(red: 0.25, green: 0.73, blue: 0.31),
            goalActive: Color(red: 0.42, green: 0.68, blue: 1.00),
            voiceRecording: Color(red: 0.36, green: 0.64, blue: 1.00),
            voiceWaveformGradient: [
                Color(red: 0.58, green: 0.80, blue: 1.00),
                Color(red: 0.18, green: 0.51, blue: 0.97),
                Color(red: 0.10, green: 0.36, blue: 0.76)
            ],
            border: Color(red: 0.19, green: 0.22, blue: 0.25),
            selectionFill: Color(red: 0.18, green: 0.51, blue: 0.97).opacity(0.18)
        )
    }

    private var xcodeLightTokens: ThemeTokens {
        // 直接对齐 Xcode Default (Light) 的编辑器、当前行、选区、注释和 markup 色；
        // UI 层只补一档中性导航器灰，避免整套主题退化成“灰底 + 系统蓝”。
        ThemeTokens(
            preset: .xcode,
            resolvedScheme: .light,
            background: Color(red: 0.96, green: 0.96, blue: 0.96),
            surface: Color(red: 1.00, green: 1.00, blue: 1.00),
            elevatedSurface: Color(red: 0.925, green: 0.929, blue: 0.937),
            userBubble: Color(red: 0.909804, green: 0.94902, blue: 1.00),
            assistantBubble: Color(red: 1.00, green: 1.00, blue: 1.00),
            systemBubble: Color(red: 0.96, green: 0.96, blue: 0.96),
            codeBlock: Color(red: 1.00, green: 1.00, blue: 1.00),
            codeText: Color.black.opacity(0.85),
            primaryText: Color.black.opacity(0.85),
            secondaryText: Color(red: 0.36526, green: 0.421879, blue: 0.475154),
            tertiaryText: Color(red: 0.50, green: 0.53, blue: 0.57),
            accent: Color(red: 0.00, green: 0.48, blue: 1.00),
            warning: Color(red: 0.937255, green: 0.717647, blue: 0.34902),
            success: Color(red: 0.152941, green: 0.494118, blue: 0.117647),
            goalActive: Color(red: 0.607592, green: 0.137526, blue: 0.576284),
            voiceRecording: Color(red: 0.0588235, green: 0.407843, blue: 0.627451),
            voiceWaveformGradient: [
                Color(red: 0.194184, green: 0.429349, blue: 0.454553),
                Color(red: 0.0588235, green: 0.407843, blue: 0.627451),
                Color(red: 0.607592, green: 0.137526, blue: 0.576284)
            ],
            border: Color(red: 0.8832, green: 0.8832, blue: 0.8832),
            selectionFill: Color(red: 0.909804, green: 0.94902, blue: 1.00)
        )
    }

    private var xcodeDarkTokens: ThemeTokens {
        // Xcode Default (Dark) 的编辑器背景并非纯黑，而是带极轻蓝相的 #1F1F24；
        // markup 面板、边框、选区和语法色继续使用同一套官方色值，建立真实的编辑器层级。
        ThemeTokens(
            preset: .xcode,
            resolvedScheme: .dark,
            background: Color(red: 0.120543, green: 0.122844, blue: 0.141312),
            surface: Color(red: 0.138526, green: 0.146864, blue: 0.169283),
            elevatedSurface: Color(red: 0.18856, green: 0.195, blue: 0.22444),
            userBubble: Color(red: 0.317647, green: 0.356862, blue: 0.439215),
            assistantBubble: Color(red: 0.138526, green: 0.146864, blue: 0.169283),
            systemBubble: Color(red: 0.18856, green: 0.195, blue: 0.22444),
            codeBlock: Color(red: 0.120543, green: 0.122844, blue: 0.141312),
            codeText: Color.white.opacity(0.85),
            primaryText: Color.white.opacity(0.94),
            secondaryText: Color(red: 0.423943, green: 0.474618, blue: 0.525183),
            tertiaryText: Color(red: 0.258298, green: 0.300954, blue: 0.355207),
            accent: Color(red: 0.330191, green: 0.511266, blue: 0.998589),
            warning: Color(red: 0.937255, green: 0.717647, blue: 0.34902),
            success: Color(red: 0.309804, green: 0.788235, blue: 0.254902),
            goalActive: Color(red: 0.988394, green: 0.37355, blue: 0.638329),
            voiceRecording: Color(red: 0.362946, green: 0.846428, blue: 0.998966),
            voiceWaveformGradient: [
                Color(red: 0.362946, green: 0.846428, blue: 0.998966),
                Color(red: 0.631373, green: 0.403922, blue: 0.901961),
                Color(red: 0.988394, green: 0.37355, blue: 0.638329)
            ],
            border: Color(red: 0.253475, green: 0.2594, blue: 0.286485),
            selectionFill: Color(red: 0.317647, green: 0.356862, blue: 0.439215)
        )
    }

    private var gruvboxLightTokens: ThemeTokens {
        ThemeTokens(
            preset: .gruvbox,
            resolvedScheme: .light,
            background: Color(red: 0.96, green: 0.91, blue: 0.82),
            surface: Color(red: 0.98, green: 0.94, blue: 0.85),
            elevatedSurface: Color(red: 0.90, green: 0.84, blue: 0.72),
            userBubble: Color(red: 0.69, green: 0.38, blue: 0.10).opacity(0.20),
            assistantBubble: Color(red: 0.98, green: 0.94, blue: 0.85),
            systemBubble: Color(red: 0.88, green: 0.81, blue: 0.68),
            codeBlock: Color(red: 0.20, green: 0.19, blue: 0.16),
            codeText: Color(red: 0.93, green: 0.86, blue: 0.68),
            primaryText: Color(red: 0.22, green: 0.18, blue: 0.13),
            secondaryText: Color(red: 0.42, green: 0.35, blue: 0.25),
            tertiaryText: Color(red: 0.58, green: 0.50, blue: 0.38),
            accent: Color(red: 0.69, green: 0.38, blue: 0.10),
            warning: Color(red: 0.80, green: 0.42, blue: 0.10),
            success: Color(red: 0.49, green: 0.53, blue: 0.17),
            goalActive: Color(red: 0.03, green: 0.40, blue: 0.47),
            voiceRecording: Color(red: 0.80, green: 0.42, blue: 0.10),
            voiceWaveformGradient: [
                Color(red: 0.86, green: 0.52, blue: 0.15),
                Color(red: 0.80, green: 0.42, blue: 0.10),
                Color(red: 0.59, green: 0.31, blue: 0.08)
            ],
            border: Color(red: 0.72, green: 0.64, blue: 0.50),
            selectionFill: Color(red: 0.69, green: 0.38, blue: 0.10).opacity(0.17)
        )
    }

    private var gruvboxDarkTokens: ThemeTokens {
        ThemeTokens(
            preset: .gruvbox,
            resolvedScheme: .dark,
            background: Color(red: 0.16, green: 0.15, blue: 0.13),
            surface: Color(red: 0.20, green: 0.19, blue: 0.16),
            elevatedSurface: Color(red: 0.27, green: 0.25, blue: 0.21),
            userBubble: Color(red: 0.84, green: 0.55, blue: 0.22).opacity(0.28),
            assistantBubble: Color(red: 0.20, green: 0.19, blue: 0.16),
            systemBubble: Color(red: 0.28, green: 0.26, blue: 0.22),
            codeBlock: Color(red: 0.11, green: 0.10, blue: 0.09),
            codeText: Color(red: 0.93, green: 0.86, blue: 0.68),
            primaryText: Color(red: 0.92, green: 0.86, blue: 0.70),
            secondaryText: Color(red: 0.74, green: 0.67, blue: 0.52),
            tertiaryText: Color(red: 0.58, green: 0.53, blue: 0.42),
            accent: Color(red: 0.84, green: 0.55, blue: 0.22),
            warning: Color(red: 0.98, green: 0.56, blue: 0.25),
            success: Color(red: 0.72, green: 0.73, blue: 0.36),
            goalActive: Color(red: 0.51, green: 0.65, blue: 0.60),
            voiceRecording: Color(red: 0.98, green: 0.56, blue: 0.25),
            voiceWaveformGradient: [
                Color(red: 0.98, green: 0.66, blue: 0.28),
                Color(red: 0.98, green: 0.56, blue: 0.25),
                Color(red: 0.75, green: 0.39, blue: 0.18)
            ],
            border: Color(red: 0.38, green: 0.35, blue: 0.29),
            selectionFill: Color(red: 0.84, green: 0.55, blue: 0.22).opacity(0.20)
        )
    }

    private func persistVisualState() {
        defaults.set(mode.rawValue, forKey: Keys.mode)
        defaults.set(preset.rawValue, forKey: Keys.preset)
        defaults.set(uiFontPreset.rawValue, forKey: Keys.uiFont)
        defaults.set(codeFontPreset.rawValue, forKey: Keys.codeFont)
        defaults.set(fontScale, forKey: Keys.fontScale)
        themeVersion += 1
        defaults.set(themeVersion, forKey: Keys.themeVersion)
    }
}
