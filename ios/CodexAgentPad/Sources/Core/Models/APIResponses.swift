import Foundation

struct HealthResponse: Codable {
    let ok: Bool
    let version: String
}

struct VersionResponse: Codable {
    let name: String
    let version: String
}

struct CodexAppServerConfigResponse: Codable {
    let gatewayWSURL: String
    let runtime: CodexAppServerRuntimeMetadata
    let projects: [AgentProject]
    let policy: CodexAppServerPolicyMetadata

    enum CodingKeys: String, CodingKey {
        case gatewayWSURL = "gateway_ws_url"
        case runtime
        case projects
        case policy
    }
}

struct CodexAppServerRuntimeMetadata: Codable, Hashable {
    let type: String
    let transport: String
    let managed: Bool
    let gatewayAvailable: Bool
    let upstreamConfigured: Bool
    let running: Bool
    let initialized: Bool
    let pendingRequests: Int

    enum CodingKeys: String, CodingKey {
        case type
        case transport
        case managed
        case gatewayAvailable = "gateway_available"
        case upstreamConfigured = "upstream_configured"
        case running
        case initialized
        case pendingRequests = "pending_requests"
    }
}

struct CodexAppServerPolicyMetadata: Codable, Hashable {
    let allowedMethods: [String]
    let projectsSource: String

    enum CodingKeys: String, CodingKey {
        case allowedMethods = "allowed_methods"
        case projectsSource = "projects_source"
    }
}

struct ProjectsResponse: Codable {
    let projects: [AgentProject]
}

struct WorkspaceResolveRequest: Encodable {
    let path: String
}

struct WorkspaceResolveResponse: Codable {
    let workspace: AgentWorkspace
}

struct SessionsResponse: Codable {
    let sessions: [AgentSession]
    let rows: [DataFlowSessionRow]
    let nextCursor: String?
    let hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case sessions
        case rows
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try container.decodeIfPresent([DataFlowSessionRow].self, forKey: .rows) ?? []
        self.rows = rows
        self.sessions = try container.decodeIfPresent([AgentSession].self, forKey: .sessions) ?? rows.map(AgentSession.init(row:))
        self.nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
        self.hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore)
    }
}

struct SessionsPage: Equatable {
    let sessions: [AgentSession]
    let nextCursor: String?
    let hasMore: Bool

    init(response: SessionsResponse) {
        self.sessions = response.sessions
        self.nextCursor = response.nextCursor
        self.hasMore = response.hasMore ?? false
    }

    init(sessions: [AgentSession], nextCursor: String? = nil, hasMore: Bool = false) {
        self.sessions = sessions
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

struct SessionResponse: Codable {
    let session: AgentSession
    let row: DataFlowSessionRow?
    let recentOutput: String?
    let lastSeq: EventSequence?

    enum CodingKeys: String, CodingKey {
        case session
        case row
        case recentOutput = "recent_output"
        case lastSeq = "last_seq"
    }

    init(session: AgentSession, row: DataFlowSessionRow? = nil, recentOutput: String? = nil, lastSeq: EventSequence? = nil) {
        self.session = session
        self.row = row
        self.recentOutput = recentOutput
        self.lastSeq = lastSeq
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let row = try container.decodeIfPresent(DataFlowSessionRow.self, forKey: .row)
        self.row = row
        if let session = try container.decodeIfPresent(AgentSession.self, forKey: .session) {
            self.session = session
        } else if let row {
            self.session = AgentSession(row: row)
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.session,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "缺少 session 或 row")
            )
        }
        self.recentOutput = try container.decodeIfPresent(String.self, forKey: .recentOutput)
        self.lastSeq = try container.decodeIfPresent(EventSequence.self, forKey: .lastSeq)
    }
}

struct CreateSessionResponse: Codable {
    let session: AgentSession
    let row: DataFlowSessionRow?
    let wsURL: String
    let firstMessage: AgentMessage?

    enum CodingKeys: String, CodingKey {
        case session
        case row
        case wsURL = "ws_url"
        case firstMessage = "first_message"
    }

    init(session: AgentSession, row: DataFlowSessionRow? = nil, wsURL: String, firstMessage: AgentMessage? = nil) {
        self.session = session
        self.row = row
        self.wsURL = wsURL
        self.firstMessage = firstMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let row = try container.decodeIfPresent(DataFlowSessionRow.self, forKey: .row)
        self.row = row
        if let session = try container.decodeIfPresent(AgentSession.self, forKey: .session) {
            self.session = session
        } else if let row {
            self.session = AgentSession(row: row)
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.session,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "缺少 session 或 row")
            )
        }
        self.wsURL = try container.decode(String.self, forKey: .wsURL)
        self.firstMessage = try container.decodeIfPresent(AgentMessage.self, forKey: .firstMessage)
    }
}

