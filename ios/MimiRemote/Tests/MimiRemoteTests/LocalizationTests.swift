import XCTest
@testable import MimiRemote

final class LocalizationTests: XCTestCase {
    func testRuntimeCatalogUsesEnglishWhenTestLanguageIsEnglish() throws {
        try XCTSkipUnless(
            Locale.preferredLanguages.first?.lowercased().hasPrefix("en") == true,
            "需使用 xcodebuild -testLanguage en 运行英文目录冒烟测试"
        )

        // 核心回归与英文 smoke 复用同一 App 容器。这里临时回到“跟随系统”，
        // 避免前序快照测试残留的显式语言偏好覆盖 -testLanguage en。
        let defaults = UserDefaults.standard
        let hadStoredLanguage = defaults.object(forKey: AppLanguage.preferenceKey) != nil
        let previousLanguage = defaults.string(forKey: AppLanguage.preferenceKey)
        defaults.removeObject(forKey: AppLanguage.preferenceKey)
        defer {
            if hadStoredLanguage {
                defaults.set(previousLanguage, forKey: AppLanguage.preferenceKey)
            } else {
                defaults.removeObject(forKey: AppLanguage.preferenceKey)
            }
        }

        XCTAssertEqual(L10n.text("ui.settings"), "settings")
        XCTAssertEqual(
            L10n.format("ui.awaiting_approval_value_value", "Review diff", " · Low risk"),
            "Awaiting approval: Review diff · Low risk"
        )
    }

    func testObjectFormatterSupportsIntegersAndMultipleArguments() {
        XCTAssertEqual(
            L10n.formatTemplate("%@ has %@ messages", arguments: [42, 3]),
            "42 has 3 messages"
        )
    }

    func testObjectFormatterDoesNotInterpretPlaceholderInsideArgument() {
        XCTAssertEqual(
            L10n.formatTemplate("Message: %@", arguments: ["literal %@ text"]),
            "Message: literal %@ text"
        )
    }

    func testObjectFormatterSupportsTranslatorControlledPosition() {
        XCTAssertEqual(
            L10n.formatTemplate("Second: %2$@; first: %1$@", arguments: ["one", "two"]),
            "Second: two; first: one"
        )
    }

    func testExplicitLanguageLookupSwitchesCatalogWithoutRestart() {
        XCTAssertEqual(L10n.text("ui.settings", language: .english), "settings")
        XCTAssertEqual(L10n.text("ui.settings", language: .simplifiedChinese), "设置")
    }

    func testSettingsInformationArchitectureLabelsAreLocalized() {
        let expectedValues: [(String, String, String)] = [
            ("ui.me", "Me", "我的"),
            ("ui.token_usage", "Token usage", "Token 使用量"),
            ("ui.current_remaining", "Current Remaining", "当前剩余"),
            ("ui.token_activity", "Token Activity", "Token 活动"),
            ("ui.my_preferences", "My Preferences", "我的偏好设置"),
            ("ui.more", "More", "更多"),
            ("ui.personalization", "Appearance & Personalization", "外观与个性化"),
            ("ui.advanced_and_development", "Advanced & Development", "高级与开发"),
            ("ui.about_and_legal", "About & Legal", "关于与法律")
        ]

        for (key, english, simplifiedChinese) in expectedValues {
            XCTAssertEqual(L10n.text(key, language: .english), english)
            XCTAssertEqual(L10n.text(key, language: .simplifiedChinese), simplifiedChinese)
        }
    }

    func testSessionRowStatefulActionLabelsAreLocalized() {
        let expectedValues: [(String, String, String)] = [
            ("ui.pin_to_top", "pin to top", "置顶"),
            ("ui.unpin", "Unpin", "取消置顶"),
            ("ui.mark_as_read", "Mark as Read", "标记为已读"),
            ("ui.mark_as_unread", "Mark as Unread", "标记为未读"),
            ("ui.archive", "Archive", "归档"),
            ("ui.unarchive", "Unarchive", "取消归档")
        ]

        for (key, english, simplifiedChinese) in expectedValues {
            XCTAssertEqual(L10n.text(key, language: .english), english)
            XCTAssertEqual(L10n.text(key, language: .simplifiedChinese), simplifiedChinese)
        }
    }

    func testSettingsLayoutMetricsUseOneVisualSystem() {
        XCTAssertEqual(SettingsLayoutMetrics.standardRowHeight, 52)
        XCTAssertEqual(SettingsLayoutMetrics.accessibilityRowHeight, 76)
        XCTAssertEqual(SettingsLayoutMetrics.iconSlot, 28)
        XCTAssertEqual(SettingsLayoutMetrics.symbolPointSize, 18)
        XCTAssertEqual(SettingsLayoutMetrics.statusModuleCornerRadius, 20)
    }

