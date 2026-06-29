import Foundation

struct SubmittedComposerDraft {
    let text: String
    let attachments: [CodexAppServerUserInput]
    let payload: CodexAppServerTurnPayload
    let voiceDraftNeedsReview: Bool
}

enum ComposerPermissionMode: String, CaseIterable, Identifiable {
    case requestApproval
    case readOnly
    case autoApprove
    case fullAccess

    static let defaultStorageKey = "composer.defaultPermissionMode"
    static let defaultMode: ComposerPermissionMode = .fullAccess

    var id: String { rawValue }

    static func stored(_ rawValue: String) -> ComposerPermissionMode {
        ComposerPermissionMode(rawValue: rawValue) ?? defaultMode
    }

    init(options: CodexAppServerTurnOptions) {
        let reviewer = options.approvalsReviewer.trimmingCharacters(in: .whitespacesAndNewlines)
        if options.sandboxMode == .readOnly {
            self = .readOnly
        } else if options.sandboxMode == .dangerFullAccess {
            self = .fullAccess
        } else if options.approvalPolicy == .onFailure, reviewer == Self.autoReviewer {
            self = .autoApprove
        } else {
            self = .requestApproval
        }
    }

    var title: String {
        switch self {
        case .requestApproval:
            return "请求批准"
        case .readOnly:
            return "只读"
        case .autoApprove:
            return "替我审批"
        case .fullAccess:
            return "完全访问"
        }
    }

    var chipTitle: String {
        switch self {
        case .requestApproval:
            return "权限 请求批准"
        case .readOnly:
            return "权限 只读"
        case .autoApprove:
            return "权限 替我审批"
        case .fullAccess:
            return "权限 完全访问"
        }
    }

    var detail: String {
        switch self {
        case .requestApproval:
            return "可写当前工作区，执行前由你确认"
        case .readOnly:
            return "默认不写文件"
        case .autoApprove:
            return "低风险审批交给代理"
        case .fullAccess:
            return "允许访问整个文件系统"
        }
    }

    var systemImage: String {
        switch self {
        case .requestApproval:
            return "lock.shield"
        case .readOnly:
            return "eye"
        case .autoApprove:
            return "checkmark.shield"
        case .fullAccess:
            return "exclamationmark.shield"
        }
    }

    var approvalPolicy: CodexAppServerApprovalPolicy {
        switch self {
        case .requestApproval, .readOnly, .fullAccess:
            return .onRequest
        case .autoApprove:
            return .onFailure
        }
    }

    var approvalsReviewer: String {
        switch self {
        case .requestApproval, .readOnly, .fullAccess:
            return "user"
        case .autoApprove:
            return Self.autoReviewer
        }
    }

    var sandboxMode: CodexAppServerSandboxMode {
        switch self {
        case .autoApprove:
            return .workspaceWrite
        case .requestApproval:
            return .workspaceWrite
        case .readOnly:
            return .readOnly
        case .fullAccess:
            return .dangerFullAccess
        }
    }

    func apply(to options: inout CodexAppServerTurnOptions) {
        options.approvalPolicy = approvalPolicy
        options.approvalsReviewer = approvalsReviewer
        options.sandboxMode = sandboxMode
        // 权限预设只开放“审批策略 + 本项目沙盒”这条安全通道；移动端仍不打开网络访问。
        options.networkAccess = false
    }

    private static let autoReviewer = "auto_review"
}

enum ComposerSendMode: String, CaseIterable, Identifiable {
    case standard
    case goal
    case plan

    var id: String { rawValue }
}

struct ComposerState {
    var draft = "" {
        didSet {
            hasNonWhitespaceDraft = Self.containsNonWhitespace(draft)
            if !hasNonWhitespaceDraft {
                voiceDraftNeedsReview = false
            }
        }
    }
    var attachments: [CodexAppServerUserInput] = []
    var turnOptions: CodexAppServerTurnOptions = .default
    var sendMode: ComposerSendMode = .standard
    private(set) var hasNonWhitespaceDraft = false
    private(set) var voiceDraftNeedsReview = false
    private var voiceDraftBase: String?
    private var voiceLastRenderedDraft: String?

    init(defaultPermissionMode: ComposerPermissionMode = .defaultMode) {
        defaultPermissionMode.apply(to: &turnOptions)
    }

