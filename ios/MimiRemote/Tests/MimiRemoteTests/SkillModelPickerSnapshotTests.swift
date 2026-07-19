#if os(iOS) && !targetEnvironment(macCatalyst)
import SnapshotTesting
import SwiftUI
import XCTest
@testable import MimiRemote

@MainActor
final class SkillModelPickerSnapshotTests: XCTestCase {
    func testEffectiveModelUsesExplicitSelectionBeforeServerDefault() {
        let options = [
            CodexAppServerModelOption(id: "gpt-5.6-sol", title: "GPT-5.6 Sol", isDefault: true),
            CodexAppServerModelOption(id: "gpt-5.6-terra", title: "GPT-5.6 Terra")
        ]

        XCTAssertEqual(
            GPT56ModelGridCatalog.effectiveModelID(selectedModelID: "gpt-5.6-terra", options: options),
            "gpt-5.6-terra"
        )
        XCTAssertTrue(GPT56ModelGridCatalog.isGridModel("gpt-5.6-terra"))
        XCTAssertNotNil(GPT56ModelGridCatalog.triggerTitle(for: "gpt-5.6-terra", effort: .high))
        XCTAssertFalse(
            GPT56ModelGridCatalog.showsStandaloneReasoningControl(
                runtimeProvider: "codex",
                modelID: "gpt-5.6-terra"
            )
        )
    }

    func testEffectiveModelResolvesDefaultGridModelWithoutExplicitSelection() {
        let options = [
            CodexAppServerModelOption(id: "gpt-5.5", title: "GPT-5.5"),
            CodexAppServerModelOption(id: "gpt-5.6-sol", title: "GPT-5.6 Sol", isDefault: true)
        ]

        let modelID = GPT56ModelGridCatalog.effectiveModelID(selectedModelID: nil, options: options)

        XCTAssertEqual(modelID, "gpt-5.6-sol")
        XCTAssertTrue(GPT56ModelGridCatalog.isGridModel(modelID))
        XCTAssertEqual(
            modelID.flatMap { GPT56ModelGridCatalog.triggerTitle(for: $0, effort: .xhigh) },
            "5.6 Sol · \(GPT56ModelGridCatalog.effortTitle(.xhigh))"
        )
        XCTAssertFalse(
            GPT56ModelGridCatalog.showsStandaloneReasoningControl(
                runtimeProvider: nil,
                modelID: modelID
            )
        )
    }

    func testNonGridAndClaudeDefaultsKeepStandaloneReasoningPath() {
        let nonGridOptions = [CodexAppServerModelOption(id: "gpt-5.5", title: "GPT-5.5", isDefault: true)]
        let claudeOptions = [
            CodexAppServerModelOption(
                id: "sonnet",
                title: "Claude Sonnet 5",
                runtimeProvider: "claude",
                isDefault: true
            )
        ]

        let nonGridModelID = GPT56ModelGridCatalog.effectiveModelID(selectedModelID: nil, options: nonGridOptions)
        let claudeModelID = GPT56ModelGridCatalog.effectiveModelID(selectedModelID: nil, options: claudeOptions)

        XCTAssertFalse(GPT56ModelGridCatalog.isGridModel(nonGridModelID))
        XCTAssertFalse(GPT56ModelGridCatalog.isGridModel(claudeModelID))
        XCTAssertTrue(
            GPT56ModelGridCatalog.showsStandaloneReasoningControl(
                runtimeProvider: "codex",
                modelID: nonGridModelID
            )
        )
        XCTAssertTrue(
            GPT56ModelGridCatalog.showsStandaloneReasoningControl(
                runtimeProvider: "claude",
                modelID: "gpt-5.6-sol"
            )
        )
    }

    func testSkillCardsAndModelGridDarkAppearance() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        let defaults = UserDefaults(suiteName: "SkillModelPickerSnapshotTests.\(UUID().uuidString)")!
        let themeStore = ThemeStore(defaults: defaults)
        themeStore.mode = .dark

