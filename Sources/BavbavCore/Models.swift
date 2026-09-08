import Foundation

public struct CodexProject: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var name: String
    public let path: String
    public var chatCount: Int

    public init(id: String, name: String, path: String, chatCount: Int = 0) {
        self.id = id
        self.name = name
        self.path = path
        self.chatCount = chatCount
    }
}

public enum ThreadRunState: String, Codable, Sendable {
    case notLoaded
    case idle
    case active
    case systemError
    case unknown
}

public struct CodexThread: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let projectID: String?
    public let cwd: String
    public let title: String
    public let preview: String
    public let updatedAt: Date
    public let state: ThreadRunState
    public let hasMessages: Bool

    public init(
        id: String,
        projectID: String?,
        cwd: String,
        title: String,
        preview: String,
        updatedAt: Date,
        state: ThreadRunState,
        hasMessages: Bool
    ) {
        self.id = id
        self.projectID = projectID
        self.cwd = cwd
        self.title = title
        self.preview = preview
        self.updatedAt = updatedAt
        self.state = state
        self.hasMessages = hasMessages
    }
}

public enum MessageRole: String, Codable, Sendable {
    case user
    case agent
}

public enum CodexMessageKind: String, Codable, Sendable {
    case user
    case agent
    case plan
    case reasoning
    case command
    case fileChange
    case mcpTool
    case dynamicTool
    case collaboration
    case webSearch
    case image
    case review
    case compaction
    case toolOutput
    case diff
    case system

    public var isConversation: Bool {
        self == .user || self == .agent
    }

    public var isChatVisible: Bool {
        isConversation || self == .reasoning || self == .collaboration
    }
}

public struct CodexMessage: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let role: MessageRole
    public let text: String
    public let kind: CodexMessageKind
    public let title: String?
    public let status: String?
    public var timestamp: Date?

    public init(
        id: String,
        role: MessageRole,
        text: String,
        kind: CodexMessageKind? = nil,
        title: String? = nil,
        status: String? = nil,
        timestamp: Date? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.kind = kind ?? (role == .user ? .user : .agent)
        self.title = title
        self.status = status
        self.timestamp = timestamp
    }
}

public enum CodexRequestID: Hashable, Sendable {
    case integer(Int)
    case string(String)

    public var stableID: String {
        switch self {
        case .integer(let value): return "rpc-int-\(value)"
        case .string(let value): return "rpc-string-\(value)"
        }
    }
}

public enum CodexInteractionKind: String, Hashable, Sendable {
    case commandApproval
    case fileApproval
    case permissionApproval
    case userInput
    case mcpForm
    case mcpURL
}

public struct CodexInteractionOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let detail: String

    public init(id: String, label: String, detail: String) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

public struct CodexInteractionQuestion: Identifiable, Hashable, Sendable {
    public let id: String
    public let header: String
    public let prompt: String
    public let options: [CodexInteractionOption]
    public let allowsOther: Bool
    public let isSecret: Bool
    public let valueType: CodexInteractionValueType
    public let allowsMultiple: Bool
    public let isRequired: Bool

    public init(
        id: String,
        header: String,
        prompt: String,
        options: [CodexInteractionOption],
        allowsOther: Bool = false,
        isSecret: Bool = false,
        valueType: CodexInteractionValueType = .string,
        allowsMultiple: Bool = false,
        isRequired: Bool = true
    ) {
        self.id = id
        self.header = header
        self.prompt = prompt
        self.options = options
        self.allowsOther = allowsOther
        self.isSecret = isSecret
        self.valueType = valueType
        self.allowsMultiple = allowsMultiple
        self.isRequired = isRequired
    }
}

public enum CodexInteractionValueType: String, Hashable, Sendable {
    case string
    case integer
    case number
    case boolean
    case stringArray
}

public struct CodexInteractionRequest: Identifiable, Hashable, Sendable {
    public var id: String { requestID.stableID }
    public let requestID: CodexRequestID
    public let threadID: String
    public let turnID: String?
    public let itemID: String?
    public let kind: CodexInteractionKind
    public let title: String
    public let summary: String
    public let detail: String
    public let options: [CodexInteractionOption]
    public let questions: [CodexInteractionQuestion]
    public let defaultOptionID: String?

    public init(
        requestID: CodexRequestID,
        threadID: String,
        turnID: String?,
        itemID: String?,
        kind: CodexInteractionKind,
        title: String,
        summary: String,
        detail: String,
        options: [CodexInteractionOption],
        questions: [CodexInteractionQuestion] = [],
        defaultOptionID: String? = nil
    ) {
        self.requestID = requestID
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.kind = kind
        self.title = title
        self.summary = summary
        self.detail = detail
        self.options = options
        self.questions = questions
        self.defaultOptionID = defaultOptionID
    }
}

public enum CodexInteractionResponse: Hashable, Sendable {
    case option(String)
    case answers([String: [String]])
    case form(action: String, content: [String: CodexFormValue])
}

public enum CodexFormValue: Hashable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case stringArray([String])
}

public struct CodexReasoningEffort: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let description: String

    public init(id: String, description: String) {
        self.id = id
        self.description = description
    }
}

public struct CodexModelDescriptor: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let model: String
    public let displayName: String
    public let description: String
    public let isDefault: Bool
    public let defaultReasoningEffort: String
    public let supportedReasoningEfforts: [CodexReasoningEffort]

    public init(
        id: String,
        model: String,
        displayName: String,
        description: String,
        isDefault: Bool,
        defaultReasoningEffort: String,
        supportedReasoningEfforts: [CodexReasoningEffort]
    ) {
        self.id = id
        self.model = model
        self.displayName = displayName
        self.description = description
        self.isDefault = isDefault
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts
    }
}

