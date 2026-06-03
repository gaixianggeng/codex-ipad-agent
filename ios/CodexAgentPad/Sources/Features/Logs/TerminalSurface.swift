import SwiftUI
import SwiftTerm

struct TerminalSize: Equatable {
    let cols: Int
    let rows: Int
}

// 方向 A：日志面板改成「忠实终端」。
// 用 SwiftTerm 的 VT100/ANSI 模拟器渲染 codex TUI 的真实屏幕，光标重绘/半截字都由模拟器
// 正确处理，不再靠 per-line 字符串清洗去猜——后者面对 TUI 重绘排列组合永远是打地鼠。
//
// 数据来源仍是 WS 的原始 PTY 字节（output 事件，含 ANSI 转义）。对话气泡走结构化
// message_completed，与这里互不影响。

/// 只读终端视图：允许滚动查看 scrollback，但不接管键盘（输入仍由 ComposerView 负责）。
final class ReadOnlyTerminalView: SwiftTerm.TerminalView {
    /// 视图按字体/尺寸自动算出的列数/行数变化时回调，用来把 PTY resize 到面板宽度，
    /// 否则 120 列的内容塞进窄面板会错位换行。
    var onSizeChange: ((Int, Int) -> Void)?
    private var lastReportedCols = 0
    private var lastReportedRows = 0

    override var canBecomeFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }

    override func layoutSubviews() {
        super.layoutSubviews()
        let terminal = getTerminal()
        let cols = terminal.cols
        let rows = terminal.rows
        guard cols > 0, rows > 0, cols != lastReportedCols || rows != lastReportedRows else {
            return
        }
        lastReportedCols = cols
        lastReportedRows = rows
        onSizeChange?(cols, rows)
    }
}

/// 持有每个会话的终端视图与字节水位。视图持久存在于 Store（不随 SwiftUI 重建丢状态），
/// 输出到达时持续喂入；面板只展示当前选中会话的那一个。
@MainActor
final class TerminalSurfaceStore: ObservableObject {
    static let retainedSessionLimit = 6

    /// (sessionID, cols, rows) —— 终端尺寸变化时通知外部把 PTY resize 过去。
    var onResize: ((String, Int, Int) -> Void)?

    private var viewsBySessionID: [String: ReadOnlyTerminalView] = [:]
    private var lastSeqBySessionID: [String: EventSequence] = [:]
    private var recentlyUsed: [String] = []

    private let font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    func view(for sessionID: String) -> ReadOnlyTerminalView {
        if let existing = viewsBySessionID[sessionID] {
            touch(sessionID)
            return existing
        }
        let view = ReadOnlyTerminalView(frame: .zero, font: font)
        view.backgroundColor = .clear
        view.onSizeChange = { [weak self] cols, rows in
            self?.onResize?(sessionID, cols, rows)
        }
        viewsBySessionID[sessionID] = view
        touch(sessionID)
        trimIfNeeded()
        return view
    }

    /// 喂入一段原始 PTY 字节（含 ANSI 转义）。seq 单调去重，避免重连 replay 重复喂入。
    func feed(_ text: String, sessionID: String, seq: EventSequence?) {
        guard !text.isEmpty else {
            return
        }
        if let seq {
            if let last = lastSeqBySessionID[sessionID], seq <= last {
                return
            }
            lastSeqBySessionID[sessionID] = seq
        }
        let view = view(for: sessionID)
        view.feed(byteArray: Array(text.utf8)[...])
    }

    func reset(sessionID: String) {
        lastSeqBySessionID.removeValue(forKey: sessionID)
        if let view = viewsBySessionID[sessionID] {
            // ESC c：硬复位，清掉旧屏幕，避免切换/重连后旧帧残留。
            view.feed(byteArray: Array("\u{1b}c".utf8)[...])
        }
    }

    private func touch(_ sessionID: String) {
        recentlyUsed.removeAll { $0 == sessionID }
        recentlyUsed.append(sessionID)
    }

    private func trimIfNeeded() {
        while recentlyUsed.count > Self.retainedSessionLimit {
            let evict = recentlyUsed.removeFirst()
            viewsBySessionID.removeValue(forKey: evict)
            lastSeqBySessionID.removeValue(forKey: evict)
        }
    }
}

/// 把 Store 里当前会话的终端视图嵌进 SwiftUI。视图本体由 Store 持有，这里只做挂载/切换。
private struct TerminalSurfaceView: UIViewRepresentable {
    @EnvironmentObject private var terminalStore: TerminalSurfaceStore
    let sessionID: String

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        mount(in: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        mount(in: container)
    }

    private func mount(in container: UIView) {
        let terminal = terminalStore.view(for: sessionID)
        if terminal.superview === container {
            return
        }
        container.subviews.forEach { $0.removeFromSuperview() }
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }
}

/// 右侧「终端」面板：表头 + 终端视图。替代旧的启发式日志面板。
struct TerminalPanelView: View {
    @EnvironmentObject private var sessionStore: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text("终端")
                        .font(.subheadline.weight(.semibold))
                    Text(sessionStore.selectedSessionID ?? "未选择会话")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if let sessionID = sessionStore.selectedSessionID {
                TerminalSurfaceView(sessionID: sessionID)
                    .id(sessionID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "暂无终端",
                    systemImage: "terminal",
                    description: Text("选择一个会话后显示其实时终端。")
                )
                .font(.caption)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(.secondarySystemBackground))
    }
}