        let skills = [
            SkillCapability(
                name: "apple-design",
                description: "Apple 风格的手势、材质与动效设计",
                scope: "user",
                path: "/Users/demo/.codex/skills/apple-design/SKILL.md",
                enabled: true,
                displayName: "Apple Design",
                shortDescription: "流畅、克制且具有物理反馈的界面",
                brandColor: "#35A7A8"
            ),
            SkillCapability(
                name: "imagegen",
                description: "生成与编辑视觉素材",
                scope: "system",
                path: "/Users/demo/.codex/skills/.system/imagegen/SKILL.md",
                enabled: true,
                displayName: "Image Generation",
                shortDescription: "创建产品概念图和位图素材",
                brandColor: "#7D65D8"
            ),
            SkillCapability(
                name: "swiftui-ui-patterns",
                description: "构建原生 SwiftUI 界面",
                scope: "repo",
                path: "/Users/demo/.codex/plugins/swiftui-ui-patterns/SKILL.md",
                enabled: true,
                displayName: "SwiftUI Patterns",
                shortDescription: "稳定的数据流与组件布局",
                brandColor: "#D47B45"
            )
        ]

        let selectedSkill = SkillVisualMetadata(capability: skills[0])
        let view = HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 18) {
                SkillPickerPanel(
                    skills: skills,
                    selectedPaths: [skills[0].path, skills[1].path],
                    errorMessage: nil,
                    isRefreshing: false,
                    onToggle: { _ in },
                    onRefresh: {},
                    onManualAdd: {}
                )

                HStack(spacing: 10) {
                    SkillAttachmentToken(metadata: selectedSkill, onOpen: {}, onRemove: {})
                    SkillAttachmentToken(metadata: SkillVisualMetadata(capability: skills[1]), onOpen: {}, onRemove: {})
                }

                SkillInvocationCard(metadata: selectedSkill, sendStatus: .confirmed)
                    .frame(width: 410)
            }

            ModelReasoningGridPicker(
                options: CodexAppServerModelOption.builtInFallback,
                selection: GPT56ModelGridSelection(modelID: "gpt-5.6-terra", effort: .high),
                selectedModelID: "gpt-5.6-terra",
                isRefreshing: false,
                isFastMode: true,
                onSelect: { _, _ in },
                onFastModeChange: { _ in },
                onSelectModelOnly: { _ in },
                onRefresh: {}
            )
        }
        .padding(28)
        .environmentObject(themeStore)
        .environment(\.colorScheme, .dark)
        .frame(width: 1024, height: 760, alignment: .topLeading)
        .background(themeStore.tokens(for: .dark).background)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 1024, height: 760))
        )
    }

    func testCompactModelGridLightFastModeOff() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        let defaults = UserDefaults(suiteName: "SkillModelPickerSnapshotTests.\(UUID().uuidString)")!
        let themeStore = ThemeStore(defaults: defaults)
        themeStore.mode = .light

        let view = ModelReasoningGridPicker(
            options: CodexAppServerModelOption.builtInFallback,
            selection: GPT56ModelGridSelection(modelID: "gpt-5.6-sol", effort: .xhigh),
            selectedModelID: "gpt-5.6-sol",
            isRefreshing: false,
            isFastMode: false,
            onSelect: { _, _ in },
            onFastModeChange: { _ in },
            onSelectModelOnly: { _ in },
            onRefresh: {}
        )
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)
        .padding(32)
        .frame(width: 440, height: 360, alignment: .top)
        .background(themeStore.tokens(for: .light).background)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 440, height: 360))
        )
    }

    func testComposerModelTriggerFastIndicator() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        let defaults = UserDefaults(suiteName: "SkillModelPickerSnapshotTests.\(UUID().uuidString)")!
        let themeStore = ThemeStore(defaults: defaults)
        themeStore.mode = .light

        let view = HStack(spacing: 18) {
            ComposerToolbarControlLabel(
                title: "5.6 Sol · 极高",
                systemImage: "cpu",
                trailingSystemImage: nil,
                isSelected: false,
                tint: nil,
                titleMaxWidth: 150,
                accessibilityLabel: "切换模型与推理强度"
            )

            ComposerToolbarControlLabel(
                title: "5.6 Sol · 极高",
                systemImage: "cpu",
                trailingSystemImage: "bolt.fill",
                isSelected: false,
                tint: nil,
                titleMaxWidth: 150,
                accessibilityLabel: "切换模型与推理强度，快速"
            )
        }
        .padding(28)
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)
        .frame(width: 520, height: 120)
        .background(themeStore.tokens(for: .light).background)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 520, height: 120))
        )
    }
}
#endif
