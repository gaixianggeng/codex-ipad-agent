import SwiftUI

struct ConversationCommentaryRow: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let message: ConversationMessage
    let layout: ConversationLayout

    var body: some View {
        commentaryBody
            .frame(maxWidth: layout.assistantBubbleMaxWidth, alignment: .leading)
            .contentShape(Rectangle())
            .messageContextMenu(
                for: message,
                retry: {},
                stop: { sessionStore.sendCtrlC() }
            )
            .accessibilityElement(children: .contain)
    }

    private var commentaryBody: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let style = MarkdownStyle.make(
            role: .assistant,
            colorScheme: colorScheme,
            fontScale: themeStore.fontScale,
            tokens: tokens
        )
        let plan = MessageRenderPlanCache.shared.plan(for: message)
        return VStack(alignment: .leading, spacing: style.blockSpacing) {
            ForEach(plan.blocks) { block in
                MarkdownBlockView(block: block, style: style)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
