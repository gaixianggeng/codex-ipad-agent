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
        let layout = ModelReasoningGridCatalog.layout(runtimeProvider: "codex", options: options)

        XCTAssertEqual(
            ModelReasoningGridCatalog.effectiveModelID(selectedModelID: "gpt-5.6-terra", options: options),
            "gpt-5.6-terra"
        )
        XCTAssertTrue(layout.contains(modelID: "gpt-5.6-terra"))
        XCTAssertNotNil(
            ModelReasoningGridCatalog.triggerTitle(
                for: "gpt-5.6-terra",
                effort: .high,
                layout: layout
            )
        )
    }

    func testEffectiveModelResolvesDefaultGridModelWithoutExplicitSelection() {
        let options = [
            CodexAppServerModelOption(id: "gpt-5.5", title: "GPT-5.5"),
            CodexAppServerModelOption(id: "gpt-5.6-sol", title: "GPT-5.6 Sol", isDefault: true)
        ]

        let layout = ModelReasoningGridCatalog.layout(runtimeProvider: "codex", options: options)
        let modelID = ModelReasoningGridCatalog.effectiveModelID(selectedModelID: nil, options: options)

        XCTAssertEqual(modelID, "gpt-5.6-sol")
        XCTAssertTrue(layout.contains(modelID: modelID))
        XCTAssertEqual(
            modelID.flatMap {
                ModelReasoningGridCatalog.triggerTitle(for: $0, effort: .xhigh, layout: layout)
            },
            "5.6 Sol · \(ModelReasoningGridCatalog.effortTitle(.xhigh))"
        )
    }

    func testClaudeUsesSharedGridWithRuntimeSpecificRowsAndEfforts() {
        let nonGridOptions = [CodexAppServerModelOption(id: "gpt-5.5", title: "GPT-5.5", isDefault: true)]
        let claudeOptions = CodexAppServerModelOption.builtInClaudeFallback

        let codexLayout = ModelReasoningGridCatalog.layout(runtimeProvider: "codex", options: nonGridOptions)
        let claudeLayout = ModelReasoningGridCatalog.layout(runtimeProvider: "claude", options: claudeOptions)
        let nonGridModelID = ModelReasoningGridCatalog.effectiveModelID(selectedModelID: nil, options: nonGridOptions)
        let claudeModelID = ModelReasoningGridCatalog.effectiveModelID(selectedModelID: nil, options: claudeOptions)

        XCTAssertFalse(codexLayout.contains(modelID: nonGridModelID))
        XCTAssertTrue(claudeLayout.contains(modelID: claudeModelID))
        XCTAssertEqual(claudeLayout.rows.map(\.model), ["haiku", "sonnet", "opus", "claude-fable-5"])
        XCTAssertEqual(
            claudeLayout.rows.map { ModelReasoningGridCatalog.shortTitle(for: $0, kind: .claude) },
            ["Haiku 4.5", "Sonnet 5", "Opus 4.8", "Fable 5"]
        )
        XCTAssertEqual(claudeLayout.efforts, [.minimal, .low, .medium, .high])
        XCTAssertFalse(claudeLayout.showsFastMode)
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
                layout: ModelReasoningGridCatalog.layout(
                    runtimeProvider: "codex",
                    options: CodexAppServerModelOption.builtInFallback
                ),
                selection: ModelReasoningGridSelection(modelID: "gpt-5.6-terra", effort: .high),
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
            layout: ModelReasoningGridCatalog.layout(
                runtimeProvider: "codex",
                options: CodexAppServerModelOption.builtInFallback
            ),
            selection: ModelReasoningGridSelection(modelID: "gpt-5.6-sol", effort: .xhigh),
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
