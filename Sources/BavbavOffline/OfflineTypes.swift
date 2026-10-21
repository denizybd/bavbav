import Foundation

public enum OfflinePlugin {
    public static let version = "0.1.0"
    public static let modelID = "huihui_ai/qwen3-abliterated:14b-v2"
}

public enum OfflineCloudDisposition: String, Codable, Sendable, Equatable {
    case notSubmitted, outcomeUnknown, confirmedStopped
}

public enum OfflineTaskPhase: String, Codable, Sendable, Equatable {
    case queued, running, paused, waitingForNetwork, awaitingCloudResolution
    case completed, failed, cancelled, handedBack
}

public struct OfflineContextMessage: Codable, Sendable, Equatable {
    public var role: String
    public var text: String
    public init(role: String, text: String) { self.role = role; self.text = text }
}

public struct OfflineLimits: Codable, Sendable, Equatable {
    public var maxContextCharacters: Int
    public var maxObjectiveCharacters: Int
    public var maxOutputCharacters: Int
    public var maxReceipts: Int
    public var maxSteps: Int
    public var maxDurationSeconds: Double

    public init(maxContextCharacters: Int = 32_000, maxObjectiveCharacters: Int = 12_000,
                maxOutputCharacters: Int = 32_000, maxReceipts: Int = 64,
                maxSteps: Int = 12, maxDurationSeconds: Double = 180) {
        self.maxContextCharacters = maxContextCharacters
        self.maxObjectiveCharacters = maxObjectiveCharacters
        self.maxOutputCharacters = maxOutputCharacters
        self.maxReceipts = maxReceipts
        self.maxSteps = maxSteps
        self.maxDurationSeconds = maxDurationSeconds
    }
}

public struct OfflineWorkRequest: Codable, Sendable, Equatable {
    public var id: String
    public var deduplicationKey: String
    public var sourceThreadID: String
    public var sourceTurnID: String?
    public var workspacePath: String
    public var objective: String
    public var context: [OfflineContextMessage]
    public var attachments: [String]
    /// Persisted operations supplied by the coordinator on an explicitly resumed execution.
    public var checkpointReceipts: [OfflineProgressReceipt]
    public var cloudDisposition: OfflineCloudDisposition
    public var limits: OfflineLimits
    public var createdAt: Date

    public init(id: String = UUID().uuidString, deduplicationKey: String, sourceThreadID: String, sourceTurnID: String? = nil,
                workspacePath: String, objective: String, context: [OfflineContextMessage] = [],
                attachments: [String] = [], checkpointReceipts: [OfflineProgressReceipt] = [],
                cloudDisposition: OfflineCloudDisposition = .notSubmitted,
                limits: OfflineLimits = OfflineLimits(), createdAt: Date = Date()) {
        self.id = id; self.deduplicationKey = deduplicationKey; self.sourceThreadID = sourceThreadID
        self.sourceTurnID = sourceTurnID
        self.workspacePath = workspacePath; self.objective = objective; self.context = context
        self.attachments = attachments; self.checkpointReceipts = checkpointReceipts
        self.cloudDisposition = cloudDisposition
        self.limits = limits; self.createdAt = createdAt
    }

    public func validate() throws {
        let limits = limits
        guard !id.isEmpty, id.count <= 128, !deduplicationKey.isEmpty, deduplicationKey.count <= 256,
              !sourceThreadID.isEmpty, sourceThreadID.count <= 256,
              sourceTurnID.map({ !$0.isEmpty && $0.count <= 256 }) ?? true,
              workspacePath.hasPrefix("/"), workspacePath.count <= 4096,
              !workspacePath.contains("\0"), createdAt.timeIntervalSince1970.isFinite else {
            throw OfflineError.invalidRequest("Missing or invalid task identity/workspace")
        }
        guard (1...64_000).contains(limits.maxContextCharacters),
              (1...24_000).contains(limits.maxObjectiveCharacters),
              (1...64_000).contains(limits.maxOutputCharacters), (1...128).contains(limits.maxReceipts),
              (1...32).contains(limits.maxSteps), limits.maxDurationSeconds.isFinite,
              (1...600).contains(limits.maxDurationSeconds) else {
            throw OfflineError.limitExceeded("Task limits exceed the offline plugin budget")
        }
        guard !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              objective.count <= limits.maxObjectiveCharacters,
              context.count <= 64, context.reduce(0, { $0 + $1.text.count }) <= limits.maxContextCharacters,
              context.allSatisfy({ ["user", "assistant", "system", "tool"].contains($0.role) }),
              attachments.count <= 8, attachments.allSatisfy({ $0.count <= 4096 && !$0.contains("\0") }) else {
            throw OfflineError.limitExceeded("Objective, context or attachments exceed the offline budget")
        }
        guard checkpointReceipts.count <= limits.maxReceipts else {
            throw OfflineError.limitExceeded("Too many resumed checkpoints")
        }
        for receipt in checkpointReceipts { try receipt.validate() }
    }
}

