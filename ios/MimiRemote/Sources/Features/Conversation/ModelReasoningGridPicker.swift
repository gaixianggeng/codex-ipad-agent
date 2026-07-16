import SwiftUI
import UIKit

struct GPT56ModelGridSelection: Equatable {
    let modelID: String
    let effort: CodexAppServerReasoningEffort
}

enum GPT56ModelGridCatalog {
    static let modelOrder = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
    static let efforts: [CodexAppServerReasoningEffort] = [.medium, .high, .xhigh]

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

    static func detail(for modelID: String) -> String {
        switch modelID.lowercased() {
        case "gpt-5.6-sol": return "精细与完成度"
        case "gpt-5.6-terra": return "日常均衡"
        case "gpt-5.6-luna": return "清晰可复现"
        default: return ""
        }
    }

    static func effortTitle(_ effort: CodexAppServerReasoningEffort) -> String {
        switch effort {
        case .medium: return "中"
        case .high: return "高"
        case .xhigh: return "最高"
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
    let onSelect: (CodexAppServerModelOption, CodexAppServerReasoningEffort) -> Void
    let onSelectModelOnly: (CodexAppServerModelOption?) -> Void
    let onRefresh: () -> Void

    @State private var dragPoint: CGPoint?
    @State private var previewSelection: GPT56ModelGridSelection?
    @State private var lastHapticSelection: GPT56ModelGridSelection?
    @State private var isDragging = false
    @State private var gestureRevision = 0

    private let rowLabelWidth: CGFloat = 82
    private let gridHeight: CGFloat = 228

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let rows = GPT56ModelGridCatalog.rows(from: options)

        VStack(alignment: .leading, spacing: 14) {
            header(tokens: tokens)
            columnLabels(tokens: tokens)
            HStack(spacing: 10) {
                rowLabels(rows: rows, tokens: tokens)
                grid(rows: rows, tokens: tokens)
            }
            HStack(spacing: 6) {
                Image(systemName: "hand.draw")
                Text("在九宫格内滑动，同时切换模型与推理强度")
            }
            .font(themeStore.uiFont(.caption))
            .foregroundStyle(tokens.secondaryText)
        }
        .padding(16)
        .frame(width: 470)
        .background(tokens.surface)
        .onChange(of: selection) { _, _ in
            guard dragPoint == nil else { return }
            previewSelection = nil
        }
    }

    private func header(tokens: ThemeTokens) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("GPT-5.6")
                    .font(themeStore.uiFont(.headline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text("模型 × 推理强度")
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
            }
            Spacer()
            Menu {
                Button {
                    onSelectModelOnly(nil)
                } label: {
                    Label("默认模型", systemImage: "arrow.uturn.backward")
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
                    Label(isRefreshing ? "刷新中" : "刷新模型列表", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing)
            } label: {
                Label("全部模型", systemImage: "chevron.right")
                    .font(themeStore.uiFont(.caption, weight: .semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func columnLabels(tokens: ThemeTokens) -> some View {
        HStack(spacing: 10) {
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
                VStack(alignment: .trailing, spacing: 2) {
                    Text(GPT56ModelGridCatalog.shortTitle(for: option.model))
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .foregroundStyle(activeSelection.modelID == option.model ? tokens.accent : tokens.primaryText)
                    Text(GPT56ModelGridCatalog.detail(for: option.model))
                        .font(themeStore.uiFont(size: 9, weight: .medium))
                        .foregroundStyle(tokens.tertiaryText)
                        .lineLimit(1)
                }
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
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(reduceTransparency ? tokens.elevatedSurface : Color.clear)
                if !reduceTransparency {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.ultraThinMaterial)
                }

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
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(tokens.border.opacity(0.9), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tokens.accent.opacity(0.09))
                        .padding(6)
                }
                Circle()
                    .fill(selected ? tokens.accent.opacity(0.28) : tokens.tertiaryText.opacity(supported ? 0.32 : 0.12))
                    .frame(width: selected ? 12 : 8, height: selected ? 12 : 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!supported)
        .accessibilityLabel("\(GPT56ModelGridCatalog.shortTitle(for: option.model))，推理强度\(GPT56ModelGridCatalog.effortTitle(effort))")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityHint("双击选择；也可在九宫格中拖动")
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
        .stroke(tokens.border.opacity(0.72), lineWidth: 1)
    }

    private func selectionLens(tokens: ThemeTokens) -> some View {
        ZStack {
            Circle()
                .fill(tokens.accent.opacity(0.16))
                .frame(width: 50, height: 50)
                .blur(radius: 5)
            Circle()
                .fill(tokens.accent.gradient)
                .frame(width: 34, height: 34)
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.62), lineWidth: 1.5)
                }
                .shadow(color: tokens.accent.opacity(0.38), radius: 9, y: 3)
            Circle()
                .fill(Color.white.opacity(0.48))
                .frame(width: 6, height: 6)
                .offset(x: -7, y: -7)
        }
        .scaleEffect(!isDragging || reduceMotion ? 1 : 1.08)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.22, dampingFraction: 0.8), value: isDragging)
    }

    private func dragGesture(rows: [CodexAppServerModelOption], size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    gestureRevision += 1
                }
                let point = rubberBanded(value.location, size: size)
                dragPoint = point
                guard let candidate = candidate(at: value.location, rows: rows, size: size),
                      candidate != previewSelection,
                      let option = rows.first(where: { $0.model == candidate.modelID }),
                      GPT56ModelGridCatalog.supports(candidate.effort, option: option)
                else {
                    return
                }
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
                    withAnimation(settleAnimation) {
                        dragPoint = nil
                        previewSelection = nil
                    }
                    return
                }
                withAnimation(settleAnimation) {
                    previewSelection = candidate
                    dragPoint = center(for: candidate, rows: rows, size: size)
                }
                onSelect(option, candidate.effort)
                let completedRevision = gestureRevision
                DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.13 : 0.36)) {
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

    private var settleAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.34, dampingFraction: 0.86, blendDuration: 0.06)
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
        previewSelection = candidate
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(settleAnimation) {
            dragPoint = nil
        }
        onSelect(option, candidate.effort)
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
