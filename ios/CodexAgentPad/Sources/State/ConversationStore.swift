import Foundation

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var messagesBySessionID: [String: [ConversationMessage]] = [:]

    private var loadedHistorySessionIDs: Set<String> = []
    private var pendingRawOutput: [String: String] = [:]
    private var pendingOutput: [String: String] = [:]
    private var transcripts: [String: String] = [:]
    private var lastAssistantBySessionID: [String: String] = [:]
    private var lastSeenSeqBySessionID: [String: EventSequence] = [:]
    private var revisionByStableMessageID: [String: ModelRevision] = [:]
    private var messageUUIDByStableMessageID: [String: UUID] = [:]
    private var cleanTasks: [String: Task<Void, Never>] = [:]
    private var parseTasks: [String: Task<Void, Never>] = [:]

    func messages(for sessionID: String?) -> [ConversationMessage] {
        guard let sessionID else {
            return []
        }
        return messagesBySessionID[sessionID] ?? []
    }

    func hasLoadedHistory(sessionID: String) -> Bool {
        loadedHistorySessionIDs.contains(sessionID)
    }

    func setHistory(_ history: [CodexHistoryMessage], sessionID: String) {
        let converted = history.map { item in
            let stableID = historyStableID(for: item)
            return ConversationMessage(
                stableID: stableID,
                clientMessageID: item.clientMessageID,
                turnID: item.turnID,
                itemID: item.itemID,
                role: messageRole(item.role),
                content: item.content,
                createdAt: item.createdAt ?? Date(),
                sendStatus: item.sendStatus ?? .confirmed,
                revision: item.revision
            )
        }
        for message in converted {
            if let stableID = message.stableID {
                messageUUIDByStableMessageID[stableID] = message.id
                if let revision = message.revision {
                    revisionByStableMessageID[stableID] = revision
                }
            }
        }
        messagesBySessionID[sessionID] = mergeHistory(converted, with: messagesBySessionID[sessionID] ?? [])
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
              let index = list.firstIndex(where: { $0.clientMessageID == clientMessageID }) else {
            return
        }
        list[index].sendStatus = status
        messagesBySessionID[sessionID] = list
    }

    func appendSystem(_ text: String, sessionID: String) {
        append(ConversationMessage(role: .system, content: text), sessionID: sessionID)
    }

    func ingestTerminalOutput(_ raw: String, sessionID: String) {
        guard !raw.isEmpty else {
            return
        }

        // WebSocket 输出先进入独立原始缓冲区，ANSI 清洗放到后台任务做，避免拖慢输入。
        let pending = (pendingRawOutput[sessionID] ?? "") + raw
        pendingRawOutput[sessionID] = String(pending.suffix(16_000))
        scheduleClean(sessionID: sessionID)
    }

    func resetLiveTranscript(sessionID: String) {
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
        let stableID = stableMessageID(prefix: "assistant", metadata: metadata, fallbackSessionID: sessionID)
        guard shouldApplyRevision(metadata.revision, stableID: stableID) else {
            return
        }

        var list = messagesBySessionID[sessionID] ?? []
        let uuid = messageUUIDByStableMessageID[stableID] ?? UUID()
        messageUUIDByStableMessageID[stableID] = uuid
        let index = list.firstIndex { $0.stableID == stableID || $0.id == uuid }

        if let index {
            list[index].content += delta.text
            list[index].sendStatus = .sending
            list[index].revision = metadata.revision
        } else {
            list.append(ConversationMessage(
                id: uuid,
                stableID: stableID,
                clientMessageID: metadata.clientMessageID,
                turnID: metadata.turnID,
                itemID: metadata.itemID,
                role: .assistant,
                content: delta.text,
                sendStatus: .sending,
                revision: metadata.revision
            ))
        }
        messagesBySessionID[sessionID] = list
    }

    func completeMessage(_ message: AgentMessage, metadata: AgentEventMetadata, fallbackSessionID: String) {
        let sessionID = metadata.sessionID ?? message.sessionID
        guard shouldAccept(metadata: metadata, sessionID: sessionID) else {
            return
        }
        let stableID = message.id
        guard shouldApplyRevision(max(metadata.revision ?? message.revision, message.revision), stableID: stableID) else {
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

        var list = messagesBySessionID[sessionID] ?? []
        let uuid = messageUUIDByStableMessageID[stableID] ?? UUID()
        messageUUIDByStableMessageID[stableID] = uuid
        if let index = list.firstIndex(where: {
            $0.stableID == stableID ||
            (message.clientMessageID != nil && $0.clientMessageID == message.clientMessageID)
        }) {
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
        messagesBySessionID[sessionID] = list
    }

    func markCurrentAssistantCompleted(metadata: AgentEventMetadata, fallbackSessionID: String) {
        let sessionID = metadata.sessionID ?? fallbackSessionID
        guard shouldAccept(metadata: metadata, sessionID: sessionID) else {
            return
        }
        let stableID = stableMessageID(prefix: "assistant", metadata: metadata, fallbackSessionID: sessionID)
        guard var list = messagesBySessionID[sessionID],
              let index = list.firstIndex(where: { $0.stableID == stableID }) else {
            return
        }
        list[index].sendStatus = .confirmed
        if let revision = metadata.revision {
            list[index].revision = revision
        }
        messagesBySessionID[sessionID] = list
    }

    private func append(_ message: ConversationMessage, sessionID: String) {
        var list = messagesBySessionID[sessionID] ?? []
        list.append(message)
        messagesBySessionID[sessionID] = list
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

    private func shouldApplyRevision(_ revision: ModelRevision?, stableID: String) -> Bool {
        guard let revision else {
            return true
        }
        if let last = revisionByStableMessageID[stableID], revision <= last {
            return false
        }
        revisionByStableMessageID[stableID] = revision
        return true
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
        let pending = ((pendingOutput[sessionID] ?? "") + "\n" + clean)
        pendingOutput[sessionID] = String(pending.suffix(12_000))
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
                let transcript = ((self.transcripts[sessionID] ?? "") + "\n" + pending)
                let boundedTranscript = String(transcript.suffix(24_000))
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
        guard !candidate.isEmpty, candidate != lastAssistantBySessionID[sessionID] else {
            return
        }
        lastAssistantBySessionID[sessionID] = candidate
        addOrUpdateAssistant(candidate, sessionID: sessionID)
    }

    private func addOrUpdateAssistant(_ text: String, sessionID: String) {
        var list = messagesBySessionID[sessionID] ?? []
        if let last = list.last, last.role == .assistant {
            list[list.count - 1].content = text
        } else {
            list.append(ConversationMessage(role: .assistant, content: text))
        }
        messagesBySessionID[sessionID] = list
    }

    private func mergeHistory(_ history: [ConversationMessage], with local: [ConversationMessage]) -> [ConversationMessage] {
        var seen = Set<String>()
        var merged: [ConversationMessage] = []

        for item in history + local {
            let key = mergeKey(for: item)
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            merged.append(item)
        }
        return merged.sorted { $0.createdAt < $1.createdAt }
    }

    private func historyStableID(for item: CodexHistoryMessage) -> MessageID? {
        // 旧 Codex rollout 没有稳定 message id，Swift 解码会补一个随机 UUID；
        // 只有带结构化元数据时才把 id 当稳定键，避免破坏本地回显去重。
        if item.clientMessageID != nil || item.turnID != nil || item.itemID != nil || item.seq != nil || item.revision != nil {
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

    private func mergeKey(for item: ConversationMessage) -> String {
        if let clientMessageID = item.clientMessageID {
            return "client:\(clientMessageID)"
        }
        if let stableID = item.stableID {
            return "stable:\(stableID)"
        }
        return "\(item.role.rawValue):\(item.content)"
    }
}
