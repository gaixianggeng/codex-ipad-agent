import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

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
        XCTAssertEqual(store.mode.subtitle, "跟随当前设备外观")
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

    func testDefaultCodexPresetUsesWhitePurplePalette() {
        let store = ThemeStore(defaults: defaults)

        let lightTokens = store.tokens(for: .light)
        let darkTokens = store.tokens(for: .dark)
        let lightBackground = rgba(lightTokens.background)
        let lightSurface = rgba(lightTokens.surface)
        let lightAccent = rgba(lightTokens.accent)
        let lightSuccess = rgba(lightTokens.success)
        let lightUserBubble = rgba(lightTokens.userBubble)
        let darkBackground = rgba(darkTokens.background)
        let darkAccent = rgba(darkTokens.accent)
        let darkSuccess = rgba(darkTokens.success)
        let darkUserBubble = rgba(darkTokens.userBubble)

        XCTAssertEqual(ThemePreset.codex.subtitle, "白色界面配紫色重点，适合长时间对话")

        XCTAssertGreaterThan(lightBackground.red, 0.97)
        XCTAssertGreaterThan(lightBackground.green, 0.96)
        XCTAssertGreaterThan(lightBackground.blue, 0.97)
        XCTAssertGreaterThan(lightSurface.red, 0.99)
        XCTAssertGreaterThan(lightSurface.green, 0.99)
        XCTAssertGreaterThan(lightSurface.blue, 0.99)

        XCTAssertGreaterThan(lightAccent.red, 0.30)
        XCTAssertLessThan(lightAccent.green, 0.20)
        XCTAssertGreaterThan(lightAccent.blue, 0.35)
        XCTAssertGreaterThan(lightAccent.blue, lightAccent.red)
        XCTAssertGreaterThan(lightSuccess.blue, 0.70)
        XCTAssertGreaterThan(lightSuccess.red, 0.25)
        XCTAssertLessThan(lightSuccess.green, lightSuccess.blue)

        XCTAssertEqual(lightUserBubble.red, 0.25, accuracy: 0.01)
        XCTAssertEqual(lightUserBubble.green, 0.13, accuracy: 0.01)
        XCTAssertEqual(lightUserBubble.blue, 0.42, accuracy: 0.01)
        XCTAssertGreaterThan(lightUserBubble.alpha, 0.99)

        XCTAssertLessThan(darkBackground.red, 0.12)
        XCTAssertLessThan(darkBackground.green, 0.10)
        XCTAssertLessThan(darkBackground.blue, 0.13)
        XCTAssertGreaterThan(darkAccent.red, 0.70)
        XCTAssertGreaterThan(darkAccent.green, 0.50)
        XCTAssertGreaterThan(darkAccent.blue, 0.80)
        XCTAssertGreaterThan(darkAccent.blue, darkAccent.red)
        XCTAssertGreaterThan(darkSuccess.blue, 0.90)
        XCTAssertGreaterThan(darkSuccess.red, 0.45)
        XCTAssertLessThan(darkSuccess.green, darkSuccess.blue)

        XCTAssertEqual(darkUserBubble.red, 0.25, accuracy: 0.01)
        XCTAssertEqual(darkUserBubble.green, 0.13, accuracy: 0.01)
        XCTAssertEqual(darkUserBubble.blue, 0.42, accuracy: 0.01)
        XCTAssertGreaterThan(darkUserBubble.alpha, 0.99)
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

    func testPrimaryColorPresetsKeepVoiceRecordingAlignedWithAccent() {
        let store = ThemeStore(defaults: defaults)

        for preset in [ThemePreset.codex, .github, .xcode] {
            store.preset = preset

            for scheme in [ColorScheme.light, .dark] {
                let tokens = store.tokens(for: scheme)
                let voice = rgba(tokens.voiceRecording)
                let accent = rgba(tokens.accent)
                let warning = rgba(tokens.warning)

                // 语音录音态要保留“正在听”的差异感，但默认/代码主题里应贴近主色，而不是跳成警告色。
                XCTAssertLessThan(
                    colorDistance(voice, accent),
                    colorDistance(voice, warning),
                    "\(preset.title) \(scheme) voice color should stay closer to accent than warning"
                )
            }
        }
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

    private func colorDistance(
        _ lhs: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat),
        _ rhs: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)
    ) -> CGFloat {
        let red = lhs.red - rhs.red
        let green = lhs.green - rhs.green
        let blue = lhs.blue - rhs.blue
        return sqrt(red * red + green * green + blue * blue)
    }
}

@MainActor
final class ResponsiveLayoutTests: XCTestCase {
    func testWorkbenchLayoutUsesCompactNavigationOnPhoneWidth() {
        let layout = WorkbenchLayout(containerWidth: 390, horizontalSizeClass: .compact)

        XCTAssertTrue(layout.usesCompactNavigation)
        XCTAssertTrue(layout.prefersDetailOnly)
        XCTAssertFalse(layout.usesAttachedInspector)
        XCTAssertLessThanOrEqual(layout.titleMaxWidth, 150)
        XCTAssertGreaterThanOrEqual(layout.titleMaxWidth, 86)
    }

    func testWorkbenchLayoutKeepsSplitNavigationOnWidePadWidth() {
        let layout = WorkbenchLayout(containerWidth: 1180, horizontalSizeClass: .regular)

        XCTAssertFalse(layout.usesCompactNavigation)
        XCTAssertFalse(layout.prefersDetailOnly)
        XCTAssertTrue(layout.usesAttachedInspector)
        XCTAssertEqual(layout.projectColumn.ideal, 330)
        XCTAssertEqual(layout.titleMaxWidth, 340)
    }

    func testConversationLayoutFitsPhonePortraitWidth() {
        let layout = ConversationLayout(containerWidth: 390, horizontalSizeClass: .compact)

        XCTAssertEqual(layout.horizontalInset, 12)
        XCTAssertEqual(layout.composerAvailableWidth, 366)
        XCTAssertEqual(layout.composerMaxWidth, .infinity)
        XCTAssertLessThanOrEqual(layout.userBubbleMaxWidth, 354)
        XCTAssertLessThanOrEqual(layout.assistantBubbleMaxWidth, 354)
        XCTAssertLessThanOrEqual(layout.runtimeCardMaxWidth, 366)
    }
}
