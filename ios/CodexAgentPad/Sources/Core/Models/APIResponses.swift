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
    let context: SessionContextSnapshot?

    init(response: MessagesResponse) {
        self.messages = response.messages
        self.previousCursor = response.previousCursor
        self.hasMoreBefore = response.hasMoreBefore ?? false
        self.context = nil
    }

    init(
        messages: [CodexHistoryMessage],
        previousCursor: String? = nil,
        hasMoreBefore: Bool = false,
        context: SessionContextSnapshot? = nil
    ) {
        self.messages = messages
        self.previousCursor = previousCursor
        self.hasMoreBefore = hasMoreBefore
        self.context = context
    }
}

struct CreateSessionRequest: Encodable {
    let projectID: String
    let projectPath: String?
    let projectName: String?
    let rootProjectID: String?
    let prompt: String
    let input: [CodexAppServerUserInput]
    let turnOptions: CodexAppServerTurnOptions
    let resumeID: String
    let clientMessageID: ClientMessageID?

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case projectPath = "project_path"
        case projectName = "project_name"
        case rootProjectID = "root_project_id"
        case prompt
        case input
        case turnOptions = "turn_options"
        case resumeID = "resume_id"
        case clientMessageID = "client_message_id"
    }

    init(
        projectID: String,
        projectPath: String? = nil,
        projectName: String? = nil,
        rootProjectID: String? = nil,
        prompt: String,
        input: [CodexAppServerUserInput]? = nil,
        turnOptions: CodexAppServerTurnOptions = .default,
        resumeID: String,
        clientMessageID: ClientMessageID? = nil
    ) {
        self.projectID = projectID
        self.projectPath = projectPath
        self.projectName = projectName
        self.rootProjectID = rootProjectID
        self.prompt = prompt
        self.input = input ?? CodexAppServerTurnPayload.defaultInput(for: prompt)
        self.turnOptions = turnOptions
        self.resumeID = resumeID
        self.clientMessageID = clientMessageID
    }
}

enum CodexAppServerImageDetail: String, Codable, CaseIterable, Hashable, Identifiable {
    case auto
    case low
    case high
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:
            return "自动"
        case .low:
            return "低"
        case .high:
            return "高"
        case .original:
            return "原图"
        }
    }
}

