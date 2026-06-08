import Foundation

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var messagesBySessionID: [String: [ConversationMessage]] = [:]

    private var loadedHistorySessionIDs: Set<String> = []
    private var lastSeenSeqBySessionID: [String: EventSequence] = [:]
    private var revisionByStableMessageID: [StableMessageCacheKey: ModelRevision] = [:]
    private var messageUUIDByStableMessageID: [StableMessageCacheKey: UUID] = [:]
    private var messageIndexByStableIDBySessionID: [String: [MessageID: Int]] = [:]
    private var messageIndexByClientMessageIDBySessionID: [String: [ClientMessageID: Int]] = [:]
    private var messageIndexByUUIDBySessionID: [String: [UUID: Int]] = [:]
    private var historyProjectionCacheBySessionID: [String: HistoryProjectionCache] = [:]
    private var pendingAssistantDeltasBySessionID: [String: PendingAssistantDelta] = [:]
    private var assistantDeltaFlushTasks: [String: Task<Void, Never>] = [:]
    private var sessionAccessTickBySessionID: [String: UInt64] = [:]
    private var sessionAccessCounter: UInt64 = 0

#if DEBUG
    private(set) var historyMergeInvocationCountForTesting = 0
#endif

    private let assistantDeltaFlushDelay: UInt64 = 80_000_000
    static let retainedSessionLimit = 32

    private struct PendingAssistantDelta {
        let stableID: MessageID
        let uuid: UUID
        let clientMessageID: ClientMessageID?
        let turnID: TurnID?
        let itemID: AgentItemID?
        var text: String
        var revision: ModelRevision?
    }

    private struct HistoryProjectionCache {
        let keys: [HistoryProjectionKey]
        let messages: [ConversationMessage]
    }

    private struct HistoryProjectionKey: Hashable {
        let stableID: MessageID?
        let wireID: MessageID?
        let role: String
        let kind: MessageKind
        let content: String
        let createdAt: Date?
        let clientMessageID: ClientMessageID?
        let turnID: TurnID?
        let itemID: AgentItemID?
        let seq: EventSequence?
        let revision: ModelRevision?
        let sendStatus: MessageSendStatus?
    }

    private struct StableMessageCacheKey: Hashable {
        let sessionID: String
        let stableID: MessageID
    }

    private struct NearbyHistoryEchoCandidate {
        let role: ConversationMessage.Role
        let content: String
        let createdAt: Date
    }

    private struct UnstableHistoryReuseKey: Hashable {
        let role: ConversationMessage.Role
        let kind: MessageKind
        let content: String
        let createdAt: Date
        let sendStatus: MessageSendStatus
        let revision: ModelRevision?
    }

    private struct UnstableHistoryReuseBucket {
        let messages: [ConversationMessage]
        var nextIndex = 0

        var isExhausted: Bool {
            nextIndex >= messages.count
        }

        mutating func pop() -> ConversationMessage? {
            guard !isExhausted else {
                return nil
            }
            let message = messages[nextIndex]
            nextIndex += 1
            return message
        }
    }

    private let nearbyHistoryEchoMergeWindow: TimeInterval = 10 * 60

    func messages(for sessionID: String?) -> [ConversationMessage] {
        guard let sessionID else {
            return []
        }
        return messagesBySessionID[sessionID] ?? []
    }

    func hasLoadedHistory(sessionID: String) -> Bool {
        loadedHistorySessionIDs.contains(sessionID)
    }

    func lastSeenSeq(for sessionID: String?) -> EventSequence? {
        guard let sessionID else {
            return nil
        }
        return lastSeenSeqBySessionID[sessionID]
    }

    func retainSessionCache(sessionID: String) {
        guard messagesBySessionID[sessionID] != nil else {
            return
        }
        touchConversationSession(sessionID)
    }

    func setHistory(_ history: [CodexHistoryMessage], sessionID: String) {
        flushPendingAssistantDelta(sessionID: sessionID)
        let converted = projectedHistoryMessages(history, sessionID: sessionID)
        for message in converted {
            if let stableID = message.stableID {
                let key = stableCacheKey(stableID: stableID, sessionID: sessionID)
                messageUUIDByStableMessageID[key] = message.id
                if let revision = message.revision {
                    revisionByStableMessageID[key] = revision
                }
            }
        }
        if let current = messagesBySessionID[sessionID], areMessagesEquivalent(current, converted) {
            // 重复刷新同一页历史时，投影已经完全等价，直接标记已加载并刷新 LRU。
            // 这沿用 Litter 的 projection no-op 思路，跳过后续 merge/sort 和 @Published 检查。
            loadedHistorySessionIDs.insert(sessionID)
            touchConversationSession(sessionID)
            return
        }
        setMessages(mergeHistory(converted, with: messagesBySessionID[sessionID] ?? []), sessionID: sessionID)
        loadedHistorySessionIDs.insert(sessionID)
    }

    func appendUser(_ text: String, sessionID: String) {
        appendLocalUser(text, sessionID: sessionID, clientMessageID: nil, sendStatus: .sent)
    }

    func appendLocalUser(
        _ text: String,
        sessionID: String,
        clientMessageID: ClientMessageID?,
        sendStatus: MessageSendStatus = .sending,
        turnPayload: CodexAppServerTurnPayload? = nil
    ) {
        if let clientMessageID,
           var list = messagesBySessionID[sessionID],
           let index = messageIndex(clientMessageID: clientMessageID, sessionID: sessionID) {
            list[index].content = text
            list[index].sendStatus = sendStatus
            list[index].turnPayload = turnPayload ?? list[index].turnPayload
            setMessages(list, sessionID: sessionID, rebuildIndexes: false)
            return
        }
        append(
            ConversationMessage(
                stableID: clientMessageID,
                clientMessageID: clientMessageID,
                role: .user,
                content: text,
                sendStatus: sendStatus,
                turnPayload: turnPayload
            ),
            sessionID: sessionID
        )
    }

    func updateSendStatus(clientMessageID: ClientMessageID, sessionID: String, status: MessageSendStatus) {
        guard var list = messagesBySessionID[sessionID],
              let index = messageIndex(clientMessageID: clientMessageID, sessionID: sessionID) else {
            return
        }
        list[index].sendStatus = status
        setMessages(list, sessionID: sessionID, rebuildIndexes: false)
    }

    func compactTurnPayloadAfterSendAccepted(clientMessageID: ClientMessageID, sessionID: String) {
        guard var list = messagesBySessionID[sessionID],
              let index = messageIndex(clientMessageID: clientMessageID, sessionID: sessionID),
              let payload = list[index].turnPayload else {
            return
        }
        let retained = payload.retainedAfterAcceptedSend()
        guard list[index].turnPayload != retained else {
            return
        }
        list[index].turnPayload = retained
        replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
    }

    func appendSystem(
        _ text: String,
        sessionID: String,
        kind: MessageKind = .message,
        metadata: AgentEventMetadata? = nil
    ) {
        if kind == .approval, text.hasPrefix("等待审批："), upsertPendingApprovalMessage(text, sessionID: sessionID) {
            return
        }
        // runtime 过程消息需要保留 turnID/itemID，UI 才能在 turn 完成后准确折叠到“已处理”组里。
        append(ConversationMessage(
            turnID: metadata?.turnID,
            itemID: metadata?.itemID,
            role: .system,
            kind: kind,
            content: text,
            createdAt: metadata?.createdAt ?? Date(),
            sendStatus: .confirmed,
            revision: metadata?.revision
        ), sessionID: sessionID)
    }

    func resolveApproval(_ approval: ApprovalSummary, accepted: Bool, sessionID: String) {
        let text = accepted ? "审批已批准：\(approval.title)" : "审批已拒绝：\(approval.title)"
        guard var list = messagesBySessionID[sessionID] else {
            appendSystem(text, sessionID: sessionID, kind: .approval)
            return
        }
        // 审批结果应该回写到原来的等待卡片上，避免时间线和详情里长期显示“等待审批”。
        if let index = list.lastIndex(where: { message in
            message.kind == .approval && message.content.contains(approval.title)
        }) {
            list[index].content = text
            setMessages(list, sessionID: sessionID, rebuildIndexes: false)
            return
        }
        appendSystem(text, sessionID: sessionID, kind: .approval)
    }

    func resolveLatestPendingApproval(sessionID: String) {
        guard var list = messagesBySessionID[sessionID],
              let index = list.lastIndex(where: { message in
                  message.kind == .approval && message.content.hasPrefix("等待审批：")
              }) else {
            return
        }
        // 远端审批、turn 完成或中断只告诉我们 request 已清理，不一定告诉最终按钮决策；
        // 用中性文案收口，避免时间线长期停在“等待审批”。
        let title = pendingApprovalTitle(from: list[index].content)
        list[index].content = title.isEmpty ? "审批已解决" : "审批已解决：\(title)"
        setMessages(list, sessionID: sessionID, rebuildIndexes: false)
    }

    func moveLocalEcho(clientMessageID: ClientMessageID, from sourceSessionID: String, to targetSessionID: String) {
        guard sourceSessionID != targetSessionID,
              var source = messagesBySessionID[sourceSessionID],
              let sourceIndex = messageIndex(clientMessageID: clientMessageID, sessionID: sourceSessionID) else {
            return
        }

        // 新建会话时先挂在本地临时 session；服务端返回真实 session_id 后，
        // 只迁移同一个 client_message_id，避免用户气泡被复制两份。
        var message = source.remove(at: sourceIndex)
        message.sendStatus = .sent

        var target = messagesBySessionID[targetSessionID] ?? []
        if let targetIndex = messageIndex(clientMessageID: clientMessageID, sessionID: targetSessionID) {
            target[targetIndex].content = message.content
            target[targetIndex].sendStatus = message.sendStatus
            target[targetIndex].turnPayload = target[targetIndex].turnPayload ?? message.turnPayload
            replaceMessagesWithoutEquivalenceCheck(target, sessionID: targetSessionID)
        } else {
            target.append(message)
            setMessages(target, sessionID: targetSessionID)
        }

        if source.isEmpty {
            clearConversationSessionState(sessionID: sourceSessionID, messages: source)
            var next = messagesBySessionID
            next.removeValue(forKey: sourceSessionID)
            messagesBySessionID = next
        } else {
            setMessages(source, sessionID: sourceSessionID)
        }
    }

    private func upsertPendingApprovalMessage(_ text: String, sessionID: String) -> Bool {
        guard var list = messagesBySessionID[sessionID] else {
            return false
        }
        let title = pendingApprovalTitle(from: text)
        if let index = list.lastIndex(where: { message in
            guard message.kind == .approval, message.content.hasPrefix("等待审批：") else {
                return false
            }
            return message.content == text || pendingApprovalTitle(from: message.content) == title
        }) {
            if list[index].content != text {
                list[index].content = text
                setMessages(list, sessionID: sessionID, rebuildIndexes: false)
            }
            return true
        }
        return false
    }

    private func pendingApprovalTitle(from text: String) -> String {
        let prefix = "等待审批："
        guard text.hasPrefix(prefix) else {
            return text
        }
        var value = String(text.dropFirst(prefix.count))
        if let range = value.range(of: "，风险：") {
            value = String(value[..<range.lowerBound])
        }
        return value
    }

    func resetLiveTranscript(sessionID: String) {
        flushPendingAssistantDelta(sessionID: sessionID)
    }

    func applyAssistantDelta(_ delta: AgentDelta, metadata: AgentEventMetadata, fallbackSessionID: String) {
        let sessionID = metadata.sessionID ?? fallbackSessionID
        guard shouldAccept(metadata: metadata, sessionID: sessionID) else {
            return
        }
        guard !delta.text.isEmpty else {
            return
        }
        let stableID = stableMessageID(prefix: "assistant", metadata: metadata, fallbackSessionID: sessionID)
        guard shouldApplyRevision(metadata.revision, stableID: stableID, sessionID: sessionID) else {
            return
        }
        let key = stableCacheKey(stableID: stableID, sessionID: sessionID)
        let uuid = messageUUIDByStableMessageID[key] ?? UUID()
        messageUUIDByStableMessageID[key] = uuid
        applyAssistantDelta(
            text: delta.text,
            stableID: stableID,
            uuid: uuid,
            clientMessageID: metadata.clientMessageID,
            turnID: metadata.turnID,
            itemID: metadata.itemID,
            revision: metadata.revision,
            sessionID: sessionID
        )
    }

    private func applyAssistantDelta(
        text: String,
        stableID: MessageID,
        uuid: UUID,
        clientMessageID: ClientMessageID?,
        turnID: TurnID?,
        itemID: AgentItemID?,
        revision: ModelRevision?,
        sessionID: String
    ) {
        if pendingAssistantDeltasBySessionID[sessionID]?.stableID != stableID {
            flushPendingAssistantDelta(sessionID: sessionID)
        }

        let index = messageIndex(stableID: stableID, sessionID: sessionID) ?? messageIndex(uuid: uuid, sessionID: sessionID)
        guard index != nil else {
            appendAssistantMessage(
                text: text,
                stableID: stableID,
                uuid: uuid,
                clientMessageID: clientMessageID,
                turnID: turnID,
                itemID: itemID,
                revision: revision,
                sessionID: sessionID
            )
            return
        }

        // 第一段 delta 已经创建了可见气泡；后续文本先合并到 per-session buffer，
        // 以固定节奏批量发布，避免每个 token/分片都触发 SwiftUI 列表重绘。
        if var pending = pendingAssistantDeltasBySessionID[sessionID] {
            pending.text += text
            pending.revision = revision ?? pending.revision
            pendingAssistantDeltasBySessionID[sessionID] = pending
        } else {
            pendingAssistantDeltasBySessionID[sessionID] = PendingAssistantDelta(
                stableID: stableID,
                uuid: uuid,
                clientMessageID: clientMessageID,
                turnID: turnID,
                itemID: itemID,
                text: text,
                revision: revision
            )
        }
        scheduleAssistantDeltaFlush(sessionID: sessionID)
    }

    func completeMessage(_ message: AgentMessage, metadata: AgentEventMetadata, fallbackSessionID: String) {
        let sessionID = metadata.sessionID ?? message.sessionID
        guard shouldAccept(metadata: metadata, sessionID: sessionID) else {
            return
        }
        flushPendingAssistantDelta(sessionID: sessionID)
        let stableID = message.id
        guard shouldApplyRevision(max(metadata.revision ?? message.revision, message.revision), stableID: stableID, sessionID: sessionID) else {
            return
        }

        let role: ConversationMessage.Role
        let clientMessageID: ClientMessageID?
        switch message.role {
        case .user:
            role = .user
            clientMessageID = message.clientMessageID
        case .assistant:
            role = .assistant
            clientMessageID = nil
        default:
            role = .system
            clientMessageID = nil
        }
        let displayKind: MessageKind = message.role == .tool && message.kind == .message ? .commandSummary : message.kind

        var list = messagesBySessionID[sessionID] ?? []
        var requiresUnconditionalWrite = false
        let key = stableCacheKey(stableID: stableID, sessionID: sessionID)
        let uuid = messageUUIDByStableMessageID[key] ?? UUID()
        messageUUIDByStableMessageID[key] = uuid
        if let index = messageIndex(stableID: stableID, sessionID: sessionID) ?? clientMessageID.flatMap({ messageIndex(clientMessageID: $0, sessionID: sessionID) }) {
            list[index].stableID = stableID
            list[index].role = role
            list[index].kind = displayKind
            list[index].content = message.content
            list[index].sendStatus = message.sendStatus == .failed ? .failed : .confirmed
            list[index].revision = message.revision
            if clientMessageID != nil, message.sendStatus != .failed {
                let retained = list[index].turnPayload?.retainedAfterAcceptedSend()
                if list[index].turnPayload != retained {
                    list[index].turnPayload = retained
                    requiresUnconditionalWrite = true
                }
            }
        } else {
            list.append(ConversationMessage(
                id: uuid,
                stableID: stableID,
                clientMessageID: clientMessageID,
                turnID: message.turnID,
                itemID: message.itemID,
                role: role,
                kind: displayKind,
                content: message.content,
                createdAt: message.createdAt ?? Date(),
                sendStatus: message.sendStatus,
                revision: message.revision
            ))
        }
        if requiresUnconditionalWrite {
            replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID)
        } else {
            setMessages(list, sessionID: sessionID)
        }
    }

    func markCurrentAssistantCompleted(metadata: AgentEventMetadata, fallbackSessionID: String) {
        let sessionID = metadata.sessionID ?? fallbackSessionID
        guard shouldAccept(metadata: metadata, sessionID: sessionID) else {
            return
        }
        flushPendingAssistantDelta(sessionID: sessionID)
        let stableID = stableMessageID(prefix: "assistant", metadata: metadata, fallbackSessionID: sessionID)
        guard var list = messagesBySessionID[sessionID],
              let index = messageIndex(stableID: stableID, sessionID: sessionID) else {
            return
        }
        list[index].sendStatus = .confirmed
        if let revision = metadata.revision {
            list[index].revision = revision
        }
        setMessages(list, sessionID: sessionID, rebuildIndexes: false)
    }

    private func append(_ message: ConversationMessage, sessionID: String) {
        if message.role != .assistant {
            flushPendingAssistantDelta(sessionID: sessionID)
        }
        var list = messagesBySessionID[sessionID] ?? []
        list.append(message)
        appendMessageWithIndex(message, list: list, sessionID: sessionID)
    }

    private func shouldAccept(metadata: AgentEventMetadata, sessionID: String) -> Bool {
        guard let seq = metadata.seq else {
            return true
        }
        if let last = lastSeenSeqBySessionID[sessionID], seq <= last {
            return false
        }
        lastSeenSeqBySessionID[sessionID] = seq
        return true
    }

    private func shouldApplyRevision(_ revision: ModelRevision?, stableID: String, sessionID: String) -> Bool {
        guard let revision else {
            return true
        }
        let key = stableCacheKey(stableID: stableID, sessionID: sessionID)
        if let last = revisionByStableMessageID[key], revision <= last {
            return false
        }
        revisionByStableMessageID[key] = revision
        return true
    }

    private func stableCacheKey(stableID: MessageID, sessionID: String) -> StableMessageCacheKey {
        StableMessageCacheKey(sessionID: sessionID, stableID: stableID)
    }

    private func stableMessageID(prefix: String, metadata: AgentEventMetadata, fallbackSessionID: String) -> String {
        if let messageID = metadata.messageID {
            return messageID
        }
        if let itemID = metadata.itemID {
            return itemID
        }
        if let turnID = metadata.turnID {
            return "\(prefix):\(fallbackSessionID):\(turnID)"
        }
        return "\(prefix):\(fallbackSessionID):live"
    }

    private func normalizedAssistantTextForDedup(_ text: String) -> String {
        AssistantTextNormalizer.normalizedAssistantTextForDedup(text)
    }

    private func appendAssistantMessage(
        text: String,
        stableID: MessageID,
        uuid: UUID,
        clientMessageID: ClientMessageID?,
        turnID: TurnID?,
        itemID: AgentItemID?,
        revision: ModelRevision?,
        sessionID: String
    ) {
        var list = messagesBySessionID[sessionID] ?? []
        let message = ConversationMessage(
            id: uuid,
            stableID: stableID,
            clientMessageID: clientMessageID,
            turnID: turnID,
            itemID: itemID,
            role: .assistant,
            content: text,
            sendStatus: .sending,
            revision: revision
        )
        list.append(message)
        appendMessageWithIndex(message, list: list, sessionID: sessionID)
    }

    private func scheduleAssistantDeltaFlush(sessionID: String) {
        guard assistantDeltaFlushTasks[sessionID] == nil else {
            return
        }
        let delay = assistantDeltaFlushDelay
        assistantDeltaFlushTasks[sessionID] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            await MainActor.run { [weak self] in
                self?.flushPendingAssistantDelta(sessionID: sessionID)
            }
        }
    }

    private func flushPendingAssistantDelta(sessionID: String) {
        assistantDeltaFlushTasks[sessionID]?.cancel()
        assistantDeltaFlushTasks[sessionID] = nil
        guard let pending = pendingAssistantDeltasBySessionID.removeValue(forKey: sessionID) else {
            return
        }

        var list = messagesBySessionID[sessionID] ?? []
        if let index = messageIndex(stableID: pending.stableID, sessionID: sessionID) ?? messageIndex(uuid: pending.uuid, sessionID: sessionID) {
            list[index].content += pending.text
            list[index].sendStatus = .sending
            list[index].revision = pending.revision ?? list[index].revision
            setMessages(list, sessionID: sessionID, rebuildIndexes: false)
            return
        }

        let message = ConversationMessage(
            id: pending.uuid,
            stableID: pending.stableID,
            clientMessageID: pending.clientMessageID,
            turnID: pending.turnID,
            itemID: pending.itemID,
            role: .assistant,
            content: pending.text,
            sendStatus: .sending,
            revision: pending.revision
        )
        list.append(message)
        appendMessageWithIndex(message, list: list, sessionID: sessionID)
    }

    private func appendMessageWithIndex(_ message: ConversationMessage, list: [ConversationMessage], sessionID: String) {
        // 普通流式/本地追加总是发生在尾部。像 Codex/Litter 的 live projection 一样只补新行索引，
        // 避免长会话里每个 append 都 O(n) 重建 stable/client/uuid 三套字典。
        guard setMessages(list, sessionID: sessionID, rebuildIndexes: false) else {
            return
        }
        indexMessage(message, at: list.count - 1, sessionID: sessionID)
    }

    @discardableResult
    private func setMessages(_ list: [ConversationMessage], sessionID: String, rebuildIndexes: Bool = true) -> Bool {
        let current = messagesBySessionID[sessionID]
        touchConversationSession(sessionID)
        let evictedSessionIDs = trimConversationSessionCacheCandidates()
        guard !areMessagesEquivalent(current, list) || !evictedSessionIDs.isEmpty else {
            return false
        }

        var nextMessagesBySessionID = messagesBySessionID
        nextMessagesBySessionID[sessionID] = list
        for evictedSessionID in evictedSessionIDs {
            let evictedMessages = nextMessagesBySessionID.removeValue(forKey: evictedSessionID) ?? []
            clearConversationSessionState(sessionID: evictedSessionID, messages: evictedMessages)
        }

        // 单次写回 @Published 字典，避免一次新增消息又逐个删除旧 session 造成多次 UI 发布。
        messagesBySessionID = nextMessagesBySessionID
        if rebuildIndexes {
            rebuildMessageIndexes(for: sessionID, messages: list)
        }
        return true
    }

    private func replaceMessagesWithoutEquivalenceCheck(
        _ list: [ConversationMessage],
        sessionID: String,
        rebuildIndexes: Bool = true
    ) {
        touchConversationSession(sessionID)
        let evictedSessionIDs = trimConversationSessionCacheCandidates()
        var nextMessagesBySessionID = messagesBySessionID
        nextMessagesBySessionID[sessionID] = list
        for evictedSessionID in evictedSessionIDs {
            let evictedMessages = nextMessagesBySessionID.removeValue(forKey: evictedSessionID) ?? []
            clearConversationSessionState(sessionID: evictedSessionID, messages: evictedMessages)
        }
        messagesBySessionID = nextMessagesBySessionID
        if rebuildIndexes {
            rebuildMessageIndexes(for: sessionID, messages: list)
        }
    }

    private func areMessagesEquivalent(_ lhs: [ConversationMessage]?, _ rhs: [ConversationMessage]) -> Bool {
        guard let lhs else {
            return rhs.isEmpty
        }
        return areMessagesEquivalent(lhs, rhs)
    }

    private func areMessagesEquivalent(_ lhs: [ConversationMessage], _ rhs: [ConversationMessage]) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        for index in lhs.indices {
            guard areMessagesEquivalent(lhs[index], rhs[index]) else {
                return false
            }
        }
        return true
    }

    private func areMessagesEquivalent(_ lhs: ConversationMessage, _ rhs: ConversationMessage) -> Bool {
        // Store 热路径只需要判断“渲染与索引语义是否等价”。用固定大小 content digest
        // 代替完整 content 比较，避免长历史/长流式回复重复刷新时反复扫描大字符串。
        lhs.id == rhs.id
            && lhs.stableID == rhs.stableID
            && lhs.clientMessageID == rhs.clientMessageID
            && lhs.turnID == rhs.turnID
            && lhs.itemID == rhs.itemID
            && lhs.role == rhs.role
            && lhs.kind == rhs.kind
            && lhs.createdAt == rhs.createdAt
            && lhs.sendStatus == rhs.sendStatus
            && lhs.revision == rhs.revision
            && lhs.contentDigest == rhs.contentDigest
            && lhs.contentByteCount == rhs.contentByteCount
    }

    private func touchConversationSession(_ sessionID: String) {
        // 流式回复会高频刷新当前 session。参考 Litter 的 render cache，用单调访问序号记录
        // LRU 热度，普通 touch 只做 O(1) 写字典；只有真正超过保留上限时才扫描找最旧项。
        sessionAccessCounter &+= 1
        sessionAccessTickBySessionID[sessionID] = sessionAccessCounter
    }

    private func trimConversationSessionCacheCandidates() -> [String] {
        var evicted: [String] = []
        while sessionAccessTickBySessionID.count > Self.retainedSessionLimit,
              let oldest = sessionAccessTickBySessionID.min(by: { $0.value < $1.value }) {
            sessionAccessTickBySessionID.removeValue(forKey: oldest.key)
            evicted.append(oldest.key)
        }
        return evicted
    }

    private func clearConversationSessionState(sessionID: String, messages: [ConversationMessage]) {
        loadedHistorySessionIDs.remove(sessionID)
        lastSeenSeqBySessionID.removeValue(forKey: sessionID)
        messageIndexByStableIDBySessionID.removeValue(forKey: sessionID)
        messageIndexByClientMessageIDBySessionID.removeValue(forKey: sessionID)
        messageIndexByUUIDBySessionID.removeValue(forKey: sessionID)
        historyProjectionCacheBySessionID.removeValue(forKey: sessionID)
        pendingAssistantDeltasBySessionID.removeValue(forKey: sessionID)
        assistantDeltaFlushTasks[sessionID]?.cancel()
        assistantDeltaFlushTasks.removeValue(forKey: sessionID)
        sessionAccessTickBySessionID.removeValue(forKey: sessionID)

        messageUUIDByStableMessageID = messageUUIDByStableMessageID.filter { $0.key.sessionID != sessionID }
        revisionByStableMessageID = revisionByStableMessageID.filter { $0.key.sessionID != sessionID }
    }

    private func rebuildMessageIndexes(for sessionID: String, messages: [ConversationMessage]) {
        var stableIndexes: [MessageID: Int] = [:]
        var clientIndexes: [ClientMessageID: Int] = [:]
        var uuidIndexes: [UUID: Int] = [:]
        stableIndexes.reserveCapacity(messages.count)
        clientIndexes.reserveCapacity(messages.count)
        uuidIndexes.reserveCapacity(messages.count)

        for (index, message) in messages.enumerated() {
            uuidIndexes[message.id] = index
            if let stableID = message.stableID {
                stableIndexes[stableID] = index
            }
            // client_message_id 只用于用户本地回显确认；非 user runtime/assistant 消息带同名字段时不能覆盖用户行索引。
            if message.role == .user, let clientMessageID = message.clientMessageID {
                clientIndexes[clientMessageID] = index
            }
        }

        messageIndexByStableIDBySessionID[sessionID] = stableIndexes
        messageIndexByClientMessageIDBySessionID[sessionID] = clientIndexes
        messageIndexByUUIDBySessionID[sessionID] = uuidIndexes
    }

    private func indexMessage(_ message: ConversationMessage, at index: Int, sessionID: String) {
        messageIndexByUUIDBySessionID[sessionID, default: [:]][message.id] = index
        if let stableID = message.stableID {
            messageIndexByStableIDBySessionID[sessionID, default: [:]][stableID] = index
        }
        // client_message_id 只索引 user 行，避免 runtime 过程事件误用同一个 client id 后影响 retry/status。
        if message.role == .user, let clientMessageID = message.clientMessageID {
            messageIndexByClientMessageIDBySessionID[sessionID, default: [:]][clientMessageID] = index
        }
    }

    private func messageIndex(stableID: MessageID, sessionID: String) -> Int? {
        messageIndexByStableIDBySessionID[sessionID]?[stableID]
    }

    private func messageIndex(clientMessageID: ClientMessageID, sessionID: String) -> Int? {
        messageIndexByClientMessageIDBySessionID[sessionID]?[clientMessageID]
    }

    private func messageIndex(uuid: UUID, sessionID: String) -> Int? {
        messageIndexByUUIDBySessionID[sessionID]?[uuid]
    }

    private func mergeHistory(_ history: [ConversationMessage], with local: [ConversationMessage]) -> [ConversationMessage] {
#if DEBUG
        historyMergeInvocationCountForTesting += 1
#endif
        var seenPrimaryKeys = Set<String>()
        var seenUUIDs = Set<UUID>()
        var historyTurnScopedTextKeys = Set<String>()
        var nearbyHistoryEchoCandidates: [NearbyHistoryEchoCandidate] = []
        var merged: [ConversationMessage] = []

        for item in history {
            guard seenUUIDs.insert(item.id).inserted else {
                continue
            }
            if let key = primaryMergeKey(for: item) {
                guard seenPrimaryKeys.insert(key).inserted else {
                    continue
                }
            }
            // 历史侧只登记 (turnId, 文本) 键、本身不参与去重：同一个 turn 内两条同文历史仍各自保留。
            if let key = turnScopedTextMergeKey(for: item) {
                historyTurnScopedTextKeys.insert(key)
            }
            nearbyHistoryEchoCandidates.append(NearbyHistoryEchoCandidate(role: item.role, content: item.content, createdAt: item.createdAt))
            merged.append(item)
        }

        for item in local {
            guard seenUUIDs.insert(item.id).inserted else {
                continue
            }
            if shouldMergeAsNearbyHistoryEcho(item, candidates: nearbyHistoryEchoCandidates) {
                continue
            }
            // app-server 的 thread/read 把 item id 重排成整条线程的全局顺序号(item-N)，与流式事件里的
            // 真实 id(msg_…)对不上，导致同一条已 confirmed 的助手消息在手动刷新后既留着直播副本又追加
            // 历史副本。turnId 两边一致、最终文本一致，按 (turnId, 文本) 兜底判为同一条：丢掉本地副本、
            // 保留历史，消除重复气泡。
            if let key = turnScopedTextMergeKey(for: item), historyTurnScopedTextKeys.contains(key) {
                continue
            }
            if let key = primaryMergeKey(for: item) {
                guard seenPrimaryKeys.insert(key).inserted else {
                    continue
                }
            }
            merged.append(item)
        }

        return merged.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.createdAt == rhs.element.createdAt {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.createdAt < rhs.element.createdAt
            }
            .map(\.element)
    }

    private func projectedHistoryMessages(_ history: [CodexHistoryMessage], sessionID: String) -> [ConversationMessage] {
        let keys = history.map { historyProjectionKey(for: $0) }
        // Litter 的 ConversationScreenModel 会缓存“hydrated -> UI item”的投影结果；
        // 这里也把历史 JSON 消息到本地 ConversationMessage 的转换缓存住。这样手动刷新、
        // 前后台恢复拿到同一页历史时，不会因为缺少稳定 id 的历史项而反复生成新 UUID。
        if let cached = historyProjectionCacheBySessionID[sessionID],
           cached.keys == keys {
            return cached.messages
        }

        let converted: [ConversationMessage]
        if let cached = historyProjectionCacheBySessionID[sessionID],
           cached.keys.count == cached.messages.count {
            converted = incrementallyProjectedHistoryMessages(
                history,
                keys: keys,
                cached: cached,
                sessionID: sessionID
            )
        } else {
            var unstableReuseBuckets = unstableHistoryReuseBuckets(sessionID: sessionID)
            converted = history.map { item in
                projectHistoryMessage(item, sessionID: sessionID, unstableReuseBuckets: &unstableReuseBuckets)
            }
        }
        historyProjectionCacheBySessionID[sessionID] = HistoryProjectionCache(keys: keys, messages: converted)
        return converted
    }

    private func incrementallyProjectedHistoryMessages(
        _ history: [CodexHistoryMessage],
        keys: [HistoryProjectionKey],
        cached: HistoryProjectionCache,
        sessionID: String
    ) -> [ConversationMessage] {
        let prefixCount = commonPrefixCount(lhs: cached.keys, rhs: keys)
        let suffixCount = commonSuffixCount(lhs: cached.keys, rhs: keys, excludingPrefix: prefixCount)
        let changedUpperBound = history.count - suffixCount

        var converted: [ConversationMessage] = []
        converted.reserveCapacity(history.count)

        if prefixCount > 0 {
            converted.append(contentsOf: cached.messages.prefix(prefixCount))
        }

        let suffixMessages = suffixCount > 0 ? cached.messages.suffix(suffixCount) : []
        // 增量投影只需要知道 prefix/suffix 这些已复用消息的 UUID；逐条插入 Set，
        // 避免 map + 数组拼接在长历史分页时额外复制一遍消息 id。
        var preservedIDs = Set<UUID>()
        preservedIDs.reserveCapacity(prefixCount + suffixCount)
        for message in converted {
            preservedIDs.insert(message.id)
        }
        for message in suffixMessages {
            preservedIDs.insert(message.id)
        }
        var unstableReuseBuckets = unstableHistoryReuseBuckets(sessionID: sessionID, excludingIDs: preservedIDs)

        if prefixCount < changedUpperBound {
            for index in prefixCount..<changedUpperBound {
                converted.append(projectHistoryMessage(history[index], sessionID: sessionID, unstableReuseBuckets: &unstableReuseBuckets))
            }
        }

        converted.append(contentsOf: suffixMessages)
        return converted
    }

    private func projectHistoryMessage(
        _ item: CodexHistoryMessage,
        sessionID: String,
        unstableReuseBuckets: inout [UnstableHistoryReuseKey: UnstableHistoryReuseBucket]
    ) -> ConversationMessage {
        let stableID = historyStableID(for: item)
        let role = messageRole(item.role)
        let createdAt = item.createdAt ?? Date()
        let sendStatus = item.sendStatus ?? .confirmed
        let id: UUID
        if let stableID,
           let reusedID = messageUUIDByStableMessageID[stableCacheKey(stableID: stableID, sessionID: sessionID)] {
            id = reusedID
        } else if stableID == nil,
                  let reused = popUnstableHistoryMessage(
                      role: role,
                      kind: item.kind,
                      content: item.content,
                      createdAt: createdAt,
                      sendStatus: sendStatus,
                      revision: item.revision,
                      buckets: &unstableReuseBuckets
                  ) {
            id = reused.id
        } else {
            id = UUID()
        }
        return ConversationMessage(
            id: id,
            stableID: stableID,
            clientMessageID: item.clientMessageID,
            turnID: item.turnID,
            itemID: item.itemID,
            role: role,
            kind: item.kind,
            content: item.content,
            createdAt: createdAt,
            sendStatus: sendStatus,
            revision: item.revision
        )
    }

    private func commonPrefixCount(lhs: [HistoryProjectionKey], rhs: [HistoryProjectionKey]) -> Int {
        let maxCount = min(lhs.count, rhs.count)
        var index = 0
        while index < maxCount, lhs[index] == rhs[index] {
            index += 1
        }
        return index
    }

    private func commonSuffixCount(lhs: [HistoryProjectionKey], rhs: [HistoryProjectionKey], excludingPrefix prefixCount: Int) -> Int {
        let maxCount = min(lhs.count, rhs.count) - prefixCount
        guard maxCount > 0 else {
            return 0
        }
        var suffixCount = 0
        while suffixCount < maxCount {
            let lhsIndex = lhs.index(lhs.endIndex, offsetBy: -suffixCount - 1)
            let rhsIndex = rhs.index(rhs.endIndex, offsetBy: -suffixCount - 1)
            guard lhs[lhsIndex] == rhs[rhsIndex] else {
                break
            }
            suffixCount += 1
        }
        return suffixCount
    }

    private func unstableHistoryReuseBuckets(sessionID: String, excludingIDs: Set<UUID> = []) -> [UnstableHistoryReuseKey: UnstableHistoryReuseBucket] {
        var grouped: [UnstableHistoryReuseKey: [ConversationMessage]] = [:]
        for message in messagesBySessionID[sessionID] ?? [] {
            guard message.stableID == nil,
                  message.clientMessageID == nil,
                  message.turnID == nil,
                  message.itemID == nil,
                  message.sendStatus == .confirmed,
                  !excludingIDs.contains(message.id)
            else {
                continue
            }
            grouped[unstableHistoryReuseKey(for: message), default: []].append(message)
        }

        var buckets: [UnstableHistoryReuseKey: UnstableHistoryReuseBucket] = [:]
        buckets.reserveCapacity(grouped.count)
        for (key, messages) in grouped {
            buckets[key] = UnstableHistoryReuseBucket(messages: messages)
        }
        return buckets
    }

    private func unstableHistoryReuseKey(for message: ConversationMessage) -> UnstableHistoryReuseKey {
        UnstableHistoryReuseKey(
            role: message.role,
            kind: message.kind,
            content: message.content,
            createdAt: message.createdAt,
            sendStatus: message.sendStatus,
            revision: message.revision
        )
    }

    private func popUnstableHistoryMessage(
        role: ConversationMessage.Role,
        kind: MessageKind,
        content: String,
        createdAt: Date,
        sendStatus: MessageSendStatus,
        revision: ModelRevision?,
        buckets: inout [UnstableHistoryReuseKey: UnstableHistoryReuseBucket]
    ) -> ConversationMessage? {
        let key = UnstableHistoryReuseKey(
            role: role,
            kind: kind,
            content: content,
            createdAt: createdAt,
            sendStatus: sendStatus,
            revision: revision
        )
        guard var bucket = buckets[key] else {
            return nil
        }
        // 同一时间同一文本也可能重复出现，按出现顺序逐个复用。
        // 用游标代替 removeFirst，避免大批重复历史消息刷新时反复搬数组。
        guard let message = bucket.pop() else {
            buckets.removeValue(forKey: key)
            return nil
        }
        if bucket.isExhausted {
            buckets.removeValue(forKey: key)
        } else {
            buckets[key] = bucket
        }
        return message
    }

    private func historyProjectionKey(for item: CodexHistoryMessage) -> HistoryProjectionKey {
        let stableID = historyStableID(for: item)
        return HistoryProjectionKey(
            stableID: stableID,
            wireID: stableID == nil ? nil : item.id,
            role: item.role,
            kind: item.kind,
            content: item.content,
            createdAt: item.createdAt,
            clientMessageID: item.clientMessageID,
            turnID: item.turnID,
            itemID: item.itemID,
            seq: item.seq,
            revision: item.revision,
            sendStatus: item.sendStatus
        )
    }

    private func historyStableID(for item: CodexHistoryMessage) -> MessageID? {
        if let stableID = appServerStableMessageID(turnID: item.turnID, itemID: item.itemID) {
            return stableID
        }
        // 旧 Codex rollout 没有稳定 message id，Swift 解码会补一个随机 UUID；
        // 只有带结构化元数据时才把 id 当稳定键，避免破坏本地回显去重。
        if item.id.hasPrefix("rollout:") || item.clientMessageID != nil || item.turnID != nil || item.itemID != nil || item.seq != nil || item.revision != nil {
            return item.id
        }
        return nil
    }

    private func messageRole(_ raw: String) -> ConversationMessage.Role {
        switch raw {
        case "assistant":
            return .assistant
        case "system":
            return .system
        default:
            return .user
        }
    }

    private func primaryMergeKey(for item: ConversationMessage) -> String? {
        if let clientMessageID = item.clientMessageID {
            return "client:\(clientMessageID)"
        }
        if let appServerStableID = appServerStableMessageID(turnID: item.turnID, itemID: item.itemID) {
            return "appserver:\(appServerStableID)"
        }
        if let stableID = item.stableID {
            return "stable:\(stableID)"
        }
        return nil
    }

    private func appServerStableMessageID(turnID: TurnID?, itemID: AgentItemID?) -> MessageID? {
        guard let itemID, !itemID.isEmpty else {
            return nil
        }
        guard let turnID, !turnID.isEmpty else {
            return itemID
        }
        return "appserver:\(turnID):\(itemID)"
    }

    // thread/read 把 assistant 的 item id 重排成整条线程的全局顺序号(item-N)，与流式 msg_… 永远对不上，
    // 仅靠 appserver:<turnId>:<itemId> 无法把直播气泡和历史副本判为同一条。turnId 两边一致、最终文本也一致，
    // 于是补一个 (turnId, 规范化文本) 的键，专门收敛已 confirmed 助手消息在手动刷新后的重复；只认 assistant，
    // 避免误伤 user(走 clientMessageId 合并)和各类 system 提示。
    private func turnScopedTextMergeKey(for item: ConversationMessage) -> String? {
        guard item.role == .assistant,
              let turnID = item.turnID, !turnID.isEmpty else {
            return nil
        }
        let normalized = normalizedAssistantTextForDedup(item.content)
        guard !normalized.isEmpty else {
            return nil
        }
        return "turn:\(turnID):assistant:\(normalized)"
    }

    private func shouldMergeAsNearbyHistoryEcho(_ item: ConversationMessage, candidates: [NearbyHistoryEchoCandidate]) -> Bool {
        guard item.sendStatus != .confirmed else {
            return false
        }
        // 旧 rollout 缺稳定 id，本地回显也可能没有 client_message_id。这里仅把“未确认本地消息”
        // 和时间接近的同文历史合并；历史页里的两条相同文本不能再被 role+content 误删。
        return candidates.contains { candidate in
            guard candidate.role == item.role,
                  abs(candidate.createdAt.timeIntervalSince(item.createdAt)) <= nearbyHistoryEchoMergeWindow else {
                return false
            }
            if candidate.content == item.content {
                return true
            }
            guard item.role == .assistant else {
                return false
            }
            return shouldMergeAssistantNearbyHistoryEcho(localContent: item.content, historyContent: candidate.content)
        }
    }

    private func shouldMergeAssistantNearbyHistoryEcho(localContent: String, historyContent: String) -> Bool {
        let localKey = normalizedAssistantTextForDedup(localContent)
        let historyKey = normalizedAssistantTextForDedup(historyContent)
        guard localKey.count >= 12, historyKey.count >= 12 else {
            return false
        }
        // 早期历史可能把同一句重绘内容连在一个气泡里；history 返回干净 assistant 后，
        // 用压缩后的语义文本合并，刷新时让干净历史替换旧脏气泡。
        return localKey == historyKey ||
            localKey.contains(historyKey) ||
            historyKey.contains(localKey)
    }
}
