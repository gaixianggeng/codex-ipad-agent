import Foundation

/// 所有跨异步边界的数据都必须携带完整主机作用域。
/// endpoint 只是可变路由，不参与身份；同一台 Mac 更换地址后仍复用原有 Profile 数据。
struct HostScope: Hashable, Sendable {
    let profileID: String
    let installationID: String
    let generation: UInt64
}

struct ScopedSessionID: Hashable, Sendable {
    let profileID: String
    let sessionID: String
}

struct ScopedProjectID: Hashable, Sendable {
    let profileID: String
    let projectID: String
}

/// 实时事件不只按 Profile 隔离，还必须绑定连接代次；切回同一台 Mac 后，
/// 上一个 generation 的尾包也不能进入新的 Runtime。
struct HostSessionLease: Hashable, Sendable {
    let hostScope: HostScope
    let sessionID: String
}

/// AppStore 只通过这个值发布当前主机身份，避免异步任务分别读取 profile、installation 和代次后
/// 拼出一份可能跨提交边界的混合状态。
struct ActiveHostState: Equatable, Sendable {
    let scope: HostScope
    let endpoint: String
    let displayName: String
    let committedAt: Date
}