    var isEmpty: Bool {
        !hasNonWhitespaceDraft && attachments.isEmpty
    }

    func canSubmit(isLoading: Bool) -> Bool {
        !isEmpty && !isLoading
    }

    var permissionMode: ComposerPermissionMode {
        ComposerPermissionMode(options: turnOptions)
    }

    mutating func applyPermissionMode(_ mode: ComposerPermissionMode) {
        mode.apply(to: &turnOptions)
    }

    var isGoalModeSelected: Bool {
        sendMode == .goal
    }

    var isPlanModeSelected: Bool {
        sendMode == .plan
    }

    mutating func toggleGoalMode() {
        // 目标是发送形态，不是立即动作；toggle 只改变下一次普通发送按钮的行为。
        sendMode = isGoalModeSelected ? .standard : .goal
    }

    mutating func togglePlanMode() {
        sendMode = isPlanModeSelected ? .standard : .plan
    }

    mutating func resetSendModeAfterSubmit() {
        resetTransientSendMode()
    }

    mutating func resetTransientSendMode() {
        // 目标/计划是下一次发送的临时模式，跟具体对话相关；切换 thread 时不能沿用到新对话。
        sendMode = .standard
    }

    mutating func takeDraftForSubmit(
        isLoading: Bool,
        turnOptionsOverride: CodexAppServerTurnOptions? = nil
    ) -> SubmittedComposerDraft? {
        guard canSubmit(isLoading: isLoading) else {
            return nil
        }
        let text = draft
        let sentAttachments = attachments
        let input = CodexAppServerTurnPayload.defaultInput(for: text) + sentAttachments
        let payload = CodexAppServerTurnPayload(input: input, options: turnOptionsOverride ?? turnOptions)
        let submittedVoiceDraftNeedsReview = voiceDraftNeedsReview
        draft = ""
        attachments = []
        voiceDraftNeedsReview = false
        voiceDraftBase = nil
        voiceLastRenderedDraft = nil
        return SubmittedComposerDraft(
            text: text,
            attachments: sentAttachments,
            payload: payload,
            voiceDraftNeedsReview: submittedVoiceDraftNeedsReview
        )
    }

    mutating func restore(_ text: String) {
        draft = text
        voiceDraftNeedsReview = false
    }

    mutating func restore(_ submitted: SubmittedComposerDraft) {
        draft = submitted.text
        attachments = submitted.attachments
        voiceDraftNeedsReview = submitted.voiceDraftNeedsReview
    }

    mutating func addAttachment(_ input: CodexAppServerUserInput) {
        attachments.append(input)
    }

    mutating func removeAttachment(id: CodexAppServerUserInput.ID) {
        attachments.removeAll { $0.id == id }
    }

    mutating func removeAttachment(at index: Int) {
        guard attachments.indices.contains(index) else {
            return
        }
        attachments.remove(at: index)
    }

    mutating func insertShortcut(_ text: String) {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = text
        } else {
            draft += "\n\(text)"
        }
    }

    mutating func beginVoiceInput() {
        voiceDraftBase = draft
        voiceLastRenderedDraft = draft
    }

    mutating func applyVoiceTranscript(_ transcript: String) {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }
        // 录音时用户仍可能键入文字或插入快捷短语；一旦发现草稿不是上一次语音写入的内容，
        // 就把当前草稿作为新的基底，避免下一段 partial transcript 回滚用户手动编辑。
        if let voiceLastRenderedDraft, draft != voiceLastRenderedDraft {
            voiceDraftBase = draft
        }
        let base = voiceDraftBase ?? draft
        if !Self.containsNonWhitespace(base) {
            draft = normalized
        } else {
            draft = base + "\n" + normalized
        }
        // 语音输入只是降低录入成本；一旦产生语音草稿，发送前仍要让用户明确审核。
        voiceDraftNeedsReview = true
        voiceLastRenderedDraft = draft
    }

    mutating func endVoiceInput() {
        voiceDraftBase = nil
        voiceLastRenderedDraft = nil
    }

    private static func containsNonWhitespace(_ text: String) -> Bool {
        // 输入热路径只需要知道“有没有有效字符”；逐字扫描可以在首个非空白处停止，
        // 避免每次按键都通过 trimmingCharacters 创建新字符串。
        text.unicodeScalars.contains { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }
}
