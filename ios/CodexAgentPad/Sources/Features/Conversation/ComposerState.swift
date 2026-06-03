import Foundation

struct ComposerState {
    var draft = ""
    var isExpanded = false

    var isEmpty: Bool {
        draft.isEmpty
    }

    func canSubmit(isLoading: Bool) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
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
}
