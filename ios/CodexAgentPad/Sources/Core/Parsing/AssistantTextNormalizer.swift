import Foundation

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

    /// 仅折叠相邻重复句子 + 去空白，不做 prompt 片段截断。
    /// 用于普通日志文本去重：含 "›"/">"/"•" 的正常输出不会被误判成 prompt 残片。
    static func plainDedupKey(_ text: String) -> String {
        collapseAdjacentRepeatedSentenceSegments(text)
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    static func stripTerminalPromptFragment(_ line: String, dropPromptOnlyLine: Bool = true) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "• ") ?? trimmed.range(of: "● ") {
            trimmed = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 历史或日志中可能混入 prompt 重绘片段，去重键只保留正文。
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
