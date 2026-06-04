import Foundation

struct ComposerState {
    var draft = "" {
        didSet {
            hasNonWhitespaceDraft = Self.containsNonWhitespace(draft)
        }
    }
    var isExpanded = false
    private(set) var hasNonWhitespaceDraft = false

    var isEmpty: Bool {
        draft.isEmpty
    }

    func canSubmit(isLoading: Bool) -> Bool {
        hasNonWhitespaceDraft && !isLoading
    }

    mutating func takeDraftForSubmit(isLoading: Bool) -> String? {
        guard canSubmit(isLoading: isLoading) else {
            return nil
        }
        let text = draft
        draft = ""
        return text
    }

    mutating func restore(_ text: String) {
        draft = text
    }

    mutating func toggleExpanded() {
        isExpanded.toggle()
    }

    private static func containsNonWhitespace(_ text: String) -> Bool {
        // 输入热路径只需要知道“有没有有效字符”；逐字扫描可以在首个非空白处停止，
        // 避免每次按键都通过 trimmingCharacters 创建新字符串。
        text.unicodeScalars.contains { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }
}
