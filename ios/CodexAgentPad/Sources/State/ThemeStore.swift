import SwiftUI

enum ThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    case highContrast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "跟随系统"
        case .light:
            return "浅色"
        case .dark:
            return "深色"
        case .highContrast:
            return "高对比"
        }
    }

    var subtitle: String {
        switch self {
        case .system:
            return "使用 iPad 当前外观"
        case .light:
            return "明亮阅读界面"
        case .dark:
            return "低眩光工作界面"
        case .highContrast:
            return "强化边界和文本"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark, .highContrast:
            return .dark
        }
    }
}

enum ThemeAccent: String, CaseIterable, Identifiable {
    case blue
    case teal
    case green
    case orange
    case rose
    case violet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue:
            return "蓝"
        case .teal:
            return "青"
        case .green:
            return "绿"
        case .orange:
            return "橙"
        case .rose:
            return "玫瑰"
        case .violet:
            return "紫"
        }
    }

    var color: Color {
        switch self {
        case .blue:
            return Color(red: 0.16, green: 0.42, blue: 0.92)
        case .teal:
            return Color(red: 0.00, green: 0.55, blue: 0.62)
        case .green:
            return Color(red: 0.12, green: 0.55, blue: 0.28)
        case .orange:
            return Color(red: 0.88, green: 0.38, blue: 0.10)
        case .rose:
            return Color(red: 0.84, green: 0.20, blue: 0.36)
        case .violet:
            return Color(red: 0.44, green: 0.30, blue: 0.86)
        }
    }
}

struct ThemeTokens {
    let background: Color
    let surface: Color
    let elevatedSurface: Color
    let userBubble: Color
    let assistantBubble: Color
    let systemBubble: Color
    let codeBlock: Color
    let primaryText: Color
    let secondaryText: Color
    let accent: Color
    let warning: Color
    let success: Color
    let border: Color
}

@MainActor
final class ThemeStore: ObservableObject {
    @Published var mode: ThemeMode {
        didSet { persistVisualState() }
    }

    @Published var accent: ThemeAccent {
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
        static let accent = "appearance.theme.accent"
        static let fontScale = "appearance.theme.fontScale"
        static let themeVersion = "appearance.theme.version"
    }

    static let minimumFontScale = 0.85
    static let maximumFontScale = 1.35
    static let defaultFontScale = 1.0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedMode = defaults.string(forKey: Keys.mode).flatMap(ThemeMode.init(rawValue:)) ?? .system
        let savedAccent = defaults.string(forKey: Keys.accent).flatMap(ThemeAccent.init(rawValue:)) ?? .blue
        let savedFontScale = defaults.object(forKey: Keys.fontScale).flatMap { $0 as? Double } ?? Self.defaultFontScale

        self.mode = savedMode
        self.accent = savedAccent
        self.fontScale = Self.clampedFontScale(savedFontScale)
        self.themeVersion = defaults.integer(forKey: Keys.themeVersion)
    }

    var preferredColorScheme: ColorScheme? {
        mode.preferredColorScheme
    }

    func setFontScale(_ value: Double) {
        fontScale = Self.clampedFontScale(value)
    }

    func reset() {
        mode = .system
        accent = .blue
        fontScale = Self.defaultFontScale
    }

    func scaledFontSize(_ baseSize: CGFloat) -> CGFloat {
        baseSize * CGFloat(fontScale)
    }

    func tokens(for systemColorScheme: ColorScheme) -> ThemeTokens {
        // 主题只产出视觉 token，不读写消息或 session 数据，保证外观切换不影响会话状态。
        switch mode {
        case .system:
            return systemColorScheme == .dark ? darkTokens : lightTokens
        case .light:
            return lightTokens
        case .dark:
            return darkTokens
        case .highContrast:
            return highContrastTokens
        }
    }

    static func clampedFontScale(_ value: Double) -> Double {
        min(max(value, minimumFontScale), maximumFontScale)
    }

    private var lightTokens: ThemeTokens {
        ThemeTokens(
            background: Color(red: 0.97, green: 0.98, blue: 0.98),
            surface: .white,
            elevatedSurface: Color(red: 0.93, green: 0.95, blue: 0.96),
            userBubble: accent.color.opacity(0.16),
            assistantBubble: .white,
            systemBubble: Color(red: 0.91, green: 0.94, blue: 0.96),
            codeBlock: Color(red: 0.10, green: 0.12, blue: 0.15),
            primaryText: Color(red: 0.08, green: 0.10, blue: 0.13),
            secondaryText: Color(red: 0.36, green: 0.40, blue: 0.46),
            accent: accent.color,
            warning: Color(red: 0.88, green: 0.48, blue: 0.08),
            success: Color(red: 0.10, green: 0.55, blue: 0.28),
            border: Color(red: 0.78, green: 0.82, blue: 0.86)
        )
    }

    private var darkTokens: ThemeTokens {
        ThemeTokens(
            background: Color(red: 0.06, green: 0.07, blue: 0.09),
            surface: Color(red: 0.10, green: 0.12, blue: 0.15),
            elevatedSurface: Color(red: 0.15, green: 0.17, blue: 0.20),
            userBubble: accent.color.opacity(0.32),
            assistantBubble: Color(red: 0.12, green: 0.14, blue: 0.17),
            systemBubble: Color(red: 0.18, green: 0.20, blue: 0.23),
            codeBlock: Color(red: 0.02, green: 0.03, blue: 0.04),
            primaryText: Color(red: 0.94, green: 0.95, blue: 0.96),
            secondaryText: Color(red: 0.70, green: 0.73, blue: 0.76),
            accent: accent.color,
            warning: Color(red: 1.00, green: 0.66, blue: 0.22),
            success: Color(red: 0.36, green: 0.82, blue: 0.50),
            border: Color(red: 0.28, green: 0.31, blue: 0.36)
        )
    }

    private var highContrastTokens: ThemeTokens {
        ThemeTokens(
            background: .black,
            surface: Color(red: 0.05, green: 0.05, blue: 0.05),
            elevatedSurface: Color(red: 0.12, green: 0.12, blue: 0.12),
            userBubble: Color(red: 0.06, green: 0.16, blue: 0.36),
            assistantBubble: .black,
            systemBubble: Color(red: 0.16, green: 0.16, blue: 0.16),
            codeBlock: .black,
            primaryText: .white,
            secondaryText: Color(red: 0.88, green: 0.88, blue: 0.88),
            accent: .yellow,
            warning: Color(red: 1.00, green: 0.72, blue: 0.00),
            success: Color(red: 0.48, green: 1.00, blue: 0.58),
            border: .white
        )
    }

    private func persistVisualState() {
        defaults.set(mode.rawValue, forKey: Keys.mode)
        defaults.set(accent.rawValue, forKey: Keys.accent)
        defaults.set(fontScale, forKey: Keys.fontScale)
        themeVersion += 1
        defaults.set(themeVersion, forKey: Keys.themeVersion)
    }
}