enum CodexAppServerUserInput: Codable, Hashable, Identifiable {
    case text(String, textElements: [CodexAppServerJSONValue] = [])
    case image(url: String, detail: CodexAppServerImageDetail? = nil)
    case localImage(path: String, detail: CodexAppServerImageDetail? = nil)
    case skill(name: String, path: String)
    case mention(name: String, path: String)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case textElements = "text_elements"
        case url
        case path
        case name
        case detail
    }

    var id: String {
        switch self {
        case .text(let text, _):
            return "text:\(text)"
        case .image(let url, _):
            return "image:\(Self.stableDigest(url))"
        case .localImage(let path, _):
            return "localImage:\(path)"
        case .skill(let name, let path):
            return "skill:\(name):\(path)"
        case .mention(let name, let path):
            return "mention:\(name):\(path)"
        }
    }

    private static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    var retainedAfterAcceptedSend: CodexAppServerUserInput? {
        switch self {
        case .image(let url, _):
            return Self.isInlineImageDataURL(url) ? nil : self
        default:
            return self
        }
    }

    private static func isInlineImageDataURL(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: "data:image/", options: [.anchored, .caseInsensitive]) != nil
    }

    var previewText: String {
        switch self {
        case .text(let text, _):
            return text
        case .image:
            return "[图片]"
        case .localImage(let path, _):
            return "[图片 \(URL(fileURLWithPath: path).lastPathComponent)]"
        case .skill(let name, _):
            return "[$\(name)]"
        case .mention(let name, _):
            return "[@\(name)]"
        }
    }

    var jsonValue: CodexAppServerJSONValue {
        switch self {
        case .text(let text, let textElements):
            return .object([
                "type": .string("text"),
                "text": .string(text),
                "text_elements": .array(textElements)
            ])
        case .image(let url, let detail):
            var object: [String: CodexAppServerJSONValue] = [
                "type": .string("image"),
                "url": .string(url)
            ]
            if let detail {
                object["detail"] = .string(detail.rawValue)
            }
            return .object(object)
        case .localImage(let path, let detail):
            var object: [String: CodexAppServerJSONValue] = [
                "type": .string("localImage"),
                "path": .string(path)
            ]
            if let detail {
                object["detail"] = .string(detail.rawValue)
            }
            return .object(object)
        case .skill(let name, let path):
            return .object([
                "type": .string("skill"),
                "name": .string(name),
                "path": .string(path)
            ])
        case .mention(let name, let path):
            return .object([
                "type": .string("mention"),
                "name": .string(name),
                "path": .string(path)
            ])
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(
                try container.decode(String.self, forKey: .text),
                textElements: try container.decodeIfPresent([CodexAppServerJSONValue].self, forKey: .textElements) ?? []
            )
        case "image":
            self = .image(
                url: try container.decode(String.self, forKey: .url),
                detail: try container.decodeIfPresent(CodexAppServerImageDetail.self, forKey: .detail)
            )
        case "localImage":
            self = .localImage(
                path: try container.decode(String.self, forKey: .path),
                detail: try container.decodeIfPresent(CodexAppServerImageDetail.self, forKey: .detail)
            )
        case "skill":
            self = .skill(
                name: try container.decode(String.self, forKey: .name),
                path: try container.decode(String.self, forKey: .path)
            )
        case "mention":
            self = .mention(
                name: try container.decode(String.self, forKey: .name),
                path: try container.decode(String.self, forKey: .path)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "未知 app-server UserInput 类型：\(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text, let textElements):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encode(textElements, forKey: .textElements)
        case .image(let url, let detail):
            try container.encode("image", forKey: .type)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(detail, forKey: .detail)
        case .localImage(let path, let detail):
            try container.encode("localImage", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(detail, forKey: .detail)
        case .skill(let name, let path):
            try container.encode("skill", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(path, forKey: .path)
        case .mention(let name, let path):
            try container.encode("mention", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(path, forKey: .path)
        }
    }
}

enum CodexAppServerReasoningEffort: String, Codable, CaseIterable, Hashable, Identifiable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }
}

enum CodexAppServerReasoningSummary: String, Codable, CaseIterable, Hashable, Identifiable {
    case auto
    case concise
    case detailed
    case none

    var id: String { rawValue }
}

enum CodexAppServerPersonality: String, Codable, CaseIterable, Hashable, Identifiable {
    case none
    case friendly
    case pragmatic

    var id: String { rawValue }
}

enum CodexAppServerApprovalPolicy: String, Codable, CaseIterable, Hashable, Identifiable {
    case untrusted
    case onFailure = "on-failure"
    case onRequest = "on-request"

    var id: String { rawValue }
}

enum CodexAppServerSandboxMode: String, Codable, CaseIterable, Hashable, Identifiable {
    case readOnly
    case workspaceWrite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readOnly:
            return "只读"
        case .workspaceWrite:
            return "可写"
        }
    }
}

struct CodexAppServerTurnOptions: Codable, Hashable {
    var model: String?
    var modelProvider: String?
    var serviceTier: String?
    var reasoningEffort: CodexAppServerReasoningEffort?
    var reasoningSummary: CodexAppServerReasoningSummary?
    var approvalPolicy: CodexAppServerApprovalPolicy
    var approvalsReviewer: String
    var sandboxMode: CodexAppServerSandboxMode
    var networkAccess: Bool
    var personality: CodexAppServerPersonality?
    var config: CodexAppServerJSONValue?
    var baseInstructions: String?
    var developerInstructions: String?
    var outputSchema: CodexAppServerJSONValue?
    var serviceName: String?
    var sessionStartSource: String?
    var threadSource: String?

    enum CodingKeys: String, CodingKey {
        case model
        case modelProvider = "model_provider"
        case serviceTier = "service_tier"
        case reasoningEffort = "reasoning_effort"
        case reasoningSummary = "reasoning_summary"
        case approvalPolicy = "approval_policy"
        case approvalsReviewer = "approvals_reviewer"
        case sandboxMode = "sandbox_mode"
        case networkAccess = "network_access"
        case personality
        case config
        case baseInstructions = "base_instructions"
        case developerInstructions = "developer_instructions"
        case outputSchema = "output_schema"
        case serviceName = "service_name"
        case sessionStartSource = "session_start_source"
        case threadSource = "thread_source"
    }

    static let `default` = CodexAppServerTurnOptions(
        model: nil,
        modelProvider: nil,
        serviceTier: nil,
        reasoningEffort: nil,
        reasoningSummary: nil,
        approvalPolicy: .onRequest,
        approvalsReviewer: "user",
        sandboxMode: .workspaceWrite,
        networkAccess: false,
        personality: nil,
        config: nil,
        baseInstructions: nil,
        developerInstructions: nil,
        outputSchema: nil,
        serviceName: nil,
        sessionStartSource: nil,
        threadSource: nil
    )

