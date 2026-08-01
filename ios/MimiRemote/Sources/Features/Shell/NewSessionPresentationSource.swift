import Foundation

/// 只有持续可见、能稳定返回的点击入口才拥有系统 zoom source。
enum NewSessionPresentationSource: String, CaseIterable, Hashable {
    case sessionsToolbarNewSession
    case sidebarNewSession

    var transitionSourceID: String { rawValue }

    /// 只有真正安装了 toolbar source，点击时才能把它上报给展示层。
    static func sessionsToolbar(hasNamespace: Bool) -> Self? {
        hasNamespace ? .sessionsToolbarNewSession : nil
    }
}

enum WorkbenchSheetDestination: String, Hashable {
    case newSession
    case settings
}

/// Sheet identity 同时记录目标、来源和本次转场，避免来源或辅助功能变化污染展示生命周期。
struct WorkbenchSheetPresentation: Identifiable, Hashable {
    let destination: WorkbenchSheetDestination
    let source: NewSessionPresentationSource?
    let transition: NewSessionPresentationTransitionPolicy

    init(
        destination: WorkbenchSheetDestination,
        source: NewSessionPresentationSource?,
        reduceMotion: Bool = false
    ) {
        let resolvedSource = destination == .newSession ? source : nil
        self.destination = destination
        self.source = resolvedSource
        // 单次展示期间锁定转场，避免动态辅助功能变化重建表单的本地状态。
        transition = NewSessionPresentationTransitionPolicy.resolve(
            destination: destination,
            source: resolvedSource,
            reduceMotion: reduceMotion
        )
    }

    var id: Self { self }
}

enum NewSessionPresentationTransitionPolicy: Hashable {
    case systemSheet
    case zoom(sourceID: String)

    static func resolve(
        destination: WorkbenchSheetDestination,
        source: NewSessionPresentationSource?,
        reduceMotion: Bool
    ) -> Self {
        guard destination == .newSession,
              !reduceMotion,
              let source else {
            return .systemSheet
        }
        return .zoom(sourceID: source.transitionSourceID)
    }
}

struct WorkbenchSheetPresentationState: Equatable {
    private(set) var presentation: WorkbenchSheetPresentation?

    mutating func present(
        _ destination: WorkbenchSheetDestination,
        source: NewSessionPresentationSource? = nil,
        reduceMotion: Bool = false
    ) {
        // 一次 Sheet 展示期间锁定来源，避免程序化重入把返回锚点换成另一个按钮。
        guard presentation == nil else { return }
        // 非 New Session 目标不能误继承此前的空间来源。
        presentation = WorkbenchSheetPresentation(
            destination: destination,
            source: source,
            reduceMotion: reduceMotion
        )
    }

    mutating func replace(with presentation: WorkbenchSheetPresentation?) {
        guard let presentation else {
            dismiss()
            return
        }
        guard self.presentation == nil else { return }
        self.presentation = presentation
    }

    mutating func dismiss() {
        presentation = nil
    }
}
