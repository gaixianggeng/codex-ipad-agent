import SwiftUI
import UIKit

struct ModelReasoningGridSelection: Equatable {
    let modelID: String
    let effort: CodexAppServerReasoningEffort
}

enum ModelReasoningGridKind: Equatable {
    case codex
    case claude
}

struct ModelReasoningGridLayout: Equatable {
    let kind: ModelReasoningGridKind
    let rows: [CodexAppServerModelOption]
    let efforts: [CodexAppServerReasoningEffort]
    let showsFastMode: Bool

    func row(matching modelID: String?) -> CodexAppServerModelOption? {
        guard let modelID else { return nil }
        switch kind {
        case .codex:
            return rows.first { $0.model.caseInsensitiveCompare(modelID) == .orderedSame }
        case .claude:
            guard let family = ModelReasoningGridCatalog.claudeFamily(for: modelID) else { return nil }
            return rows.first { ModelReasoningGridCatalog.claudeFamily(for: $0.model) == family }
        }
    }

    func contains(modelID: String?) -> Bool {
        row(matching: modelID) != nil
    }
}

enum ModelReasoningGridCatalog {
    static let codexModelOrder = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
    static let codexEfforts: [CodexAppServerReasoningEffort] = [.medium, .high, .xhigh]
    static let claudeFamilyOrder = ["haiku", "sonnet", "opus", "fable"]
    static let claudeEfforts: [CodexAppServerReasoningEffort] = [.minimal, .low, .medium, .high]

    static func effectiveModelID(
        selectedModelID: String?,
        options: [CodexAppServerModelOption]
    ) -> String? {
        if let selectedModelID = selectedModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !selectedModelID.isEmpty {
            return selectedModelID
        }

        // model == nil 表示沿用服务端默认模型；展示层必须解析成真实模型，
        // 否则默认 GPT-5.6 会被误判为普通模型，重复显示独立推理入口。
        let visibleOptions = options.filter { !$0.hidden }
        return (visibleOptions.first(where: \.isDefault) ?? visibleOptions.first)?.model
    }

    static func layout(
        runtimeProvider: String?,
        options: [CodexAppServerModelOption]
    ) -> ModelReasoningGridLayout {
        let visible = options.filter { !$0.hidden }
        let runtime = runtimeProvider?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if runtime == "claude" {
            let source = visible.isEmpty ? CodexAppServerModelOption.builtInClaudeFallback : visible
            let rows = claudeFamilyOrder.compactMap { family in
                preferredClaudeOption(family: family, options: source)
            }
            let resolvedRows = rows.isEmpty ? Array(source.prefix(3)) : rows
            return ModelReasoningGridLayout(
                kind: .claude,
                rows: resolvedRows,
                efforts: supportedEfforts(in: resolvedRows, fallback: claudeEfforts),
                showsFastMode: false
            )
        }

        let rows = codexModelOrder.compactMap { id in
            visible.first { $0.model.caseInsensitiveCompare(id) == .orderedSame }
                ?? CodexAppServerModelOption.builtInFallback.first { $0.model == id }
        }
        return ModelReasoningGridLayout(
            kind: .codex,
            rows: rows,
            efforts: supportedEfforts(in: rows, fallback: codexEfforts),
            showsFastMode: true
        )
    }

    static func triggerTitle(
        for modelID: String,
        effort: CodexAppServerReasoningEffort,
        layout: ModelReasoningGridLayout
    ) -> String? {
        guard let option = layout.row(matching: modelID) else { return nil }
        let modelTitle: String
        switch layout.kind {
        case .codex:
            modelTitle = "5.6 \(shortTitle(for: option, kind: .codex))"
        case .claude:
            modelTitle = shortTitle(for: option, kind: .claude)
        }
        return "\(modelTitle) · \(effortTitle(effort))"
    }

