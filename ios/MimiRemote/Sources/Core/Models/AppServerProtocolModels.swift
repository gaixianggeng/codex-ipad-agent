import Foundation

// Codex app-server JSON-RPC 消息与请求构建器，字段兼容逻辑保持原样。
// 多个 app-server DTO 需要同一空字符串兼容规则，保持 module-internal。
extension String {
    var appServerNilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

enum CodexAppServerRequestID: Codable, Hashable, CustomStringConvertible {
    case int(Int64)
    case string(String)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "JSON-RPC id 必须是 string、number 或 null")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var description: String {
        switch self {
        case .int(let value):
            return String(value)
        case .string(let value):
            return value
        case .null:
            return "null"
        }
    }
}

struct CodexAppServerRequest: Codable, Hashable {
    let id: CodexAppServerRequestID
    let method: String
    let params: CodexAppServerJSONValue?

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
    }

    init(id: CodexAppServerRequestID, method: String, params: CodexAppServerJSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(CodexAppServerRequestID.self, forKey: .id)
        self.method = try container.decode(String.self, forKey: .method)
        self.params = try container.decodeIfPresent(CodexAppServerJSONValue.self, forKey: .params)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Codex app-server 线路格式会省略 jsonrpc 字段；这里保持原样，避免 Swift 端引入额外协议差异。
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

struct CodexAppServerNotification: Codable, Hashable {
    let method: String
    let params: CodexAppServerJSONValue?

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case method
        case params
    }

    init(method: String, params: CodexAppServerJSONValue? = nil) {
        self.method = method
        self.params = params
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.method = try container.decode(String.self, forKey: .method)
        self.params = try container.decodeIfPresent(CodexAppServerJSONValue.self, forKey: .params)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

struct CodexAppServerServerRequest: Codable, Hashable {
    let id: CodexAppServerRequestID
    let method: String
    let params: CodexAppServerJSONValue?

    init(id: CodexAppServerRequestID, method: String, params: CodexAppServerJSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

struct CodexAppServerError: Codable, Hashable, LocalizedError {
    let code: Int
    let message: String
    let data: CodexAppServerJSONValue?

    var errorDescription: String? {
        "app-server 错误 \(code)：\(message)"
    }
}

struct CodexAppServerResponse: Codable, Hashable {
    let id: CodexAppServerRequestID
    let result: CodexAppServerJSONValue?
    let error: CodexAppServerError?

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case result
        case error
    }

    init(id: CodexAppServerRequestID, result: CodexAppServerJSONValue? = nil, error: CodexAppServerError? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(CodexAppServerRequestID.self, forKey: .id)
        self.result = try container.decodeIfPresent(CodexAppServerJSONValue.self, forKey: .result)
        self.error = try container.decodeIfPresent(CodexAppServerError.self, forKey: .error)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

enum CodexAppServerMessage: Hashable {
    case response(CodexAppServerResponse)
    case notification(CodexAppServerNotification)
    case serverRequest(CodexAppServerServerRequest)
}

extension CodexAppServerMessage: Decodable {
    enum CodingKeys: String, CodingKey {
        case id
        case method
        case params
        case result
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let method = try container.decodeIfPresent(String.self, forKey: .method) {
            let params = try container.decodeIfPresent(CodexAppServerJSONValue.self, forKey: .params)
            if container.contains(.id) {
                self = .serverRequest(CodexAppServerServerRequest(
                    id: try container.decode(CodexAppServerRequestID.self, forKey: .id),
                    method: method,
                    params: params
                ))
            } else {
                self = .notification(CodexAppServerNotification(method: method, params: params))
            }
            return
        }
        guard container.contains(.id) else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "JSON-RPC 响应缺少 id")
            )
        }
        self = .response(CodexAppServerResponse(
            id: try container.decode(CodexAppServerRequestID.self, forKey: .id),
            result: try container.decodeIfPresent(CodexAppServerJSONValue.self, forKey: .result),
            error: try container.decodeIfPresent(CodexAppServerError.self, forKey: .error)
        ))
    }
}

struct CodexAppServerRequestSpec: Hashable {
    let method: String
    let params: CodexAppServerJSONValue?

    init(method: String, params: CodexAppServerJSONValue? = .object([:])) {
        self.method = method
        self.params = params
    }

    func request(id: CodexAppServerRequestID) -> CodexAppServerRequest {
        CodexAppServerRequest(id: id, method: method, params: params)
    }
}

enum CodexAppServerRequestBuilderError: LocalizedError, Equatable {
    case projectNotAllowlisted(String)
    case pathNotAllowlisted(String)
    case unsafeParameter(String)

    var errorDescription: String? {
        switch self {
        case .projectNotAllowlisted(let id):
            return "项目不在远程 allowlist 中：\(id)"
        case .pathNotAllowlisted(let path):
            return "工作目录不在远程 allowlist 中：\(path)"
        case .unsafeParameter(let reason):
            return "app-server 请求参数不安全：\(reason)"
        }
    }
}

enum CodexAppServerReviewDelivery: String, Hashable {
    case inline
    case detached
}

enum CodexAppServerThreadUnsubscribeStatus: String, Hashable {
    case notLoaded
    case notSubscribed
    case unsubscribed
}

struct CodexAppServerReviewStartResult: Hashable {
    let reviewThreadID: String
    let turnID: String?
}

enum CodexAppServerReviewTarget: Hashable {
    case uncommittedChanges
    case baseBranch(String)
    case commit(sha: String, title: String? = nil)
    case custom(String)

    /// 移动端远程 Review 只接受可枚举目标；这里集中做 trim 和 custom 拒绝，
    /// 保证 UI、Store 与请求 builder 不会各自形成不同的安全边界。
    func validatedInlineTarget() throws -> CodexAppServerReviewTarget {
        switch self {
        case .uncommittedChanges:
            return .uncommittedChanges
        case .baseBranch(let branch):
            let normalized = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw CodexAppServerRequestBuilderError.unsafeParameter("review base branch 不能为空")
            }
            return .baseBranch(normalized)
        case .commit(let sha, let title):
            let normalizedSHA = sha.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedSHA.isEmpty else {
                throw CodexAppServerRequestBuilderError.unsafeParameter("review commit sha 不能为空")
            }
            return .commit(
                sha: normalizedSHA,
                title: title?.trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty
            )
        case .custom:
            // custom 是自由提示词，应继续走 turn/start 的统一沙盒与审批约束。
            throw CodexAppServerRequestBuilderError.unsafeParameter("远程 Review 不允许 custom target")
        }
    }

    fileprivate func appServerValue() throws -> CodexAppServerJSONValue {
        switch self {
        case .uncommittedChanges:
            return .object(["type": .string("uncommittedChanges")])
        case .baseBranch(let branch):
            let normalized = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw CodexAppServerRequestBuilderError.unsafeParameter("review base branch 不能为空")
            }
            return .object([
                "type": .string("baseBranch"),
                "branch": .string(normalized)
            ])
        case .commit(let sha, let title):
            let normalizedSHA = sha.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedSHA.isEmpty else {
                throw CodexAppServerRequestBuilderError.unsafeParameter("review commit sha 不能为空")
            }
            return CodexAppServerJSONValue.objectValue([
                "type": .string("commit"),
                "sha": .string(normalizedSHA),
                "title": title?.trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty.map { .string($0) }
            ])
        case .custom(let instructions):
            let normalized = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw CodexAppServerRequestBuilderError.unsafeParameter("review instructions 不能为空")
            }
            return .object([
                "type": .string("custom"),
                "instructions": .string(normalized)
            ])
        }
    }
}

