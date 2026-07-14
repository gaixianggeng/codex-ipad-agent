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

    func testDefaultCodexPresetUsesWarmWorkbenchPalette() {
        let store = ThemeStore(defaults: defaults)

        let lightTokens = store.tokens(for: .light)
        let darkTokens = store.tokens(for: .dark)
        let lightBackground = rgba(lightTokens.background)
        let lightSurface = rgba(lightTokens.surface)
        let lightElevatedSurface = rgba(lightTokens.elevatedSurface)
        let lightAccent = rgba(lightTokens.accent)
        let lightSuccess = rgba(lightTokens.success)
        let lightUserBubble = rgba(lightTokens.userBubble)
        let lightSidebarBackground = rgba(lightTokens.sidebarBackground)
        let lightSidebarHoverFill = rgba(lightTokens.sidebarHoverFill)
        let lightInputBackground = rgba(lightTokens.inputBackground)
        let lightPlanCardBackground = rgba(lightTokens.planCardBackground)
        let lightPlanCardBorder = rgba(lightTokens.planCardBorder)
        let lightBorder = rgba(lightTokens.border)
        let lightSelectionFill = rgba(lightTokens.selectionFill)
        let lightSecondaryText = rgba(lightTokens.secondaryText)
        let codexSwatchForeground = rgba(ThemePreset.codex.swatchForeground)
        let codexSwatchBackground = rgba(ThemePreset.codex.swatchBackground)
        let darkBackground = rgba(darkTokens.background)
        let darkSurface = rgba(darkTokens.surface)
        let darkElevatedSurface = rgba(darkTokens.elevatedSurface)
        let darkAccent = rgba(darkTokens.accent)
        let darkSuccess = rgba(darkTokens.success)
        let darkUserBubble = rgba(darkTokens.userBubble)

        XCTAssertEqual(ThemePreset.codex.title, "暖阳")
        XCTAssertEqual(ThemePreset.codex.subtitle, "中性暖白配单一深紫主色，克制但不沉闷")

        assertRGB(lightBackground, red: 249, green: 248, blue: 245)
        assertRGB(lightSidebarBackground, red: 249, green: 248, blue: 245)
        assertRGB(lightSelectionFill, red: 239, green: 236, blue: 237)
        assertRGB(lightSidebarHoverFill, red: 240, green: 239, blue: 237)
        assertRGB(lightInputBackground, red: 255, green: 255, blue: 255)
        assertRGB(lightPlanCardBackground, red: 255, green: 255, blue: 255)
        assertRGB(lightPlanCardBorder, red: 230, green: 227, blue: 224)
        assertRGB(lightBorder, red: 229, green: 226, blue: 223)
        assertRGB(lightSecondaryText, red: 142, green: 142, blue: 147)
        XCTAssertGreaterThan(lightSurface.red, 0.99)
        XCTAssertGreaterThan(lightSurface.green, 0.99)
        XCTAssertGreaterThan(lightSurface.blue, 0.99)
        XCTAssertEqual(lightTokens.assistantBubble, .white)
        XCTAssertGreaterThan(lightElevatedSurface.red, lightElevatedSurface.blue)
        XCTAssertLessThan(abs(lightElevatedSurface.red - lightElevatedSurface.blue), 0.12)

        XCTAssertEqual(lightAccent.red, lightUserBubble.red, accuracy: 0.001)
        XCTAssertEqual(lightAccent.green, lightUserBubble.green, accuracy: 0.001)
        XCTAssertEqual(lightAccent.blue, lightUserBubble.blue, accuracy: 0.001)
        XCTAssertEqual(codexSwatchBackground.red, lightBackground.red, accuracy: 0.001)
        XCTAssertEqual(codexSwatchBackground.green, lightBackground.green, accuracy: 0.001)
        XCTAssertEqual(codexSwatchBackground.blue, lightBackground.blue, accuracy: 0.001)
        XCTAssertGreaterThan(lightSuccess.green, lightSuccess.red)
        XCTAssertGreaterThan(lightSuccess.green, lightSuccess.blue)

        // 浅色主操作保留品牌色；深色必须使用更亮的语义色，不能沉入暖黑背景。
        assertRGB(lightUserBubble, red: 74, green: 20, blue: 74)
        assertRGB(rgba(lightTokens.primaryAction), red: 74, green: 20, blue: 74)
        let darkPrimaryAction = rgba(darkTokens.primaryAction)
        XCTAssertEqual(darkPrimaryAction.red, darkAccent.red, accuracy: 0.001)
        XCTAssertEqual(darkPrimaryAction.green, darkAccent.green, accuracy: 0.001)
        XCTAssertEqual(darkPrimaryAction.blue, darkAccent.blue, accuracy: 0.001)
        XCTAssertGreaterThan(lightUserBubble.alpha, 0.99)
        XCTAssertEqual(codexSwatchForeground.red, lightUserBubble.red, accuracy: 0.001)
        XCTAssertEqual(codexSwatchForeground.green, lightUserBubble.green, accuracy: 0.001)
        XCTAssertEqual(codexSwatchForeground.blue, lightUserBubble.blue, accuracy: 0.001)

        XCTAssertLessThan(darkBackground.red, 0.12)
        XCTAssertLessThan(darkBackground.green, 0.12)
        XCTAssertLessThan(darkBackground.blue, 0.12)
        XCTAssertLessThan(abs(darkBackground.red - darkBackground.blue), 0.03)
        XCTAssertLessThan(abs(darkSurface.red - darkSurface.blue), 0.04)
        XCTAssertLessThan(abs(darkElevatedSurface.red - darkElevatedSurface.blue), 0.04)
        XCTAssertGreaterThan(darkAccent.red, 0.75)
        XCTAssertGreaterThan(darkAccent.green, 0.65)
        XCTAssertGreaterThan(darkAccent.blue, 0.85)
        XCTAssertGreaterThan(darkAccent.blue, darkAccent.green)
        XCTAssertGreaterThan(darkSuccess.green, darkSuccess.red)
        XCTAssertGreaterThan(darkSuccess.green, darkSuccess.blue)

        XCTAssertGreaterThan(darkUserBubble.red, darkBackground.red + 0.15)
        XCTAssertGreaterThan(darkUserBubble.green, darkBackground.green + 0.10)
        XCTAssertGreaterThan(darkUserBubble.blue, darkBackground.blue + 0.15)
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

                if preset == .codex, scheme == .light {
                    assertRGB(voice, red: 74, green: 20, blue: 74)
                    assertRGB(rgba(tokens.tint(for: .active)), red: 74, green: 20, blue: 74)
                    continue
                }

                // 语音录音态要保留“正在听”的差异感，但默认/代码主题里应贴近主色，而不是跳成警告色。
                XCTAssertLessThan(
                    colorDistance(voice, accent),
                    colorDistance(voice, warning),
                    "\(preset.title) \(scheme) voice color should stay closer to accent than warning"
                )
            }
        }
    }

    func testCodexDarkTokensKeepTextAndActionsReadable() {
        let store = ThemeStore(defaults: defaults)
        store.mode = .dark
        store.preset = .codex
        let tokens = store.tokens(for: .light)

        // 直接约束对比度而不是锁死 RGB，后续微调配色时仍能防止深紫重新沉入暗色背景。
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.primaryAction, tokens.background), 3.0)
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.primaryText, tokens.background), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.secondaryText, tokens.background), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.tertiaryText, tokens.background), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.userBubbleForeground, tokens.userBubble), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.primaryActionForeground, tokens.primaryAction), 4.5)
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

    private func assertRGB(
        _ color: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat),
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        accuracy: CGFloat = 0.003
    ) {
        XCTAssertEqual(color.red, red / 255.0, accuracy: accuracy)
        XCTAssertEqual(color.green, green / 255.0, accuracy: accuracy)
        XCTAssertEqual(color.blue, blue / 255.0, accuracy: accuracy)
        XCTAssertGreaterThan(color.alpha, 0.99)
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

    private func contrastRatio(_ foreground: Color, _ background: Color) -> CGFloat {
        let foregroundLuminance = relativeLuminance(rgba(foreground))
        let backgroundLuminance = relativeLuminance(rgba(background))
        return (max(foregroundLuminance, backgroundLuminance) + 0.05)
            / (min(foregroundLuminance, backgroundLuminance) + 0.05)
    }

    private func relativeLuminance(
        _ color: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)
    ) -> CGFloat {
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red)
            + 0.7152 * linear(color.green)
            + 0.0722 * linear(color.blue)
    }
}

