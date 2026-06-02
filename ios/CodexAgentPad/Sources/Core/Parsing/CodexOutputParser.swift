import Foundation

// 旧 TUI transcript 解析器：生产消息气泡由后端结构化 message_completed /
// assistant_delta 驱动；这个 parser 只作为旧协议 fallback 和测试样本保留。
struct CodexOutputParser {
    func latestAssistantBlock(from transcript: String) -> String {
        let lines = latestAssistantTailLines(from: transcript)
        guard !lines.isEmpty else {
            return ""
        }

        var parts: [String] = []
        for line in lines.prefix(18) {
            if parts.isEmpty == false && shouldStopAfterAssistantStart(line) {
                break
            }
            let cleaned = removeBulletPrefix(line)
            if cleaned.isEmpty {
                continue
            }
            if isTerminalChrome(cleaned) || isStatusLine(line) {
                break
            }
            parts.append(cleaned)
        }

        let rawText = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = AssistantTextNormalizer
            .collapseAdjacentRepeatedSentenceSegments(rawText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else {
            return ""
        }
        return String(text.prefix(4000))
    }

    private func latestAssistantTailLines(from transcript: String) -> [String] {
        var reversedTail: [String] = []
        for rawLine in transcript.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let line = normalizeLine(String(rawLine))
            guard !line.isEmpty else {
                continue
            }
            reversedTail.append(line)
            if isAssistantStartLine(line) {
                // 解析只需要最近 assistant 起点后的尾部窗口。像 Litter 的 streaming render cache
                // 一样复用“稳定前缀不参与热路径”的思路，避免每次流式刷新都规范化整段 transcript。
                return Array(reversedTail.reversed())
            }
        }
        return []
    }

    private func normalizeLine(_ line: String) -> String {
        let tableChars = CharacterSet(charactersIn: "╭╮╰╯│─┌┐└┘├┤┬┴┼")
        return line
            .components(separatedBy: tableChars)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func removeBulletPrefix(_ line: String) -> String {
        AssistantTextNormalizer.stripTerminalPromptFragment(line, dropPromptOnlyLine: false)
    }

    private func isAssistantStartLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("• ") || trimmed.hasPrefix("● ") else {
            return false
        }
        let content = removeBulletPrefix(trimmed)
        return !content.isEmpty &&
            !isTerminalChrome(content) &&
            !isStatusLine(trimmed) &&
            !isStatusLine(content) &&
            !isStatusFragment(content)
    }

    private func shouldStopAfterAssistantStart(_ line: String) -> Bool {
        if isTerminalChrome(line) || isStatusLine(line) || isStatusFragment(line) {
            return true
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("• ") || trimmed.hasPrefix("● ") {
            return true
        }
        return false
    }

    private func isTerminalChrome(_ line: String) -> Bool {
        let prefixes = ["›", ">", "model:", "directory:", "permissions:", "Run ", "Starting MCP", "Tip:", "[agentd]", "OpenAI Codex", "Under-development features enabled"]
        return prefixes.contains { line.hasPrefix($0) }
    }

    private func isStatusLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("esc to interrupt") ||
            trimmed.hasPrefix("Working") ||
            trimmed.hasPrefix("◦") ||
            trimmed.hasPrefix("⠋") ||
            trimmed.hasPrefix("⠙") ||
            trimmed.hasPrefix("⠹") ||
            trimmed.hasPrefix("⠸") ||
            trimmed.hasPrefix("⠼") ||
            trimmed.hasPrefix("⠴") ||
            trimmed.hasPrefix("⠦") ||
            trimmed.hasPrefix("⠧") ||
            trimmed.hasPrefix("⠇") ||
            trimmed.hasPrefix("⠏")
    }

    private func isStatusFragment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return true
        }
        // Codex TUI 会在答案后逐字符重绘 Working 状态，例如 W / Wo / Wor / • 6。
        if "Working".hasPrefix(trimmed) {
            return true
        }
        if trimmed.count <= 3, trimmed.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
            return true
        }
        return false
    }
}

enum AssistantTextNormalizer {
    static func normalizedAssistantTextForDedup(_ text: String) -> String {
        let cleaned = text.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { rawLine -> String? in
                let line = stripTerminalPromptFragment(String(rawLine))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else {
                    return nil
                }
                return line
            }
            .joined(separator: "\n")
        let collapsed = collapseAdjacentRepeatedSentenceSegments(cleaned)
        return collapsed
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    static func stripTerminalPromptFragment(_ line: String, dropPromptOnlyLine: Bool = true) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "• ") ?? trimmed.range(of: "● ") {
            trimmed = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Codex TUI 重绘时，用户输入行可能被拼到 assistant 行尾，例如：
        // "一个程序员去买菜。 ›Implement {feature}..."。对话气泡只保留回复正文。
        for marker in [" ›", " >Implement", " > Implement"] {
            if let range = trimmed.range(of: marker) {
                return String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if dropPromptOnlyLine, trimmed.hasPrefix("›") || trimmed.hasPrefix(">") {
            return ""
        }
        return trimmed
    }

    static func collapseAdjacentRepeatedSentenceSegments(_ text: String) -> String {
        let segments = sentenceSegments(from: text)
        guard segments.count > 1 else {
            return text
        }

        var collapsed: [String] = []
        var lastKey = ""
        var didDropDuplicate = false
        for segment in segments {
            let key = normalizedSegmentKey(segment)
            guard !key.isEmpty else {
                continue
            }
            if key == lastKey {
                didDropDuplicate = true
                continue
            }
            collapsed.append(segment)
            lastKey = key
        }

        guard didDropDuplicate else {
            return text
        }
        // 只在确认有连续重复时重排段落，避免正常多句回答被无谓改格式。
        return collapsed.joined(separator: "\n\n")
    }

    private static func sentenceSegments(from text: String) -> [String] {
        let chars = Array(text)
        guard !chars.isEmpty else {
            return []
        }

        let terminators = Set<Character>(["。", "！", "？", "!", "?"])
        let trailingPunctuation = Set<Character>(["。", "！", "？", "!", "?", "”", "’", "\"", "'", "）", ")", "]", "】", "」", "』"])
        var segments: [String] = []
        var start = 0
        var index = 0

        while index < chars.count {
            if terminators.contains(chars[index]) {
                var end = index + 1
                while end < chars.count, trailingPunctuation.contains(chars[end]) {
                    end += 1
                }
                while end < chars.count, isWhitespace(chars[end]) {
                    end += 1
                }
                appendSegment(chars[start..<end], to: &segments)
                start = end
                index = end
            } else {
                index += 1
            }
        }

        if start < chars.count {
            appendSegment(chars[start..<chars.count], to: &segments)
        }
        return segments
    }

    private static func appendSegment(_ slice: ArraySlice<Character>, to segments: inout [String]) {
        let segment = String(slice).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else {
            return
        }
        segments.append(segment)
    }

    private static func normalizedSegmentKey(_ segment: String) -> String {
        segment
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    private static func isWhitespace(_ char: Character) -> Bool {
        char.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}