public struct OfflineProgressReceipt: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: String
    public var summary: String
    public var details: String
    public var createdAt: Date
    public init(id: String = UUID().uuidString, kind: String, summary: String,
                details: String = "", createdAt: Date = Date()) {
        self.id = id; self.kind = kind; self.summary = summary; self.details = details; self.createdAt = createdAt
    }
    public func validate() throws {
        guard !id.isEmpty, id.count <= 128, !kind.isEmpty, kind.count <= 64,
              summary.count <= 2000, details.count <= 8000, createdAt.timeIntervalSince1970.isFinite else {
            throw OfflineError.limitExceeded("Invalid or oversized progress receipt")
        }
    }
}

public enum OfflineResultDisposition: String, Codable, Sendable, Equatable {
    case completed, waitingForNetwork
}

public struct OfflineWorkResult: Codable, Sendable, Equatable {
    public var summary: String
    public var output: String
    public var receipts: [OfflineProgressReceipt]
    public var disposition: OfflineResultDisposition
    public init(summary: String, output: String, receipts: [OfflineProgressReceipt] = [],
                disposition: OfflineResultDisposition = .completed) {
        self.summary = summary; self.output = output; self.receipts = receipts
        self.disposition = disposition
    }
}

public protocol OfflineWorker: Sendable {
    func run(request: OfflineWorkRequest,
             progress: @escaping @Sendable (OfflineProgressReceipt) async throws -> Void) async throws -> OfflineWorkResult
}

public struct OfflineHandoffReport: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let taskID: String
    public let sourceThreadID: String
    public let modelID: String
    public let objective: String
    public let summary: String
    public let output: String
    public let receipts: [OfflineProgressReceipt]
    public let createdAt: Date

    public var text: String { composerText }

    public var composerText: String {
        var remaining = 12_000
        var journal: [String] = []
        for receipt in receipts {
            let line = "- [\(receipt.kind)] \(receipt.summary)\(receipt.details.isEmpty ? "" : "\n  " + receipt.details)"
            guard remaining > 0 else { break }
            let bounded = String(line.prefix(remaining))
            journal.append(bounded)
            remaining -= bounded.count
        }
        if journal.count < receipts.count { journal.append("Kalan işlem ayrıntıları Bavbav'ın yerel görev kaydında saklandı.") }
        return """
        [Bavbav offline handoff · \(taskID) · \(id)]
        Yerel model: \(modelID). Bu ayrı bir yerel çalışmadır; bulut oturumunun devamı değildir.
        Amaç: \(objective)
        Özet: \(summary)

        \(output)

        Kalıcı işlem kayıtları (\(receipts.count)):
        \(journal.joined(separator: "\n"))

        Orijinal dosyalara otomatik yazılmadı. Önerileri doğrula; kaydedilmiş işlemleri tekrarlama.
        """
    }
}

public struct OfflineTaskRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { request.id }
    public var request: OfflineWorkRequest
    public var phase: OfflineTaskPhase
    public var attemptID: String?
    public var receipts: [OfflineProgressReceipt]
    public var result: OfflineWorkResult?
    public var errorMessage: String?
    public var updatedAt: Date
    public var handoff: OfflineHandoffReport?
    public var handoffAcceptedAt: Date?

    public init(request: OfflineWorkRequest) {
        self.request = request
        phase = request.cloudDisposition == .outcomeUnknown ? .awaitingCloudResolution : .queued
        attemptID = nil; receipts = []; result = nil; errorMessage = nil
        updatedAt = request.createdAt; handoff = nil; handoffAcceptedAt = nil
    }
}

public enum OfflineError: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest(String), invalidTransition(String), repositoryBusy(String)
    case corruptRepository(String), storageFailure(String), limitExceeded(String)
    case workerFailure(String), networkUnavailable(String), cancelled, staleExecution

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason): return "Geçersiz yerel görev: \(reason)"
        case .invalidTransition(let reason): return "Görev durumu bu işleme uygun değil: \(reason)"
        case .repositoryBusy: return "Yerel görev deposu başka bir Bavbav işlemi tarafından kullanılıyor."
        case .corruptRepository: return "Yerel görev kaydı okunamadı. Güvenlik için otomatik yürütme durduruldu."
        case .storageFailure: return "Yerel görev kaydı diske güvenli biçimde yazılamadı. İşlem durduruldu."
        case .limitExceeded(let reason): return "Yerel çalışma sınırına ulaşıldı: \(reason)"
        case .workerFailure(let reason): return "Yerel çalışma başarısız: \(reason)"
        case .networkUnavailable(let reason): return "Bağlantı bekleniyor: \(reason)"
        case .cancelled: return "Yerel çalışma iptal edildi."
        case .staleExecution: return "Eski veya iptal edilmiş çalışma sonucu yok sayıldı."
        }
    }
}
