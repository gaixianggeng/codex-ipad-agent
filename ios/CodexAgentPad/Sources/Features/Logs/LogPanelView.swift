import SwiftUI

struct LogPanelView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var logStore: LogStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("日志")
                        .font(.subheadline.weight(.semibold))
                    Text(sessionStore.selectedSessionID ?? "未选择会话")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Toggle("自动滚动", isOn: $logStore.autoScroll)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("自动滚动")
            }
            .padding(10)
            Divider()
            logContent
        }
        .background(Color(.systemBackground))
        .foregroundStyle(.primary)
    }

    private var logContent: some View {
        let log = logStore.log(for: sessionStore.selectedSessionID)
        return ScrollViewReader { proxy in
            ScrollView {
                Text(log.isEmpty ? "暂无终端输出" : log)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(log.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
                    .textSelection(.enabled)
                Color.clear
                    .frame(height: 1)
                    .id("bottom")
            }
            .onChange(of: log) { _, _ in
                guard logStore.autoScroll else {
                    return
                }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}
