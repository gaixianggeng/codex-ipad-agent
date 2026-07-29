import SwiftUI

/// 会话管理 Sheet 使用单一枚举路由，避免重命名和 Review 各自维护布尔状态。
enum SessionActionPresentation: Identifiable {
    case rename(AgentSession)
    case review(AgentSession)

    var id: String {
        switch self {
        case .rename(let session):
            return "rename:\(session.id)"
        case .review(let session):
            return "review:\(session.id)"
        }
    }
}

/// 列表、项目侧栏和详情工具栏共用同一组会话动作。
///
/// 页面级的“刷新”和“显示详情”不属于会话自身能力，由各页面在此内容之后追加。
struct SessionActionMenuContent: View {
    @EnvironmentObject private var sessionStore: SessionStore

    let session: AgentSession
    @Binding var presentation: SessionActionPresentation?

    var body: some View {
        let isPinned = sessionStore.isSessionPinned(session.id)
        let isArchived = sessionStore.isSessionArchived(session.id)
        let reminder = sessionStore.sessionReminder(for: session.id)

        Group {
            if sessionStore.isSessionObserving(session),
               !sessionStore.isExternalReadOnlySession(session) {
                Button {
                    sessionStore.takeOverSession(session)
                } label: {
                    Label(L10n.text("ui.take_over_to_ipad"), systemImage: "hand.raised.fill")
                }
            }

            Button {
                sessionStore.toggleSessionPinned(session)
            } label: {
                Label(
                    isPinned ? L10n.text("ui.unpin") : L10n.text("ui.pin_to_top"),
                    systemImage: isPinned ? "pin.slash" : "pin"
                )
            }

            if sessionStore.supportsCodexThreadManagement(session) {
                Divider()

                Button {
                    presentation = .rename(session)
                } label: {
                    Label(L10n.text("ui.rename"), systemImage: "pencil")
                }

                Button {
                    Task { await sessionStore.duplicateSessionInCurrentWorkspace(session) }
                } label: {
                    Label(L10n.text("ui.duplicate_session"), systemImage: "doc.on.doc")
                }
                .disabled(
                    session.isRunning || sessionStore.duplicatingSessionIDs.contains(session.id)
                )

                Button {
                    Task { await sessionStore.compactSessionContext(session) }
                } label: {
                    Label(
                        L10n.text("ui.compression_context"),
                        systemImage: "arrow.down.right.and.arrow.up.left"
                    )
                }
                .disabled(session.isRunning)

                Button {
                    presentation = .review(session)
                } label: {
                    Label(L10n.text("ui.start_code_review"), systemImage: "checklist.checked")
                }
                .disabled(session.isRunning)
            }

            Divider()

            Button {
                Task { await sessionStore.handoffSessionToWorktree(session) }
            } label: {
                Label(
                    L10n.text("ui.go_to_the_new_git_worktree"),
                    systemImage: "arrow.triangle.branch"
                )
            }
            .disabled(session.isRunning || sessionStore.isCreatingWorktree)

            Menu {
                Button {
                    Task { await sessionStore.scheduleSessionReminder(session, after: 30 * 60) }
                } label: {
                    Label(L10n.text("ui.30_minutes_later"), systemImage: "timer")
                }
                Button {
                    Task { await sessionStore.scheduleSessionReminder(session, after: 2 * 60 * 60) }
                } label: {
                    Label(L10n.text("ui.2_hours_later"), systemImage: "clock")
                }
                Button {
                    Task { await sessionStore.scheduleSessionReminder(session, after: 24 * 60 * 60) }
                } label: {
                    Label(L10n.text("ui.tomorrow"), systemImage: "calendar")
                }
                if reminder != nil {
                    Button(role: .destructive) {
                        sessionStore.clearSessionReminder(session)
                    } label: {
                        Label(L10n.text("ui.clear_reminder"), systemImage: "bell.slash")
                    }
                }
            } label: {
                Label(
                    L10n.text("ui.reminder"),
                    systemImage: reminder == nil ? "bell" : "bell.fill"
                )
            }

            Button(role: isArchived ? nil : .destructive) {
                Task { await sessionStore.toggleSessionArchivedRemote(session) }
            } label: {
                Label(
                    isArchived ? L10n.text("ui.unarchive") : L10n.text("ui.archive"),
                    systemImage: isArchived ? "archivebox.fill" : "archivebox"
                )
            }
            .disabled(sessionStore.isExternalReadOnlySession(session))
        }
    }
}

private struct SessionActionSheetsModifier: ViewModifier {
    @Binding var presentation: SessionActionPresentation?

    func body(content: Content) -> some View {
        content.sheet(item: $presentation) { destination in
            switch destination {
            case .rename(let session):
                SessionRenameSheet(session: session)
            case .review(let session):
                SessionReviewSheet(session: session)
            }
        }
    }
}

private struct SessionActionsContextMenuModifier: ViewModifier {
    @State private var presentation: SessionActionPresentation?
    let session: AgentSession

    func body(content: Content) -> some View {
        content
            .contextMenu {
                SessionActionMenuContent(
                    session: session,
                    presentation: $presentation
                )
            }
            .sessionActionSheets(presentation: $presentation)
    }
}

extension View {
    func sessionActionSheets(
        presentation: Binding<SessionActionPresentation?>
    ) -> some View {
        modifier(SessionActionSheetsModifier(presentation: presentation))
    }

    func sessionRowActions(_ session: AgentSession) -> some View {
        modifier(SessionActionsContextMenuModifier(session: session))
    }
}
