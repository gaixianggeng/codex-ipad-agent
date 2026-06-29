import SwiftUI

struct MarkdownStyle: Equatable {
    let role: ConversationMessage.Role
    let textColor: Color
    let secondaryColor: Color
    let linkColor: Color
    let codeForeground: Color
    let codeBackground: Color
    let tableBackground: Color
    let quoteBar: Color
    let dividerColor: Color
    let blockSpacing: CGFloat
    let textLineSpacing: CGFloat
    let fontScale: Double

    static func make(
        role: ConversationMessage.Role,
        colorScheme: ColorScheme,
        fontScale: Double = 1.0,
        tokens: ThemeTokens? = nil
    ) -> MarkdownStyle {
        let isUser = role == .user
        let fallbackAccent = colorScheme == .dark
            ? Color(red: 0.77, green: 0.56, blue: 0.84)
            : Color(red: 0.38, green: 0.12, blue: 0.41)
        // 默认白紫主题的用户气泡是深紫底，需要单独使用浅色文字；其它主题继续走自身 token。
        let usesDarkUserBubble = isUser && (tokens?.preset == .codex || tokens == nil)
        let userText = Color(red: 0.97, green: 0.94, blue: 0.99)
        return MarkdownStyle(
            role: role,
            textColor: usesDarkUserBubble ? userText : (tokens?.primaryText ?? .primary),
            secondaryColor: usesDarkUserBubble ? userText.opacity(0.74) : (tokens?.secondaryText ?? .secondary),
            linkColor: usesDarkUserBubble ? userText : (tokens?.accent ?? fallbackAccent),
            codeForeground: usesDarkUserBubble ? userText : (tokens?.codeText ?? .primary),
            codeBackground: usesDarkUserBubble ? Color.white.opacity(0.16) : (tokens?.codeBlock ?? Color(.tertiarySystemBackground)),
            tableBackground: usesDarkUserBubble ? Color.white.opacity(0.16) : (tokens?.elevatedSurface ?? Color(.secondarySystemBackground)),
            quoteBar: usesDarkUserBubble
                ? Color.white.opacity(0.56)
                : (tokens?.accent.opacity(colorScheme == .dark ? 0.76 : 0.64)
                    ?? fallbackAccent.opacity(colorScheme == .dark ? 0.76 : 0.64)),
            dividerColor: tokens?.border ?? (usesDarkUserBubble ? Color.white.opacity(0.24) : Color(.separator)),
            // 对话气泡里的 Markdown 按“阅读辅助”处理，字号比文档页面克制，避免回复显得笨重。
            blockSpacing: 7,
            textLineSpacing: 2,
            fontScale: fontScale
        )
    }

    var bodyFont: Font {
        .system(size: scaled(15))
    }

    var codeFont: Font {
        .system(size: scaled(13), design: .monospaced)
    }

    var captionFont: Font {
        .system(size: scaled(11), weight: .medium)
    }

    func headingFont(level: Int) -> Font {
        switch level {
        case 1:
            return .system(size: scaled(20), weight: .bold)
        case 2:
            return .system(size: scaled(18), weight: .bold)
        case 3:
            return .system(size: scaled(17), weight: .semibold)
        case 4:
            return .system(size: scaled(16), weight: .semibold)
        default:
            return .system(size: scaled(15), weight: .semibold)
        }
    }

    func scaled(_ baseSize: CGFloat) -> CGFloat {
        baseSize * CGFloat(fontScale)
    }
}
