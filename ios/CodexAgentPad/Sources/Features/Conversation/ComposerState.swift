import Foundation

struct SubmittedComposerDraft {
    let text: String
    let attachments: [CodexAppServerUserInput]
    let payload: CodexAppServerTurnPayload
}

struct ComposerState {
    var draft = "" {
        didSet {
            hasNonWhitespaceDraft = Self.containsNonWhitespace(draft)
        }
    }
    var isExpanded = false
    var attachments: [CodexAppServerUserInput] = []
    var turnOptions: CodexAppServerTurnOptions = .default
    private(set) var hasNonWhitespaceDraft = false
    private var voiceDraftBase: String?
    private var voiceLastRenderedDraft: String?

    var isEmpty: Bool {
        !hasNonWhitespaceDraft && attachments.isEmpty
    }

    func canSubmit(isLoading: Bool) -> Bool {
        !isEmpty && !isLoading
    }

    mutating func takeDraftForSubmit(isLoading: Bool) -> SubmittedComposerDraft? {
        guard canSubmit(isLoading: isLoading) else {
            return nil
        }
        let text = draft
        let sentAttachments = attachments
        let input = CodexAppServerTurnPayload.defaultInput(for: text) + sentAttachments
        let payload = CodexAppServerTurnPayload(input: input, options: turnOptions)
        draft = ""
        attachments = []
        voiceDraftBase = nil
        voiceLastRenderedDraft = nil
        return SubmittedComposerDraft(text: text, attachments: sentAttachments, payload: payload)
    }

    mutating func restore(_ text: String) {
        draft = text
    }

    mutating func restore(_ submitted: SubmittedComposerDraft) {
        draft = submitted.text
        attachments = submitted.attachments
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

    mutating func toggleExpanded() {
        isExpanded.toggle()
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
        if base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = normalized
        } else {
            draft = base + "\n" + normalized
        }
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
