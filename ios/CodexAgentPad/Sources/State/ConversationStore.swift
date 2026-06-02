import Foundation

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var messagesBySessionID: [String: [ConversationMessage]] = [:]

    private var loadedHistorySessionIDs: Set<String> = []
    private var pendingRawOutput: [String: String] = [:]
    private var pendingOutput: [String: String] = [:]
    private var transcripts: [String: String] = [:]
    private var lastAssistantBySessionID: [String: String] = [:]
    // 一旦收到结构化助手消息的会话，就以结构化为准、忽略 PTY 解析兜底，避免两路并存导致重复。
    private var sawStructuredAssistant: Set<String> = []
    private var lastSeenSeqBySessionID: [String: EventSequence] = [:]
    private var revisionByStableMessageID: [StableMessageCacheKey: ModelRevision] = [:]
    private var messageUUIDByStableMessageID: [StableMessageCacheKey: UUID] = [:]
    private var messageIndexByStableIDBySessionID: [String: [MessageID: Int]] = [:]
    private var messageIndexByClientMessageIDBySessionID: [String: [ClientMessageID: Int]] = [:]
    private var messageIndexByUUIDBySessionID: [String: [UUID: Int]] = [:]
    private var historyProjectionCacheBySessionID: [String: HistoryProjectionCache] = [:]
    private var pendingAssistantDeltasBySessionID: [String: PendingAssistantDelta] = [:]
    private var assistantDeltaFlushTasks: [String: Task<Void, Never>] = [:]
    private var cleanTasks: [String: Task<Void, Never>] = [:]
    private var parseTasks: [String: Task<Void, Never>] = [:]
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

    private struct LegacyEchoCandidate {
        let role: ConversationMessage.Role
        let content: String
        let createdAt: Date
    }

    private struct LegacyHistoryReuseKey: Hashable {
        let role: ConversationMessage.Role
        let content: String
        let createdAt: Date
        let sendStatus: MessageSendStatus
        let revision: ModelRevision?
    }

    private struct LegacyHistoryReuseBucket {
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

    private let legacyEchoMergeWindow: TimeInterval = 10 * 60

    func messages(for sessionID: String?) -> [ConversationMessage] {
        guard let sessionID else {
            return []
        }
        return messagesBySessionID[sessionID] ?? []
    }

    func hasLoadedHistory(sessionID: String) -> Bool {
        loadedHistorySessionIDs.contains(sessionID)
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
        lastAssistantBySessionID[sessionID] = ""
    }

    func appendLocalUser(
        _ text: String,
        sessionID: String,
        clientMessageID: ClientMessageID?,
        sendStatus: MessageSendStatus = .sending
    ) {
        append(
            ConversationMessage(
                stableID: clientMessageID,
                clientMessageID: clientMessageID,
                role: .user,
                content: text,
                sendStatus: sendStatus
            ),
            sessionID: sessionID
        )
        lastAssistantBySessionID[sessionID] = ""
    }

    func updateSendStatus(clientMessageID: ClientMessageID, sessionID: String, status: MessageSendStatus) {
        guard var list = messagesBySessionID[sessionID],
              let index = messageIndex(clientMessageID: clientMessageID, sessionID: sessionID) else {
            return
        }
        list[index].sendStatus = status
        setMessages(list, sessionID: sessionID, rebuildIndexes: false)
    }

    func appendSystem(_ text: String, sessionID: String) {
        append(ConversationMessage(role: .system, content: text), sessionID: sessionID)
    }

    func ingestTerminalOutput(_ raw: String, sessionID: String) {
        guard !raw.isEmpty else {
            return
        }

        // 旧协议/测试兜底入口：生产路径已经由结构化 AgentEvent.messageCompleted /
        // assistantDelta 驱动消息气泡，PTY 文本只进入日志。这里保留给老 WebSocket
        // transcript 和 parser 回归测试，避免把旧兼容逻辑误当成主链路继续扩展。
        // WebSocket 输出先进入独立原始缓冲区，ANSI 清洗放到后台任务做，避免拖慢输入。
        pendingRawOutput[sessionID] = appendBoundedWindow(raw, to: pendingRawOutput[sessionID], maxCharacters: 16_000)
        scheduleClean(sessionID: sessionID)
    }

    func resetLiveTranscript(sessionID: String) {
        flushPendingAssistantDelta(sessionID: sessionID)
        pendingRawOutput[sessionID] = ""
        pendingOutput[sessionID] = ""
        transcripts[sessionID] = ""
        lastAssistantBySessionID[sessionID] = ""
        lastSeenSeqBySessionID[sessionID] = nil
        cleanTasks[sessionID]?.cancel()
        cleanTasks[sessionID] = nil
        parseTasks[sessionID]?.cancel()
        parseTasks[sessionID] = nil
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
        markStructuredAssistant(sessionID: sessionID)

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
        switch message.role {
        case .user:
            role = .user
        case .assistant:
            role = .assistant
        default:
            role = .system
        }
        if role == .assistant {
            markStructuredAssistant(sessionID: sessionID)
        }

        var list = messagesBySessionID[sessionID] ?? []
        let key = stableCacheKey(stableID: stableID, sessionID: sessionID)
        let uuid = messageUUIDByStableMessageID[key] ?? UUID()
        messageUUIDByStableMessageID[key] = uuid
        if let index = messageIndex(stableID: stableID, sessionID: sessionID) ?? message.clientMessageID.flatMap({ messageIndex(clientMessageID: $0, sessionID: sessionID) }) {
            list[index].stableID = stableID
            list[index].content = message.content
            list[index].sendStatus = message.sendStatus == .failed ? .failed : .confirmed
            list[index].revision = message.revision
        } else {
            list.append(ConversationMessage(
                id: uuid,
                stableID: stableID,
                clientMessageID: message.clientMessageID,
                turnID: message.turnID,
                itemID: message.itemID,
                role: role,
                content: message.content,
                createdAt: message.createdAt ?? Date(),
                sendStatus: message.sendStatus,
                revision: message.revision
            ))
        }
        setMessages(list, sessionID: sessionID)
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

    private func scheduleClean(sessionID: String) {
        guard cleanTasks[sessionID] == nil else {
            return
        }
        cleanTasks[sessionID] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
            } catch {
                return
            }

            let raw = await MainActor.run { [weak self] () -> String in
                guard let self else {
                    return ""
                }
                let raw = self.pendingRawOutput[sessionID] ?? ""
                self.pendingRawOutput[sessionID] = ""
                return raw
            }
            guard !raw.isEmpty else {
                await MainActor.run { [weak self] in
                    self?.finishCleanTask(sessionID: sessionID)
                }
                return
            }

            // ANSI 清洗可能遇到大段终端控制序列，放到 utility 优先级后台线程。
            let clean = await Task.detached(priority: .utility) {
                AnsiCleaner.clean(raw)
            }.value
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run { [weak self] in
                self?.appendCleanTerminalOutput(clean, sessionID: sessionID)
                self?.finishCleanTask(sessionID: sessionID)
            }
        }
    }

    private func finishCleanTask(sessionID: String) {
        cleanTasks[sessionID] = nil
        if pendingRawOutput[sessionID]?.isEmpty == false {
            scheduleClean(sessionID: sessionID)
        }
    }

    private func appendCleanTerminalOutput(_ clean: String, sessionID: String) {
        guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // 对话解析只消费清洗后的输出，不依赖右侧日志渲染完成。
        pendingOutput[sessionID] = appendBoundedWindow(clean, to: pendingOutput[sessionID], separator: "\n", maxCharacters: 12_000)
        scheduleParse(sessionID: sessionID)
    }

    private func scheduleParse(sessionID: String) {
        parseTasks[sessionID]?.cancel()
        parseTasks[sessionID] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 700_000_000)
            } catch {
                return
            }

            let transcript = await MainActor.run { [weak self] () -> String in
                guard let self else {
                    return ""
                }
                defer {
                    self.parseTasks[sessionID] = nil
                }
                guard let pending = self.pendingOutput[sessionID],
                      !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return ""
                }
                self.pendingOutput[sessionID] = ""
                let boundedTranscript = self.appendBoundedWindow(
                    pending,
                    to: self.transcripts[sessionID],
                    separator: "\n",
                    maxCharacters: 24_000
                )
                self.transcripts[sessionID] = boundedTranscript
                return boundedTranscript
            }
            guard !transcript.isEmpty else {
                return
            }

            // parser 只处理 bounded transcript，离开主线程计算，避免 UI 卡顿。
            let candidate = await Task.detached(priority: .utility) {
                CodexOutputParser().latestAssistantBlock(from: transcript)
            }.value
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run { [weak self] in
                self?.applyAssistantCandidate(candidate, sessionID: sessionID)
            }
        }
    }

    private func applyAssistantCandidate(_ candidate: String, sessionID: String) {
        // 已有结构化助手消息时，PTY 解析只会重复且带终端装饰，直接忽略。
        guard !sawStructuredAssistant.contains(sessionID) else {
            return
        }
        guard !candidate.isEmpty, candidate != lastAssistantBySessionID[sessionID] else {
            return
        }
        if shouldIgnoreAssistantCandidateAsDuplicate(candidate, sessionID: sessionID) {
            lastAssistantBySessionID[sessionID] = candidate
            return
        }
        lastAssistantBySessionID[sessionID] = candidate
        addOrUpdateAssistant(candidate, sessionID: sessionID)
    }

    private func shouldIgnoreAssistantCandidateAsDuplicate(_ candidate: String, sessionID: String) -> Bool {
        let normalizedCandidate = normalizedAssistantTextForDedup(candidate)
        guard normalizedCandidate.count >= 12 else {
            return false
        }

        // 刷新运行中历史会话时，Go rollout 已经能返回干净的 agent_message，
        // recent_output 仍可能包含同一段 PTY 尾部。这里只过滤“内容已经存在”的兜底解析，
        // 不阻断 rollout 还没落盘时靠 PTY 先显示的新回复。
        for message in (messagesBySessionID[sessionID] ?? []).reversed() where message.role == .assistant {
            let normalizedExisting = normalizedAssistantTextForDedup(message.content)
            guard normalizedExisting.count >= 12 else {
                continue
            }
            if normalizedCandidate == normalizedExisting ||
                normalizedCandidate.contains(normalizedExisting) ||
                normalizedExisting.contains(normalizedCandidate) {
                return true
            }
        }
        return false
    }

    private func normalizedAssistantTextForDedup(_ text: String) -> String {
        AssistantTextNormalizer.normalizedAssistantTextForDedup(text)
    }

    private func markStructuredAssistant(sessionID: String) {
        guard sawStructuredAssistant.insert(sessionID).inserted else {
            return
        }
        // 第一次收到结构化助手消息：把此前 PTY 解析兜底生成的助手气泡（stableID == nil）清掉，
        // 避免“干净的结构化消息”和“带装饰的解析消息”同时出现在记录里。
        if let list = messagesBySessionID[sessionID] {
            let filtered = list.filter { !($0.role == .assistant && $0.stableID == nil) }
            if filtered.count != list.count {
                setMessages(filtered, sessionID: sessionID)
            }
        }
        lastAssistantBySessionID[sessionID] = ""
    }

    private func appendBoundedWindow(
        _ addition: String,
        to current: String?,
        separator: String = "",
        maxCharacters: Int
    ) -> String {
        guard maxCharacters > 0 else {
            return ""
        }
        let boundedAddition = boundedSuffix(addition, maxCharacters: maxCharacters)
        guard boundedAddition.count < maxCharacters,
              let current,
              !current.isEmpty
        else {
            return boundedAddition
        }

        let currentBudget = maxCharacters - boundedAddition.count - separator.count
        guard currentBudget > 0 else {
            return boundedSuffix(separator + boundedAddition, maxCharacters: maxCharacters)
        }
        // 实时 PTY 输出只需要尾部窗口；先裁当前缓存再拼新块，避免 current+addition
        // 构造出超大临时字符串再 suffix，和 Litter 的 terminal tail window 思路一致。
        return boundedSuffix(current, maxCharacters: currentBudget) + separator + boundedAddition
    }

    private func boundedSuffix(_ value: String, maxCharacters: Int) -> String {
        guard value.count > maxCharacters else {
            return value
        }
        return String(value.suffix(maxCharacters))
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

    private func addOrUpdateAssistant(_ text: String, sessionID: String) {
        var list = messagesBySessionID[sessionID] ?? []
        if let last = list.last, last.role == .assistant {
            list[list.count - 1].content = text
            setMessages(list, sessionID: sessionID, rebuildIndexes: false)
        } else {
            let message = ConversationMessage(role: .assistant, content: text)
            list.append(message)
            appendMessageWithIndex(message, list: list, sessionID: sessionID)
        }
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
        pendingRawOutput.removeValue(forKey: sessionID)
        pendingOutput.removeValue(forKey: sessionID)
        transcripts.removeValue(forKey: sessionID)
        lastAssistantBySessionID.removeValue(forKey: sessionID)
        sawStructuredAssistant.remove(sessionID)
        lastSeenSeqBySessionID.removeValue(forKey: sessionID)
        messageIndexByStableIDBySessionID.removeValue(forKey: sessionID)
        messageIndexByClientMessageIDBySessionID.removeValue(forKey: sessionID)
        messageIndexByUUIDBySessionID.removeValue(forKey: sessionID)
        historyProjectionCacheBySessionID.removeValue(forKey: sessionID)
        pendingAssistantDeltasBySessionID.removeValue(forKey: sessionID)
        assistantDeltaFlushTasks[sessionID]?.cancel()
        assistantDeltaFlushTasks.removeValue(forKey: sessionID)
        cleanTasks[sessionID]?.cancel()
        cleanTasks.removeValue(forKey: sessionID)
        parseTasks[sessionID]?.cancel()
        parseTasks.removeValue(forKey: sessionID)
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
            if let clientMessageID = message.clientMessageID {
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
        if let clientMessageID = message.clientMessageID {
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
        var legacyEchoCandidates: [LegacyEchoCandidate] = []
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
            legacyEchoCandidates.append(LegacyEchoCandidate(role: item.role, content: item.content, createdAt: item.createdAt))
            merged.append(item)
        }

        for item in local {
            guard seenUUIDs.insert(item.id).inserted else {
                continue
            }
            if shouldMergeAsLegacyEcho(item, candidates: legacyEchoCandidates) {
                continue
            }
            if let key = primaryMergeKey(for: item) {
                guard seenPrimaryKeys.insert(key).inserted else {
                    continue
                }
            }
            merged.append(item)
        }

        return merged.sorted { $0.createdAt < $1.createdAt }
    }

    private func projectedHistoryMessages(_ history: [CodexHistoryMessage], sessionID: String) -> [ConversationMessage] {
        let keys = history.map { historyProjectionKey(for: $0) }
        // Litter 的 ConversationScreenModel 会缓存“hydrated -> UI item”的投影结果；
        // 这里也把历史 JSON 消息到本地 ConversationMessage 的转换缓存住。这样手动刷新、
        // 前后台恢复拿到同一页历史时，不会因为 legacy rollout 缺稳定 id 而反复生成新 UUID。
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
            var legacyReuseBuckets = legacyHistoryReuseBuckets(sessionID: sessionID)
            converted = history.map { item in
                projectHistoryMessage(item, sessionID: sessionID, legacyReuseBuckets: &legacyReuseBuckets)
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
        var legacyReuseBuckets = legacyHistoryReuseBuckets(sessionID: sessionID, excludingIDs: preservedIDs)

        if prefixCount < changedUpperBound {
            for index in prefixCount..<changedUpperBound {
                converted.append(projectHistoryMessage(history[index], sessionID: sessionID, legacyReuseBuckets: &legacyReuseBuckets))
            }
        }

        converted.append(contentsOf: suffixMessages)
        return converted
    }

    private func projectHistoryMessage(
        _ item: CodexHistoryMessage,
        sessionID: String,
        legacyReuseBuckets: inout [LegacyHistoryReuseKey: LegacyHistoryReuseBucket]
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
                  let reused = popLegacyHistoryMessage(
                      role: role,
                      content: item.content,
                      createdAt: createdAt,
                      sendStatus: sendStatus,
                      revision: item.revision,
                      buckets: &legacyReuseBuckets
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

    private func legacyHistoryReuseBuckets(sessionID: String, excludingIDs: Set<UUID> = []) -> [LegacyHistoryReuseKey: LegacyHistoryReuseBucket] {
        var grouped: [LegacyHistoryReuseKey: [ConversationMessage]] = [:]
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
            grouped[legacyHistoryReuseKey(for: message), default: []].append(message)
        }

        var buckets: [LegacyHistoryReuseKey: LegacyHistoryReuseBucket] = [:]
        buckets.reserveCapacity(grouped.count)
        for (key, messages) in grouped {
            buckets[key] = LegacyHistoryReuseBucket(messages: messages)
        }
        return buckets
    }

    private func legacyHistoryReuseKey(for message: ConversationMessage) -> LegacyHistoryReuseKey {
        LegacyHistoryReuseKey(
            role: message.role,
            content: message.content,
            createdAt: message.createdAt,
            sendStatus: message.sendStatus,
            revision: message.revision
        )
    }

    private func popLegacyHistoryMessage(
        role: ConversationMessage.Role,
        content: String,
        createdAt: Date,
        sendStatus: MessageSendStatus,
        revision: ModelRevision?,
        buckets: inout [LegacyHistoryReuseKey: LegacyHistoryReuseBucket]
    ) -> ConversationMessage? {
        let key = LegacyHistoryReuseKey(
            role: role,
            content: content,
            createdAt: createdAt,
            sendStatus: sendStatus,
            revision: revision
        )
        guard var bucket = buckets[key] else {
            return nil
        }
        // 同一时间同一文本也可能重复出现，按出现顺序逐个复用。
        // 用游标代替 removeFirst，避免大批重复 legacy 消息刷新时反复搬数组。
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
        if let stableID = item.stableID {
            return "stable:\(stableID)"
        }
        return nil
    }

    private func shouldMergeAsLegacyEcho(_ item: ConversationMessage, candidates: [LegacyEchoCandidate]) -> Bool {
        guard item.sendStatus != .confirmed else {
            return false
        }
        // 旧 rollout 缺稳定 id，本地回显也可能没有 client_message_id。这里仅把“未确认本地消息”
        // 和时间接近的同文历史合并；历史页里的两条相同文本不能再被 role+content 误删。
        return candidates.contains { candidate in
            guard candidate.role == item.role,
                  abs(candidate.createdAt.timeIntervalSince(item.createdAt)) <= legacyEchoMergeWindow else {
                return false
            }
            if candidate.content == item.content {
                return true
            }
            guard item.role == .assistant else {
                return false
            }
            return shouldMergeAssistantLegacyEcho(localContent: item.content, historyContent: candidate.content)
        }
    }

    private func shouldMergeAssistantLegacyEcho(localContent: String, historyContent: String) -> Bool {
        let localKey = normalizedAssistantTextForDedup(localContent)
        let historyKey = normalizedAssistantTextForDedup(historyContent)
        guard localKey.count >= 12, historyKey.count >= 12 else {
            return false
        }
        // PTY 兜底可能把同一句重绘内容连在一个气泡里；history 返回干净 assistant 后，
        // 用压缩后的语义文本合并，刷新时让干净历史替换旧脏气泡。
        return localKey == historyKey ||
            localKey.contains(historyKey) ||
            historyKey.contains(localKey)
    }
}
