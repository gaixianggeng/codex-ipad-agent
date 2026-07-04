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
        let createdAt: Date?
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
        let updatedAt: Date?
        let clientMessageID: ClientMessageID?
        let turnID: TurnID?
        let itemID: AgentItemID?
        let seq: EventSequence?
        let revision: ModelRevision?
        let sendStatus: MessageSendStatus?
        let timelineOrdinal: Int64?
        let userDelivery: UserMessageDelivery?
        let isTimestampFallback: Bool
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
        let updatedAt: Date?
        let sendStatus: MessageSendStatus
        let revision: ModelRevision?
        let timelineOrdinal: Int64?
        let userDelivery: UserMessageDelivery?
        let isTimestampFallback: Bool
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
    private static let undatedHistoryFallbackDate = Date(timeIntervalSince1970: 0)

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

    func setHistory(
        _ history: [CodexHistoryMessage],
        sessionID: String,
        authoritativeCompletedTurnItems: [TurnID: Set<AgentItemID>] = [:]
    ) {
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
        setMessages(
            mergeHistory(
                converted,
                with: messagesBySessionID[sessionID] ?? [],
                authoritativeCompletedTurnItems: authoritativeCompletedTurnItems
            ),
            sessionID: sessionID
        )
        loadedHistorySessionIDs.insert(sessionID)
    }

    func replaceHistorySnapshot(
        _ history: [CodexHistoryMessage],
        sessionID: String,
        authoritativeCompletedTurnItems: [TurnID: Set<AgentItemID>] = [:]
    ) {
        flushPendingAssistantDelta(sessionID: sessionID)
        let previousHistoryProjectionIDs = Set(historyProjectionCacheBySessionID[sessionID]?.messages.map(\.id) ?? [])
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

        if converted.isEmpty, messagesBySessionID[sessionID]?.isEmpty == false {
            // app-server 偶发返回空首屏时，不能清掉用户当前可见的历史和运行态消息；
            // 只标记本轮加载完成，分页游标由 SessionStore 根据 page metadata 继续维护。
            loadedHistorySessionIDs.insert(sessionID)
            touchConversationSession(sessionID)
            return
        }

        let localToPreserve = (messagesBySessionID[sessionID] ?? []).filter { message in
            !previousHistoryProjectionIDs.contains(message.id)
        }
        let snapshot = mergeHistory(
            converted,
            with: localToPreserve,
            authoritativeCompletedTurnItems: authoritativeCompletedTurnItems
        )
        if let current = messagesBySessionID[sessionID], areMessagesEquivalent(current, snapshot) {
            loadedHistorySessionIDs.insert(sessionID)
            touchConversationSession(sessionID)
            return
        }
        // 首屏 full/summary 历史是当前会话的 canonical 快照。替换上一轮历史投影，
        // 但保留尚未进入 thread/read 的本地发送、审批、补充信息等运行态消息。
        setMessages(snapshot, sessionID: sessionID)
        loadedHistorySessionIDs.insert(sessionID)
    }

    func appendUser(_ text: String, sessionID: String, createdAt: Date? = nil) {
        appendLocalUser(text, sessionID: sessionID, clientMessageID: nil, sendStatus: .sent, createdAt: createdAt)
    }

    func appendLocalUser(
        _ text: String,
        sessionID: String,
        clientMessageID: ClientMessageID?,
        sendStatus: MessageSendStatus = .sending,
        turnPayload: CodexAppServerTurnPayload? = nil,
        userDelivery: UserMessageDelivery? = nil,
        createdAt: Date? = nil
    ) {
        if let clientMessageID,
           var list = messagesBySessionID[sessionID],
           let index = messageIndex(clientMessageID: clientMessageID, sessionID: sessionID) {
            let didChange = list[index].content != text ||
                list[index].sendStatus != sendStatus ||
                (turnPayload != nil && list[index].turnPayload != turnPayload)
            guard didChange else {
                return
            }
            list[index].content = text
            list[index].sendStatus = sendStatus
            list[index].turnPayload = turnPayload ?? list[index].turnPayload
            list[index].userDelivery = userDelivery ?? list[index].userDelivery
            list[index].updatedAt = Date()
            replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
            return
        }
        append(
            ConversationMessage(
                stableID: clientMessageID,
                clientMessageID: clientMessageID,
                role: .user,
                content: text,
                createdAt: createdAt ?? Date(),
                sendStatus: sendStatus,
                turnPayload: turnPayload,
                userDelivery: userDelivery
            ),
            sessionID: sessionID
        )
    }

    @discardableResult
    func updateSendStatus(clientMessageID: ClientMessageID, sessionID: String, status: MessageSendStatus) -> Bool {
        guard var list = messagesBySessionID[sessionID],
              let index = messageIndex(clientMessageID: clientMessageID, sessionID: sessionID) else {
            return false
        }
        guard shouldTransitionSendStatus(from: list[index].sendStatus, to: status) else {
            return false
        }
        list[index].sendStatus = status
        list[index].updatedAt = Date()
        replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
        return true
    }

    func markSendingUserMessagesFailed(sessionID: String) {
        guard var list = messagesBySessionID[sessionID] else {
            return
        }
        var changed = false
        for index in list.indices where list[index].role == .user && list[index].sendStatus == .sending {
            list[index].sendStatus = .failed
            list[index].updatedAt = Date()
            changed = true
        }
        guard changed else {
            return
        }
        replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
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
        metadata: AgentEventMetadata? = nil,
        createdAt: Date? = nil
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
            createdAt: metadata?.createdAt ?? createdAt ?? Date(),
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
            list[index].updatedAt = Date()
            replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
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
        list[index].updatedAt = Date()
        replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
    }

    func resolveLatestPendingUserInput(sessionID: String, skipped: Bool) {
        guard var list = messagesBySessionID[sessionID],
              let index = list.lastIndex(where: { message in
                  message.kind == .userInput
                      && (message.content.hasPrefix("等待补充信息：") || message.content.hasPrefix("等待引导输入："))
              }) else {
            if skipped {
                appendSystem("已跳过补充信息，继续执行", sessionID: sessionID, kind: .userInput)
            }
            return
        }
        let title = pendingUserInputTitle(from: list[index].content)
        let prefix = skipped ? "已跳过补充信息" : "补充信息已提交"
        list[index].content = title.isEmpty ? prefix : "\(prefix)：\(title)"
        list[index].updatedAt = Date()
        replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
    }

    func restorePendingUserInput(_ request: AgentUserInputRequest, sessionID: String) {
        let text = "等待补充信息：\(request.title)"
        guard var list = messagesBySessionID[sessionID] else {
            appendSystem(text, sessionID: sessionID, kind: .userInput)
            return
        }
        // 补充信息提交是乐观收起 UI；如果发送失败，需要把时间线从“已提交”退回“等待补充信息”。
        if let index = list.lastIndex(where: { message in
            message.kind == .userInput
                && (message.content.hasPrefix("补充信息已提交") || message.content.hasPrefix("引导输入已提交"))
        }) {
            list[index].content = text
            list[index].updatedAt = Date()
            replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
            return
        }
        appendSystem(text, sessionID: sessionID, kind: .userInput)
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
                replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
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

    private func pendingUserInputTitle(from text: String) -> String {
        for prefix in ["等待补充信息：", "等待引导输入："] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return text
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
            createdAt: metadata.createdAt,
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
        createdAt: Date?,
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
                createdAt: createdAt,
                revision: revision,
                sessionID: sessionID
            )
            return
        }
        if let index,
           messagesBySessionID[sessionID]?[index].sendStatus == .confirmed {
            // item/completed 是权威最终内容；它落地后迟到的 delta 不能再把气泡改回 streaming。
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
                createdAt: createdAt,
                text: text,
                revision: revision
            )
        }
        scheduleAssistantDeltaFlush(sessionID: sessionID)
    }

    func completeMessage(_ message: AgentMessage, metadata: AgentEventMetadata, fallbackSessionID: String) {
        let sessionID = firstNonEmpty(metadata.sessionID, message.sessionID, fallbackSessionID)
        guard shouldAccept(metadata: metadata, sessionID: sessionID) else {
            return
        }
        flushPendingAssistantDelta(sessionID: sessionID)
        let stableID = message.id
        guard shouldApplyCompletedRevision(max(metadata.revision ?? message.revision, message.revision), stableID: stableID, sessionID: sessionID) else {
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
        if let index = messageIndex(stableID: stableID, sessionID: sessionID) ?? clientMessageID.flatMap({ messageIndex(clientMessageID: $0, sessionID: sessionID) }) {
            let previous = list[index]
            list[index].stableID = stableID
            list[index].role = role
            list[index].kind = displayKind
            list[index].content = message.content
            list[index].sendStatus = message.sendStatus == .failed ? .failed : .confirmed
            list[index].revision = message.revision
            list[index].updatedAt = message.updatedAt ?? metadata.createdAt ?? Date()
            list[index].isTimestampFallback = message.isTimestampFallback
            list[index].userDelivery = nil
            if clientMessageID != nil, message.sendStatus != .failed {
                let retained = list[index].turnPayload?.retainedAfterAcceptedSend()
                if list[index].turnPayload != retained {
                    list[index].turnPayload = retained
                }
            }
            messageUUIDByStableMessageID[stableCacheKey(stableID: stableID, sessionID: sessionID)] = list[index].id
            removeMessageIndex(previous, at: index, sessionID: sessionID)
            replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
            indexMessage(list[index], at: index, sessionID: sessionID)
        } else {
            let key = stableCacheKey(stableID: stableID, sessionID: sessionID)
            let uuid = messageUUIDByStableMessageID[key] ?? UUID()
            let completedMessage = ConversationMessage(
                id: uuid,
                stableID: stableID,
                clientMessageID: clientMessageID,
                turnID: message.turnID,
                itemID: message.itemID,
                role: role,
                kind: displayKind,
                content: message.content,
                createdAt: message.createdAt ?? Date(),
                updatedAt: message.updatedAt ?? metadata.createdAt,
                sendStatus: message.sendStatus,
                revision: message.revision,
                isTimestampFallback: message.isTimestampFallback
            )
            // 回放/迟到的 completed 事件带的是流式 item id；thread/read 把 item id 重排成 item-N 后，
            // 同一条内容可能已经以历史投影身份在列表里。找到孪生卡就把真实时间/终态回填给它，
            // 不再追加重复卡（与 mergeHistory 的 turn+文本去重语义保持一致）。
            if let twinIndex = historyProjectedTwinIndex(for: completedMessage, in: list) {
                var twin = list[twinIndex]
                if twin.isTimestampFallback, let liveCreatedAt = message.createdAt {
                    twin.createdAt = liveCreatedAt
                    twin.isTimestampFallback = false
                }
                twin.updatedAt = message.updatedAt ?? metadata.createdAt ?? twin.updatedAt
                twin.sendStatus = message.sendStatus == .failed ? .failed : .confirmed
                twin.revision = max(message.revision, twin.revision ?? message.revision)
                list[twinIndex] = twin
                messageUUIDByStableMessageID[key] = twin.id
                // 真实时间回填后，历史孪生卡可能需要从估算时间位置挪回真实时间线位置。
                let resorted = timelineSortEntries(from: list)
                    .sorted(by: areTimelineSortEntriesInOrder)
                    .map(\.message)
                replaceMessagesWithoutEquivalenceCheck(resorted, sessionID: sessionID, rebuildIndexes: true)
                // 流式 id 也指向孪生卡，后续同一事件的补发/查找直接原位命中。
                if let resolvedIndex = resorted.firstIndex(where: { $0.id == twin.id }) {
                    messageIndexByStableIDBySessionID[sessionID, default: [:]][stableID] = resolvedIndex
                }
                return
            }
            messageUUIDByStableMessageID[key] = completedMessage.id
            list.append(completedMessage)
            appendMessageWithIndex(completedMessage, list: list, sessionID: sessionID)
        }
    }

    private func historyProjectedTwinIndex(for message: ConversationMessage, in list: [ConversationMessage]) -> Int? {
        guard let key = turnScopedTextMergeKey(for: message) else {
            return nil
        }
        // 只认历史投影（带 timelineOrdinal）的孪生卡；同 turn 内两条真实的 live 重复输出仍各自保留。
        return list.lastIndex { candidate in
            guard candidate.timelineOrdinal != nil,
                  candidate.turnID == message.turnID,
                  candidate.id != message.id else {
                return false
            }
            return turnScopedTextMergeKey(for: candidate) == key
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
        list[index].updatedAt = metadata.createdAt ?? Date()
        if let revision = metadata.revision {
            list[index].revision = revision
        }
        replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
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

    private func shouldApplyCompletedRevision(_ revision: ModelRevision?, stableID: String, sessionID: String) -> Bool {
        guard let revision else {
            return true
        }
        let key = stableCacheKey(stableID: stableID, sessionID: sessionID)
        if let last = revisionByStableMessageID[key], revision < last {
            return false
        }
        revisionByStableMessageID[key] = revision
        return true
    }

    private func shouldTransitionSendStatus(from current: MessageSendStatus, to next: MessageSendStatus) -> Bool {
        guard current != next else {
            return false
        }
        switch current {
        case .confirmed:
            return false
        case .sent:
            // send accepted 已经表示服务端收到；后到的 failure/sending callback 不能让 UI 倒退。
            return next == .confirmed
        case .failed:
            return next == .sending
        case .sending, .local:
            return true
        }
    }

    private func firstNonEmpty(_ values: String?...) -> String {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
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
        createdAt: Date?,
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
            createdAt: createdAt ?? Date(),
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
            replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
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
            createdAt: pending.createdAt ?? Date(),
            sendStatus: .sending,
            revision: pending.revision
        )
        list.append(message)
        appendMessageWithIndex(message, list: list, sessionID: sessionID)
    }

    private func appendMessageWithIndex(_ message: ConversationMessage, list: [ConversationMessage], sessionID: String) {
        // 普通流式/本地追加总是发生在尾部。像 Codex/Litter 的 live projection 一样只补新行索引，
        // 避免长会话里每个 append 都 O(n) 重建 stable/client/uuid 三套字典。
        // 例外：断线回放/迟到 completed 事件带着比当前尾部更早的原始时间戳到达；时间线顺序只有
        // merge 的排序在维护，直接钉在尾部会把旧卡显示在更新的消息（如历史投影的 plan）后面。
        // 尾部逆序是罕见路径，检测到就用同一套 timeline 排序整体归位。
        if list.count >= 2, message.createdAt < list[list.count - 2].createdAt {
            let resorted = timelineSortEntries(from: list)
                .sorted(by: areTimelineSortEntriesInOrder)
                .map(\.message)
            replaceMessagesWithoutEquivalenceCheck(resorted, sessionID: sessionID, rebuildIndexes: true)
            return
        }
        replaceMessagesWithoutEquivalenceCheck(list, sessionID: sessionID, rebuildIndexes: false)
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
            && lhs.updatedAt == rhs.updatedAt
            && lhs.sendStatus == rhs.sendStatus
            && lhs.revision == rhs.revision
            && lhs.timelineOrdinal == rhs.timelineOrdinal
            && lhs.userDelivery == rhs.userDelivery
            && lhs.isTimestampFallback == rhs.isTimestampFallback
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

    private func removeMessageIndex(_ message: ConversationMessage, at index: Int, sessionID: String) {
        if messageIndexByUUIDBySessionID[sessionID]?[message.id] == index {
            messageIndexByUUIDBySessionID[sessionID]?[message.id] = nil
        }
        if let stableID = message.stableID,
           messageIndexByStableIDBySessionID[sessionID]?[stableID] == index {
            messageIndexByStableIDBySessionID[sessionID]?[stableID] = nil
        }
        // 原地确认本地 echo 时 stableID 会从临时 client id 变成服务端 id；
        // 只删除旧行自己的 client 索引，再由 indexMessage 写回更新后的 user 行索引。
        if message.role == .user,
           let clientMessageID = message.clientMessageID,
           messageIndexByClientMessageIDBySessionID[sessionID]?[clientMessageID] == index {
            messageIndexByClientMessageIDBySessionID[sessionID]?[clientMessageID] = nil
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

    private func mergeHistory(
        _ history: [ConversationMessage],
        with local: [ConversationMessage],
        authoritativeCompletedTurnItems: [TurnID: Set<AgentItemID>] = [:]
    ) -> [ConversationMessage] {
#if DEBUG
        historyMergeInvocationCountForTesting += 1
#endif
        var seenPrimaryKeys = Set<String>()
        var seenUUIDs = Set<UUID>()
        var historyTurnScopedTextKeys = Set<String>()
        var nearbyHistoryEchoCandidates: [NearbyHistoryEchoCandidate] = []
        var merged: [ConversationMessage] = []
        let liveBackfill = liveBackfillCandidates(from: local)

        for rawItem in history {
            let item = historyMessageByBackfillingLiveFacts(rawItem, candidates: liveBackfill)
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
            if shouldPruneOrphanedHistoryProcess(
                item,
                authoritativeCompletedTurnItems: authoritativeCompletedTurnItems
            ) {
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

        return timelineSortEntries(from: merged)
            .sorted(by: areTimelineSortEntriesInOrder)
            .map(\.message)
    }

    private func shouldPruneOrphanedHistoryProcess(
        _ item: ConversationMessage,
        authoritativeCompletedTurnItems: [TurnID: Set<AgentItemID>]
    ) -> Bool {
        guard item.timelineOrdinal != nil,
              let turnID = item.turnID,
              let itemID = item.itemID,
              let authoritativeItemIDs = authoritativeCompletedTurnItems[turnID],
              !authoritativeItemIDs.contains(itemID),
              isPrunableHistoryProcessKind(item.kind) else {
            return false
        }
        // 核心逻辑：只清历史投影卡。实时命令卡也有 turnID/itemID，但没有 timelineOrdinal；
        // commandExecution 不落盘时，完成快照天然缺它们，不能把用户正在看的实时过程卡删掉。
        return true
    }

    private func isPrunableHistoryProcessKind(_ kind: MessageKind) -> Bool {
        kind == .commandSummary || kind == .fileChangeSummary
    }

    private struct LiveBackfillCandidates {
        var byPrimaryKey: [String: ConversationMessage] = [:]
        var byTurnScopedTextKey: [String: ConversationMessage] = [:]
    }

    private func liveBackfillCandidates(from local: [ConversationMessage]) -> LiveBackfillCandidates {
        var result = LiveBackfillCandidates()
        for message in local {
            if let key = primaryMergeKey(for: message) {
                result.byPrimaryKey[key] = bestLiveBackfill(existing: result.byPrimaryKey[key], candidate: message)
            }
            if let key = turnScopedTextMergeKey(for: message) {
                result.byTurnScopedTextKey[key] = bestLiveBackfill(existing: result.byTurnScopedTextKey[key], candidate: message)
            }
        }
        return result
    }

    private func bestLiveBackfill(existing: ConversationMessage?, candidate: ConversationMessage) -> ConversationMessage {
        guard let existing else {
            return candidate
        }
        if existing.isTimestampFallback != candidate.isTimestampFallback {
            return candidate.isTimestampFallback ? existing : candidate
        }
        return candidate.createdAt >= existing.createdAt ? candidate : existing
    }

    private func historyMessageByBackfillingLiveFacts(_ history: ConversationMessage, candidates: LiveBackfillCandidates) -> ConversationMessage {
        let candidate = primaryMergeKey(for: history).flatMap { candidates.byPrimaryKey[$0] }
            ?? turnScopedTextMergeKey(for: history).flatMap { candidates.byTurnScopedTextKey[$0] }
        guard let candidate else {
            return history
        }
        var next = history
        if history.isTimestampFallback && !candidate.isTimestampFallback {
            next.createdAt = candidate.createdAt
            next.updatedAt = candidate.updatedAt ?? history.updatedAt
            next.isTimestampFallback = false
        } else if history.isTimestampFallback, candidate.createdAt != history.createdAt {
            next.createdAt = candidate.createdAt
            next.updatedAt = candidate.updatedAt ?? history.updatedAt
        }
        return next
    }

    private struct TimelineSortEntry {
        let offset: Int
        let message: ConversationMessage
        let effectiveAt: Date
        let timelineOrdinal: Int64?
    }

    private func timelineSortEntries(from messages: [ConversationMessage]) -> [TimelineSortEntry] {
        var entries = messages.enumerated().map { offset, message in
            TimelineSortEntry(
                offset: offset,
                message: message,
                effectiveAt: message.createdAt,
                timelineOrdinal: message.timelineOrdinal
            )
        }
        var ordinalIndicesByTurn: [TurnID: [Int]] = [:]
        for (index, message) in messages.enumerated() {
            guard let turnID = message.turnID,
                  message.timelineOrdinal != nil else {
                continue
            }
            ordinalIndicesByTurn[turnID, default: []].append(index)
        }

        for indices in ordinalIndicesByTurn.values {
            var lastEffectiveAt: Date?
            var lastReliableEffectiveAt: Date?
            for index in indices.sorted(by: { leftIndex, rightIndex in
                compareTimelineOrdinalThenOffset(leftIndex, rightIndex, entries: entries)
            }) {
                let entry = entries[index]
                let effectiveAt: Date
                if entry.message.isTimestampFallback {
                    // 估算时间只能被前序消息向后托住；它自己不能反过来压住后续真实时间。
                    if let lastEffectiveAt, entry.effectiveAt < lastEffectiveAt {
                        effectiveAt = lastEffectiveAt
                    } else {
                        effectiveAt = entry.effectiveAt
                    }
                } else if let lastReliableEffectiveAt, entry.effectiveAt < lastReliableEffectiveAt {
                    // 真实时间之间仍按 ordinal 保持同 turn 内单调，避免上游真实时间短暂反挂。
                    effectiveAt = lastReliableEffectiveAt
                } else {
                    effectiveAt = entry.effectiveAt
                }
                // history item 用 live 副本回填真实时间后，时间和 thread/read item 顺序可能短暂反挂。
                // 同 turn 内先把 ordinal 骨架的时间单调化，再统一排序；但不能让 fallback 时间覆盖真实时间。
                entries[index] = TimelineSortEntry(
                    offset: entry.offset,
                    message: entry.message,
                    effectiveAt: effectiveAt,
                    timelineOrdinal: entry.timelineOrdinal
                )
                lastEffectiveAt = lastEffectiveAt.map { max($0, effectiveAt) } ?? effectiveAt
                if !entry.message.isTimestampFallback {
                    lastReliableEffectiveAt = lastReliableEffectiveAt.map { max($0, effectiveAt) } ?? effectiveAt
                }
            }
        }

        return entries
    }

    private func compareTimelineOrdinalThenOffset(
        _ leftIndex: Int,
        _ rightIndex: Int,
        entries: [TimelineSortEntry]
    ) -> Bool {
        let left = entries[leftIndex]
        let right = entries[rightIndex]
        if let leftOrdinal = left.timelineOrdinal,
           let rightOrdinal = right.timelineOrdinal,
           leftOrdinal != rightOrdinal {
            return leftOrdinal < rightOrdinal
        }
        return left.offset < right.offset
    }

    private func areTimelineSortEntriesInOrder(_ lhs: TimelineSortEntry, _ rhs: TimelineSortEntry) -> Bool {
        if lhs.effectiveAt != rhs.effectiveAt {
            return lhs.effectiveAt < rhs.effectiveAt
        }
        switch (lhs.timelineOrdinal, rhs.timelineOrdinal) {
        case (.some(let leftOrdinal), .some(let rightOrdinal)) where leftOrdinal != rightOrdinal:
            return leftOrdinal < rightOrdinal
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return lhs.offset < rhs.offset
        }
    }

    private func projectedHistoryMessages(_ history: [CodexHistoryMessage], sessionID: String) -> [ConversationMessage] {
        let keys = history.map { historyProjectionKey(for: $0) }
        let fallbackCreatedAts = deterministicHistoryCreatedAtFallbacks(for: history)
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
                fallbackCreatedAts: fallbackCreatedAts,
                cached: cached,
                sessionID: sessionID
            )
        } else {
            var unstableReuseBuckets = unstableHistoryReuseBuckets(sessionID: sessionID)
            converted = history.indices.map { index in
                projectHistoryMessage(
                    history[index],
                    sessionID: sessionID,
                    fallbackCreatedAt: fallbackCreatedAts[index],
                    unstableReuseBuckets: &unstableReuseBuckets
                )
            }
        }
        historyProjectionCacheBySessionID[sessionID] = HistoryProjectionCache(keys: keys, messages: converted)
        return converted
    }

    private func incrementallyProjectedHistoryMessages(
        _ history: [CodexHistoryMessage],
        keys: [HistoryProjectionKey],
        fallbackCreatedAts: [Date],
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
                converted.append(projectHistoryMessage(
                    history[index],
                    sessionID: sessionID,
                    fallbackCreatedAt: fallbackCreatedAts[index],
                    unstableReuseBuckets: &unstableReuseBuckets
                ))
            }
        }

        converted.append(contentsOf: suffixMessages)
        return converted
    }

    private func projectHistoryMessage(
        _ item: CodexHistoryMessage,
        sessionID: String,
        fallbackCreatedAt: Date,
        unstableReuseBuckets: inout [UnstableHistoryReuseKey: UnstableHistoryReuseBucket]
    ) -> ConversationMessage {
        let stableID = historyStableID(for: item)
        let role = messageRole(item.role)
        let createdAt = item.createdAt ?? fallbackCreatedAt
        let isTimestampFallback = item.isTimestampFallback || item.createdAt == nil
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
                      updatedAt: item.updatedAt,
                      sendStatus: sendStatus,
                      revision: item.revision,
                      timelineOrdinal: item.timelineOrdinal,
                      userDelivery: item.userDelivery,
                      isTimestampFallback: isTimestampFallback,
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
            updatedAt: item.updatedAt,
            sendStatus: sendStatus,
            revision: item.revision,
            timelineOrdinal: item.timelineOrdinal,
            userDelivery: item.userDelivery,
            isTimestampFallback: isTimestampFallback
        )
    }

    private func deterministicHistoryCreatedAtFallbacks(for history: [CodexHistoryMessage]) -> [Date] {
        guard !history.isEmpty else {
            return []
        }
        var nextKnown = Array<Date?>(repeating: nil, count: history.count)
        var upcoming: Date?
        for index in stride(from: history.count - 1, through: 0, by: -1) {
            nextKnown[index] = upcoming
            if let createdAt = history[index].createdAt {
                upcoming = createdAt
            }
        }

        var fallbacks: [Date] = []
        fallbacks.reserveCapacity(history.count)
        var previousKnown: Date?
        for index in history.indices {
            if let createdAt = history[index].createdAt {
                fallbacks.append(createdAt)
                previousKnown = createdAt
            } else if let previousKnown {
                fallbacks.append(previousKnown.addingTimeInterval(0.001))
            } else if let next = nextKnown[index] {
                fallbacks.append(next.addingTimeInterval(-0.001))
            } else {
                // 历史缺时间时必须使用稳定值，不能用 Date()；否则旧消息会被投影成“刚刚加载”。
                fallbacks.append(Self.undatedHistoryFallbackDate)
            }
        }
        return fallbacks
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
            updatedAt: message.updatedAt,
            sendStatus: message.sendStatus,
            revision: message.revision,
            timelineOrdinal: message.timelineOrdinal,
            userDelivery: message.userDelivery,
            isTimestampFallback: message.isTimestampFallback
        )
    }

    private func popUnstableHistoryMessage(
        role: ConversationMessage.Role,
        kind: MessageKind,
        content: String,
        createdAt: Date,
        updatedAt: Date?,
        sendStatus: MessageSendStatus,
        revision: ModelRevision?,
        timelineOrdinal: Int64?,
        userDelivery: UserMessageDelivery?,
        isTimestampFallback: Bool,
        buckets: inout [UnstableHistoryReuseKey: UnstableHistoryReuseBucket]
    ) -> ConversationMessage? {
        let key = UnstableHistoryReuseKey(
            role: role,
            kind: kind,
            content: content,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sendStatus: sendStatus,
            revision: revision,
            timelineOrdinal: timelineOrdinal,
            userDelivery: userDelivery,
            isTimestampFallback: isTimestampFallback
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
            updatedAt: item.updatedAt,
            clientMessageID: item.clientMessageID,
            turnID: item.turnID,
            itemID: item.itemID,
            seq: item.seq,
            revision: item.revision,
            sendStatus: item.sendStatus,
            timelineOrdinal: item.timelineOrdinal,
            userDelivery: item.userDelivery,
            isTimestampFallback: item.isTimestampFallback
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

    // thread/read 会把部分 item id 重排成整条线程的全局顺序号(item-N)，与流式 msg_… 对不上。
    // 仅靠 appserver:<turnId>:<itemId> 无法把直播副本和历史快照判为同一条，所以补一个
    // (turnId, 语义类型, 规范化文本) 的兜底键。这里只覆盖最终 assistant 和可折叠过程卡，
    // user 继续走 clientMessageId，approval/error/userInput 等交互状态不能按文本合并。
    private func turnScopedTextMergeKey(for item: ConversationMessage) -> String? {
        guard let turnID = item.turnID, !turnID.isEmpty else {
            return nil
        }
        let semanticKind: String
        if item.role == .assistant {
            semanticKind = "assistant"
        } else if item.role == .system, let processKind = processMessageMergeKind(for: item.kind) {
            semanticKind = processKind
        } else {
            return nil
        }
        let normalized = normalizedAssistantTextForDedup(item.content)
        guard !normalized.isEmpty else {
            return nil
        }
        return "turn:\(turnID):\(semanticKind):\(normalized)"
    }

    private func processMessageMergeKind(for kind: MessageKind) -> String? {
        switch kind {
        case .reasoningSummary, .plan, .commandSummary, .fileChangeSummary:
            return kind.rawValue
        case .message, .approval, .userInput, .error:
            return nil
        }
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
