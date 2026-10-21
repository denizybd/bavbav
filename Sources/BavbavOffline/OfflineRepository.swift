import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One atomic snapshot, protected by an exclusive process lease for its entire lifetime.
/// The lease file must never be removed while the repository is in use.
public final class OfflineRepository: @unchecked Sendable {
    public let rootURL: URL
    public let maxTasks: Int
    private let mutex = NSLock()
    private final class Lease {
        let descriptor: Int32
        init(_ descriptor: Int32) { self.descriptor = descriptor }
        deinit { flock(descriptor, LOCK_UN); close(descriptor) }
    }
    private let lease: Lease
    private let stateURL: URL
    private let byteLimit = 32 * 1024 * 1024
    private var storageFault = false
    private var coordinatorOwner: String?

    private struct Snapshot: Codable {
        let schemaVersion: Int
        let records: [OfflineTaskRecord]
    }

    func claimCoordinator(_ identifier: String) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard coordinatorOwner == nil else { throw OfflineError.repositoryBusy(rootURL.path) }
        coordinatorOwner = identifier
    }

    func releaseCoordinator(_ identifier: String) {
        mutex.lock(); defer { mutex.unlock() }
        if coordinatorOwner == identifier { coordinatorOwner = nil }
    }

    public init(rootURL: URL, maxTasks: Int = 128) throws {
        guard rootURL.isFileURL, (1...128).contains(maxTasks) else {
            throw OfflineError.invalidRequest("Invalid repository location or capacity")
        }
        self.rootURL = rootURL.standardizedFileURL
        self.maxTasks = maxTasks
        self.stateURL = self.rootURL.appendingPathComponent("tasks.json")
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: self.rootURL, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let values = try self.rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw OfflineError.invalidRequest("Repository must be a real private directory")
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.rootURL.path)
        } catch let error as OfflineError { throw error }
        catch { throw OfflineError.storageFailure(String(describing: error)) }
        let lockPath = self.rootURL.appendingPathComponent("repository.lease").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw OfflineError.storageFailure("Cannot open repository lease") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw OfflineError.repositoryBusy(self.rootURL.path)
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            flock(descriptor, LOCK_UN); close(descriptor)
            throw OfflineError.storageFailure("Cannot protect repository lease")
        }
        lease = Lease(descriptor)
        _ = try load()
    }

    public func load() throws -> [OfflineTaskRecord] {
        mutex.lock(); defer { mutex.unlock() }
        guard !storageFault else { throw OfflineError.storageFailure("Repository is fenced after a failed transaction") }
        let fm = FileManager.default
        guard fm.fileExists(atPath: stateURL.path) else { return [] }
        do {
            let values = try stateURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= byteLimit else {
                throw OfflineError.corruptRepository("Invalid snapshot file")
            }
            let data = try Data(contentsOf: stateURL, options: [.mappedIfSafe])
            let decoder = JSONDecoder()
            // Native Date's exact Double representation is retained for receipt identity comparisons.
            decoder.dateDecodingStrategy = .deferredToDate
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            guard snapshot.schemaVersion == 1 else { throw OfflineError.corruptRepository("Unsupported schema") }
            try validate(snapshot.records)
            return snapshot.records
        } catch let error as OfflineError { throw error }
        catch { throw OfflineError.corruptRepository(String(describing: error)) }
    }

    public func save(_ records: [OfflineTaskRecord]) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard !storageFault else { throw OfflineError.storageFailure("Repository is fenced after a failed transaction") }
        try validate(records)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(Snapshot(schemaVersion: 1, records: records)) }
        catch { throw OfflineError.storageFailure("Cannot encode task checkpoint") }
        guard data.count <= byteLimit else { throw OfflineError.limitExceeded("Repository snapshot is full") }
        var committed = false
        defer { if !committed { storageFault = true } }
        let temporaryURL = rootURL.appendingPathComponent(".checkpoint-\(UUID().uuidString).tmp")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw OfflineError.storageFailure("Cannot create private checkpoint") }
        var descriptorOpen = true
        defer {
            if descriptorOpen { close(descriptor) }
            // This path is an exact, random file created by this transaction only.
            unlink(temporaryURL.path)
        }
        let wrote = data.withUnsafeBytes { bytes -> Bool in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wrote, fsync(descriptor) == 0 else { throw OfflineError.storageFailure("Cannot flush checkpoint") }
        guard close(descriptor) == 0 else {
            descriptorOpen = false
            throw OfflineError.storageFailure("Cannot close checkpoint")
        }
        descriptorOpen = false
        guard rename(temporaryURL.path, stateURL.path) == 0 else {
            throw OfflineError.storageFailure("Cannot atomically replace checkpoint")
        }
        let directory = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw OfflineError.storageFailure("Cannot open checkpoint directory") }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw OfflineError.storageFailure("Cannot flush checkpoint directory") }
        committed = true
    }

    private func validate(_ records: [OfflineTaskRecord]) throws {
        guard records.count <= maxTasks, Set(records.map(\.id)).count == records.count,
              Set(records.map(\.request.deduplicationKey)).count == records.count else {
            throw OfflineError.corruptRepository("Duplicate task identity or repository capacity exceeded")
        }
        for record in records {
            try record.request.validate()
            guard record.receipts.count <= record.request.limits.maxReceipts,
                  Set(record.receipts.map(\.id)).count == record.receipts.count,
                  (record.errorMessage?.count ?? 0) <= 4000 else {
                throw OfflineError.corruptRepository("Invalid progress journal")
            }
            for receipt in record.receipts { try receipt.validate() }
            if let result = record.result {
                guard result.summary.count <= 4000, result.output.count <= record.request.limits.maxOutputCharacters,
                      result.receipts.count <= record.request.limits.maxReceipts else {
                    throw OfflineError.corruptRepository("Oversized result")
                }
                for receipt in result.receipts { try receipt.validate() }
            }
            if record.phase == .running && (record.attemptID?.isEmpty != false) {
                throw OfflineError.corruptRepository("Running task has no execution identity")
            }
            if record.request.cloudDisposition == .outcomeUnknown
                && ![.awaitingCloudResolution, .paused, .cancelled].contains(record.phase) {
                throw OfflineError.corruptRepository("Unknown cloud work cannot execute locally")
            }
            if [.completed, .handedBack].contains(record.phase) && record.result == nil {
                throw OfflineError.corruptRepository("Completed task has no result")
            }
            if [.completed, .handedBack].contains(record.phase) && record.result?.disposition != .completed {
                throw OfflineError.corruptRepository("Incomplete work cannot be marked completed")
            }
            if let handoff = record.handoff {
                guard handoff.taskID == record.id, handoff.sourceThreadID == record.request.sourceThreadID,
                      handoff.modelID == OfflinePlugin.modelID, handoff.receipts == record.receipts,
                      handoff.output == record.result?.output, handoff.summary == record.result?.summary else {
                    throw OfflineError.corruptRepository("Handoff identity mismatch")
                }
            }
            if record.phase == .handedBack && (record.handoff == nil || record.handoffAcceptedAt == nil) {
                throw OfflineError.corruptRepository("Handoff lacks explicit acceptance")
            }
        }
    }
}