@MainActor
final class ResponsiveLayoutTests: XCTestCase {
    func testWorkbenchLayoutUsesCompactNavigationOnPhoneWidth() {
        let layout = WorkbenchLayout(containerWidth: 390, horizontalSizeClass: .compact)

        XCTAssertTrue(layout.usesCompactNavigation)
        XCTAssertFalse(WorkspaceRootView.shouldEmbedNavigationStack(
            usesCompactNavigation: layout.usesCompactNavigation
        ))
        XCTAssertTrue(layout.prefersDetailOnly)
        XCTAssertFalse(layout.usesAttachedInspector)
        XCTAssertLessThanOrEqual(layout.titleMaxWidth, 150)
        XCTAssertGreaterThanOrEqual(layout.titleMaxWidth, 86)
    }

    func testWorkbenchLayoutUsesCompactNavigationOnLegacyIPadMiniPortraitWidth() {
        let layout = WorkbenchLayout(containerWidth: 768, horizontalSizeClass: .regular)

        XCTAssertTrue(layout.usesCompactNavigation)
        XCTAssertFalse(WorkspaceRootView.shouldEmbedNavigationStack(
            usesCompactNavigation: layout.usesCompactNavigation
        ))
        XCTAssertTrue(layout.prefersDetailOnly)
        XCTAssertFalse(layout.usesAttachedInspector)
    }

    func testWorkbenchLayoutKeepsSplitNavigationOnWidePadWidth() {
        let layout = WorkbenchLayout(containerWidth: 1180, horizontalSizeClass: .regular)

        XCTAssertFalse(layout.usesCompactNavigation)
        XCTAssertTrue(WorkspaceRootView.shouldEmbedNavigationStack(
            usesCompactNavigation: layout.usesCompactNavigation
        ))
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
        XCTAssertEqual(layout.composerBottomPadding, 8)
        XCTAssertLessThanOrEqual(layout.userBubbleMaxWidth, 354)
        XCTAssertLessThanOrEqual(layout.assistantBubbleMaxWidth, 354)
        XCTAssertLessThanOrEqual(layout.runtimeCardMaxWidth, 366)
    }

    func testConversationLayoutKeepsPadComposerCloseToBottomSafeArea() {
        let layout = ConversationLayout(containerWidth: 716, horizontalSizeClass: .regular)

        XCTAssertEqual(layout.composerTopPadding, 12)
        XCTAssertEqual(layout.composerBottomPadding, 10)
    }
}
