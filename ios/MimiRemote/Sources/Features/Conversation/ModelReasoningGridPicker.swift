import SwiftUI
import UIKit

struct GPT56ModelGridSelection: Equatable {
    let modelID: String
    let effort: CodexAppServerReasoningEffort
}

enum GPT56ModelGridCatalog {
    static let modelOrder = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
    static let efforts: [CodexAppServerReasoningEffort] = [.medium, .high, .xhigh]

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

    static func isGridModel(_ modelID: String?) -> Bool {
        guard let modelID else { return false }
        return modelOrder.contains(modelID.lowercased())
    }

    static func triggerTitle(
        for modelID: String,
        effort: CodexAppServerReasoningEffort
    ) -> String? {
        guard isGridModel(modelID) else { return nil }
        return "5.6 \(shortTitle(for: modelID)) · \(effortTitle(effort))"
    }

    static func showsStandaloneReasoningControl(
        runtimeProvider: String?,
        modelID: String?
    ) -> Bool {
        runtimeProvider == "claude" || !isGridModel(modelID)
    }

    static func rows(from options: [CodexAppServerModelOption]) -> [CodexAppServerModelOption] {
        let visible = options.filter { !$0.hidden }
        return modelOrder.compactMap { id in
            visible.first { $0.model.lowercased() == id }
                ?? CodexAppServerModelOption.builtInFallback.first { $0.model == id }
        }
    }

    static func shortTitle(for modelID: String) -> String {
        switch modelID.lowercased() {
        case "gpt-5.6-sol": return "Sol"
        case "gpt-5.6-terra": return "Terra"
        case "gpt-5.6-luna": return "Luna"
        default: return modelID
        }
    }

    static func effortTitle(_ effort: CodexAppServerReasoningEffort) -> String {
        switch effort {
        case .medium: return L10n.text("ui.in")
        case .high: return L10n.text("ui.high")
        case .xhigh: return L10n.text("ui.highest")
        default: return effort.rawValue
        }
    }

    static func supports(_ effort: CodexAppServerReasoningEffort, option: CodexAppServerModelOption) -> Bool {
        option.supportedReasoningEfforts.isEmpty || option.supportedReasoningEfforts.contains(effort.rawValue)
    }
}

