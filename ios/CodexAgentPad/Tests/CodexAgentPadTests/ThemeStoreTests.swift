import SwiftUI
import UIKit
import XCTest
@testable import CodexAgentPad

@MainActor
final class ThemeStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ThemeStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultAppearanceStateUsesSafeMVPValues() {
        let store = ThemeStore(defaults: defaults)

        XCTAssertEqual(store.mode, .system)
        XCTAssertEqual(store.preset, .codex)
        XCTAssertEqual(store.uiFontPreset, .system)
        XCTAssertEqual(store.codeFontPreset, .systemMono)
        XCTAssertEqual(store.fontScale, ThemeStore.defaultFontScale)
        XCTAssertNil(store.preferredColorScheme)

        let tokens = store.tokens(for: .light)
        XCTAssertEqual(tokens.preset, .codex)
        XCTAssertEqual(tokens.resolvedScheme, .light)
    }

    func testPersistsAppearancePreferences() {
        let store = ThemeStore(defaults: defaults)

        store.mode = .dark
        store.preset = .gruvbox
        store.uiFontPreset = .rounded
        store.codeFontPreset = .menlo
        store.setFontScale(1.20)

        let restored = ThemeStore(defaults: defaults)
        XCTAssertEqual(restored.mode, .dark)
        XCTAssertEqual(restored.preset, .gruvbox)
        XCTAssertEqual(restored.uiFontPreset, .rounded)
        XCTAssertEqual(restored.codeFontPreset, .menlo)
        XCTAssertEqual(restored.fontScale, 1.20, accuracy: 0.001)
        XCTAssertEqual(restored.preferredColorScheme, .dark)
    }

    func testInvalidStoredValuesFallBackToDefaults() {
        defaults.set("broken", forKey: "appearance.theme.mode")
        defaults.set("unknown", forKey: "appearance.theme.preset")
        defaults.set("comic-sans", forKey: "appearance.theme.uiFont")
        defaults.set("terminal", forKey: "appearance.theme.codeFont")
        defaults.set(99.0, forKey: "appearance.theme.fontScale")

        let store = ThemeStore(defaults: defaults)

        XCTAssertEqual(store.mode, .system)
        XCTAssertEqual(store.preset, .codex)
        XCTAssertEqual(store.uiFontPreset, .system)
        XCTAssertEqual(store.codeFontPreset, .systemMono)
        XCTAssertEqual(store.fontScale, ThemeStore.maximumFontScale)
    }

    func testFontScaleClampsToSupportedRange() {
        let store = ThemeStore(defaults: defaults)

        store.setFontScale(0.1)
        XCTAssertEqual(store.fontScale, ThemeStore.minimumFontScale)

        store.setFontScale(9.0)
        XCTAssertEqual(store.fontScale, ThemeStore.maximumFontScale)
    }

    func testResetPersistsDefaults() {
        let store = ThemeStore(defaults: defaults)
        store.mode = .dark
        store.preset = .xcode
        store.uiFontPreset = .serif
        store.codeFontPreset = .menlo
        store.setFontScale(1.25)

        store.reset()

        let restored = ThemeStore(defaults: defaults)
        XCTAssertEqual(restored.mode, .system)
        XCTAssertEqual(restored.preset, .codex)
        XCTAssertEqual(restored.uiFontPreset, .system)
        XCTAssertEqual(restored.codeFontPreset, .systemMono)
        XCTAssertEqual(restored.fontScale, ThemeStore.defaultFontScale)
    }

    func testResetResolvesToCurrentSystemColorScheme() {
        let store = ThemeStore(defaults: defaults)
        store.mode = .light

        store.reset()

        XCTAssertNil(store.preferredColorScheme)
        XCTAssertEqual(store.resolvedColorScheme(for: .dark), .dark)
        XCTAssertEqual(store.tokens(for: .dark).resolvedScheme, .dark)
    }

    func testTokenSelectionUsesPresetAndResolvedScheme() {
        let store = ThemeStore(defaults: defaults)
        store.mode = .system
        store.preset = .xcode

        XCTAssertEqual(store.tokens(for: .light).preset, .xcode)
        XCTAssertEqual(store.tokens(for: .light).resolvedScheme, .light)
        XCTAssertEqual(store.tokens(for: .dark).resolvedScheme, .dark)

        store.mode = .light
        XCTAssertEqual(store.tokens(for: .dark).resolvedScheme, .light)

        store.mode = .dark
        XCTAssertEqual(store.tokens(for: .light).resolvedScheme, .dark)
    }

    func testXcodePresetKeepsEditorInspiredContrastAndAccents() {
        let store = ThemeStore(defaults: defaults)
        store.preset = .xcode

        let lightTokens = store.tokens(for: .light)
        let darkTokens = store.tokens(for: .dark)
        let lightCodeBlock = rgba(lightTokens.codeBlock)
        let lightCodeText = rgba(lightTokens.codeText)
        let darkBackground = rgba(darkTokens.background)
        let darkCodeBlock = rgba(darkTokens.codeBlock)
        let accent = rgba(lightTokens.accent)
        let warning = rgba(lightTokens.warning)
        let success = rgba(darkTokens.success)

        XCTAssertGreaterThan(lightCodeBlock.red, 0.95)
        XCTAssertGreaterThan(lightCodeBlock.green, 0.96)
        XCTAssertGreaterThan(lightCodeBlock.blue, 0.98)
        XCTAssertLessThan(lightCodeText.red, 0.15)
        XCTAssertLessThan(lightCodeText.green, 0.15)
        XCTAssertLessThan(lightCodeText.blue, 0.18)

        XCTAssertLessThan(abs(darkBackground.red - darkBackground.blue), 0.04)
        XCTAssertLessThan(abs(darkCodeBlock.red - darkCodeBlock.blue), 0.03)

        XCTAssertGreaterThan(accent.blue, 0.95)
        XCTAssertGreaterThan(accent.green, 0.45)
        XCTAssertGreaterThan(warning.red, 0.95)
        XCTAssertLessThan(warning.blue, 0.10)
        XCTAssertGreaterThan(success.green, success.red)
        XCTAssertGreaterThan(success.green, success.blue)
    }

    func testGitHubPresetProvidesLightAndDarkTokens() {
        let store = ThemeStore(defaults: defaults)
        store.preset = .github

        let lightTokens = store.tokens(for: .light)
        let darkTokens = store.tokens(for: .dark)

        XCTAssertTrue(ThemePreset.allCases.contains(.github))
        XCTAssertEqual(ThemePreset.github.title, "GitHub")
        XCTAssertEqual(lightTokens.preset, .github)
        XCTAssertEqual(lightTokens.resolvedScheme, .light)
        XCTAssertEqual(darkTokens.preset, .github)
        XCTAssertEqual(darkTokens.resolvedScheme, .dark)
    }

    func testThemeVersionIncrementsWhenVisualStateChanges() {
        let store = ThemeStore(defaults: defaults)
        let originalVersion = store.themeVersion

        store.preset = .gruvbox

        XCTAssertGreaterThan(store.themeVersion, originalVersion)
    }

    private func rgba(_ color: Color) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return (red, green, blue, alpha)
    }
}
