import SwiftUI

struct LogPanelView: View {
    var body: some View {
        LogTailView()
    }
}

struct LogTailView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var logStore: LogStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(themeStore.uiFont(.callout, weight: .semibold))
                    .foregroundStyle(tokens.secondaryText)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text("日志")
                        .font(themeStore.uiFont(.subheadline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(sessionSubtitle)
                        .font(themeStore.codeFont(.caption2))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(1)

                Spacer()

                Toggle("自动滚动", isOn: $logStore.autoScroll)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("自动滚动")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Rectangle()
                .fill(tokens.border)
                .frame(height: 1)

            logContent
        }
        .background(tokens.surface)
        .foregroundStyle(tokens.primaryText)
    }

    private var logContent: some View {
        // 行已在 LogStore 后台算好，这里只读缓存，body 不再做重活。
        let lines = logStore.lines(for: sessionStore.selectedSessionID)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if lines.isEmpty {
                        ContentUnavailableView(
                            "暂无日志",
                            systemImage: "terminal",
                            description: Text("当前会话还没有终端输出。")
                        )
                        .font(themeStore.uiFont(.caption))
                        .padding(.top, 48)
                    } else {
                        ForEach(lines) { line in
                            LogLineRow(line: line)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(8)
            }
            .background(themeStore.tokens(for: colorScheme).background)
            .onChange(of: lines.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: lines.last?.text) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard logStore.autoScroll else {
            return
        }
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    private var sessionSubtitle: String {
        return sessionStore.selectedSessionID ?? "未选择会话"
    }
}

struct LogDisplayLine: Identifiable, Hashable {
    enum Kind: Hashable {
        case command
        case assistant
        case system
        case warning
        case plain

        var symbolName: String {
            switch self {
            case .command:
                return "chevron.right"
            case .assistant:
                return "text.bubble"
            case .system:
                return "gearshape"
            case .warning:
                return "exclamationmark.triangle"
            case .plain:
                return "terminal"
            }
        }
    }

    let id: Int
    let text: String
    let kind: Kind
}

struct LogPanelFormatter {
    private let maxRenderedLogLines = 360

    func renderedLines(from log: String, startLineID: Int = 0) -> [LogDisplayLine] {
        guard !log.isEmpty else {
            return []
        }

        // 只渲染最新的可见行，同时把日志重绘产生的大量空行和边框压掉。
        let normalizedLines = log
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { normalizeTerminalLine(String($0)) }

        var result: [LogDisplayLine] = []
        var lastKey = ""
        for (rawIndex, rawLine) in normalizedLines.enumerated() {
            guard let line = makeDisplayLine(from: rawLine, id: startLineID + rawIndex) else {
                continue
            }
            // 按归一化后的语义文本去重：日志重绘常常只差尾部输入框占位符或空白，
            // 原来的“严格相邻相等”挡不住，这里用压缩后的 key 把这些近似重复行合并掉。
            let dedupKey = dedupKey(for: line)
            let effectiveKey = dedupKey.isEmpty ? line.text : dedupKey
            guard effectiveKey != lastKey else {
                continue
            }
            result.append(line)
            lastKey = effectiveKey
        }
        return Array(result.suffix(maxRenderedLogLines))
    }

    private func makeDisplayLine(from line: String, id: Int) -> LogDisplayLine? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isNoiseLine(trimmed) else {
            return nil
        }

        if trimmed.hasPrefix("[agentd] warning") || trimmed.hasPrefix("warning:") {
            return LogDisplayLine(id: id, text: trimmed, kind: .warning)
        }
        if trimmed.hasPrefix("[agentd]") {
            return LogDisplayLine(id: id, text: trimmed, kind: .system)
        }
        if trimmed.hasPrefix("›") || trimmed.hasPrefix(">") {
            return LogDisplayLine(id: id, text: stripPromptPrefix(trimmed), kind: .command)
        }
        if trimmed.hasPrefix("•") || trimmed.hasPrefix("●") {
            return LogDisplayLine(id: id, text: cleanAssistantText(stripBulletPrefix(trimmed)), kind: .assistant)
        }
        // 普通日志行只做“无损”的重复句子折叠，绝不按 prompt 片段截断，
        // 否则像 "Home › Settings"、"note: > Implement later"、"data: • item" 这类正常输出会被误伤。
        return LogDisplayLine(id: id, text: collapseRepeatedSentences(trimmed), kind: .plain)
    }

    private func dedupKey(for line: LogDisplayLine) -> String {
        switch line.kind {
        case .assistant:
            // assistant/bullet 行是 prompt 残片的高发区，按剥离 prompt 片段后的语义文本去重。
            return AssistantTextNormalizer.normalizedAssistantTextForDedup(line.text)
        default:
            // 其余行（plain/command/system…）只折叠重复句子 + 去空白，不截断含 "›"/">" 的正常内容。
            return AssistantTextNormalizer.plainDedupKey(line.text)
        }
    }

    private func cleanAssistantText(_ text: String) -> String {
        // assistant 气泡行：1) 去掉被日志重绘拼到行尾的输入框占位符（"… ›Implement {feature} …"）；
        // 2) 合并同一行里被重画两遍的句子。失败时回退原文，避免把正常内容清空。
        let stripped = AssistantTextNormalizer.stripTerminalPromptFragment(text, dropPromptOnlyLine: false)
        let collapsed = AssistantTextNormalizer
            .collapseAdjacentRepeatedSentenceSegments(stripped)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? text : collapsed
    }

    private func collapseRepeatedSentences(_ text: String) -> String {
        let collapsed = AssistantTextNormalizer
            .collapseAdjacentRepeatedSentenceSegments(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? text : collapsed
    }

    private func normalizeTerminalLine(_ line: String) -> String {
        let tableChars = CharacterSet(charactersIn: "╭╮╰╯│─┌┐└┘├┤┬┴┼")
        let withoutChrome = line
            .components(separatedBy: tableChars)
            .joined(separator: " ")
        return withoutChrome
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripPromptPrefix(_ line: String) -> String {
        String(line.drop { $0 == "›" || $0 == ">" || $0 == " " })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripBulletPrefix(_ line: String) -> String {
        String(line.drop { $0 == "•" || $0 == "●" || $0 == " " })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isNoiseLine(_ line: String) -> Bool {
        if line == "Working" || line == "thinking" || line == "esc to interrupt" {
            return true
        }
        // 流式日志重绘会留下 W/Wo/Wor 这类半截状态，日志面板里直接过滤。
        if "Working".hasPrefix(line), line.count <= 6 {
            return true
        }
        if line.count <= 2, line.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
            return true
        }
        return false
    }
}

private struct LogLineRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let line: LogDisplayLine

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(alignment: .top, spacing: 7) {
            Image(systemName: line.kind.symbolName)
                .font(themeStore.uiFont(.caption2, weight: .semibold))
                .foregroundStyle(rowTint(tokens: tokens))
                .frame(width: 13, height: 16)
                .padding(.top, 1)

            Text(line.text)
                .font(themeStore.codeFont(size: 11))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(3)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(tokens: tokens))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(rowBorder(tokens: tokens), lineWidth: 1)
        }
    }

    private func rowTint(tokens: ThemeTokens) -> Color {
        switch line.kind {
        case .command:
            return tokens.accent
        case .assistant:
            return tokens.success
        case .system, .warning:
            return tokens.warning
        case .plain:
            return tokens.secondaryText
        }
    }

    private func rowBackground(tokens: ThemeTokens) -> Color {
        switch line.kind {
        case .command:
            return tokens.accent.opacity(0.10)
        case .assistant:
            return tokens.success.opacity(0.08)
        case .system:
            return tokens.warning.opacity(0.10)
        case .warning:
            return tokens.warning.opacity(0.12)
        case .plain:
            return tokens.elevatedSurface
        }
    }

    private func rowBorder(tokens: ThemeTokens) -> Color {
        switch line.kind {
        case .command:
            return tokens.accent.opacity(0.18)
        case .assistant:
            return tokens.success.opacity(0.16)
        case .system, .warning:
            return tokens.warning.opacity(0.20)
        case .plain:
            return tokens.border.opacity(0.65)
        }
    }
}
