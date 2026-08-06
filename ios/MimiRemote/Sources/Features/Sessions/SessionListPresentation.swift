import Foundation

/// 历史会话列表使用的日期桶。`displayOrder` 是稳定的 UI 顺序，调用方不需要依赖枚举声明顺序。
enum SessionHistoryDateBucket: CaseIterable, Equatable, Hashable, Sendable {
    case today
    case yesterday
    case thisWeek
    case thisMonth
    case earlier

    /// 分区卡片按“近到远”展示；空桶由分组 helper 过滤掉。
    static let displayOrder: [SessionHistoryDateBucket] = [
        .today,
        .yesterday,
        .thisWeek,
        .thisMonth,
        .earlier,
    ]

    static var allCases: [SessionHistoryDateBucket] { displayOrder }
}

/// 一个非空日期分组。会话顺序由输入决定，不在这里按时间二次排序。
struct SessionHistoryDateGroup: Equatable, Hashable, Identifiable {
    let bucket: SessionHistoryDateBucket
    let sessions: [AgentSession]

    var id: SessionHistoryDateBucket { bucket }
}

/// 会话列表需要的纯展示计算，避免 SwiftUI View 同时承担日期和字符串规则。
enum SessionListPresentation {
    /// 按历史时间将会话放入固定日期桶；空桶不返回，桶内保持输入顺序。
    static func historyGroups(
        _ sessions: [AgentSession],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [SessionHistoryDateGroup] {
        var sessionsByBucket: [SessionHistoryDateBucket: [AgentSession]] = [:]

        for session in sessions {
            let bucket = dateBucket(for: session, now: now, calendar: calendar)
            sessionsByBucket[bucket, default: []].append(session)
        }

        // 遍历固定顺序而不是字典顺序，确保分区卡片不会随进程或哈希种子变化。
        return SessionHistoryDateBucket.displayOrder.compactMap { bucket in
            guard let sessions = sessionsByBucket[bucket], !sessions.isEmpty else { return nil }
            return SessionHistoryDateGroup(bucket: bucket, sessions: sessions)
        }
    }

    /// 具名参数入口，便于 View 将“历史会话”语义与其他会话数组区分开。
    static func historyDateGroups(
        sessions: [AgentSession],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [SessionHistoryDateGroup] {
        historyGroups(sessions, now: now, calendar: calendar)
    }

    /// 公开日期判定入口；显式传入 now 和 Calendar，按 Calendar 的本地时区处理跨午夜和周/月边界。
    static func dateBucket(
        for session: AgentSession,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> SessionHistoryDateBucket {
        dateBucket(for: session.recencyAt ?? session.updatedAt ?? session.createdAt, now: now, calendar: calendar)
    }

    /// 无会话模型时的日期判定入口；缺失日期按 earlier 保留，避免历史结果被丢弃。
    static func dateBucket(
        for date: Date?,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> SessionHistoryDateBucket {
        guard let date else { return .earlier }

        // Calendar 的时区决定“本地日”；先判今天和昨天，防止“同一周/同一月”吞掉更具体的分组。
        if calendar.isDate(date, inSameDayAs: now) {
            return .today
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }

        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return .thisWeek
        }

        if calendar.isDate(date, equalTo: now, toGranularity: .month) {
            return .thisMonth
        }

        return .earlier
    }

    /// 将标题转成列表中的单行文本；只生成副本，不修改 AgentSession.title。
    static func displayTitle(_ title: String) -> String {
        let normalizedLineEndings = title.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // 行首 Markdown 标记需要在压平换行前处理，否则第二行会失去“行首”语义。
        let strippedLinePrefixes = normalizedLineEndings
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripLeadingMarkdown(from: String($0)) }
            .joined(separator: " ")

        // 列表仅展示标题文本：成对粗体/下划线标记和反引号不应出现在卡片标题中。
        let withoutInlineMarks = strippedLinePrefixes
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")

        // `isWhitespace` 同时覆盖空格、Tab 和不同换行形式，统一成一个可扫读的间隔。
        return withoutInlineMarks
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// 直接从会话读取标题，便于列表调用方避免接触原始字段。
    static func displayTitle(for session: AgentSession) -> String {
        displayTitle(session.title)
    }

    /// SessionListView 的命名入口；保留 displayTitle 作为更通用的字符串 helper。
    static func titleDisplayText(for session: AgentSession) -> String {
        displayTitle(for: session)
    }

    /// 优先展示 dir 的末段；dir 为空时回退 project。路径无法拆出末段时返回原选择值。
    static func directoryTail(for session: AgentSession) -> String {
        let normalizedDir = session.dir.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProject = session.project.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferred = normalizedDir.isEmpty ? normalizedProject : normalizedDir
        let withoutTrailingSlashes = preferred.replacingOccurrences(
            of: "/+$",
            with: "",
            options: .regularExpression
        )

        guard !withoutTrailingSlashes.isEmpty,
              let lastComponent = withoutTrailingSlashes
                .split(separator: "/", omittingEmptySubsequences: true)
                .last,
              !lastComponent.isEmpty else {
            // 例如 "/" 或空字符串没有可提取的 component，原值是稳定且可解释的 fallback。
            return preferred
        }

        return String(lastComponent)
    }

    /// SessionListView 的命名入口；不改变原始 dir/project 字段。
    static func directoryDisplayText(for session: AgentSession) -> String {
        directoryTail(for: session)
    }

    private static func stripLeadingMarkdown(from line: String) -> String {
        var result = line

        // 允许引用、标题、列表标记嵌套在一起；循环只处理行首，正文中的符号保持不变。
        while let range = result.range(
            of: #"^\s*(?:(?:#{1,6}\s*)|(?:>\s*)|(?:[-*+]\s+)|(?:\d+[.)]\s+))"#,
            options: .regularExpression
        ) {
            let stripped = String(result[range.upperBound...])
            guard stripped != result else { break }
            result = stripped
        }

        return result
    }
}
