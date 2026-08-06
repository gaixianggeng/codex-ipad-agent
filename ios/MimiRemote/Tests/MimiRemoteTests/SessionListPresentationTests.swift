import Foundation
import SwiftUI
import XCTest
@testable import MimiRemote

final class SessionListPresentationTests: XCTestCase {
    func testDateBucketsPreferTodayAndYesterdayAtLocalMidnight() {
        let calendar = makeCalendar(timeZone: "Asia/Shanghai")
        let now = makeDate(calendar, year: 2025, month: 6, day: 2, hour: 0, minute: 15)

        XCTAssertEqual(
            SessionListPresentation.dateBucket(
                for: makeDate(calendar, year: 2025, month: 6, day: 2, hour: 0, minute: 1),
                now: now,
                calendar: calendar
            ),
            .today
        )
        XCTAssertEqual(
            SessionListPresentation.dateBucket(
                for: makeDate(calendar, year: 2025, month: 6, day: 1, hour: 23, minute: 59),
                now: now,
                calendar: calendar
            ),
            .yesterday
        )
    }

    func testDateBucketsRespectWeekMonthBoundariesAndExplicitTimeZone() {
        var calendar = makeCalendar(timeZone: "America/Los_Angeles")
        calendar.firstWeekday = 2 // Monday, independent of the machine locale.
        calendar.minimumDaysInFirstWeek = 1

        let now = makeDate(calendar, year: 2025, month: 1, day: 8, hour: 12)
        let thisWeek = makeDate(calendar, year: 2025, month: 1, day: 6, hour: 9)
        let previousWeekSameMonth = makeDate(calendar, year: 2025, month: 1, day: 5, hour: 9)
        let thisMonth = makeDate(calendar, year: 2025, month: 1, day: 20, hour: 9)
        let earlier = makeDate(calendar, year: 2024, month: 12, day: 31, hour: 9)

        XCTAssertEqual(SessionListPresentation.dateBucket(for: thisWeek, now: now, calendar: calendar), .thisWeek)
        XCTAssertEqual(SessionListPresentation.dateBucket(for: previousWeekSameMonth, now: now, calendar: calendar), .thisMonth)
        XCTAssertEqual(SessionListPresentation.dateBucket(for: thisMonth, now: now, calendar: calendar), .thisMonth)
        XCTAssertEqual(SessionListPresentation.dateBucket(for: earlier, now: now, calendar: calendar), .earlier)

        // 同一个绝对时刻在 UTC 可能落入另一日；判定必须使用显式 Calendar 的本地时区。
        let localLateNight = makeDate(calendar, year: 2025, month: 1, day: 7, hour: 23, minute: 30)
        XCTAssertEqual(SessionListPresentation.dateBucket(for: localLateNight, now: now, calendar: calendar), .yesterday)
    }

    func testDateBucketUsesRecencyUpdatedCreatedFallbackAndKeepsNilDates() {
        let calendar = makeCalendar(timeZone: "Asia/Shanghai")
        let now = makeDate(calendar, year: 2025, month: 4, day: 10, hour: 12)
        let today = makeDate(calendar, year: 2025, month: 4, day: 10, hour: 10)
        let yesterday = makeDate(calendar, year: 2025, month: 4, day: 9, hour: 10)
        let earlier = makeDate(calendar, year: 2025, month: 3, day: 31, hour: 10)

        let recencyWins = makeSession(
            id: "recency",
            createdAt: today,
            updatedAt: yesterday,
            recencyAt: earlier
        )
        let updatedWins = makeSession(
            id: "updated",
            createdAt: today,
            updatedAt: yesterday,
            recencyAt: nil
        )
        let createdWins = makeSession(
            id: "created",
            createdAt: today,
            updatedAt: nil,
            recencyAt: nil
        )
        let missingDate = makeSession(id: "missing", createdAt: nil, updatedAt: nil, recencyAt: nil)

        XCTAssertEqual(SessionListPresentation.dateBucket(for: recencyWins, now: now, calendar: calendar), .earlier)
        XCTAssertEqual(SessionListPresentation.dateBucket(for: updatedWins, now: now, calendar: calendar), .yesterday)
        XCTAssertEqual(SessionListPresentation.dateBucket(for: createdWins, now: now, calendar: calendar), .today)
        XCTAssertEqual(SessionListPresentation.dateBucket(for: missingDate, now: now, calendar: calendar), .earlier)
    }

