import SwiftUI

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

/// 新建会话表单在紧凑布局使用可拖拽高度，宽屏沿用系统表单尺寸。
struct NewSessionPresentationModifier: ViewModifier {
    let isCompact: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isCompact {
            content
                .presentationDetents([.height(430), .large])
                .presentationDragIndicator(.visible)
        } else {
            content.presentationSizing(.form)
        }
    }
}

/// Inspector 与 New Session 使用不同的空间来源，避免两个展示生命周期互相污染。
enum InspectorPresentationSource: String, Hashable {
    case sessionToolbarInspector

    var transitionSourceID: String { rawValue }
}

/// Inspector 的入口宿主。只有 regular/medium 布局下持续可见的工具栏按钮能成为 zoom source。
enum InspectorPresentationHost: Hashable {
    case compactSheet
    case mediumSheet
    case attached
}

enum InspectorPresentationTransitionPolicy: Hashable {
    case systemSheet
    case zoom(sourceID: String)
}

/// 仅描述本次 Inspector 展示的动画身份，不持有 Inspector 内部选择或业务状态。
struct InspectorPresentationContext: Hashable {
    let host: InspectorPresentationHost
    let source: InspectorPresentationSource?
    let transition: InspectorPresentationTransitionPolicy

    init(
        host: InspectorPresentationHost,
        source: InspectorPresentationSource? = nil,
        hasNamespace: Bool = false,
        reduceMotion: Bool = false
    ) {
        self.host = host

        let resolvedSource: InspectorPresentationSource? = if host == .mediumSheet,
                                                               source == .sessionToolbarInspector,
                                                               hasNamespace {
            source
        } else {
            nil
        }
        self.source = resolvedSource

        if !reduceMotion, let resolvedSource {
            transition = .zoom(sourceID: resolvedSource.transitionSourceID)
        } else {
            transition = .systemSheet
        }
    }

}

/// `showingInspector` 仍由界面层负责；这里仅锁定与其同步的动画上下文。
struct InspectorPresentationState: Equatable {
    private(set) var context: InspectorPresentationContext?

    mutating func present(
        on host: InspectorPresentationHost,
        source: InspectorPresentationSource? = nil,
        hasNamespace: Bool = false,
        reduceMotion: Bool = false
    ) {
        // 展示期间拒绝重入，避免另一个入口替换返回锚点或动态辅助功能改变转场。
        guard context == nil else { return }
        context = InspectorPresentationContext(
            host: host,
            source: source,
            hasNamespace: hasNamespace,
            reduceMotion: reduceMotion
        )
    }

    mutating func dismiss() {
        context = nil
    }

    mutating func layoutHostDidChange(to host: InspectorPresentationHost) {
        guard context?.host != host else { return }
        // Sheet 与 attached Inspector 是不同 host；旧 source/zoom 不得跨容器延续。
        context = nil
    }
}
