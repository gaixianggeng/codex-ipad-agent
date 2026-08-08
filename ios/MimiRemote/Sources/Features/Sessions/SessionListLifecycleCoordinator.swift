import SwiftUI

/// 列表展示只冻结会话所属分区和顺序；行内容始终从最新业务模型读取。
/// 这样状态可以原位更新，同时避免滚动中的跨 Section 删除和插入抢走 viewport。
struct SessionListMembership: Equatable {
    var activeIDs: [SessionID]
    var historyIDs: [SessionID]

    static let empty = SessionListMembership(activeIDs: [], historyIDs: [])

    init(activeIDs: [SessionID], historyIDs: [SessionID]) {
        self.activeIDs = activeIDs
        self.historyIDs = historyIDs
    }

    init(sessions: [AgentSession]) {
        activeIDs = sessions.filter(\.isRunning).map(\.id)
        historyIDs = sessions.filter { !$0.isRunning }.map(\.id)
    }

    var allIDs: Set<SessionID> {
        Set(activeIDs).union(historyIDs)
    }

    func retainingIDs(in latestIDs: Set<SessionID>) -> Self {
        SessionListMembership(
            activeIDs: activeIDs.filter(latestIDs.contains),
            historyIDs: historyIDs.filter(latestIDs.contains)
        )
    }
}

/// 筛选条件改变属于用户主动切换内容，必须立即提交；只有同一上下文里的实时状态更新才延迟重排。
struct SessionListLifecycleContext: Equatable {
    let profileID: String
    let workspaceID: String
    let statusFilterID: String
    let searchQuery: String
}

enum SessionLifecyclePhase: Equatable {
    case waiting
    case completion
    case failure
    case neutral
}

/// Haptic 使用明确业务状态判断，不能用颜色或 `!isRunning` 反推终态，避免把未知协议状态误报为完成。
struct SessionLifecycleObservation: Equatable {
    let id: SessionID
    let phase: SessionLifecyclePhase

    init(id: SessionID, phase: SessionLifecyclePhase) {
        self.id = id
        self.phase = phase
    }

    init(session: AgentSession, foregroundActivity: SessionForegroundActivity?) {
        id = session.id
        phase = Self.resolvePhase(session: session, foregroundActivity: foregroundActivity)
    }

    private static func resolvePhase(
        session: AgentSession,
        foregroundActivity: SessionForegroundActivity?
    ) -> SessionLifecyclePhase {
        switch session.status {
        case SessionStatus.failed.rawValue:
            return .failure
        case SessionStatus.completed.rawValue, SessionStatus.closed.rawValue:
            return .completion
        case SessionStatus.running.rawValue,
             SessionStatus.waitingForApproval.rawValue,
             SessionStatus.waitingForInput.rawValue:
            return .waiting
        case SessionStatus.history.rawValue, SessionStatus.idle.rawValue:
            switch foregroundActivity {
            case .waitingForAssistant, .receivingAssistant:
                return .waiting
            case .refreshing:
                return .neutral
            case nil:
                return .completion
            }
        default:
            switch foregroundActivity {
            case .waitingForAssistant, .receivingAssistant:
                return .waiting
            case .refreshing, nil:
                return .neutral
            }
        }
    }
}

struct SessionListLifecycleInput: Equatable {
    let membership: SessionListMembership
    let feedbackObservations: [SessionLifecycleObservation]
    let context: SessionListLifecycleContext
}

/// 每个会话只有在本次页面生命周期里确实见过运行/等待态后才允许发终态反馈。
/// 记录只保留当前输入中的 ID，列表重建或首次载入历史不会补发陈旧 Haptic。
struct SessionLifecycleFeedbackTracker {
    private struct Memory {
        var armedByWaiting: Bool
    }

    private var memoryByID: [SessionID: Memory] = [:]

    mutating func reset(with observations: [SessionLifecycleObservation]) {
        memoryByID.removeAll(keepingCapacity: true)
        for observation in observations {
            memoryByID[observation.id] = Memory(
                armedByWaiting: observation.phase == .waiting
            )
        }
    }

    mutating func observe(_ observations: [SessionLifecycleObservation]) -> MimiHapticEvent? {
        observeTransitions(observations).feedback
    }

