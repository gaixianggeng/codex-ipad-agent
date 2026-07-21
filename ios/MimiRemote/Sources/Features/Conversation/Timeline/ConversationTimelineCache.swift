import Foundation

struct ConversationTimelineSnapshot {
    let items: [ConversationTimelineItem]
    let itemIDs: [String]
    let tailItemID: String?

    static let empty = ConversationTimelineSnapshot(items: [], itemIDs: [], tailItemID: nil)
}

final class ConversationTimelineItemCache {
    private var keys: [ConversationTimelineCacheKey] = []
    private var cachedSnapshot = ConversationTimelineSnapshot.empty

    func snapshot(
        from messages: [ConversationMessage],
        suspendingUpdates: Bool = false
    ) -> ConversationTimelineSnapshot {
        // 用户正在拖动/减速时保留同一份 List 快照。流式输出仍进入 Store，
        // 但不在每个 delta 上重建整条长时间线；滚动结束后一次性追上最新状态。
        if suspendingUpdates, !cachedSnapshot.items.isEmpty {
            return cachedSnapshot
        }

        let nextKeys = messages.map { ConversationTimelineCacheKey(message: $0) }
        guard nextKeys != keys else {
            return cachedSnapshot
        }
        let nextItems = ConversationTimelineItemBuilder.items(from: messages)
        keys = nextKeys
        cachedSnapshot = ConversationTimelineSnapshot(
            items: nextItems,
            itemIDs: nextItems.map(\.id),
            tailItemID: nextItems.last?.id
        )
        return cachedSnapshot
    }

    func removeAll() {
        keys.removeAll()
        cachedSnapshot = .empty
    }

    var tailItemID: String? {
        cachedSnapshot.tailItemID
    }
}

private struct ConversationTimelineCacheKey: Equatable {
    let id: UUID
    let stableID: MessageID?
    let clientMessageID: ClientMessageID?
    let turnID: TurnID?
    let itemID: AgentItemID?
    let role: ConversationMessage.Role
    let kind: MessageKind
    let createdAt: Date
    let updatedAt: Date?
    let sendStatus: MessageSendStatus
    let revision: ModelRevision?
    let renderFingerprint: ConversationMessageRenderFingerprint
    let turnPayload: CodexAppServerTurnPayload?
    let activityPayload: ConversationActivityPayload?
    let isTimestampFallback: Bool

    init(message: ConversationMessage) {
        self.id = message.id
        self.stableID = message.stableID
        self.clientMessageID = message.clientMessageID
        self.turnID = message.turnID
        self.itemID = message.itemID
        self.role = message.role
        self.kind = message.kind
        self.createdAt = message.createdAt
        self.updatedAt = message.updatedAt
        self.sendStatus = message.sendStatus
        self.revision = message.revision
        self.renderFingerprint = message.renderFingerprint
        self.turnPayload = message.turnPayload
        self.activityPayload = message.activityPayload
        self.isTimestampFallback = message.isTimestampFallback
    }
}
