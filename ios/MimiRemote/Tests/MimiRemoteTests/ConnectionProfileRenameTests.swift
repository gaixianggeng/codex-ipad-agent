import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

@MainActor
final class ConnectionProfileRenameTests: XCTestCase {
    func testPresentationKeepsOneRouteUntilExplicitDismissal() {
        let first = makeProfile(id: "mac-a", displayName: "Mac A")
        let second = makeProfile(id: "mac-b", displayName: "Mac B")
        var presentation = ConnectionProfileRenamePresentationState()

        presentation.present(first)
        XCTAssertEqual(
            presentation.route,
            ConnectionProfileRenameRoute(profile: first)
        )

        presentation.present(second)
        XCTAssertEqual(presentation.route?.profileID, first.id, "已有 Sheet 时不能替换其编辑目标")

        presentation.dismiss()
        XCTAssertNil(presentation.route)
        presentation.present(second)
        XCTAssertEqual(presentation.route?.profileID, second.id)
    }

    func testMarkedTextEditingChangedImmediatelyUpdatesDraftValidation() {
        let box = RenameDraftBox(ConnectionProfileRenameDraft(displayName: ""))
        let field = ConnectionProfileNameTextField(
            placeholder: "电脑名称",
            text: Binding(
                get: { box.draft.displayName },
                set: { box.draft.updateDisplayName($0) }
            ),
            onSubmit: {}
        )
        let coordinator = ConnectionProfileNameTextField.Coordinator(field)
        let textField = MarkedTextField()
        textField.text = "win"

        XCTAssertNotNil(textField.markedTextRange, "用例必须模拟输入法尚未提交的可见文本")
        coordinator.textDidChange(textField)

        XCTAssertEqual(box.draft.displayName, "win")
        XCTAssertNil(box.draft.validationMessage)
        XCTAssertTrue(box.draft.canSubmit)
    }

    func testDraftValidationTracksEmptyValidAndTooLongNames() {
        var draft = ConnectionProfileRenameDraft(displayName: "旧名称")
        XCTAssertTrue(draft.canSubmit)

        draft.updateDisplayName("   \n")
        XCTAssertEqual(
            draft.validationMessage,
            ConnectionProfileError.invalidDisplayName.localizedDescription
        )
        XCTAssertFalse(draft.canSubmit)

        draft.updateDisplayName("win")
        XCTAssertNil(draft.validationMessage)
        XCTAssertTrue(draft.canSubmit)

        draft.updateDisplayName(String(repeating: "a", count: AppStore.connectionProfileDisplayNameLimit + 1))
        XCTAssertEqual(
            draft.validationMessage,
            ConnectionProfileError.displayNameTooLong(
                maximum: AppStore.connectionProfileDisplayNameLimit
            ).localizedDescription
        )
        XCTAssertFalse(draft.canSubmit)
    }

    func testSaveAndCancelActionsControlDismissalWithoutCrossWriting() {
        var draft = ConnectionProfileRenameDraft(displayName: "新 Mac")
        var savedNames: [String] = []

        XCTAssertTrue(draft.perform(.cancel) { savedNames.append($0) })
        XCTAssertTrue(savedNames.isEmpty, "取消不能修改原名称")

        XCTAssertTrue(draft.perform(.save) { savedNames.append($0) })
        XCTAssertEqual(savedNames, ["新 Mac"])

        draft.updateDisplayName("   ")
        XCTAssertFalse(draft.perform(.save) { savedNames.append($0) })
        XCTAssertEqual(savedNames, ["新 Mac"], "无效名称不能进入保存回调")
    }

    func testSaveFailureKeepsDraftAndEditingClearsError() {
        var draft = ConnectionProfileRenameDraft(displayName: "仍需保留")

        XCTAssertFalse(draft.perform(.save) { _ in throw RenameFailure() })
        XCTAssertEqual(draft.displayName, "仍需保留")
        XCTAssertEqual(draft.submitError, "保存失败")

        draft.updateDisplayName("继续编辑")
        XCTAssertNil(draft.submitError)
        XCTAssertEqual(draft.displayName, "继续编辑")
    }

    private func makeProfile(id: String, displayName: String) -> ConnectionProfile {
        ConnectionProfile(
            id: id,
            displayName: displayName,
            endpoint: "http://100.64.0.10:8787",
            lastSuccessfulAt: nil
        )
    }
}

private final class RenameDraftBox {
    var draft: ConnectionProfileRenameDraft

    init(_ draft: ConnectionProfileRenameDraft) {
        self.draft = draft
    }
}

private struct RenameFailure: LocalizedError {
    var errorDescription: String? { "保存失败" }
}

private final class MarkedTextField: UITextField {
    private let simulatedMarkedTextRange = SimulatedTextRange()

    override var markedTextRange: UITextRange? {
        simulatedMarkedTextRange
    }
}

private final class SimulatedTextPosition: UITextPosition {}

private final class SimulatedTextRange: UITextRange {
    private let lowerBound = SimulatedTextPosition()
    private let upperBound = SimulatedTextPosition()

    override var start: UITextPosition { lowerBound }
    override var end: UITextPosition { upperBound }
    override var isEmpty: Bool { false }
}
