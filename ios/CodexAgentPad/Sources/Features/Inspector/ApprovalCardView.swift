import SwiftUI

struct ApprovalCardView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var conversationStore: ConversationStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let approval = sessionStore.selectedSession?.pendingApproval {
                    PendingApprovalCard(
                        approval: approval,
                        onApprove: { sessionStore.decideApproval(approval, accept: true) },
                        onDecline: { sessionStore.decideApproval(approval, accept: false) }
                    )
                }

                ForEach(approvalMessages) { message in
                    InspectorSummaryCard(
                        symbolName: "checkmark.seal",
                        title: "审批记录",
                        subtitle: message.content,
                        tint: .orange
                    )
                }

                if sessionStore.selectedSession?.pendingApproval == nil && approvalMessages.isEmpty {
                    ContentUnavailableView("暂无审批", systemImage: "checkmark.seal")
                        .font(.caption)
                        .padding(.top, 48)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var approvalMessages: [ConversationMessage] {
        Array(
            conversationStore
                .messages(for: sessionStore.selectedSessionID)
                .filter { $0.kind == .approval }
                .suffix(20)
        )
    }
}

private struct PendingApprovalCard: View {
    let approval: ApprovalSummary
    let onApprove: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                Text(approval.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Text(approval.kind)
                if let count = approval.count {
                    Text("\(count) 项")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(action: onDecline) {
                    Label("拒绝", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)

                Button(action: onApprove) {
                    Label("批准", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        }
    }
}
