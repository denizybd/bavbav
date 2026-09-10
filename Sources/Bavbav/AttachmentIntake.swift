import AppKit
import BavbavCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct AttachmentIntakeResult {
    var attachments: [ComposerAttachment] = []
    var errors: [String] = []
}

/// Only imports explicitly chosen/dropped items. The original is never moved or
/// modified; each item is copied before it can become part of a queued message.
@MainActor
final class AttachmentIntake {
    nonisolated static let maximumCount = 12
    nonisolated static let maximumFileBytes: Int64 = 25 * 1_024 * 1_024
    static let shared = AttachmentIntake()
    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        Array(Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
                  + [.fileURL, .png, .tiff]))
    }

    let directory: URL
    private let queue: OperationQueue
    private let promiseTimeout: TimeInterval

    init(directory: URL? = nil, promiseTimeout: TimeInterval = 30) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("Bavbav/Attachments", isDirectory: true)
        self.promiseTimeout = promiseTimeout
        queue = OperationQueue()
        queue.name = "Bavbav.AttachmentIntake"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
    }

    static func accepts(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: acceptedTypes) != nil
    }

    /// This entry point snapshots the pasteboard AND requests promised files
    /// before performDragOperation returns. Capture the destination thread in
    /// the caller's completion, never look up the selected thread on delivery.
    @discardableResult
    func importPasteboard(_ pasteboard: NSPasteboard,
                         completion: @escaping (AttachmentIntakeResult) -> Void) -> Bool {
        guard Self.accepts(pasteboard) else { return false }
        let objects = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self, NSURL.self,
            NSPasteboardItem.self], options: [.urlReadingFileURLsOnly: true]) ?? []
        var sources: [Source] = []
        var promises: [NSFilePromiseReceiver] = []
        var errors: [String] = []
        for object in objects {
            if let promise = object as? NSFilePromiseReceiver {
                promises.append(promise)
            } else if let url = object as? URL, url.isFileURL {
                sources.append(.file(url))
            } else if let item = object as? NSPasteboardItem,
                      let type = item.availableType(from: [.png, .tiff]), let data = item.data(forType: type) {
                if data.count <= Self.maximumFileBytes { sources.append(.image(data)) }
                else { errors.append("The image exceeds the 25 MiB limit.") }
            }
        }
        // Some older pasteboard owners expose image bytes on the board rather
        // than through readable NSPasteboardItem objects.
        if sources.isEmpty && promises.isEmpty && errors.isEmpty,
           let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type) {
            if data.count <= Self.maximumFileBytes { sources.append(.image(data)) }
            else { errors.append("The image exceeds the 25 MiB limit.") }
        }
        let requested = sources.count + promises.reduce(0) { $0 + max(1, $1.fileTypes.count) }
        guard requested <= Self.maximumCount else {
            completion(AttachmentIntakeResult(errors: ["You can add up to 12 files at a time."]))
            return true
        }
        guard requested > 0 else {
            completion(AttachmentIntakeResult(errors: errors.isEmpty ? ["The dropped item could not be read."] : errors))
            return true
        }
        let batch = Batch(directory: directory, queue: queue, initialErrors: errors,
                          completion: completion)
        batch.start(sources: sources, promises: promises, timeout: promiseTimeout)
        return true
    }

    func ingest(pasteboard: NSPasteboard) async -> AttachmentIntakeResult {
        await withCheckedContinuation { continuation in
            if !importPasteboard(pasteboard, completion: { continuation.resume(returning: $0) }) {
                continuation.resume(returning: AttachmentIntakeResult(errors: ["Drop an image or document here."]))
            }
        }
    }

    func ingest(urls: [URL]) async -> AttachmentIntakeResult {
        guard urls.count <= Self.maximumCount else {
            return AttachmentIntakeResult(errors: ["You can add up to 12 files at a time."])
        }
        guard !urls.isEmpty else { return AttachmentIntakeResult() }
        return await withCheckedContinuation { continuation in
            let batch = Batch(directory: directory, queue: queue, initialErrors: [],
                              completion: { continuation.resume(returning: $0) })
            batch.start(sources: urls.map(Source.file), promises: [], timeout: promiseTimeout)
        }
    }

    private enum Source: Sendable { case file(URL), image(Data) }

    /// Retained by outstanding operations/callbacks, independent of a chat
    /// window's lifetime. Every mutable member is confined to the main actor.
    @MainActor private final class Batch {
        nonisolated private static let conversionLock = NSLock()
        let directory: URL
        let queue: OperationQueue
        var result: AttachmentIntakeResult
        var completion: ((AttachmentIntakeResult) -> Void)?
        var pending = 0
        var nextIndex = 0
        var attachments: [(Int, ComposerAttachment)] = []
        var receivers: [NSFilePromiseReceiver] = []
        var promiseDirectories: [URL] = []
        var timeoutWork: DispatchWorkItem?

        init(directory: URL, queue: OperationQueue, initialErrors: [String],
             completion: @escaping (AttachmentIntakeResult) -> Void) {
            self.directory = directory
            self.queue = queue
            self.result = AttachmentIntakeResult(errors: initialErrors)
            self.completion = completion
        }

        func start(sources: [Source], promises: [NSFilePromiseReceiver], timeout: TimeInterval) {
            receivers = promises
            pending = sources.count + promises.reduce(0) { $0 + max(1, $1.fileTypes.count) }
            for source in sources { submit(source, index: takeIndex()) }
            if !promises.isEmpty {
                // AppKit requires the same destination directory for every
                // receiver in a drag. Request delivery while the drop is active.
                let incoming = directory.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                    promiseDirectories.append(incoming)
                    for receiver in promises {
                        let index = takeIndex()
                        receiver.receivePromisedFiles(atDestination: incoming, options: [:], operationQueue: queue) { [self] url, error in
                            // The receiver invokes this inside file coordination;
                            // make our private copy before leaving that callback.
                            let outcome = error.map { Result<ComposerAttachment, Error>.failure($0) }
                                ?? Self.importSource(.file(url), directory: directory)
                            DispatchQueue.main.async { self.received(outcome, index: index) }
                        }
                        let expected = max(1, receiver.fileTypes.count)
                        // Legacy providers may promise more than one file/type.
                        // fileNames is populated by receivePromisedFiles above.
                        pending += max(0, receiver.fileNames.count - expected)
                    }
                } catch {
                    pending -= promises.reduce(0) { $0 + max(1, $1.fileTypes.count) }
                    result.errors.append("Could not import the screenshot: \(error.localizedDescription)")
                }
            }
            if pending == 0 { finish(); return }
            let work = DispatchWorkItem { [self] in
                guard completion != nil else { return }
                result.errors.append("The file transfer timed out. Try dropping the image again.")
                finish()
            }
            timeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        }

        func takeIndex() -> Int { defer { nextIndex += 1 }; return nextIndex }

        func submit(_ source: Source, index: Int) {
            queue.addOperation { [self] in
                let outcome = Self.importSource(source, directory: directory)
                DispatchQueue.main.async { self.received(outcome, index: index) }
            }
        }

        func received(_ outcome: Result<ComposerAttachment, Error>, index: Int) {
            guard completion != nil else {
                // A late promise after timeout must not attach to a later chat.
                if case .success(let attachment) = outcome { Self.removeOwnedCopy(attachment, in: directory) }
                return
            }
            switch outcome {
            case .success(let attachment):
                if attachments.count < AttachmentIntake.maximumCount { attachments.append((index, attachment)) }
                else {
                    Self.removeOwnedCopy(attachment, in: directory)
                    result.errors.append("You can add up to 12 files at a time.")
                }
            case .failure(let error): result.errors.append(error.localizedDescription)
            }
            pending -= 1
            if pending <= 0 { finish() }
        }

        func finish() {
            guard let completion else { return }
            self.completion = nil
            timeoutWork?.cancel()
            timeoutWork = nil
            result.attachments = attachments.sorted { $0.0 < $1.0 }.map(\.1)
            let directories = promiseDirectories
            queue.addOperation { directories.forEach { try? FileManager.default.removeItem(at: $0) } }
            receivers.removeAll()
            completion(result)
        }

        nonisolated static func removeOwnedCopy(_ attachment: ComposerAttachment, in directory: URL) {
            let parent = attachment.localURL.deletingLastPathComponent()
            guard parent.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                  UUID(uuidString: parent.lastPathComponent) != nil else { return }
            try? FileManager.default.removeItem(at: parent)
        }

        nonisolated static func importSource(_ source: Source, directory: URL) -> Result<ComposerAttachment, Error> {
            do { return .success(try copy(source, directory: directory)) }
            catch { return .failure(error) }
        }

        nonisolated static func copy(_ source: Source, directory: URL) throws -> ComposerAttachment {
            let id = UUID().uuidString
            let destinationDirectory = directory.appendingPathComponent(id, isDirectory: true)
            var succeeded = false
            defer { if !succeeded { try? FileManager.default.removeItem(at: destinationDirectory) } }
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let destination: URL
            let name: String
            let isImage: Bool
            switch source {
            case .file(let original):
                guard original.isFileURL else { throw IntakeError("Only local files can be attached.") }
                let scoped = original.startAccessingSecurityScopedResource()
                defer { if scoped { original.stopAccessingSecurityScopedResource() } }
                let values = try original.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey,
                    .isSymbolicLinkKey, .isPackageKey, .fileSizeKey, .contentTypeKey])
                guard values.isRegularFile == true, values.isDirectory != true,
                      values.isSymbolicLink != true, values.isPackage != true,
                      FileManager.default.isReadableFile(atPath: original.path) else {
                    throw IntakeError("\(original.lastPathComponent): choose a readable file; folders cannot be attached.")
                }
                if let type = values.contentType,
                   type.conforms(to: .executable) || type.conforms(to: .application) {
                    throw IntakeError("\(original.lastPathComponent): applications cannot be attached.")
                }
                guard let size = values.fileSize, size <= AttachmentIntake.maximumFileBytes else {
                    throw IntakeError("\(original.lastPathComponent): the file exceeds the 25 MiB limit.")
                }
                let originalCopy = destinationDirectory.appendingPathComponent(original.lastPathComponent)
                try FileManager.default.copyItem(at: original, to: originalCopy)
                isImage = values.contentType?.conforms(to: .image) == true
                if isImage {
                    guard let image = CGImageSourceCreateWithURL(originalCopy as CFURL, nil) else {
                        throw IntakeError("\(original.lastPathComponent): the image could not be read.")
                    }
                    try validateImageSource(image)
                    let type = CGImageSourceGetType(image) as String?
                    if type != UTType.png.identifier && type != UTType.jpeg.identifier {
                        // Vision input is portable PNG/JPEG, including when a
                        // user chooses a HEIC photo or a TIFF screenshot file.
                        name = original.deletingPathExtension().lastPathComponent + ".png"
                        destination = destinationDirectory.appendingPathComponent(name)
                        let converted = destinationDirectory.appendingPathComponent(".converted-\(UUID().uuidString).png")
                        try writePNG(image, to: converted)
                        try FileManager.default.removeItem(at: originalCopy)
                        try FileManager.default.moveItem(at: converted, to: destination)
                    } else {
                        name = original.lastPathComponent
                        destination = originalCopy
                    }
                } else {
                    name = original.lastPathComponent
                    destination = originalCopy
                }
            case .image(let data):
                guard data.count <= AttachmentIntake.maximumFileBytes,
                      let image = CGImageSourceCreateWithData(data as CFData, nil) else {
                    throw IntakeError("The image could not be read or exceeds the 25 MiB limit.")
                }
                try validateImageSource(image)
                name = "Screenshot.png"
                destination = destinationDirectory.appendingPathComponent(name)
                if CGImageSourceGetType(image) as String? == UTType.png.identifier {
                    // PNG screenshots are already in their final format; do
                    // not inflate a full bitmap just to write the same bytes.
                    try data.write(to: destination, options: .atomic)
                } else {
                    try writePNG(image, to: destination)
                }
                isImage = true
            }
            let copied = try destination.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard copied.isRegularFile == true, copied.isSymbolicLink != true,
                  let size = copied.fileSize, size <= AttachmentIntake.maximumFileBytes else {
                throw IntakeError("\(name): the file exceeds the 25 MiB limit.")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            succeeded = true
            return ComposerAttachment(id: id, path: destination.path, name: name,
                byteCount: Int64(size), isImage: isImage)
        }

        nonisolated static func writePNG(_ source: CGImageSource, to url: URL) throws {
            // Permit AppKit's promise coordination to make progress while
            // serializing the only operation that inflates large bitmaps.
            conversionLock.lock()
            defer { conversionLock.unlock() }
            guard let output = CGImageDestinationCreateWithURL(url as CFURL,
                UTType.png.identifier as CFString, 1, nil) else { throw IntakeError("The image could not be saved.") }
            CGImageDestinationAddImageFromSource(output, source, 0, nil)
            guard CGImageDestinationFinalize(output) else { throw IntakeError("The image could not be saved.") }
        }

        nonisolated static func validateImageSource(_ source: CGImageSource) throws {
            guard CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue > 0, height.doubleValue > 0,
                  width.doubleValue * height.doubleValue <= 60_000_000 else {
                throw IntakeError("The image is unreadable or too large (maximum 60 megapixels).")
            }
        }
    }

    private struct IntakeError: LocalizedError {
        var errorDescription: String? { message }
        let message: String
        init(_ message: String) { self.message = message }
    }
}

