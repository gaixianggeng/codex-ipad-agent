import Foundation

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

        let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "• ") ?? trimmed.range(of: "● ") {
            return String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
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