struct ModelReasoningGridPicker: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let options: [CodexAppServerModelOption]
    let selection: GPT56ModelGridSelection
    let selectedModelID: String?
    let isRefreshing: Bool
    let isFastMode: Bool
    let onSelect: (CodexAppServerModelOption, CodexAppServerReasoningEffort) -> Void
    let onFastModeChange: (Bool) -> Void
    let onSelectModelOnly: (CodexAppServerModelOption?) -> Void
    let onRefresh: () -> Void

    @State private var dragPoint: CGPoint?
    @State private var previewSelection: GPT56ModelGridSelection?
    @State private var lastHapticSelection: GPT56ModelGridSelection?
    @State private var isDragging = false
    @State private var gestureRevision = 0

    // 九宫格保持 54pt 的单格高度；删掉解释性文案后收窄浮层，但不给 Dynamic Type 继续挤压行名。
    private let pickerWidth: CGFloat = 352
    private let rowLabelWidth: CGFloat = 52
    private let gridHeight: CGFloat = 162
    private let dragCancellationMargin: CGFloat = 12

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let rows = GPT56ModelGridCatalog.rows(from: options)

        VStack(alignment: .leading, spacing: 8) {
            header(tokens: tokens)
            columnLabels(tokens: tokens)
            HStack(spacing: 8) {
                rowLabels(rows: rows, tokens: tokens)
                grid(rows: rows, tokens: tokens)
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
                ForEach(GPT56ModelGridCatalog.efforts) { effort in
                    Text(GPT56ModelGridCatalog.effortTitle(effort))
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(activeSelection.effort == effort ? tokens.accent : tokens.secondaryText)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func rowLabels(rows: [CodexAppServerModelOption], tokens: ThemeTokens) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { option in
                Text(GPT56ModelGridCatalog.shortTitle(for: option.model))
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

    private func grid(rows: [CodexAppServerModelOption], tokens: ThemeTokens) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            let cellSize = CGSize(width: size.width / 3, height: size.height / 3)

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tokens.elevatedSurface.opacity(reduceTransparency ? 1 : 0.56))

                gridLines(size: size, tokens: tokens)

                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { rowIndex, option in
                        HStack(spacing: 0) {
                            ForEach(Array(GPT56ModelGridCatalog.efforts.enumerated()), id: \.element.id) { columnIndex, effort in
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
                    .position(dragPoint ?? center(for: activeSelection, rows: rows, size: size))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tokens.border.opacity(0.72), lineWidth: 0.75)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .simultaneousGesture(dragGesture(rows: rows, size: size))
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
        let candidate = GPT56ModelGridSelection(modelID: option.model, effort: effort)
        let selected = activeSelection == candidate
        let supported = GPT56ModelGridCatalog.supports(effort, option: option)

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
        .accessibilityLabel(L10n.format("ui.value_reasoning_strength_value", GPT56ModelGridCatalog.shortTitle(for: option.model), GPT56ModelGridCatalog.effortTitle(effort)))
        .accessibilityValue(selected ? L10n.text("ui.selected") : L10n.text("ui.not_selected"))
        .accessibilityHint(L10n.text("ui.double_click_to_select_you_can_also_drag"))
    }

    private func gridLines(size: CGSize, tokens: ThemeTokens) -> some View {
        Path { path in
            for column in 1...2 {
                let x = size.width * CGFloat(column) / 3
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for row in 1...2 {
                let y = size.height * CGFloat(row) / 3
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
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

    private func dragGesture(rows: [CodexAppServerModelOption], size: CGSize) -> some Gesture {
        // 单击交给格子 Button；8pt 后才认定为拖动，避免一次点击同时走两条提交链路。
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    gestureRevision += 1
                }
                let point = rubberBanded(value.location, size: size)
                dragPoint = point
                guard let candidate = candidate(at: value.location, rows: rows, size: size),
                      let option = rows.first(where: { $0.model == candidate.modelID }),
                      GPT56ModelGridCatalog.supports(candidate.effort, option: option)
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
                guard let candidate = candidate(at: value.location, rows: rows, size: size),
                      let option = rows.first(where: { $0.model == candidate.modelID }),
                      GPT56ModelGridCatalog.supports(candidate.effort, option: option)
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
                    dragPoint = center(for: candidate, rows: rows, size: size)
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

    private var activeSelection: GPT56ModelGridSelection {
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
        rows: [CodexAppServerModelOption],
        size: CGSize
    ) -> GPT56ModelGridSelection? {
        guard rows.count == 3, size.width > 0, size.height > 0 else { return nil }
        guard point.x >= -dragCancellationMargin,
              point.x <= size.width + dragCancellationMargin,
              point.y >= -dragCancellationMargin,
              point.y <= size.height + dragCancellationMargin
        else {
            return nil
        }
        let x = min(max(point.x, 0), size.width - 0.001)
        let y = min(max(point.y, 0), size.height - 0.001)
        let column = min(2, max(0, Int(x / (size.width / 3))))
        let row = min(2, max(0, Int(y / (size.height / 3))))
        return GPT56ModelGridSelection(
            modelID: rows[row].model,
            effort: GPT56ModelGridCatalog.efforts[column]
        )
    }

    private func center(
        for selection: GPT56ModelGridSelection,
        rows: [CodexAppServerModelOption],
        size: CGSize
    ) -> CGPoint {
        let row = rows.firstIndex(where: { $0.model == selection.modelID }) ?? 0
        let column = GPT56ModelGridCatalog.efforts.firstIndex(of: selection.effort) ?? 0
        return CGPoint(
            x: (CGFloat(column) + 0.5) * size.width / 3,
            y: (CGFloat(row) + 0.5) * size.height / 3
        )
    }

    private func commit(_ candidate: GPT56ModelGridSelection, option: CodexAppServerModelOption) {
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