struct MessagesResponse: Codable {
    let messages: [CodexHistoryMessage]
    let page: MessagePage?
    let nextCursor: String?
    let previousCursor: String?
    let hasMoreBefore: Bool?

    enum CodingKeys: String, CodingKey {
        case messages
        case page
        case nextCursor = "next_cursor"
        case previousCursor = "previous_cursor"
        case hasMoreBefore = "has_more_before"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.page = try container.decodeIfPresent(MessagePage.self, forKey: .page)
        if let page {
            self.messages = page.messages.map {
                CodexHistoryMessage(
                    id: $0.id,
                    role: $0.role.rawValue,
                    content: $0.content,
                    createdAt: $0.createdAt,
                    clientMessageID: $0.clientMessageID,
                    turnID: $0.turnID,
                    itemID: $0.itemID,
                    seq: $0.seq,
                    revision: $0.revision,
                    sendStatus: $0.sendStatus
                )
            }
            self.nextCursor = page.nextCursor
            self.previousCursor = page.previousCursor
            self.hasMoreBefore = page.hasMoreBefore
        } else {
            self.messages = try container.decodeIfPresent([CodexHistoryMessage].self, forKey: .messages) ?? []
            self.nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            self.previousCursor = try container.decodeIfPresent(String.self, forKey: .previousCursor)
            self.hasMoreBefore = try container.decodeIfPresent(Bool.self, forKey: .hasMoreBefore)
        }
    }
}

struct HistoryMessagesPage: Equatable {
    let messages: [CodexHistoryMessage]
    let previousCursor: String?
    let hasMoreBefore: Bool

    init(response: MessagesResponse) {
        self.messages = response.messages
        self.previousCursor = response.previousCursor
        self.hasMoreBefore = response.hasMoreBefore ?? false
    }

    init(messages: [CodexHistoryMessage], previousCursor: String? = nil, hasMoreBefore: Bool = false) {
        self.messages = messages
        self.previousCursor = previousCursor
        self.hasMoreBefore = hasMoreBefore
    }
}

struct CreateSessionRequest: Encodable {
    let projectID: String
    let projectPath: String?
    let projectName: String?
    let rootProjectID: String?
    let prompt: String
    let resumeID: String
    let clientMessageID: ClientMessageID?

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case projectPath = "project_path"
        case projectName = "project_name"
        case rootProjectID = "root_project_id"
        case prompt
        case resumeID = "resume_id"
        case clientMessageID = "client_message_id"
    }

    init(
        projectID: String,
        projectPath: String? = nil,
        projectName: String? = nil,
        rootProjectID: String? = nil,
        prompt: String,
        resumeID: String,
        clientMessageID: ClientMessageID? = nil
    ) {
        self.projectID = projectID
        self.projectPath = projectPath
        self.projectName = projectName
        self.rootProjectID = rootProjectID
        self.prompt = prompt
        self.resumeID = resumeID
        self.clientMessageID = clientMessageID
    }
}

