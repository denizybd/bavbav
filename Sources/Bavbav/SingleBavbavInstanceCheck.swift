import Foundation
import Darwin

/// Only UUID-scoped temporary files are touched. No actual app lease, account,
/// network connection, screen capture, permission prompt or process control.
@MainActor enum SingleBavbavInstanceCheck {
    private struct Failure: Error { let message: String }

    static func run() -> Bool {
        let files = FileManager.default
        let directory = files.temporaryDirectory
            .appendingPathComponent("bavbav-instance-check-\(UUID())", isDirectory: true)
        var createdDirectory = false
        var leases: [SingleBavbavInstance] = []
        var count = 0
        defer {
            for lease in leases { lease.release() }
            // The exact directory was uniquely created by this fixture. Never
            // remove Runtime, Application Support or a caller-supplied path.
            if createdDirectory { try? files.removeItem(at: directory) }
        }
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            count += 1
            guard try condition() else { throw Failure(message: message) }
        }
        func makeLease(_ name: String) -> SingleBavbavInstance {
            let lease = SingleBavbavInstance(directory: directory.appendingPathComponent(name, isDirectory: true))
            leases.append(lease)
            return lease
        }
        func mode(_ url: URL) throws -> Int {
            (try files.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        func failed(_ claim: SingleBavbavInstance.Claim) -> Bool {
            if case .failure = claim { return true }
            return false
        }

        do {
            guard !files.fileExists(atPath: directory.path) else {
                throw Failure(message: "unique fixture directory already exists")
            }
            try files.createDirectory(at: directory, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
            createdDirectory = true
            let runtime = directory.appendingPathComponent("shared", isDirectory: true)
            let lock = runtime.appendingPathComponent("instance.lock")
            let expectedPID = Data("\(Darwin.getpid())\n".utf8)
            let owner = makeLease("shared")
            try check(owner.claim() == .owner, "first lease owns a new runtime")
            try check(owner.claim() == .owner, "repeat claim is idempotent without releasing ownership")
            try check(try Data(contentsOf: lock) == expectedPID, "owner writes its actual PID")
            try check(try mode(runtime) == 0o700, "runtime directory is private0700")
            try check(try mode(lock) == 0o600, "lock file is private0600")

            let duplicate = makeLease("shared")
            try check(duplicate.claim() == .alreadyRunning(pid: Darwin.getpid()), "second lease sees the current owner PID")
            try check(try Data(contentsOf: lock) == expectedPID, "blocked duplicate does not truncate or replace PID")
            duplicate.release()
            try check(duplicate.claim() == .alreadyRunning(pid: Darwin.getpid()), "releasing a blocked duplicate never unlocks owner")
            let third = makeLease("shared")
            try check(third.claim() == .alreadyRunning(pid: Darwin.getpid()), "owner remains exclusive after duplicate release/retry")

            owner.release()
            owner.release()
            try check(files.fileExists(atPath: lock.path), "release preserves lock inode instead of unlinking it")
            try check(duplicate.claim() == .owner, "released lease is reclaimed by a waiting duplicate")
            try check(owner.claim() == .alreadyRunning(pid: Darwin.getpid()), "old owner cannot steal replacement's lock")
            owner.release()
            try check(third.claim() == .alreadyRunning(pid: Darwin.getpid()), "old owner's redundant release does not unlock replacement")
            duplicate.release()
            try check(third.claim() == .owner, "replacement release permits the next owner")
            third.release()

            let deinitRuntime = directory.appendingPathComponent("deinit", isDirectory: true)
            var scopedOwner: SingleBavbavInstance? = SingleBavbavInstance(directory: deinitRuntime)
            try check(scopedOwner?.claim() == .owner, "deinit fixture acquires exclusive ownership")
            let afterDeinit = makeLease("deinit")
            try withExtendedLifetime(scopedOwner) {
                try check(afterDeinit.claim() == .alreadyRunning(pid: Darwin.getpid()), "live scoped owner blocks another lease")
            }
            scopedOwner = nil
            try check(afterDeinit.claim() == .owner, "deinit releases the descriptor and allows reclaim")
            afterDeinit.release()

            for (index, contents) in ["not a pid\n", "99999999\n", String(repeating: "9", count: 200)].enumerated() {
                let name = "stale-\(index)"
                let staleRuntime = directory.appendingPathComponent(name, isDirectory: true)
                try files.createDirectory(at: staleRuntime, withIntermediateDirectories: false,
                                          attributes: [.posixPermissions: 0o755])
                let staleLock = staleRuntime.appendingPathComponent("instance.lock")
                try Data(contents.utf8).write(to: staleLock)
                let newOwner = makeLease(name)
                try check(newOwner.claim() == .owner, "unlocked stale/malformed PID is not ownership, case\(index)")
                try check(try Data(contentsOf: staleLock) == expectedPID, "fresh owner replaces and truncates stale PID, case\(index)")
                try check(try mode(staleRuntime) == 0o700 && mode(staleLock) == 0o600,
                          "fresh owner normalizes private permissions, case\(index)")
                newOwner.release()
            }

            let target = directory.appendingPathComponent("symlink-target.txt")
            let sentinel = Data("fixture sentinel; never overwritten".utf8)
            try sentinel.write(to: target)
            let symlinkRuntime = directory.appendingPathComponent("lock-symlink", isDirectory: true)
            try files.createDirectory(at: symlinkRuntime, withIntermediateDirectories: false)
            try files.createSymbolicLink(at: symlinkRuntime.appendingPathComponent("instance.lock"),
                                         withDestinationURL: target)
            try check(failed(makeLease("lock-symlink").claim()), "lock symlink is rejected")
            try check(try Data(contentsOf: target) == sentinel, "lock symlink target is never truncated or written")

            let actualDirectory = directory.appendingPathComponent("directory-target", isDirectory: true)
            try files.createDirectory(at: actualDirectory, withIntermediateDirectories: false)
            let directoryLink = directory.appendingPathComponent("directory-symlink", isDirectory: true)
            try files.createSymbolicLink(at: directoryLink, withDestinationURL: actualDirectory)
            try check(failed(makeLease("directory-symlink").claim()), "runtime directory symlink is rejected")
            try check(!files.fileExists(atPath: actualDirectory.appendingPathComponent("instance.lock").path),
                      "runtime directory symlink target does not receive a lock")

            let regularRuntime = directory.appendingPathComponent("regular-runtime")
            try sentinel.write(to: regularRuntime)
            try check(failed(makeLease("regular-runtime").claim()), "regular file cannot act as a runtime directory")
            try check(try Data(contentsOf: regularRuntime) == sentinel, "invalid runtime regular file is preserved")

            let directoryLockRuntime = directory.appendingPathComponent("directory-lock", isDirectory: true)
            try files.createDirectory(at: directoryLockRuntime.appendingPathComponent("instance.lock", isDirectory: true),
                                      withIntermediateDirectories: true)
            try check(failed(makeLease("directory-lock").claim()), "directory cannot act as a regular lock file")
            try check((try files.attributesOfItem(atPath: directoryLockRuntime.appendingPathComponent("instance.lock").path)[.type]
                       as? FileAttributeType) == .typeDirectory, "invalid directory lock target is preserved")

            print("SINGLE BAVBAV INSTANCE CHECK PASSED: \(count) checks; exclusivity, idempotence, reclaim/deinit, stale PID, private modes and rejected symlinks; isolated temporary files only")
            return true
        } catch {
            fputs("SINGLE BAVBAV INSTANCE CHECK FAILED: \((error as? Failure)?.message ?? error.localizedDescription)\n", stderr)
            return false
        }
    }
}
