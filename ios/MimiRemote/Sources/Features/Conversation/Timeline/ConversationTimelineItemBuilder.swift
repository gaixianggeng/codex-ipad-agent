import Foundation

struct ConversationTimelineItemBuilder {
    static func items(from messages: [ConversationMessage]) -> [ConversationTimelineItem] {
        let turnLifecycles = effectiveTurnLifecycles(in: messages)
        var items: [ConversationTimelineItem] = []
        var index = messages.startIndex

        while index < messages.endIndex {
            let message = messages[index]
            guard isActivityMessage(message) else {
                items.append(.message(message))
                index = messages.index(after: index)
                continue
            }

            var activityMessages: [ConversationMessage] = []
            while index < messages.endIndex,
                  isActivityMessage(messages[index]),
                  belongsToSameActivitySequence(message, messages[index]) {
                activityMessages.append(messages[index])
                index = messages.index(after: index)
            }
            let turnLifecycle = message.turnID.flatMap { turnLifecycles[$0] }
                ?? fallbackTurnLifecycle(for: activityMessages, nextIndex: index, messages: messages)
            let keepsRunningWhileTurnIsActive = isLatestActivitySequence(
                for: message,
                nextIndex: index,
                messages: messages
            )
            // 时间线只折叠相邻过程项，不跨 commentary、plan 或 final 搬运内容。
            // 输入顺序由上游 canonical timeline 决定，视图投影不能再次改写语义顺序。
            items.append(contentsOf: activityItems(
                from: activityMessages,
                turnLifecycle: turnLifecycle,
                keepsRunningWhileTurnIsActive: keepsRunningWhileTurnIsActive
            ))
        }

        return items
    }

    private static func isActivityMessage(_ message: ConversationMessage) -> Bool {
        guard message.role == .system else {
            return false
        }
        switch message.kind {
        case .reasoningSummary, .commandSummary, .fileChangeSummary:
            return true
        case .approval, .userInput:
            return isResolvedInteractionMessage(message)
        case .commentary, .plan, .error, .message:
            return false
        }
    }

    private static func isResolvedInteractionMessage(_ message: ConversationMessage) -> Bool {
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        switch message.kind {
        case .approval:
            return content.hasPrefix(L10n.text("ui.approval_approved")) || content.hasPrefix(L10n.text("ui.approved")) ||
                content.hasPrefix(L10n.text("ui.approval_rejected")) || content.hasPrefix(L10n.text("ui.rejected"))
        case .userInput:
            return content.hasPrefix(L10n.text("ui.additional_information_has_been_submitted")) || content.hasPrefix(L10n.text("ui.boot_input_submitted")) ||
                content.hasPrefix(L10n.text("ui.additional_information_skipped")) || content.hasPrefix(L10n.text("ui.boot_input_skipped"))
        case .message, .commentary, .plan, .reasoningSummary, .commandSummary, .fileChangeSummary, .error:
            return false
        }
    }

    private static func belongsToSameActivitySequence(
        _ first: ConversationMessage,
        _ candidate: ConversationMessage
    ) -> Bool {
        first.turnID == candidate.turnID
    }

    private static func isCompletedAssistantMessage(_ message: ConversationMessage) -> Bool {
        guard message.role == .assistant && message.kind == .message else {
            return false
        }
        return message.sendStatus == .confirmed || message.sendStatus == .sent
    }

    private static func effectiveTurnLifecycles(
        in messages: [ConversationMessage]
    ) -> [TurnID: ConversationTurnLifecycle] {
        let messagesByTurnID = Dictionary(grouping: messages.compactMap { message -> (TurnID, ConversationMessage)? in
            guard let turnID = message.turnID, !turnID.isEmpty else { return nil }
            return (turnID, message)
        }, by: { $0.0 })
        var result: [TurnID: ConversationTurnLifecycle] = [:]
        for (turnID, entries) in messagesByTurnID {
            let turnMessages = entries.map(\.1)
            let lifecycles = turnMessages.compactMap(\.turnLifecycle)
            if lifecycles.contains(.failed) || turnMessages.contains(where: { $0.role == .assistant && $0.sendStatus == .failed }) {
                result[turnID] = .failed
                continue
            }
            if lifecycles.contains(.interrupted) {
                result[turnID] = .interrupted
                continue
            }
            if lifecycles.contains(.completed) {
                result[turnID] = .completed
                continue
            }
            // 旧 gateway 没有可靠 lifecycle 时才回退到 final；显式 inProgress 不能被提前收口。
            if turnMessages.allSatisfy({ $0.turnLifecycle == nil || $0.turnLifecycle == .unknown }),
               turnMessages.contains(where: isCompletedAssistantMessage) {
                result[turnID] = .completed
                continue
            }
            result[turnID] = lifecycles.contains(.inProgress) ||
                turnMessages.contains(where: { $0.activityPayload?.isInProgress == true })
                ? .inProgress
                : .unknown
        }
        return result
    }