    func testHistoryGroupsOmitEmptyBucketsAndPreserveInputOrder() {
        var calendar = makeCalendar(timeZone: "Asia/Shanghai")
        calendar.firstWeekday = 2
        let now = makeDate(calendar, year: 2025, month: 4, day: 9, hour: 12)
        let firstToday = makeSession(
            id: "today-1",
            createdAt: makeDate(calendar, year: 2025, month: 4, day: 9, hour: 9)
        )
        let secondToday = makeSession(
            id: "today-2",
            createdAt: makeDate(calendar, year: 2025, month: 4, day: 9, hour: 10)
        )
        let yesterday = makeSession(
            id: "yesterday",
            createdAt: makeDate(calendar, year: 2025, month: 4, day: 8, hour: 10)
        )
        let earlier = makeSession(
            id: "earlier",
            createdAt: makeDate(calendar, year: 2025, month: 3, day: 1, hour: 10)
        )

        let groups = SessionListPresentation.historyGroups(
            [firstToday, secondToday, yesterday, earlier],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(groups.map(\.bucket), [.today, .yesterday, .earlier])
        XCTAssertEqual(groups.flatMap(\.sessions).map(\.id), ["today-1", "today-2", "yesterday", "earlier"])
        XCTAssertFalse(groups.contains { $0.bucket == .thisWeek || $0.bucket == .thisMonth })
    }

    func testDisplayTitleFlattensWhitespaceAndRemovesMarkdownPrefixes() {
        let original = "  ## **Hello**\n> - __world__\tand `code`  "
        let session = makeSession(id: "title", title: original)

        XCTAssertEqual(SessionListPresentation.displayTitle(original), "Hello world and code")
        XCTAssertEqual(SessionListPresentation.displayTitle(for: session), "Hello world and code")
        XCTAssertEqual(session.title, original)
    }

    func testDirectoryTailPrefersDirFallsBackToProjectAndHandlesTrailingSlashes() {
        XCTAssertEqual(
            SessionListPresentation.directoryTail(
                for: makeSession(id: "dir", project: "Fallback", dir: "/Users/me/project///")
            ),
            "project"
        )
        XCTAssertEqual(
            SessionListPresentation.directoryTail(
                for: makeSession(id: "trimmed-dir", project: "Fallback", dir: " /Users/me/project///  ")
            ),
            "project"
        )
        XCTAssertEqual(
            SessionListPresentation.directoryTail(
                for: makeSession(id: "project", project: "Fallback", dir: "")
            ),
            "Fallback"
        )
        XCTAssertEqual(
            SessionListPresentation.directoryTail(
                for: makeSession(id: "root", project: "Fallback", dir: "/")
            ),
            "/"
        )
        XCTAssertEqual(
            SessionListPresentation.directoryTail(
                for: makeSession(id: "empty", project: "", dir: "")
            ),
            ""
        )
    }

    func testTableDensityFallsBackAtAccessibilitySizes() {
        XCTAssertEqual(
            SessionIndexRowDensity.resolved(prefersTable: true, dynamicTypeSize: .large),
            .table
        )
        XCTAssertEqual(
            SessionIndexRowDensity.resolved(prefersTable: true, dynamicTypeSize: .accessibility3),
            .compact
        )
        XCTAssertEqual(
            SessionIndexRowDensity.resolved(prefersTable: false, dynamicTypeSize: .large),
            .compact
        )
    }

    private func makeSession(
        id: SessionID,
        project: String = "Project",
        dir: String = "/tmp/project",
        title: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        recencyAt: Date? = nil
    ) -> AgentSession {
        AgentSession(
            id: id,
            projectID: "project-id",
            project: project,
            dir: dir,
            title: title ?? id,
            status: SessionStatus.history.rawValue,
            source: "codex",
            resumeID: nil,
            createdAt: createdAt,
            updatedAt: updatedAt,
            recencyAt: recencyAt
        )
    }

    private func makeCalendar(timeZone identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func makeDate(
        _ calendar: Calendar,
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}
