import Foundation

// 模型目录过滤、默认值选择和会话 runtime 锁定集中在这里，避免 ComposerView
// 同时承担视图布局与模型策略。成员保持 module-internal，供 ComposerView 跨文件扩展协作。
extension ComposerView {
    var modelOptionsForMenu: [CodexAppServerModelOption] {
        let source = sessionStore.appServerModelOptions.isEmpty
            ? CodexAppServerModelOption.builtInFallback
            : sessionStore.appServerModelOptions
        let options = source.filter { !$0.hidden }
        guard let runtimeProvider = selectedSessionRuntimeProviderForModelMenu else {
            return options
        }
        let scoped = options.filter { option in
            normalizedRuntimeProvider(option.runtimeProvider) == runtimeProvider
        }
        if scoped.isEmpty, runtimeProvider == "claude" {
            return CodexAppServerModelOption.builtInClaudeFallback
        }
        if scoped.isEmpty, runtimeProvider == "codex" {
            return CodexAppServerModelOption.builtInFallback
        }
        return scoped.isEmpty ? options : scoped
    }

    var selectedModelSummaryTitle: String {
        guard let model = composerState.turnOptions.model?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !model.isEmpty
        else {
            return defaultModelSummaryTitle
        }
        if let option = modelOptionsForMenu.first(where: { item in
            item.model == model
                && item.runtimeProvider == composerState.turnOptions.runtimeProvider
                && (composerState.turnOptions.modelProvider == nil
                    || item.provider == composerState.turnOptions.modelProvider)
        }) {
            return developerModeEnabled ? option.menuTitle : option.title
        }
        if developerModeEnabled,
           let provider = composerState.turnOptions.modelProvider?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !provider.isEmpty {
            return "\(model) · \(provider)"
        }
        return model
    }

    var defaultModelSummaryTitle: String {
        guard let option = modelOptionsForMenu.first(where: \.isDefault)
            ?? modelOptionsForMenu.first
        else {
            return L10n.text("ui.default_model")
        }
        return developerModeEnabled ? option.menuTitle : option.title
    }

    var selectedSessionRuntimeProviderForModelMenu: String? {
        guard let session = sessionStore.selectedSession else {
            return nil
        }
        // 新建页已经选择了 runtime；本地草稿的 nil 是 Codex 的协议简写，不表示
        // 可以再由模型菜单切换到 Claude。
        if session.source == "local", session.runtimeProvider == nil {
            return "codex"
        }
        return normalizedRuntimeProvider(session.runtimeProvider ?? session.source)
    }

    func clampModelSelectionToSelectedSessionRuntime() {
        guard let runtimeProvider = selectedSessionRuntimeProviderForModelMenu else {
            return
        }
        let runtimeChanged =
            normalizedRuntimeProvider(composerState.turnOptions.runtimeProvider) != runtimeProvider
        let explicitModelID = composerState.turnOptions.model?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .appServerNilIfEmpty
        let unsupportedModel = !developerModeEnabled
            && explicitModelID != nil
            && modelOption(matching: explicitModelID) == nil
        let normalizedEffort: CodexAppServerReasoningEffort?
        if developerModeEnabled {
            normalizedEffort = composerState.turnOptions.reasoningEffort.flatMap { effort in
                supportsReasoningEffort(effort, modelID: effectiveModelID) ? effort : nil
            }
        } else {
            let option = modelOption(matching: effectiveModelID)
            normalizedEffort = ModelReasoningGridCatalog.normalizedVisibleEffort(
                option: option,
                current: composerState.turnOptions.reasoningEffort,
                layout: modelReasoningGridLayout
            )
        }
        let unsupportedEffort = composerState.turnOptions.reasoningEffort != normalizedEffort
        let unsupportedServiceTier = runtimeProvider == "claude"
            && composerState.turnOptions.serviceTier?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        guard runtimeChanged || unsupportedModel || unsupportedEffort || unsupportedServiceTier else {
            return
        }
        composerState.updateTurnOptions { options in
            if runtimeChanged || unsupportedModel {
                // 切换 runtime 或目录刷新淘汰旧模型时，使用产品约定默认值：
                // Codex 为 GPT-5.6 Sol/xhigh，Claude 为 Opus 5/high。
                applyPreferredDefaultModel(runtimeProvider: runtimeProvider, to: &options)
            } else if unsupportedEffort {
                options.reasoningEffort = normalizedEffort
            }
            if runtimeProvider == "claude" {
                options.serviceTier = nil
            }
        }
    }

    func applyPreferredDefaultModel(
        runtimeProvider: String,
        to options: inout CodexAppServerTurnOptions
    ) {
        guard let option = ModelReasoningGridCatalog.preferredDefaultOption(
            runtimeProvider: runtimeProvider,
            options: modelOptionsForMenu
        ) else {
            options.runtimeProvider = runtimeProvider == "codex" ? nil : runtimeProvider
            options.model = nil
            options.modelProvider = nil
            options.reasoningEffort = nil
            options.serviceTier = nil
            return
        }
        let layout = ModelReasoningGridCatalog.layout(
            runtimeProvider: runtimeProvider,
            options: modelOptionsForMenu
        )
        let effort = ModelReasoningGridCatalog.preferredDefaultEffort(
            runtimeProvider: runtimeProvider,
            option: option,
            layout: layout
        )
        ModelReasoningGridCatalog.applySelection(
            option: option,
            effort: effort,
            preservesServerDefault: false,
            fallbackRuntimeProvider: runtimeProvider == "codex" ? nil : runtimeProvider,
            to: &options
        )
        options.serviceTier = nil
    }

    func supportsReasoningEffort(
        _ effort: CodexAppServerReasoningEffort,
        modelID: String?
    ) -> Bool {
        let option = modelOption(matching: modelID)
        guard let option else {
            // 未知/自定义模型继续走开发者模式原有能力，不能因本地目录不认识就擅自降级。
            return true
        }
        return ModelReasoningGridCatalog.supports(
            effort,
            option: option,
            kind: modelReasoningGridLayout.kind
        )
    }

    func normalizeModelControlsForStandardComposer(
        _ options: inout CodexAppServerTurnOptions
    ) {
        let modelID = ModelReasoningGridCatalog.effectiveModelID(
            selectedModelID: options.model,
            options: modelOptionsForMenu
        )
        let option = modelOption(matching: modelID)
        options.reasoningEffort = ModelReasoningGridCatalog.normalizedVisibleEffort(
            option: option,
            current: options.reasoningEffort,
            layout: modelReasoningGridLayout
        )
        // 普通模式只有 Fast 会写 priority；auto/flex 仅属于开发者高级选项。
        options.serviceTier = ModelReasoningGridCatalog.normalizedStandardServiceTier(
            options.serviceTier,
            runtimeProvider: options.runtimeProvider
        )
    }

    func modelOption(matching modelID: String?) -> CodexAppServerModelOption? {
        guard let modelID else { return nil }
        return modelOptionsForMenu.first {
            $0.model.caseInsensitiveCompare(modelID) == .orderedSame
        } ?? modelReasoningGridLayout.model(matching: modelID)
    }

    func payloadRuntimeProviderForSelectedSessionLock() -> String? {
        guard let runtimeProvider = selectedSessionRuntimeProviderForModelMenu else {
            return nil
        }
        return runtimeProvider == "codex" ? nil : runtimeProvider
    }

    func normalizedRuntimeProvider(_ rawValue: String?) -> String {
        CodexAppServerSessionRuntime.normalizedRuntimeProvider(rawValue)
    }
}
