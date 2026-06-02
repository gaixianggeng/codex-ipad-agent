import Foundation

struct HealthResponse: Codable {
    let ok: Bool
    let version: String
}

struct VersionResponse: Codable {
    let name: String
    let version: String
}

struct ProjectsResponse: Codable {
    let projects: [AgentProject]
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
    let prompt: String
    let resumeID: String
    let title: String
    let cols: Int
    let rows: Int
    let clientMessageID: ClientMessageID?

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case prompt
        case resumeID = "resume_id"
        case title
        case cols
        case rows
        case clientMessageID = "client_message_id"
    }

    init(
        projectID: String,
        prompt: String,
        resumeID: String,
        title: String,
        cols: Int,
        rows: Int,
        clientMessageID: ClientMessageID? = nil
    ) {
        self.projectID = projectID
        self.prompt = prompt
        self.resumeID = resumeID
        self.title = title
        self.cols = cols
        self.rows = rows
        self.clientMessageID = clientMessageID
    }
}
