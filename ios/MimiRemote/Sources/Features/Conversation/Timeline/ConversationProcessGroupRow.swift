import SwiftUI

struct ConversationProcessGroupRow: View, Equatable {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme

    let group: ConversationProcessGroup
    let layout: ConversationLayout
    let isExpanded: Bool
    let expandedActivityIDs: Set<String>
    let toggleGroup: () -> Void
    let toggleActivity: (ConversationMessage) -> Void

    static func == (lhs: ConversationProcessGroupRow, rhs: ConversationProcessGroupRow) -> Bool {
        guard lhs.group.id == rhs.group.id,
              lhs.group.title == rhs.group.title,
              lhs.group.status == rhs.group.status,
              lhs.group.activities.count == rhs.group.activities.count,
              lhs.group.failedCount == rhs.group.failedCount,
              lhs.layout == rhs.layout,
              lhs.isExpanded == rhs.isExpanded,
              lhs.expandedActivityIDs == rhs.expandedActivityIDs
        else {
            return false
        }
        return !lhs.isExpanded || lhs.group.activities == rhs.group.activities
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Button(action: toggleGroup) {
                    header
                }
                .buttonStyle(.plain)
                .accessibilityLabel(summaryText)
                .accessibilityValue(accessibilityValue)
                .accessibilityHint(isExpanded ? L10n.text("ui.collapse_this_stage_of_activities") : L10n.text("ui.expand_this_stage_of_activities"))

                if isExpanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(group.activities) { message in
                            ConversationActivityRow(
                                message: message,
                                layout: layout,
                                isExpanded: expandedActivityIDs.contains(
                                    ConversationTimelineItem.activityID(for: message)
                                ),
                                toggle: { toggleActivity(message) }
                            )
                            .equatable()
                            .padding(.leading, 20)
                        }
                    }
                    .transition(activityTransition)
                }
            }
            .frame(maxWidth: layout.assistantBubbleMaxWidth, alignment: .leading)

            Spacer(minLength: layout.messageSideSpacer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusMarker

            Text(summaryText)
                .font(themeStore.uiFont(.caption, weight: .medium))
                .italic()
                .foregroundStyle(headerTint)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(themeStore.uiFont(.caption2, weight: .semibold))
                .foregroundStyle(tokens.secondaryText.opacity(0.76))
                .frame(width: 18, height: 18)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusMarker: some View {
        switch group.status {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .tint(tokens.secondaryText)
                .frame(width: 14, height: 18)
        case .completed:
            Image(systemName: "circle.fill")
                .font(themeStore.uiFont(size: 5, weight: .semibold))
                .foregroundStyle(tokens.secondaryText)
                .frame(width: 14, height: 18)
        case .interrupted:
            Image(systemName: "stop.circle.fill")
                .font(themeStore.uiFont(size: 11, weight: .semibold))
                .foregroundStyle(tokens.secondaryText)
                .frame(width: 14, height: 18)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(themeStore.uiFont(size: 11, weight: .semibold))
                .foregroundStyle(Color.red)
                .frame(width: 14, height: 18)
        }
    }

    private var activityTransition: AnyTransition {
        accessibilityReduceMotion
            ? .opacity
            : .opacity.combined(with: .move(edge: .top))
    }

    private var accessibilityValue: String {
        let state = isExpanded ? L10n.text("ui.expanded") : L10n.text("ui.collected")
        return L10n.format(
            "ui.value_contains_value",
            state,
            L10n.plural("ui.activities_count", count: group.activities.count)
        )
    }

    private var summaryText: String {
        [group.title, group.failureDetail]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var headerTint: Color {
        group.status == .failed ? .red : tokens.secondaryText
    }

    private var tokens: ThemeTokens {
        themeStore.tokens(for: colorScheme)
    }
}
