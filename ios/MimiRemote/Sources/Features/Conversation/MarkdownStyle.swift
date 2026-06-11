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
        return MarkdownStyle(
            role: role,
            textColor: tokens?.primaryText ?? (isUser ? .white : .primary),
            secondaryColor: tokens?.secondaryText ?? (isUser ? Color.white.opacity(0.74) : .secondary),
            linkColor: tokens?.accent ?? (isUser ? Color.white : Color.accentColor),
            codeForeground: tokens?.codeText ?? (isUser ? .white : .primary),
            codeBackground: tokens?.codeBlock ?? (isUser ? Color.white.opacity(0.16) : Color(.tertiarySystemBackground)),
            tableBackground: tokens?.elevatedSurface ?? (isUser ? Color.white.opacity(0.16) : Color(.secondarySystemBackground)),
            quoteBar: tokens?.accent.opacity(colorScheme == .dark ? 0.76 : 0.64)
                ?? (isUser ? Color.white.opacity(0.56) : Color.accentColor.opacity(colorScheme == .dark ? 0.76 : 0.64)),
            dividerColor: tokens?.border ?? (isUser ? Color.white.opacity(0.24) : Color(.separator)),
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