    static func shortTitle(
        for option: CodexAppServerModelOption,
        kind: ModelReasoningGridKind
    ) -> String {
        guard kind == .claude else {
            return shortTitle(for: option.model, kind: kind)
        }

        let title = option.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              title.caseInsensitiveCompare(option.model) != .orderedSame
        else {
            return shortTitle(for: option.model, kind: kind)
        }

        // Claude alias 会随 CLI 升级指向新版本，版本号必须来自服务端模型目录，
        // 不能按 family 写死，否则旧 bridge 的具体模型会被展示成尚未使用的新版本。
        if let prefix = title.range(of: "Claude ", options: [.anchored, .caseInsensitive]) {
            let stripped = String(title[prefix.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stripped.isEmpty ? shortTitle(for: option.model, kind: kind) : stripped
        }
        return title
    }

    static func shortTitle(for modelID: String, kind: ModelReasoningGridKind) -> String {
        switch kind {
        case .codex:
            switch modelID.lowercased() {
            case "gpt-5.6-sol": return "Sol"
            case "gpt-5.6-terra": return "Terra"
            case "gpt-5.6-luna": return "Luna"
            default: return modelID
            }
        case .claude:
            switch claudeFamily(for: modelID) {
            case "fable": return "Fable"
            case "sonnet": return "Sonnet"
            case "opus": return "Opus"
            case "haiku": return "Haiku"
            default: return modelID
            }
        }
    }

    static func effortTitle(_ effort: CodexAppServerReasoningEffort) -> String {
        switch effort {
        case .none: return L10n.text("ui.close")
        case .minimal: return L10n.text("ui.lowest")
        case .low: return L10n.text("ui.low")
        case .medium: return L10n.text("ui.in")
        case .high: return L10n.text("ui.high")
        case .xhigh: return L10n.text("ui.highest")
        }
    }

    static func supports(_ effort: CodexAppServerReasoningEffort, option: CodexAppServerModelOption) -> Bool {
        option.supportedReasoningEfforts.isEmpty || option.supportedReasoningEfforts.contains(effort.rawValue)
    }

    static func supports(
        _ effort: CodexAppServerReasoningEffort,
        option: CodexAppServerModelOption,
        layout: ModelReasoningGridLayout
    ) -> Bool {
        let isGridEffortAvailable = !layout.contains(modelID: option.model) || layout.efforts.contains(effort)
        return isGridEffortAvailable && supports(effort, option: option)
    }

    static func supportedEfforts(
        for option: CodexAppServerModelOption?,
        layout: ModelReasoningGridLayout
    ) -> [CodexAppServerReasoningEffort] {
        guard let option else {
            // 未知/自定义模型沿用开发者模式原有入口，不凭本地目录擅自限制服务端能力。
            return CodexAppServerReasoningEffort.allCases
        }
        return CodexAppServerReasoningEffort.allCases.filter {
            supports($0, option: option, layout: layout)
        }
    }

    static func reasoningEffortForModelSelection(
        option: CodexAppServerModelOption?,
        current: CodexAppServerReasoningEffort?,
        layout: ModelReasoningGridLayout
    ) -> CodexAppServerReasoningEffort? {
        guard let option else {
            return nil
        }
        if let defaultEffort = option.defaultReasoningEffort.flatMap(CodexAppServerReasoningEffort.init(rawValue:)),
           supports(defaultEffort, option: option, layout: layout) {
            return defaultEffort
        }
        guard let current, supports(current, option: option, layout: layout) else {
            return nil
        }
        return current
    }

    static func claudeFamily(for modelID: String) -> String? {
        let normalized = modelID.lowercased()
        return claudeFamilyOrder.first { family in
            normalized == family || normalized.contains("-\(family)-") || normalized.hasSuffix("-\(family)")
        }
    }

    private static func preferredClaudeOption(
        family: String,
        options: [CodexAppServerModelOption]
    ) -> CodexAppServerModelOption? {
        let matches = options.filter { claudeFamily(for: $0.model) == family }
        return matches.first(where: \CodexAppServerModelOption.isDefault)
            ?? matches.first(where: { $0.model.lowercased() != family })
            ?? matches.first
    }

    private static func supportedEfforts(
        in rows: [CodexAppServerModelOption],
        fallback: [CodexAppServerReasoningEffort]
    ) -> [CodexAppServerReasoningEffort] {
        let supported = Set(rows.flatMap(\.supportedReasoningEfforts))
        guard !supported.isEmpty else { return fallback }
        return CodexAppServerReasoningEffort.allCases.filter { supported.contains($0.rawValue) }
    }
}

struct ModelReasoningGridPicker: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let options: [CodexAppServerModelOption]
    let layout: ModelReasoningGridLayout
    let selection: ModelReasoningGridSelection
    let selectedModelID: String?
    let isRefreshing: Bool
    let isFastMode: Bool
    let onSelect: (CodexAppServerModelOption, CodexAppServerReasoningEffort) -> Void
    let onFastModeChange: (Bool) -> Void
    let onSelectModelOnly: (CodexAppServerModelOption?) -> Void
    let onRefresh: () -> Void

    @State private var dragPoint: CGPoint?
    @State private var previewSelection: ModelReasoningGridSelection?
    @State private var lastHapticSelection: ModelReasoningGridSelection?
    @State private var isDragging = false
    @State private var gestureRevision = 0

    // 每行保持 54pt；渠道只提供行列数据，手势、动效和可访问性统一由组件负责。
    private let pickerWidth: CGFloat = 352
    private let dragCancellationMargin: CGFloat = 12

    private var rowLabelWidth: CGFloat {
        layout.kind == .claude ? 68 : 52
    }

    private var gridHeight: CGFloat {
        CGFloat(max(layout.rows.count, 1)) * 54
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        VStack(alignment: .leading, spacing: 8) {
            header(tokens: tokens)
            columnLabels(tokens: tokens)
            HStack(spacing: 8) {
                rowLabels(tokens: tokens)
                grid(tokens: tokens)
            }
        }
        .padding(12)
        .frame(width: pickerWidth)
        .background(tokens.surface)
        .onChange(of: selection) { _, _ in
            guard dragPoint == nil else { return }
            previewSelection = nil
        }
    }

    private func header(tokens: ThemeTokens) -> some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    onSelectModelOnly(nil)
                } label: {
                    Label(L10n.text("ui.default_model"), systemImage: "arrow.uturn.backward")
                }
                ForEach(visibleAllModels) { option in
                    Button {
                        onSelectModelOnly(option)
                    } label: {
                        Label(option.menuTitle, systemImage: option.model == selectedModelID ? "checkmark" : "cpu")
                    }
                }
                Divider()
                Button(action: onRefresh) {
                    Label(isRefreshing ? L10n.text("ui.refreshing") : L10n.text("ui.refresh_model_list"), systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing)
            } label: {
                HStack(spacing: 4) {
                    Text(L10n.text("ui.all_models"))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(themeStore.uiFont(size: 9, weight: .bold))
                }
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tokens.accent)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(tokens.elevatedSurface.opacity(0.72), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(tokens.border.opacity(0.58), lineWidth: 0.75)
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(ComposerPressButtonStyle(reduceMotion: reduceMotion))
            .accessibilityLabel(L10n.text("ui.all_models"))

            Spacer(minLength: 12)

            if layout.showsFastMode {
                Toggle(isOn: fastModeBinding) {
                    HStack(spacing: 5) {
                        Image(systemName: isFastMode ? "bolt.fill" : "bolt")
                        Text(L10n.text("ui.fast"))
                    }
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(isFastMode ? Color.white : tokens.accent)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(
                        isFastMode ? tokens.accent : tokens.elevatedSurface.opacity(0.72),
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .strokeBorder(
                                isFastMode ? tokens.accent.opacity(0.88) : tokens.border.opacity(0.58),
                                lineWidth: 0.75
                            )
                    }
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .toggleStyle(.button)
                .buttonStyle(ComposerPressButtonStyle(reduceMotion: reduceMotion))
                .accessibilityLabel(L10n.text("ui.quick_mode"))
                .accessibilityValue(isFastMode ? L10n.text("ui.already_turned_on") : L10n.text("ui.closed"))
                .accessibilityHint(L10n.text("ui.after_turning_it_on_the_priority_service_speed"))
            }
        }
        .frame(height: 44)
    }

