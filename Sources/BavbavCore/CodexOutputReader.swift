import Foundation
import Darwin

/// One bounded reader per child stream. A consumer must finish a chunk before
/// another is read, so a stalled event sink applies real pipe backpressure.
/// The wake pipe also fences cancellation and child exit without idle polling.
final class CodexOutputReader: @unchecked Sendable {
    private let lock = NSLock()
    private let descriptor: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private var cancelled = false
    private var closed = false
    private var exitStatus: Int32?

    init(handle: FileHandle) throws {
        let descriptor = Darwin.dup(handle.fileDescriptor)
        guard descriptor >= 0 else { throw CodexClientError.processFailed("Cannot open child output") }
        var wake: [Int32] = [0, 0]
        guard Darwin.pipe(&wake) == 0 else {
            Darwin.close(descriptor)
            throw CodexClientError.processFailed("Cannot create child output wake pipe")
        }
        self.descriptor = descriptor; wakeRead = wake[0]; wakeWrite = wake[1]
        for fd in [descriptor, wake[0], wake[1]] { _ = Darwin.fcntl(fd, F_SETFD, FD_CLOEXEC) }
    }

    deinit {
        if !closed { Darwin.close(descriptor); Darwin.close(wakeRead); Darwin.close(wakeWrite) }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !cancelled else { return }
        cancelled = true; wake()
    }

    func processExited(_ status: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, exitStatus == nil else { return }
        exitStatus = status; wake()
    }

    private func wake() {
        var byte: UInt8 = 1
        _ = Darwin.write(wakeWrite, &byte, 1)
    }

    private var state: (cancelled: Bool, exitStatus: Int32?) {
        lock.lock(); defer { lock.unlock() }
        return (cancelled, exitStatus)
    }

    func start(label: String, consume: @escaping @Sendable (Data, Int) -> Void,
               ended: @escaping @Sendable (Int32?, String?) -> Void) {
        DispatchQueue(label: label, qos: .userInitiated).async {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var reason: String?
            var sequence = 0
            defer {
                self.lock.lock(); self.closed = true
                Darwin.close(self.descriptor); Darwin.close(self.wakeRead); Darwin.close(self.wakeWrite)
                let cancelled = self.cancelled, status = self.exitStatus
                self.lock.unlock()
                if !cancelled { ended(status, reason) }
            }
            while true {
                let state = self.state
                if state.cancelled { return }
                var descriptors = [pollfd(fd: self.descriptor, events: Int16(POLLIN), revents: 0),
                                   pollfd(fd: self.wakeRead, events: Int16(POLLIN), revents: 0)]
                // Once the child has exited, drain every byte already in its
                // pipe. An inherited writer cannot keep the dead session alive.
                let result = Darwin.poll(&descriptors, 2, state.exitStatus == nil ? -1 : 0)
                if result < 0 {
                    if errno == EINTR { continue }
                    reason = "Child output read failed"; return
                }
                if result == 0 { return }
                if descriptors[1].revents != 0 {
                    var wakeBytes = [UInt8](repeating: 0, count: 8)
                    _ = Darwin.read(self.wakeRead, &wakeBytes, wakeBytes.count)
                    continue
                }
                if descriptors[0].revents & Int16(POLLNVAL) != 0 {
                    reason = "Child output closed"; return
                }
                if descriptors[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(self.descriptor, $0.baseAddress, $0.count) }
                    if count == 0 { return }
                    if count < 0 {
                        if errno == EINTR { continue }
                        reason = "Child output read failed"; return
                    }
                    consume(Data(buffer.prefix(count)), sequence)
                    sequence += 1
                }
            }
        }
    }
}
