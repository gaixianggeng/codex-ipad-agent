import Foundation

struct CodexOutputParser {
    func latestAssistantBlock(from transcript: String) -> String {
        let lines = transcript
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { normalizeLine(String($0)) }
            .filter { !$0.isEmpty }

        guard let start = lines.lastIndex(where: { $0.contains("• ") || $0.contains("● ") }) else {
            return ""
        }

        var parts: [String] = []
        for line in lines[start..<min(lines.count, start + 18)] {
            let cleaned = removeBulletPrefix(line)
            if cleaned.isEmpty {
                continue
            }
            if isTerminalChrome(cleaned) {
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

    private func normalizeLine(_ line: String) -> String {
        let tableChars = CharacterSet(charactersIn: "╭╮╰╯│─┌┐└┘├┤┬┴┼")
        return line
            .components(separatedBy: tableChars)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func removeBulletPrefix(_ line: String) -> String {
        if let range = line.range(of: "• ") ?? line.range(of: "● ") {
            return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isTerminalChrome(_ line: String) -> Bool {
        let prefixes = ["›", ">", "model:", "directory:", "permissions:", "Run ", "Starting MCP", "Tip:", "[agentd]", "OpenAI Codex", "Under-development features enabled"]
        return prefixes.contains { line.hasPrefix($0) }
    }
}