/// A stable native host, not a click-catching overlay. File drags bubble here;
/// ordinary mouse/text/scroll events keep their existing native destinations.
struct AttachmentDropRegion<Content: View>: NSViewRepresentable {
    var isEnabled: Bool = true
    var onHoverChanged: (Bool) -> Void = { _ in }
    var onDrop: (NSPasteboard) -> Bool
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> AttachmentDropContainer<Content> {
        AttachmentDropContainer(content: content(), isEnabled: isEnabled,
                                onHoverChanged: onHoverChanged, onDrop: onDrop)
    }

    func updateNSView(_ view: AttachmentDropContainer<Content>, context: Context) {
        view.isEnabled = isEnabled
        view.onHoverChanged = onHoverChanged
        view.onDrop = onDrop
        view.host.rootView = content()
        view.needsLayout = true
    }
}

final class AttachmentDropContainer<Content: View>: NSView {
    let host: NSHostingView<Content>
    var isEnabled: Bool
    var onHoverChanged: (Bool) -> Void
    var onDrop: (NSPasteboard) -> Bool
    private var hovering = false

    init(content: Content, isEnabled: Bool, onHoverChanged: @escaping (Bool) -> Void,
         onDrop: @escaping (NSPasteboard) -> Bool) {
        host = NSHostingView(rootView: content)
        self.isEnabled = isEnabled
        self.onHoverChanged = onHoverChanged
        self.onDrop = onDrop
        super.init(frame: .zero)
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        registerForDraggedTypes(AttachmentIntake.acceptedTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        host.frame = bounds
        // NSTextView's default file-URL drop inserts the pathname. Remove only
        // attachment types; native text selection/reordering remains registered.
        let excluded = Set(AttachmentIntake.acceptedTypes)
        func removeNestedFileHandlers(_ view: NSView) {
            let types = view.registeredDraggedTypes
            let remaining = types.filter { !excluded.contains($0) }
            if remaining != types {
                view.unregisterDraggedTypes()
                view.registerForDraggedTypes(remaining)
            }
            view.subviews.forEach(removeNestedFileHandlers)
        }
        removeNestedFileHandlers(host)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = isEnabled && sender.draggingSourceOperationMask.contains(.copy)
            && AttachmentIntake.accepts(sender.draggingPasteboard)
        setHovering(accepted)
        return accepted ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { setHovering(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { setHovering(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isEnabled && AttachmentIntake.accepts(sender.draggingPasteboard)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setHovering(false)
        guard isEnabled, AttachmentIntake.accepts(sender.draggingPasteboard) else { return false }
        return onDrop(sender.draggingPasteboard)
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { setHovering(false) }
    private func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        onHoverChanged(value)
    }
}