    func turnParams(projectPath: String) -> [String: CodexAppServerJSONValue?] {
        [
            "model": model.flatMap(nonEmptyString).map { .string($0) },
            "serviceTier": serviceTier.flatMap(nonEmptyString).map { .string($0) },
            "effort": reasoningEffort.map { .string($0.rawValue) },
            "summary": reasoningSummary.map { .string($0.rawValue) },
            "approvalPolicy": .string(approvalPolicy.rawValue),
            "approvalsReviewer": .string(approvalsReviewer),
            "sandboxPolicy": sandboxPolicy(projectPath: projectPath),
            "personality": personality.map { .string($0.rawValue) },
            "outputSchema": outputSchema
        ]
    }

    func threadParams(projectPath: String) -> [String: CodexAppServerJSONValue?] {
        [
            "model": model.flatMap(nonEmptyString).map { .string($0) },
            "modelProvider": modelProvider.flatMap(nonEmptyString).map { .string($0) },
            "serviceTier": serviceTier.flatMap(nonEmptyString).map { .string($0) },
            "approvalPolicy": .string(approvalPolicy.rawValue),
            "approvalsReviewer": .string(approvalsReviewer),
            "sandbox": .string(sandboxMode == .readOnly ? "read-only" : "workspace-write"),
            "personality": personality.map { .string($0.rawValue) },
            "config": config,
            "serviceName": serviceName.flatMap(nonEmptyString).map { .string($0) },
            "baseInstructions": baseInstructions.flatMap(nonEmptyString).map { .string($0) },
            "developerInstructions": developerInstructions.flatMap(nonEmptyString).map { .string($0) },
            "sessionStartSource": sessionStartSource.flatMap(nonEmptyString).map { .string($0) },
            "threadSource": threadSource.flatMap(nonEmptyString).map { .string($0) }
        ]
    }

    private func sandboxPolicy(projectPath: String) -> CodexAppServerJSONValue {
        switch sandboxMode {
        case .readOnly:
            return .object([
                "type": .string("readOnly"),
                "networkAccess": .bool(networkAccess)
            ])
        case .workspaceWrite:
            return .object([
                "type": .string("workspaceWrite"),
                "writableRoots": .array([.string(projectPath)]),
                "networkAccess": .bool(networkAccess),
                "excludeTmpdirEnvVar": .bool(false),
                "excludeSlashTmp": .bool(false)
            ])
        }
    }

    private func nonEmptyString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }
}

struct CodexAppServerTurnPayload: Codable, Hashable {
    var input: [CodexAppServerUserInput]
    var options: CodexAppServerTurnOptions

    init(input: [CodexAppServerUserInput], options: CodexAppServerTurnOptions = .default) {
        self.input = input
        self.options = options
    }

    init(prompt: String, options: CodexAppServerTurnOptions = .default) {
        self.input = Self.defaultInput(for: prompt)
        self.options = options
    }

    var isEmpty: Bool {
        input.allSatisfy { item in
            switch item {
            case .text(let text, _):
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:
                return false
            }
        }
    }