    func testTokenCountFormatterUsesProductCompactUnits() {
        XCTAssertEqual(
            TokenCountFormatter.string(50_160_000_000, language: .simplifiedChinese),
            "501.6亿"
        )
        XCTAssertEqual(
            TokenCountFormatter.string(50_160_000_000, language: .english),
            "50.2B"
        )
        XCTAssertEqual(TokenCountFormatter.string(nil, language: .english), "—")
    }

    func testTokenActivityCalendarAggregatesAndRejectsInvalidDays() throws {
        let calendar = TokenActivityCalendar.utcCalendar
        let endingAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 30))
        )
        let weeks = TokenActivityCalendar.weeks(
            buckets: [
                AccountTokenUsageDailyBucket(startDate: "2026-07-30", tokens: 100),
                AccountTokenUsageDailyBucket(startDate: "2026-07-30", tokens: 50),
                AccountTokenUsageDailyBucket(startDate: "2026-07-29", tokens: -20),
                AccountTokenUsageDailyBucket(startDate: "2026-02-30", tokens: 999),
                AccountTokenUsageDailyBucket(startDate: "2026-08-01", tokens: 999)
            ],
            endingAt: endingAt
        )

        XCTAssertEqual(weeks.count, 53)
        XCTAssertTrue(weeks.allSatisfy { $0.days.count == 7 })
        let activeDay = try XCTUnwrap(
            weeks.flatMap(\.days).first {
                calendar.isDate($0.date, inSameDayAs: endingAt)
            }
        )
        XCTAssertEqual(activeDay.tokens, 150)
        XCTAssertGreaterThan(activeDay.intensity, 0)
        XCTAssertNil(TokenActivityCalendar.date(from: "2026-02-30"))
        XCTAssertEqual(
            weeks.flatMap(\.days).filter { $0.tokens > 0 }.count,
            1,
            "未来日、非法日期与负数都不能进入活动统计"
        )
    }

    func testTokenActivityCalendarSaturatesDuplicateBucketOverflow() throws {
        let calendar = TokenActivityCalendar.utcCalendar
        let endingAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 30))
        )
        let weeks = TokenActivityCalendar.weeks(
            buckets: [
                AccountTokenUsageDailyBucket(startDate: "2026-07-30", tokens: .max),
                AccountTokenUsageDailyBucket(startDate: "2026-07-30", tokens: 1)
            ],
            endingAt: endingAt
        )
        let activeDay = try XCTUnwrap(
            weeks.flatMap(\.days).first {
                calendar.isDate($0.date, inSameDayAs: endingAt)
            }
        )

        XCTAssertEqual(activeDay.tokens, .max)
        XCTAssertEqual(activeDay.intensity, 4)
    }

    func testStoredLanguageFallsBackToSystemForUnknownValue() {
        let suiteName = "LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AppLanguage.stored(in: defaults), .system)
        defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.stored(in: defaults), .english)
        defaults.set("unsupported", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.stored(in: defaults), .system)
    }

    func testVoiceInputProviderDefaultsToCodexAndPreservesKnownSelection() {
        let suiteName = "VoiceInputProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(VoiceInputProvider.stored(in: defaults), .codex)
        defaults.set(VoiceInputProvider.apple.rawValue, forKey: VoiceInputProvider.storageKey)
        XCTAssertEqual(VoiceInputProvider.stored(in: defaults), .apple)
        defaults.set(VoiceInputProvider.codex.rawValue, forKey: VoiceInputProvider.storageKey)
        XCTAssertEqual(VoiceInputProvider.stored(in: defaults), .codex)
        defaults.set("future-provider", forKey: VoiceInputProvider.storageKey)
        XCTAssertEqual(VoiceInputProvider.stored(in: defaults), .codex)
    }

    func testVoiceInputProvidersExposeDistinctNativeSystemIcons() {
        XCTAssertEqual(VoiceInputProvider.codex.icon, .system("waveform"))
        XCTAssertEqual(VoiceInputProvider.apple.icon, .system("siri"))
    }

    func testCodexVoiceInputDescriptionExplainsPostRecordingTranscription() {
        XCTAssertEqual(
            L10n.text("ui.codex_voice_input_description", language: .simplifiedChinese),
            "使用 Codex 内置语音能力 · 录音结束后转写"
        )
        XCTAssertEqual(
            L10n.text("ui.codex_voice_input_description", language: .english),
            "Uses Codex built-in voice capability · Transcribes after recording"
        )
    }
}
