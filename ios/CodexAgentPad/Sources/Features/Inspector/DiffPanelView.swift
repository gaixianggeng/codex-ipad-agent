import SwiftUI

struct DiffPanelView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var conversationStore: ConversationStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if fileChangeItems.isEmpty {
                    ContentUnavailableView("暂无文件变更", systemImage: "doc.text.magnifyingglass")
                        .font(themeStore.uiFont(.caption))
                        .padding(.top, 48)
                } else {
                    ForEach(fileChangeItems) { item in
                        InspectorSummaryCard(
                            symbolName: "doc.text.magnifyingglass",
                            title: item.title,
                            subtitle: item.displaySubtitle,
                            tint: tokens.accent
                        )
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var fileChangeItems: [DiffPanelItem] {
        let messages = conversationStore
            .messages(for: sessionStore.selectedSessionID)
            .filter { $0.kind == .fileChangeSummary }
            .suffix(80)

        return DiffPanelItem.items(from: messages)
    }
}

struct DiffPanelItem: Identifiable {
    let fileKey: String
    var latestContent = ""
    var latestCreatedAt = Date.distantPast
    var count = 0
    var wasCollapsed = false

    var id: String { fileKey }

    var title: String {
        count > 1 ? "文件变更 x\(count)" : "文件变更"
    }

    var displaySubtitle: String {
        let suffix = wasCollapsed ? "\n\n已折叠长 diff，仅展示尾部摘要。" : ""
        return latestContent + suffix
    }

    mutating func merge(_ message: ConversationMessage) {
        count += 1
        if message.createdAt >= latestCreatedAt {
            latestCreatedAt = message.createdAt
            let collapsed = Self.collapsedContent(message.content)
            latestContent = collapsed.content
            wasCollapsed = collapsed.wasCollapsed
        }
    }

    static func fileKey(from message: ConversationMessage) -> String {
        let content = message.content
            .replacingOccurrences(of: "文件变更：", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let firstToken = content.split(separator: " ", maxSplits: 1).first.map(String.init)
        return firstToken?.isEmpty == false ? firstToken! : message.stableID ?? message.id.uuidString
    }

    static func items<S: Sequence>(from messages: S) -> [DiffPanelItem] where S.Element == ConversationMessage {
        var grouped: [String: DiffPanelItem] = [:]
        for message in messages {
            let key = DiffPanelItem.fileKey(from: message)
            grouped[key, default: DiffPanelItem(fileKey: key)].merge(message)
        }

        return grouped.values
            .sorted { $0.latestCreatedAt > $1.latestCreatedAt }
            .prefix(50)
            .map { $0 }
    }

    static func collapsedContent(_ content: String) -> (content: String, wasCollapsed: Bool) {
        let maxCharacters = 1_200
        guard content.count > maxCharacters else {
            return (content, false)
        }
        return (String(content.suffix(maxCharacters)), true)
    }
}

struct InspectorSummaryCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let symbolName: String
    let title: String
    let subtitle: String
    let tint: Color
    let lineLimit: Int?

    init(symbolName: String, title: String, subtitle: String, tint: Color, lineLimit: Int? = 4) {
        self.symbolName = symbolName
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.lineLimit = lineLimit
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbolName)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(subtitle)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(lineLimit)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        }
    }

}