    private var fastModeBinding: Binding<Bool> {
        Binding(
            get: { isFastMode },
            set: { newValue in
                guard newValue != isFastMode else { return }
                UISelectionFeedbackGenerator().selectionChanged()
                onFastModeChange(newValue)
            }
        )
    }

    private func columnLabels(tokens: ThemeTokens) -> some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: rowLabelWidth, height: 1)
            HStack(spacing: 0) {
                ForEach(layout.efforts) { effort in
                    Text(ModelReasoningGridCatalog.effortTitle(effort))
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(activeSelection.effort == effort ? tokens.accent : tokens.secondaryText)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func rowLabels(tokens: ThemeTokens) -> some View {
        VStack(spacing: 0) {
            ForEach(layout.rows) { option in
                Text(ModelReasoningGridCatalog.shortTitle(for: option, kind: layout.kind))
                    .font(themeStore.uiFont(.subheadline, weight: .semibold))
                    .foregroundStyle(activeSelection.modelID == option.model ? tokens.accent : tokens.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .frame(width: rowLabelWidth, alignment: .trailing)
                    .frame(maxHeight: .infinity, alignment: .trailing)
            }
        }
        .frame(width: rowLabelWidth, height: gridHeight)
    }

    private func grid(tokens: ThemeTokens) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            let cellSize = CGSize(
                width: size.width / CGFloat(max(layout.efforts.count, 1)),
                height: size.height / CGFloat(max(layout.rows.count, 1))
            )

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tokens.elevatedSurface.opacity(reduceTransparency ? 1 : 0.56))

                gridLines(size: size, tokens: tokens)

                VStack(spacing: 0) {
                    ForEach(Array(layout.rows.enumerated()), id: \.element.id) { rowIndex, option in
                        HStack(spacing: 0) {
                            ForEach(Array(layout.efforts.enumerated()), id: \.element.id) { columnIndex, effort in
                                gridCell(
                                    option: option,
                                    effort: effort,
                                    row: rowIndex,
                                    column: columnIndex,
                                    tokens: tokens
                                )
                                .frame(width: cellSize.width, height: cellSize.height)
                            }
                        }
                    }
                }

                selectionLens(tokens: tokens)
                    .position(dragPoint ?? center(for: activeSelection, size: size))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tokens.border.opacity(0.72), lineWidth: 0.75)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .simultaneousGesture(dragGesture(size: size))
        }
        .frame(height: gridHeight)
    }

    private func gridCell(
        option: CodexAppServerModelOption,
        effort: CodexAppServerReasoningEffort,
        row: Int,
        column: Int,
        tokens: ThemeTokens
    ) -> some View {
        let candidate = ModelReasoningGridSelection(modelID: option.model, effort: effort)
        let selected = activeSelection == candidate
        let supported = ModelReasoningGridCatalog.supports(effort, option: option)

        return Button {
            guard supported else { return }
            commit(candidate, option: option)
        } label: {
            ZStack {
                if selected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(tokens.accent.opacity(0.055))
                        .padding(4)
                }
                Circle()
                    .fill(selected ? tokens.accent.opacity(0.28) : tokens.tertiaryText.opacity(supported ? 0.32 : 0.12))
                    .frame(width: selected ? 8 : 6, height: selected ? 8 : 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(ComposerPressButtonStyle(reduceMotion: reduceMotion))
        .disabled(!supported)
        .accessibilityLabel(L10n.format(
            "ui.value_reasoning_strength_value",
            ModelReasoningGridCatalog.shortTitle(for: option, kind: layout.kind),
            ModelReasoningGridCatalog.effortTitle(effort)
        ))
        .accessibilityValue(selected ? L10n.text("ui.selected") : L10n.text("ui.not_selected"))
        .accessibilityHint(L10n.text("ui.double_click_to_select_you_can_also_drag"))
    }

    private func gridLines(size: CGSize, tokens: ThemeTokens) -> some View {
        Path { path in
            if layout.efforts.count > 1 {
                for column in 1..<layout.efforts.count {
                    let x = size.width * CGFloat(column) / CGFloat(layout.efforts.count)
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
            }
            if layout.rows.count > 1 {
                for row in 1..<layout.rows.count {
                    let y = size.height * CGFloat(row) / CGFloat(layout.rows.count)
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
        }
        .stroke(tokens.border.opacity(0.46), lineWidth: 0.75)
    }

    private func selectionLens(tokens: ThemeTokens) -> some View {
        ZStack {
            Circle()
                .fill(tokens.accent.opacity(0.13))
                .frame(width: 38, height: 38)
                .blur(radius: 4)
            Circle()
                .fill(tokens.accent.gradient)
                .frame(width: 26, height: 26)
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.58), lineWidth: 1)
                }
                .shadow(color: tokens.accent.opacity(0.28), radius: 5, y: 2)
            Circle()
                .fill(Color.white.opacity(0.48))
                .frame(width: 4, height: 4)
                .offset(x: -5, y: -5)
        }
        .scaleEffect(!isDragging || reduceMotion ? 1 : 1.06)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.22, dampingFraction: 1), value: isDragging)
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        // 单击交给格子 Button；8pt 后才认定为拖动，避免一次点击同时走两条提交链路。
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    gestureRevision += 1
                }
                let point = rubberBanded(value.location, size: size)
                dragPoint = point
                guard let candidate = candidate(at: value.location, size: size),
                      let option = layout.rows.first(where: { $0.model == candidate.modelID }),
                      ModelReasoningGridCatalog.supports(candidate.effort, option: option)
                else {
                    // 手指可继续看到橡皮筋阻力；超出容错边界后清掉预览，松手会取消选择。
                    previewSelection = nil
                    lastHapticSelection = nil
                    return
                }
                guard candidate != previewSelection else { return }
                previewSelection = candidate
                if candidate != lastHapticSelection {
                    UISelectionFeedbackGenerator().selectionChanged()
                    lastHapticSelection = candidate
                }
            }
            .onEnded { value in
                isDragging = false
                guard let candidate = candidate(at: value.location, size: size),
                      let option = layout.rows.first(where: { $0.model == candidate.modelID }),
                      ModelReasoningGridCatalog.supports(candidate.effort, option: option)
                else {
                    withAnimation(dragSettleAnimation) {
                        dragPoint = nil
                        previewSelection = nil
                    }
                    lastHapticSelection = nil
                    return
                }
                withAnimation(dragSettleAnimation) {
                    previewSelection = candidate
                    dragPoint = center(for: candidate, size: size)
                }
                onSelect(option, candidate.effort)
                let completedRevision = gestureRevision
                DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.13 : 0.32)) {
                    guard completedRevision == gestureRevision, !isDragging else { return }
                    dragPoint = nil
                    previewSelection = nil
                    lastHapticSelection = nil
                }
            }
    }

    private var activeSelection: ModelReasoningGridSelection {
        previewSelection ?? selection
    }

    private var tapSelectionAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.1)
            : .spring(response: 0.24, dampingFraction: 1)
    }

    private var dragSettleAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.3, dampingFraction: 1)
    }

    private var visibleAllModels: [CodexAppServerModelOption] {
        options.filter { !$0.hidden }
    }

    private func candidate(
        at point: CGPoint,
        size: CGSize
    ) -> ModelReasoningGridSelection? {
        guard !layout.rows.isEmpty,
              !layout.efforts.isEmpty,
              size.width > 0,
              size.height > 0
        else {
            return nil
        }
        guard point.x >= -dragCancellationMargin,
              point.x <= size.width + dragCancellationMargin,
              point.y >= -dragCancellationMargin,
              point.y <= size.height + dragCancellationMargin
        else {
            return nil
        }
        let x = min(max(point.x, 0), size.width - 0.001)
        let y = min(max(point.y, 0), size.height - 0.001)
        let columnWidth = size.width / CGFloat(layout.efforts.count)
        let rowHeight = size.height / CGFloat(layout.rows.count)
        let column = min(layout.efforts.count - 1, max(0, Int(x / columnWidth)))
        let row = min(layout.rows.count - 1, max(0, Int(y / rowHeight)))
        return ModelReasoningGridSelection(
            modelID: layout.rows[row].model,
            effort: layout.efforts[column]
        )
    }

    private func center(
        for selection: ModelReasoningGridSelection,
        size: CGSize
    ) -> CGPoint {
        let row = layout.rows.firstIndex(where: { $0.model == selection.modelID }) ?? 0
        let column = layout.efforts.firstIndex(of: selection.effort) ?? 0
        return CGPoint(
            x: (CGFloat(column) + 0.5) * size.width / CGFloat(max(layout.efforts.count, 1)),
            y: (CGFloat(row) + 0.5) * size.height / CGFloat(max(layout.rows.count, 1))
        )
    }

    private func commit(_ candidate: ModelReasoningGridSelection, option: CodexAppServerModelOption) {
        gestureRevision += 1
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(tapSelectionAnimation) {
            previewSelection = candidate
            dragPoint = nil
        }
        onSelect(option, candidate.effort)
        let completedRevision = gestureRevision
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.11 : 0.24)) {
            guard completedRevision == gestureRevision, !isDragging else { return }
            previewSelection = nil
            lastHapticSelection = nil
        }
    }

    private func rubberBanded(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: rubberBanded(point.x, lower: 0, upper: size.width),
            y: rubberBanded(point.y, lower: 0, upper: size.height)
        )
    }

    private func rubberBanded(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        if value < lower {
            return lower - rubberDistance(lower - value)
        }
        if value > upper {
            return upper + rubberDistance(value - upper)
        }
        return value
    }

    private func rubberDistance(_ distance: CGFloat) -> CGFloat {
        // 边缘阻力只提供“碰到边界”的物理反馈，不允许离散选择跳出九宫格。
        18 * (1 - 1 / (distance / 70 + 1))
    }
}