struct CodexAppServerRequestBuilder {
    private let projectsByID: [String: AgentProject]
    private let allowlistedPaths: Set<String>

    init(allowlistedProjects: [AgentProject]) {
        self.projectsByID = Dictionary(uniqueKeysWithValues: allowlistedProjects.map { ($0.id, $0) })
        self.allowlistedPaths = Set(allowlistedProjects.map(\.path).compactMap(Self.standardizedAllowlistPath))
    }

    func threadList(
        cwd: String,
        limit: Int? = 20,
        cursor: String? = nil,
        useStateDBOnly: Bool = true
    ) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        return CodexAppServerRequestSpec(method: "thread/list", params: CodexAppServerJSONValue.objectValue([
            "cwd": .string(path),
            "limit": limit.map { .int(Int64($0)) },
            "cursor": cursor.map { .string($0) },
            // 列表分页 cursor 必须和本地侧栏排序保持同一基准，避免加载更多后漏掉最新会话。
            "sortKey": .string("updated_at"),
            "sortDirection": .string("desc"),
            "archived": .bool(false),
            "useStateDbOnly": .bool(useStateDBOnly)
        ]))
    }

    func threadSearch(
        query: String,
        limit: Int? = 50,
        cursor: String? = nil
    ) throws -> CodexAppServerRequestSpec {
        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchTerm.isEmpty else {
            throw CodexAppServerRequestBuilderError.unsafeParameter("thread/search 搜索词不能为空")
        }
        // thread/search 本身不接收 cwd。iOS 只发送搜索词和分页字段，目录授权与结果裁剪仍由
        // 既有 agentd gateway 策略负责，避免客户端借搜索接口注入任意工作目录。
        return CodexAppServerRequestSpec(method: "thread/search", params: CodexAppServerJSONValue.objectValue([
            "searchTerm": .string(searchTerm),
            "limit": limit.map { .int(Int64($0)) },
            "cursor": cursor.map { .string($0) },
            "sortKey": .string("updated_at"),
            "sortDirection": .string("desc"),
            "archived": .bool(false)
        ]))
    }

    func modelList() -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "model/list")
    }

    func skillsList(cwd: String, forceReload: Bool = false) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        return CodexAppServerRequestSpec(method: "skills/list", params: .object([
            "cwds": .array([.string(path)]),
            "forceReload": .bool(forceReload)
        ]))
    }

    func installedPluginList(cwd: String) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        return CodexAppServerRequestSpec(method: "plugin/installed", params: .object([
            "cwds": .array([.string(path)])
        ]))
    }

    func accountRateLimitsRead() -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "account/rateLimits/read")
    }

    func threadStart(projectID: String, model: String? = nil, options: CodexAppServerTurnOptions = .default) throws -> CodexAppServerRequestSpec {
        var resolved = options
        if resolved.model == nil {
            resolved.model = model
        }
        return try threadStart(cwd: pathForProject(id: projectID), options: resolved)
    }

    func threadStart(cwd: String, model: String? = nil, options: CodexAppServerTurnOptions = .default) throws -> CodexAppServerRequestSpec {
        var resolved = options
        if resolved.model == nil {
            resolved.model = model
        }
        return try threadStart(cwd: cwd, options: resolved)
    }

    func threadStart(cwd: String, options: CodexAppServerTurnOptions = .default) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        var params = safeThreadRuntimeParams(cwd: path)
        options.threadParams(projectPath: path).forEach { key, value in
            params[key] = value
        }
        try validateRemoteSafeParams(params, projectPath: path)
        return CodexAppServerRequestSpec(method: "thread/start", params: .object(params.compactMapValues { $0 }))
    }

    func threadResume(threadID: String, projectID: String, model: String? = nil, options: CodexAppServerTurnOptions = .default) throws -> CodexAppServerRequestSpec {
        var resolved = options
        if resolved.model == nil {
            resolved.model = model
        }
        return try threadResume(threadID: threadID, cwd: pathForProject(id: projectID), options: resolved)
    }

    // 保留显式 model 的兼容入口；model 不设默认值，避免与支持初始历史页的新入口发生重载歧义。
    func threadResume(threadID: String, cwd: String, model: String?, options: CodexAppServerTurnOptions = .default) throws -> CodexAppServerRequestSpec {
        var resolved = options
        if resolved.model == nil {
            resolved.model = model
        }
        return try threadResume(threadID: threadID, cwd: cwd, options: resolved)
    }

    func threadResume(
        threadID: String,
        cwd: String,
        options: CodexAppServerTurnOptions = .default,
        includeInitialTurnsPage: Bool = true
    ) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        var params = safeThreadRuntimeParams(cwd: path)
        params["threadId"] = .string(threadID)
        params["excludeTurns"] = .bool(true)
        if includeInitialTurnsPage {
            // 恢复只顺带取最近小页，避免普通 resume 把整段 rollout 和内联图片重新下发。
            params["initialTurnsPage"] = .object([
                "limit": .int(5),
                "sortDirection": .string("desc"),
                "itemsView": .string("full")
            ])
        }
        params["ephemeral"] = nil
        options.threadParams(projectPath: path).forEach { key, value in
            params[key] = value
        }
        try validateRemoteSafeParams(params, projectPath: path)
        return CodexAppServerRequestSpec(method: "thread/resume", params: .object(params.compactMapValues { $0 }))
    }

    func threadFork(threadID: String, cwd: String, options: CodexAppServerTurnOptions = .default) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        var params = safeThreadRuntimeParams(cwd: path)
        params["threadId"] = .string(threadID)
        options.threadParams(projectPath: path).forEach { key, value in
            params[key] = value
        }
        params["sessionStartSource"] = nil
        try validateRemoteSafeParams(params, projectPath: path)
        return CodexAppServerRequestSpec(method: "thread/fork", params: .object(params.compactMapValues { $0 }))
    }

    func threadRead(threadID: String, includeTurns: Bool = true) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/read", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID),
            "includeTurns": .bool(includeTurns)
        ]))
    }

    func threadTurnsList(
        threadID: String,
        cursor: String? = nil,
        limit: Int? = 40,
        sortDirection: String = "desc",
        itemsView: String = "full"
    ) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/turns/list", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID),
            "cursor": cursor.map { .string($0) },
            "limit": limit.map { .int(Int64($0)) },
            "sortDirection": .string(sortDirection),
            "itemsView": .string(itemsView)
        ]))
    }

    func threadGoalGet(threadID: String) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/goal/get", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID)
        ]))
    }

    func threadGoalSet(
        threadID: String,
        objective: String? = nil,
        status: ThreadGoalStatus? = nil,
        tokenBudget: Int64? = nil
    ) -> CodexAppServerRequestSpec {
        // 目标状态由 app-server 持久化；iPad 端只提交明确变化的字段。
        CodexAppServerRequestSpec(method: "thread/goal/set", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID),
            "objective": objective.map { .string($0) },
            "status": status.map { .string($0.rawValue) },
            "tokenBudget": tokenBudget.map { .int($0) }
        ]))
    }

    func threadGoalClear(threadID: String) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/goal/clear", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID)
        ]))
    }

    func threadArchive(threadID: String) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/archive", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID)
        ]))
    }

    func threadUnarchive(threadID: String) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/unarchive", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID)
        ]))
    }

    func threadSetName(threadID: String, name: String) throws -> CodexAppServerRequestSpec {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw CodexAppServerRequestBuilderError.unsafeParameter("会话名称不能为空")
        }
        guard normalized.utf8.count <= 256 else {
            throw CodexAppServerRequestBuilderError.unsafeParameter("会话名称不能超过 256 bytes")
        }
        return CodexAppServerRequestSpec(method: "thread/name/set", params: .object([
            "threadId": .string(threadID),
            "name": .string(normalized)
        ]))
    }

    func threadCompactStart(threadID: String) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/compact/start", params: .object([
            "threadId": .string(threadID)
        ]))
    }

    func threadUnsubscribe(threadID: String) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/unsubscribe", params: .object([
            "threadId": .string(threadID)
        ]))
    }

    func reviewStart(
        threadID: String,
        target: CodexAppServerReviewTarget,
        delivery: CodexAppServerReviewDelivery? = nil
    ) throws -> CodexAppServerRequestSpec {
        guard delivery != .detached else {
            // Gateway 第一批只允许原 thread 内 review，避免创建尚未登记授权的新 thread。
            throw CodexAppServerRequestBuilderError.unsafeParameter("远程 Review 只允许 inline")
        }
        let normalizedTarget = try target.validatedInlineTarget()
        // review target 使用官方当前的 discriminated union，避免继续传旧版自由 prompt。
        return CodexAppServerRequestSpec(method: "review/start", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID),
            "target": try normalizedTarget.appServerValue(),
            "delivery": delivery.map { .string($0.rawValue) }
        ]))
    }

    func turnStart(
        threadID: String,
        projectID: String,
        prompt: String,
        clientMessageID: ClientMessageID? = nil
    ) throws -> CodexAppServerRequestSpec {
        try turnStart(
            threadID: threadID,
            cwd: pathForProject(id: projectID),
            payload: CodexAppServerTurnPayload(prompt: prompt),
            clientMessageID: clientMessageID
        )
    }

    func turnStart(
        threadID: String,
        cwd: String,
        prompt: String,
        clientMessageID: ClientMessageID? = nil
    ) throws -> CodexAppServerRequestSpec {
        try turnStart(
            threadID: threadID,
            cwd: cwd,
            payload: CodexAppServerTurnPayload(prompt: prompt),
            clientMessageID: clientMessageID
        )
    }

    func turnStart(
        threadID: String,
        projectID: String,
        payload: CodexAppServerTurnPayload,
        clientMessageID: ClientMessageID? = nil
    ) throws -> CodexAppServerRequestSpec {
        try turnStart(threadID: threadID, cwd: pathForProject(id: projectID), payload: payload, clientMessageID: clientMessageID)
    }

    func turnStart(
        threadID: String,
        cwd: String,
        payload: CodexAppServerTurnPayload,
        clientMessageID: ClientMessageID? = nil
    ) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        var params: [String: CodexAppServerJSONValue?] = [
            "threadId": .string(threadID),
            "cwd": .string(path),
            "input": payload.appServerInput,
            "clientUserMessageId": clientMessageID.map { .string($0) }
        ]
        payload.options.turnParams(projectPath: path).forEach { key, value in
            params[key] = value
        }
        try validateRemoteSafeParams(params, projectPath: path)
        return CodexAppServerRequestSpec(method: "turn/start", params: .object(params.compactMapValues { $0 }))
    }

    func turnSteer(
        threadID: String,
        cwd: String,
        payload: CodexAppServerTurnPayload,
        clientMessageID: ClientMessageID? = nil,
        expectedTurnID: TurnID
    ) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        let params: [String: CodexAppServerJSONValue?] = [
            "threadId": .string(threadID),
            "input": payload.appServerInput,
            "clientUserMessageId": clientMessageID.map { .string($0) },
            "expectedTurnId": .string(expectedTurnID)
        ]
        // steer 是对当前 active turn 的补充输入，不携带模型/权限等 turn 启动参数；
        // 这里只复用结构化输入校验，确保附件路径仍然来自 allowlist。
        try validateRemoteSafeParams(params, projectPath: path)
        return CodexAppServerRequestSpec(method: "turn/steer", params: .object(params.compactMapValues { $0 }))
    }

    func turnInterrupt(threadID: String, turnID: String) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "turn/interrupt", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID),
            "turnId": .string(turnID)
        ]))
    }

    func validateRemoteSafeParams(_ params: CodexAppServerJSONValue, projectPath: String) throws {
        let path = try allowlistedPath(projectPath)
        guard let object = params.objectValue else {
            throw CodexAppServerRequestBuilderError.unsafeParameter("params 必须是 object")
        }
        try validateRemoteSafeParams(object.mapValues { Optional($0) }, projectPath: path)
    }

    private func pathForProject(id: String) throws -> String {
        guard let project = projectsByID[id] else {
            throw CodexAppServerRequestBuilderError.projectNotAllowlisted(id)
        }
        return try allowlistedPath(project.path)
    }

    private func allowlistedPath(_ path: String) throws -> String {
        let standardized = Self.standardizedAllowlistPath(path) ?? ""
        guard allowlistedPaths.contains(standardized) else {
            throw CodexAppServerRequestBuilderError.pathNotAllowlisted(path.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return standardized
    }

    private func safeThreadRuntimeParams(cwd: String) -> [String: CodexAppServerJSONValue?] {
        [
            "cwd": .string(cwd),
            // thread/start 只建立 app-server thread，使用 proven app-server 字段，不发送 runtimeWorkspaceRoots。
            "approvalPolicy": .string("on-request"),
            "approvalsReviewer": .string("user"),
            "sandbox": .string("danger-full-access"),
            "ephemeral": .bool(false)
        ]
    }

    private func validateRemoteSafeParams(_ params: [String: CodexAppServerJSONValue?], projectPath: String) throws {
        if let cwd = params["cwd"]??.stringValue, cwd != projectPath {
            throw CodexAppServerRequestBuilderError.unsafeParameter("cwd 必须来自项目 allowlist")
        }
        if normalizedDangerToken(params["approvalPolicy"]??.stringValue) == "never" {
            throw CodexAppServerRequestBuilderError.unsafeParameter("approvalPolicy=never 被禁止")
        }
        try validateNoDangerousConfig(params["config"] ?? nil)
        guard let sandbox = params["sandboxPolicy"]??.objectValue else {
            return
        }
        // 默认允许用户批准下的最高文件系统权限，但仍不默认打开网络访问。
        if sandbox["networkAccess"]?.boolValue == true {
            throw CodexAppServerRequestBuilderError.unsafeParameter("远程默认禁止网络访问")
        }
        let writableRoots = sandbox["writableRoots"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if writableRoots.contains(where: { $0 != projectPath }) {
            throw CodexAppServerRequestBuilderError.unsafeParameter("writableRoots 只能包含当前 allowlist 项目")
        }
        let inputPaths = try collectWorkspaceInputPaths(params["input"] ?? nil)
        if inputPaths.contains(where: { !isPathInAllowlist($0) }) {
            throw CodexAppServerRequestBuilderError.unsafeParameter("结构化输入路径必须来自当前 allowlist 项目")
        }
    }

    private func normalizedDangerToken(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    private func collectWorkspaceInputPaths(_ input: CodexAppServerJSONValue?) throws -> [String] {
        guard let items = input?.arrayValue else {
            return []
        }
        var paths: [String] = []
        for item in items {
            guard let object = item.objectValue else {
                throw CodexAppServerRequestBuilderError.unsafeParameter("turn/start.input item 必须是 object")
            }
            let type = object["type"]?.stringValue ?? ""
            switch type {
            case "localImage", "mention":
                guard let path = object["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                    throw CodexAppServerRequestBuilderError.unsafeParameter("turn/start.input.\(type).path 不能为空")
                }
                paths.append(path)
            case "skill":
                // Skill 可能来自用户级 / 管理员级 skill root 或插件缓存，不一定在当前项目 allowlist 内。
                // 这里只校验字段完整性；skill root 的来源可信度由 agentd capabilities / app-server 负责。
                guard let path = object["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                    throw CodexAppServerRequestBuilderError.unsafeParameter("turn/start.input.skill.path 不能为空")
                }
            case "image":
                let url = object["url"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !url.isEmpty else {
                    throw CodexAppServerRequestBuilderError.unsafeParameter("turn/start.input.image.url 不能为空")
                }
                if url.lowercased().hasPrefix("file:") {
                    throw CodexAppServerRequestBuilderError.unsafeParameter("image.url 不允许 file URL，请使用 localImage.path")
                }
            case "text":
                continue
            default:
                throw CodexAppServerRequestBuilderError.unsafeParameter("turn/start.input 类型不支持：\(type)")
            }
        }
        return paths
    }

    private func isPathInAllowlist(_ raw: String) -> Bool {
        guard let path = Self.standardizedAllowlistPath(raw) else {
            return false
        }
        return allowlistedPaths.contains { root in
            path == root || path.hasPrefix(root + "/")
        }
    }

    private func validateNoDangerousConfig(_ value: CodexAppServerJSONValue?, parentKey: String? = nil) throws {
        guard let value else {
            return
        }
        switch value {
        case .object(let object):
            for (key, child) in object {
                let normalizedKey = normalizedDangerToken(key)
                if normalizedKey == "dangerfullaccess" {
                    throw CodexAppServerRequestBuilderError.unsafeParameter("config 不允许 dangerFullAccess")
                }
                if normalizedKey == "approvalpolicy",
                   normalizedDangerToken(child.stringValue) == "never" {
                    throw CodexAppServerRequestBuilderError.unsafeParameter("config 不允许 approvalPolicy=never")
                }
                if normalizedKey == "sandbox" || normalizedKey == "sandboxmode" || (parentKey == "sandboxpolicy" && normalizedKey == "type"),
                   normalizedDangerToken(child.stringValue) == "dangerfullaccess" {
                    throw CodexAppServerRequestBuilderError.unsafeParameter("config 不允许 dangerFullAccess")
                }
                if normalizedKey == "networkaccess",
                   child.boolValue == true || child.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true" {
                    throw CodexAppServerRequestBuilderError.unsafeParameter("config 不允许 networkAccess=true")
                }
                try validateNoDangerousConfig(child, parentKey: normalizedKey)
            }
        case .array(let values):
            for child in values {
                try validateNoDangerousConfig(child, parentKey: parentKey)
            }
        default:
            return
        }
    }

    private static func standardizedAllowlistPath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}