    private static func fallbackTurnLifecycle(
        for processMessages: [ConversationMessage],
        nextIndex: [ConversationMessage].Index,
        messages: [ConversationMessage]
    ) -> ConversationTurnLifecycle {
        guard sharedTurnID(in: processMessages) == nil,
              let next = messages[safe: nextIndex],
              next.role == .assistant else {
            return .unknown
        }
        if next.sendStatus == .failed {
            return .failed
        }
        return isCompletedAssistantMessage(next) ? .completed : .unknown
    }

    private static func isLatestActivitySequence(
        for firstMessage: ConversationMessage,
        nextIndex: [ConversationMessage].Index,
        messages: [ConversationMessage]
    ) -> Bool {
        let remaining = messages[nextIndex...]
        guard let turnID = firstMessage.turnID else {
            return !remaining.contains(where: isActivityMessage)
        }
        return !remaining.contains { message in
            guard message.turnID == turnID else {
                return false
            }
            if isActivityMessage(message) {
                return true
            }
            // commentary/plan/交互卡已经开始展示下一阶段时，上一批命令必须收口；
            // final 的显式 inProgress 仍可能只是尚未完成的流式正文，保持原有兼容语义。
            return message.kind != .message || message.role != .assistant
        }
    }

    private static func sharedTurnID(in messages: [ConversationMessage]) -> TurnID? {
        let turnIDs = Set(messages.compactMap(\.turnID))
        guard turnIDs.count == 1, let turnID = turnIDs.first, !turnID.isEmpty else {
            return nil
        }
        return turnID
    }

    private static func activityItems(
        from messages: [ConversationMessage],
        turnLifecycle: ConversationTurnLifecycle,
        keepsRunningWhileTurnIsActive: Bool
    ) -> [ConversationTimelineItem] {
        var result: [ConversationTimelineItem] = []
        var commandMessages: [ConversationMessage] = []

        func flushCommands(hasFollowingActivity: Bool) {
            guard !commandMessages.isEmpty else {
                return
            }
            result.append(.activityBatch(activityBatch(
                from: commandMessages,
                turnLifecycle: turnLifecycle,
                keepsRunningWhileTurnIsActive: keepsRunningWhileTurnIsActive && !hasFollowingActivity
            )))
            commandMessages.removeAll(keepingCapacity: true)
        }

        for element in ConversationProcessGrouper.elements(
            from: messages,
            turnLifecycle: turnLifecycle,
            keepsRunningWhileTurnIsActive: keepsRunningWhileTurnIsActive
        ) {
            switch element {
            case .group(let group):
                flushCommands(hasFollowingActivity: true)
                result.append(.processGroup(group))
            case .activity(let message):
                if message.activityPayload?.category == .runCommand ||
                    (message.activityPayload == nil && message.kind == .commandSummary) {
                    commandMessages.append(message)
                } else {
                    flushCommands(hasFollowingActivity: true)
                    result.append(.activity(message))
                }
            }
        }
        flushCommands(hasFollowingActivity: false)
        return result
    }

    private static func activityBatch(
        from messages: [ConversationMessage],
        turnLifecycle: ConversationTurnLifecycle,
        keepsRunningWhileTurnIsActive: Bool
    ) -> ConversationActivityBatch {
        let firstID = messages.first?.id.uuidString ?? UUID().uuidString
        let kind: ConversationCommandPresentationKind = messages.allSatisfy {
            $0.activityPayload?.commandPresentationKind == .exploration
        } ? .exploration : .execution
        return ConversationActivityBatch(
            id: "activity-batch:\(firstID)",
            messages: messages,
            kind: kind,
            status: .resolve(
                turnLifecycle: turnLifecycle,
                activities: messages,
                keepsRunningWhileTurnIsActive: keepsRunningWhileTurnIsActive
            )
        )
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
