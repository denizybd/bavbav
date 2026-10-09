import Foundation
import Darwin

/// The normal application retains one lease for its entire lifetime. Diagnostic
/// runners deliberately do not claim it. The kernel, not a stale PID file,
/// decides ownership; an interrupted or crashed application releases its lock.
@MainActor final class SingleBavbavInstance {
    enum Claim: Equatable {
        case owner
        case alreadyRunning(pid: Int32?)
        case failure(reason: String)
    }

    private let directory: URL?
    private var descriptor: Int32 = -1

    /// Passing a dedicated temporary directory allows side-effect-free lease
    /// fixtures. Normal launches use only Bavbav's private Runtime directory.
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                               in: .userDomainMask).first?
            .appendingPathComponent("Bavbav", isDirectory: true)
            .appendingPathComponent("Runtime", isDirectory: true)
    }

    func claim() -> Claim {
        if descriptor >= 0 { return .owner }
        guard let directory, directory.isFileURL, directory.path != "/" else {
            return .failure(reason: "Bavbav çalışma dizini bulunamadı.")
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return .failure(reason: "Bavbav çalışma dizini açılamadı: \(error.localizedDescription)")
        }

        // Pin the directory before opening the file so a final-component
        // symlink, rename or replacement cannot redirect the file operation.
        let directoryFD = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryFD >= 0 else { return failure("Çalışma dizini güvenle açılamadı", errno) }
        defer { Darwin.close(directoryFD) }
        var directoryInfo = stat()
        guard Darwin.fstat(directoryFD, &directoryInfo) == 0 else {
            return failure("Çalışma dizini doğrulanamadı", errno)
        }
        guard directoryInfo.st_uid == Darwin.geteuid(),
              directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            return .failure(reason: "Bavbav çalışma dizini bu kullanıcıya ait güvenli bir dizin değil.")
        }
        guard Darwin.fchmod(directoryFD, mode_t(0o700)) == 0 else {
            return failure("Çalışma dizini izinleri korunamadı", errno)
        }

        // NONBLOCK also prevents a malformed FIFO at this path from hanging
        // startup; fstat below accepts only an owned, singly linked regular file.
        let fileFD = "instance.lock".withCString {
            Darwin.openat(directoryFD, $0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
                          mode_t(0o600))
        }
        guard fileFD >= 0 else { return failure("Uygulama kilidi açılamadı", errno) }
        var keepDescriptor = false
        defer { if !keepDescriptor { Darwin.close(fileFD) } }
        var fileInfo = stat()
        guard Darwin.fstat(fileFD, &fileInfo) == 0 else {
            return failure("Uygulama kilidi doğrulanamadı", errno)
        }
        guard fileInfo.st_uid == Darwin.geteuid(), fileInfo.st_nlink == 1,
              fileInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            return .failure(reason: "Bavbav uygulama kilidi bu kullanıcıya ait güvenli bir dosya değil.")
        }

        var lockResult: Int32
        // Use the unqualified C overload: Swift6.4 resolves Darwin.flock to
        // struct flock, while flock(Int32, Int32) imports the POSIX function.
        repeat { lockResult = flock(fileFD, LOCK_EX | LOCK_NB) }
        while lockResult != 0 && errno == EINTR
        if lockResult != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN else {
                return failure("Uygulama kilidi alınamadı", code)
            }
            // Informational only. The caller must verify this PID's live app
            // identity before activating it; it is never authority to kill.
            return .alreadyRunning(pid: readPID(fileFD))
        }

        guard Darwin.fchmod(fileFD, mode_t(0o600)) == 0 else {
            let result = failure("Uygulama kilidi izinleri korunamadı", errno)
            flock(fileFD, LOCK_UN)
            return result
        }
        // No truncation or PID write happens before an exclusive lock exists.
        guard Darwin.ftruncate(fileFD, 0) == 0, writePID(fileFD) else {
            let result = failure("Uygulama kilidi kaydedilemedi", errno)
            flock(fileFD, LOCK_UN)
            return result
        }
        descriptor = fileFD
        keepDescriptor = true
        return .owner
    }

    /// Does not delete the file. Unlinking a lock file lets other processes lock
    /// a different inode while an existing owner still holds the previous one.
    func release() {
        guard descriptor >= 0 else { return }
        let ownedDescriptor = descriptor
        descriptor = -1
        flock(ownedDescriptor, LOCK_UN)
        Darwin.close(ownedDescriptor)
    }

    deinit {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
    }

    private func readPID(_ fileFD: Int32) -> Int32? {
        var bytes = [UInt8](repeating: 0, count: 64)
        var count: Int
        repeat {
            count = bytes.withUnsafeMutableBytes { Darwin.pread(fileFD, $0.baseAddress, $0.count, 0) }
        } while count < 0 && errno == EINTR
        guard count > 0, count < bytes.count,
              let value = String(bytes: bytes.prefix(count), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let pid = Int32(value), pid > 0 else { return nil }
        return pid
    }

    private func writePID(_ fileFD: Int32) -> Bool {
        let bytes = Array("\(Darwin.getpid())\n".utf8)
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes {
                Darwin.pwrite(fileFD, $0.baseAddress?.advanced(by: offset), bytes.count - offset, off_t(offset))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                if count == 0 { errno = EIO }
                return false
            }
            offset += count
        }
        return true
    }

    private func failure(_ operation: String, _ code: Int32) -> Claim {
        .failure(reason: "\(operation): \(String(cString: Darwin.strerror(code)))")
    }
}