    /// 与 Haptic 共用同一条“确实见过 waiting 后进入终态”的判定链路，
    /// 侧边栏高亮只消费完成 ID，不另行通过颜色或 `!isRunning` 猜测状态。
    mutating func observeTransitions(
        _ observations: [SessionLifecycleObservation]
    ) -> SessionLifecycleTransitionResult {
        let currentIDs = Set(observations.map(\.id))
        memoryByID = memoryByID.filter { currentIDs.contains($0.key) }

        var completedIDs: [SessionID] = []
        var failedIDs: [SessionID] = []

        for observation in observations {
            guard var memory = memoryByID[observation.id] else {
                // 新出现的终态只建立基线；新出现的等待态静默武装下一次结束。
                memoryByID[observation.id] = Memory(
                    armedByWaiting: observation.phase == .waiting
                )
                continue
            }

            switch observation.phase {
            case .waiting:
                memory.armedByWaiting = true
            case .completion:
                if memory.armedByWaiting {
                    completedIDs.append(observation.id)
                    memory.armedByWaiting = false
                }
            case .failure:
                if memory.armedByWaiting {
                    failedIDs.append(observation.id)
                    memory.armedByWaiting = false
                }
            case .neutral:
                // 短暂未知状态不解除武装，避免 running → unknown → completed 漏掉反馈。
                break
            }
            memoryByID[observation.id] = memory
        }

        let feedback: MimiHapticEvent?
        if !failedIDs.isEmpty {
            feedback = .failure
        } else if !completedIDs.isEmpty {
            feedback = .completion
        } else {
            feedback = nil
        }
        return SessionLifecycleTransitionResult(
            feedback: feedback,
            completedSessionIDs: completedIDs,
            failedSessionIDs: failedIDs
        )
    }
}

struct SessionLifecycleTransitionResult {
    let feedback: MimiHapticEvent?
    let completedSessionIDs: [SessionID]
    let failedSessionIDs: [SessionID]
}

/// 侧边栏只需要一个短暂完成高亮；跟踪器复用列表已经验证过的生命周期信号，
/// Profile 切换时重新建基线，避免同 ID 在另一台主机上产生伪高亮。
@MainActor
final class SessionSidebarHighlightCoordinator: ObservableObject {
    @Published private(set) var highlightedSessionID: SessionID?

    private var profileID: String?
    private var tracker = SessionLifecycleFeedbackTracker()
    private var highlightRevision: UInt = 0

    func observe(profileID: String, observations: [SessionLifecycleObservation]) {
        guard self.profileID == profileID else {
            self.profileID = profileID
            tracker.reset(with: observations)
            clearHighlight()
            return
        }

        let result = tracker.observeTransitions(observations)
        guard let sessionID = result.completedSessionIDs.last else { return }

        highlightRevision &+= 1
        let revision = highlightRevision
        highlightedSessionID = sessionID

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard revision == highlightRevision else { return }
            highlightedSessionID = nil
        }
    }

    private func clearHighlight() {
        highlightRevision &+= 1
        highlightedSessionID = nil
    }
}

@MainActor
final class SessionListLifecycleCoordinator: ObservableObject {
    @Published private(set) var membership: SessionListMembership = .empty
    @Published private(set) var isUserScrolling = false

    private(set) var pendingMembership: SessionListMembership?
    private(set) var hasObservedInput = false

    private var context: SessionListLifecycleContext?
    private var feedbackTracker = SessionLifecycleFeedbackTracker()

    /// 合并最新展示快照并返回本批次唯一的 Haptic；失败与完成同批时失败优先。
    func observe(_ input: SessionListLifecycleInput) -> MimiHapticEvent? {
        let displayContextChanged = context != input.context

        let feedback: MimiHapticEvent?
        if !hasObservedInput || displayContextChanged {
            // 用户切换 Profile、工作区、筛选或搜索时重新建立反馈基线，
            // 防止同 ID 的旧上下文等待态影响新内容，也不补发切换期间已经结束的会话。
            feedbackTracker.reset(with: input.feedbackObservations)
            feedback = nil
        } else {
            feedback = feedbackTracker.observe(input.feedbackObservations)
        }

        if !hasObservedInput || displayContextChanged {
            // Profile、搜索和筛选都是明确的内容切换，不沿用旧 viewport 的冻结分组。
            commit(input.membership)
            pendingMembership = nil
        } else if isUserScrolling {
            // pending 永远只有最新一份；已消失的 ID 立即移除，新 ID 和跨区移动等 idle 再统一提交。
            pendingMembership = input.membership == membership ? nil : input.membership
            commit(membership.retainingIDs(in: input.membership.allIDs))
        } else {
            commit(input.membership)
            pendingMembership = nil
        }

        context = input.context
        hasObservedInput = true
        return feedback
    }

    func setScrollPhase(_ phase: ScrollPhase, latestMembership: SessionListMembership) {
        setUserScrolling(
            Self.shouldSuspendRegroup(for: phase),
            latestMembership: latestMembership
        )
    }

    func setUserScrolling(_ shouldSuspend: Bool, latestMembership: SessionListMembership) {
        guard shouldSuspend != isUserScrolling else {
            return
        }

        isUserScrolling = shouldSuspend
        guard !shouldSuspend else {
            return
        }

        // 回到 idle 立即在同一轮事件处理中落地最后一份 pending，不累积过期中间状态。
        commit(pendingMembership ?? latestMembership)
        pendingMembership = nil
    }

    static func shouldSuspendRegroup(for phase: ScrollPhase) -> Bool {
        switch phase {
        case .tracking, .interacting, .decelerating:
            return true
        case .idle, .animating:
            return false
        }
    }

    private func commit(_ nextMembership: SessionListMembership) {
        guard membership != nextMembership else {
            return
        }
        membership = nextMembership
    }
}