indirect enum CodexAppServerJSONValue: Codable, Hashable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case object([String: CodexAppServerJSONValue])
    case array([CodexAppServerJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CodexAppServerJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: CodexAppServerJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "app-server JSON 值格式无效")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        default:
            return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let value):
            return Int(value)
        case .double(let value):
            return Int(value)
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }

    var objectValue: [String: CodexAppServerJSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    var arrayValue: [CodexAppServerJSONValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }

    subscript(key: String) -> CodexAppServerJSONValue? {
        objectValue?[key]
    }

    static func objectValue(_ values: [String: CodexAppServerJSONValue?]) -> CodexAppServerJSONValue {
        .object(values.compactMapValues { $0 })
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

struct CodexAppServerRequestBuilder {
    private let projectsByID: [String: AgentProject]
    private let allowlistedPaths: Set<String>

    init(allowlistedProjects: [AgentProject]) {
        self.projectsByID = Dictionary(uniqueKeysWithValues: allowlistedProjects.map { ($0.id, $0) })
        self.allowlistedPaths = Set(allowlistedProjects.map(\.path).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    func threadList(cwd: String, limit: Int? = 20, cursor: String? = nil) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        return CodexAppServerRequestSpec(method: "thread/list", params: CodexAppServerJSONValue.objectValue([
            "cwd": .string(path),
            "limit": limit.map { .int(Int64($0)) },
            "cursor": cursor.map { .string($0) }
        ]))
    }

    func threadStart(projectID: String, model: String? = nil) throws -> CodexAppServerRequestSpec {
        try threadStart(cwd: pathForProject(id: projectID), model: model)
    }

    func threadStart(cwd: String, model: String? = nil) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        var params = safeThreadRuntimeParams(cwd: path)
        params["model"] = model.map { .string($0) }
        try validateRemoteSafeParams(params, projectPath: path)
        return CodexAppServerRequestSpec(method: "thread/start", params: .object(params.compactMapValues { $0 }))
    }

    func threadResume(threadID: String, projectID: String, model: String? = nil) throws -> CodexAppServerRequestSpec {
        try threadResume(threadID: threadID, cwd: pathForProject(id: projectID), model: model)
    }

    func threadResume(threadID: String, cwd: String, model: String? = nil) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        var params = safeThreadRuntimeParams(cwd: path)
        params["threadId"] = .string(threadID)
        params["excludeTurns"] = .bool(true)
        params["ephemeral"] = nil
        params["model"] = model.map { .string($0) }
        try validateRemoteSafeParams(params, projectPath: path)
        return CodexAppServerRequestSpec(method: "thread/resume", params: .object(params.compactMapValues { $0 }))
    }

    func threadRead(threadID: String, includeTurns: Bool = true) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/read", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID),
            "includeTurns": .bool(includeTurns)
        ]))
    }

    func turnStart(
        threadID: String,
        projectID: String,
        prompt: String,
        clientMessageID: ClientMessageID? = nil
    ) throws -> CodexAppServerRequestSpec {
        try turnStart(threadID: threadID, cwd: pathForProject(id: projectID), prompt: prompt, clientMessageID: clientMessageID)
    }

    func turnStart(
        threadID: String,
        cwd: String,
        prompt: String,
        clientMessageID: ClientMessageID? = nil
    ) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        let params: [String: CodexAppServerJSONValue?] = [
            "threadId": .string(threadID),
            "cwd": .string(path),
            "input": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(prompt),
                    "text_elements": .array([])
                ])
            ]),
            // 远程 iPad 操作默认需要用户审批，不能让移动端悄悄切到 never。
            "approvalPolicy": .string("on-request"),
            "approvalsReviewer": .string("user"),
            // turn/start 是实际执行入口，必须限制在 allowlist 项目根目录内写入，并默认关闭网络。
            "sandboxPolicy": safeSandboxPolicy(projectPath: path),
            "clientUserMessageId": clientMessageID.map { .string($0) }
        ]
        try validateRemoteSafeParams(params, projectPath: path)
        return CodexAppServerRequestSpec(method: "turn/start", params: .object(params.compactMapValues { $0 }))
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
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowlistedPaths.contains(trimmed) else {
            throw CodexAppServerRequestBuilderError.pathNotAllowlisted(trimmed)
        }
        return trimmed
    }

    private func safeThreadRuntimeParams(cwd: String) -> [String: CodexAppServerJSONValue?] {
        [
            "cwd": .string(cwd),
            // thread/start 只建立 app-server thread，使用 proven app-server 字段，不发送 runtimeWorkspaceRoots。
            "approvalPolicy": .string("on-request"),
            "approvalsReviewer": .string("user"),
            "sandbox": .string("workspace-write"),
            "ephemeral": .bool(false)
        ]
    }

    private func safeSandboxPolicy(projectPath: String) -> CodexAppServerJSONValue {
        .object([
            "type": .string("workspaceWrite"),
            "writableRoots": .array([.string(projectPath)]),
            "networkAccess": .bool(false),
            "excludeTmpdirEnvVar": .bool(false),
            "excludeSlashTmp": .bool(false)
        ])
    }

    private func validateRemoteSafeParams(_ params: [String: CodexAppServerJSONValue?], projectPath: String) throws {
        if let cwd = params["cwd"]??.stringValue, cwd != projectPath {
            throw CodexAppServerRequestBuilderError.unsafeParameter("cwd 必须来自项目 allowlist")
        }
        if normalizedDangerToken(params["approvalPolicy"]??.stringValue) == "never" {
            throw CodexAppServerRequestBuilderError.unsafeParameter("approvalPolicy=never 被禁止")
        }
        if normalizedDangerToken(params["sandbox"]??.stringValue) == "dangerfullaccess" {
            throw CodexAppServerRequestBuilderError.unsafeParameter("dangerFullAccess sandbox 被禁止")
        }
        guard let sandbox = params["sandboxPolicy"]??.objectValue else {
            return
        }
        if normalizedDangerToken(sandbox["type"]?.stringValue) == "dangerfullaccess" {
            throw CodexAppServerRequestBuilderError.unsafeParameter("dangerFullAccess sandboxPolicy 被禁止")
        }
        if sandbox["networkAccess"]?.boolValue == true {
            throw CodexAppServerRequestBuilderError.unsafeParameter("远程默认禁止网络访问")
        }
        let writableRoots = sandbox["writableRoots"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if writableRoots.contains(where: { $0 != projectPath }) {
            throw CodexAppServerRequestBuilderError.unsafeParameter("writableRoots 只能包含当前 allowlist 项目")
        }
    }

    private func normalizedDangerToken(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }
}