public struct CodexRateLimitWindow: Hashable, Codable, Sendable {
    public let usedPercent: Int
    public let durationMinutes: Int?
    public let resetsAt: Date?

    public init(usedPercent: Int, durationMinutes: Int?, resetsAt: Date?) {
        self.usedPercent = max(0, min(100, usedPercent))
        self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Int { max(0, 100 - usedPercent) }
}

public struct CodexRateLimits: Hashable, Codable, Sendable {
    public let limitID: String?
    public let limitName: String?
    public let planType: String?
    public let primary: CodexRateLimitWindow?
    public let secondary: CodexRateLimitWindow?

    public init(
        limitID: String?,
        limitName: String?,
        planType: String?,
        primary: CodexRateLimitWindow?,
        secondary: CodexRateLimitWindow?
    ) {
        self.limitID = limitID
        self.limitName = limitName
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
    }
}

public struct CodexDailyUsage: Identifiable, Hashable, Codable, Sendable {
    public var id: String { startDate }
    public let startDate: String
    public let tokens: Int64

    public init(startDate: String, tokens: Int64) {
        self.startDate = startDate
        self.tokens = tokens
    }
}

public struct CodexAccountUsage: Hashable, Codable, Sendable {
    public let lifetimeTokens: Int64?
    public let peakDailyTokens: Int64?
    public let currentStreakDays: Int?
    public let daily: [CodexDailyUsage]

    public init(
        lifetimeTokens: Int64?,
        peakDailyTokens: Int64?,
        currentStreakDays: Int?,
        daily: [CodexDailyUsage]
    ) {
        self.lifetimeTokens = lifetimeTokens
        self.peakDailyTokens = peakDailyTokens
        self.currentStreakDays = currentStreakDays
        self.daily = daily
    }
}

public struct CodexTurnStart: Hashable, Sendable {
    public let id: String
    public let status: String

    public init(id: String, status: String) {
        self.id = id
        self.status = status
    }
}

public struct CodexThreadRuntime: Hashable, Codable, Sendable {
    public let model: String?
    public let effort: String?

    public init(model: String?, effort: String?) {
        self.model = model
        self.effort = effort
    }

    public static let unknown = CodexThreadRuntime(model: nil, effort: nil)
}

public struct CodexThreadFork: Hashable, Sendable {
    public let thread: CodexThread
    public let runtime: CodexThreadRuntime

    public init(thread: CodexThread, runtime: CodexThreadRuntime) {
        self.thread = thread
        self.runtime = runtime
    }
}

public enum CodexExecutionMode: Hashable, Sendable {
    case workspace
    case readOnly
    case fullAccess
}

public enum CodexServerEvent: Sendable {
    case turnStarted(threadID: String, turnID: String)
    case itemStarted(threadID: String, turnID: String, message: CodexMessage)
    case agentMessageDelta(threadID: String, turnID: String, itemID: String, delta: String)
    case itemTextDelta(
        threadID: String,
        turnID: String,
        itemID: String,
        kind: CodexMessageKind,
        title: String,
        delta: String
    )
    case itemCompleted(threadID: String, turnID: String, message: CodexMessage)
    case turnDiffUpdated(threadID: String, turnID: String, diff: String)
    case turnCompleted(threadID: String, turnID: String, status: String, error: String?)
    case rateLimitsUpdated(CodexRateLimits)
    case interactionRequested(CodexInteractionRequest)
    case interactionResolved(requestID: CodexRequestID, threadID: String?)
    case warning(threadID: String?, message: String)
    case transportClosed(message: String)
}

public struct CodexHealth: Equatable, Sendable {
    public let codexHome: String
    public let platform: String
    public let userAgent: String
    public let accountType: String?
    public let authenticated: Bool
    public let historyAvailable: Bool
    public let modelAvailable: Bool

    public init(
        codexHome: String,
        platform: String,
        userAgent: String,
        accountType: String?,
        authenticated: Bool,
        historyAvailable: Bool,
        modelAvailable: Bool
    ) {
        self.codexHome = codexHome
        self.platform = platform
        self.userAgent = userAgent
        self.accountType = accountType
        self.authenticated = authenticated
        self.historyAvailable = historyAvailable
        self.modelAvailable = modelAvailable
    }
}

public enum CodexClientError: LocalizedError {
    case executableNotFound
    case processFailed(String)
    case invalidResponse(String)
    case rpcError(String)
    case timeout(String)
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Codex çalıştırıcısı bulunamadı."
        case .processFailed(let detail):
            return "Codex başlatılamadı: \(detail)"
        case .invalidResponse(let detail):
            return "Codex geçersiz yanıt verdi: \(detail)"
        case .rpcError(let detail):
            return "Codex hatası: \(detail)"
        case .timeout(let method):
            return "Codex yanıtı zaman aşımına uğradı (\(method))."
        case .disconnected:
            return "Codex bağlantısı kapandı."
        }
    }

    public var isActiveWriterConflict: Bool {
        guard case .rpcError(let detail) = self else { return false }
        let normalized = detail.lowercased()
        return normalized.contains("active writer")
            || normalized.contains("already has a writer")
            || normalized.contains("writer is active")
    }
}
