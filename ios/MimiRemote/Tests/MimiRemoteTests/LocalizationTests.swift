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
            ("ui.status", "Status", "状态"),
            ("ui.token_quota", "Token quota", "Token 额度"),
            ("ui.connection", "Connection", "连接"),
            ("ui.mac_devices", "Mac Devices", "Mac 设备"),
            ("ui.personalization", "Appearance & Personalization", "外观与个性化"),
            ("ui.advanced", "Diagnostics & Development", "诊断与开发"),
            ("ui.legal_and_support", "About & Support", "关于与支持")
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
        XCTAssertEqual(SettingsLayoutMetrics.quotaSummaryMinimumHeight, 104)
        XCTAssertEqual(SettingsQuotaLayoutMetrics.wide.candidateWidth, 420)
        XCTAssertEqual(SettingsQuotaLayoutMetrics.wide.ringDiameter, 82)
        XCTAssertEqual(SettingsQuotaLayoutMetrics.wide.ringLineWidth, 5.5)
        XCTAssertEqual(SettingsQuotaLayoutMetrics.wide.informationWidth, 230)
        XCTAssertEqual(SettingsQuotaLayoutMetrics.compact.candidateWidth, 290)
        XCTAssertEqual(SettingsQuotaLayoutMetrics.compact.ringDiameter, 68)
        XCTAssertEqual(SettingsQuotaLayoutMetrics.compact.ringLineWidth, 5)
        XCTAssertEqual(SettingsQuotaLayoutMetrics.compact.informationWidth, 210)
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