    var previewText: String {
        input.map(\.previewText)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var textPrompt: String {
        input.compactMap { item in
            if case .text(let text, _) = item {
                return text
            }
            return nil
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var appServerInput: CodexAppServerJSONValue {
        .array(input.map(\.jsonValue))
    }

    func retainedAfterAcceptedSend() -> CodexAppServerTurnPayload? {
        let retainedInput = input.compactMap(\.retainedAfterAcceptedSend)
        let retained = CodexAppServerTurnPayload(input: retainedInput, options: options)
        if retained.input.isEmpty && retained.options == .default {
            return nil
        }
        return retained
    }

    static func defaultInput(for prompt: String) -> [CodexAppServerUserInput] {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [.text(trimmed)]
    }
}

struct CodexAppServerModelOption: Codable, Hashable, Identifiable {
    let model: String
    let title: String
    let provider: String?
    let description: String?
    let isDefault: Bool

    init(
        id: String,
        title: String? = nil,
        provider: String? = nil,
        description: String? = nil,
        isDefault: Bool = false
    ) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmedID
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? trimmedID
        self.provider = provider?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.description = description?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.isDefault = isDefault
    }

    var id: String {
        guard let provider else {
            return model
        }
        return "\(model)@\(provider)"
    }

    var menuTitle: String {
        guard let provider else {
            return title
        }
        return "\(title) · \(provider)"
    }

    static let builtInFallback: [CodexAppServerModelOption] = [
        CodexAppServerModelOption(id: "gpt-5-codex", title: "gpt-5-codex"),
        CodexAppServerModelOption(id: "gpt-5.1-codex", title: "gpt-5.1-codex"),
        CodexAppServerModelOption(id: "gpt-5", title: "gpt-5"),
        CodexAppServerModelOption(id: "gpt-5.1", title: "gpt-5.1")
    ]

    static func parseListResult(_ result: CodexAppServerJSONValue?) -> [CodexAppServerModelOption] {
        let rawItems = modelItems(from: result)
        var seen: Set<String> = []
        var options: [CodexAppServerModelOption] = []
        for item in rawItems {
            guard let option = option(from: item), !seen.contains(option.id) else {
                continue
            }
            seen.insert(option.id)
            options.append(option)
        }
        return options.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private static func modelItems(from result: CodexAppServerJSONValue?) -> [CodexAppServerJSONValue] {
        guard let result else {
            return []
        }
        if let items = result.arrayValue {
            return items
        }
        guard let object = result.objectValue else {
            return []
        }
        for key in ["models", "data", "items"] {
            if let items = object[key]?.arrayValue {
                return items
            }
            if let keyed = object[key]?.objectValue {
                return keyed.map { key, value in
                    if var object = value.objectValue {
                        object["id"] = object["id"] ?? .string(key)
                        return .object(object)
                    }
                    return .object(["id": .string(key), "title": value])
                }
            }
        }
        return object.map { key, value in
            if var item = value.objectValue {
                item["id"] = item["id"] ?? .string(key)
                return .object(item)
            }
            return .object(["id": .string(key), "title": value])
        }
    }

    private static func option(from item: CodexAppServerJSONValue) -> CodexAppServerModelOption? {
        if let id = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return CodexAppServerModelOption(id: id)
        }
        guard let object = item.objectValue else {
            return nil
        }
        let id = firstString(in: object, keys: ["id", "model", "name", "slug"])
        guard let id, !id.isEmpty else {
            return nil
        }
        return CodexAppServerModelOption(
            id: id,
            title: firstString(in: object, keys: ["title", "label", "displayName", "display_name", "name"]),
            provider: firstString(in: object, keys: ["provider", "modelProvider", "model_provider"]),
            description: firstString(in: object, keys: ["description", "summary"]),
            isDefault: object["isDefault"]?.boolValue ?? object["default"]?.boolValue ?? false
        )
    }

    private static func firstString(in object: [String: CodexAppServerJSONValue], keys: [String]) -> String? {
        for key in keys {
            let value = object[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                return value
            }
        }
        return nil
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

private extension String {
    var nilIfEmpty: String? {
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

struct CodexAppServerRequestBuilder {
    private let projectsByID: [String: AgentProject]
    private let allowlistedPaths: Set<String>

    init(allowlistedProjects: [AgentProject]) {
        self.projectsByID = Dictionary(uniqueKeysWithValues: allowlistedProjects.map { ($0.id, $0) })
        self.allowlistedPaths = Set(allowlistedProjects.map(\.path).compactMap(Self.standardizedAllowlistPath))
    }

    func threadList(cwd: String, limit: Int? = 20, cursor: String? = nil) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        return CodexAppServerRequestSpec(method: "thread/list", params: CodexAppServerJSONValue.objectValue([
            "cwd": .string(path),
            "limit": limit.map { .int(Int64($0)) },
            "cursor": cursor.map { .string($0) }
        ]))
    }

    func modelList() -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "model/list")
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

    func threadResume(threadID: String, cwd: String, model: String? = nil, options: CodexAppServerTurnOptions = .default) throws -> CodexAppServerRequestSpec {
        var resolved = options
        if resolved.model == nil {
            resolved.model = model
        }
        return try threadResume(threadID: threadID, cwd: cwd, options: resolved)
    }

    func threadResume(threadID: String, cwd: String, options: CodexAppServerTurnOptions = .default) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        var params = safeThreadRuntimeParams(cwd: path)
        params["threadId"] = .string(threadID)
        params["excludeTurns"] = .bool(true)
        params["ephemeral"] = nil
        options.threadParams(projectPath: path).forEach { key, value in
            params[key] = value
        }
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
            "sandbox": .string("workspace-write"),
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
        if normalizedDangerToken(params["sandbox"]??.stringValue) == "dangerfullaccess" {
            throw CodexAppServerRequestBuilderError.unsafeParameter("dangerFullAccess sandbox 被禁止")
        }
        try validateNoDangerousConfig(params["config"] ?? nil)
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
        let inputPaths = try collectUserInputPaths(params["input"] ?? nil)
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

    private func collectUserInputPaths(_ input: CodexAppServerJSONValue?) throws -> [String] {
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
            case "localImage", "skill", "mention":
                guard let path = object["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                    throw CodexAppServerRequestBuilderError.unsafeParameter("turn/start.input.\(type).path 不能为空")
                }
                paths.append(path)
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
