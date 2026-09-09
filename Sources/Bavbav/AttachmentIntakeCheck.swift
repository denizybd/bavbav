import AppKit
import BavbavCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Private pasteboards, temporary fixtures and an unordered native window.
/// Does not read the general clipboard, capture the screen or synthesize input.
@MainActor
enum AttachmentIntakeCheck {
    private struct Failure: Error { let message: String }

    static func run() async -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Bavbav-attachment-check-\(UUID().uuidString)")
        let sourceDirectory = directory.appendingPathComponent("source")
        let importedDirectory = directory.appendingPathComponent("imported")
        let board = NSPasteboard(name: .init("Bavbav.AttachmentCheck.\(UUID().uuidString)"))
        defer {
            board.releaseGlobally()
            try? FileManager.default.removeItem(at: directory)
        }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !condition() { throw Failure(message: message) }
        }
        do {
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            let png = sourceDirectory.appendingPathComponent("Screenshot fixture.png")
            try createPNG(at: png)
            let note = sourceDirectory.appendingPathComponent("notes.txt")
            try Data("These are attachment test notes.\n".utf8).write(to: note)
            let intake = AttachmentIntake(directory: importedDirectory, promiseTimeout: 0.8)
            let picked = await intake.ingest(urls: [png, note])
            try check(picked.errors.isEmpty && picked.attachments.count == 2, "file picker imports image and document: \(picked.errors)")
            try check(picked.attachments.map(\.isImage) == [true, false], "image/document kind retained")
            try check(picked.attachments.map(\.name) == [png.lastPathComponent, note.lastPathComponent], "input order and names retained")
            for attachment in picked.attachments {
                try check(attachment.localURL.path.hasPrefix(importedDirectory.path + "/"), "stable app-owned copy")
                try check(FileManager.default.isReadableFile(atPath: attachment.path), "copied item readable")
                try check(attachment.byteCount > 0, "byte size recorded")
                let attributes = try FileManager.default.attributesOfItem(atPath: attachment.path)
                try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private copy permissions")
            }

            board.clearContents()
            try check(board.writeObjects([png as NSURL]), "native file URL written to private pasteboard")
            try check(AttachmentIntake.accepts(board), "native file URL drag accepted")
            let dragged = await intake.ingest(pasteboard: board)
            try check(dragged.attachments.count == 1 && dragged.errors.isEmpty, "native file URL imported once: \(dragged.errors)")

            board.clearContents()
            let originalImage = try Data(contentsOf: png)
            board.setData(originalImage, forType: .png)
            let image = await intake.ingest(pasteboard: board)
            try check(image.attachments.count == 1 && image.errors.isEmpty, "raw PNG drop imported: \(image.errors)")
            try check(image.attachments.first?.isImage == true, "raw PNG remains an image")
            try check(image.attachments.first.map { $0.localURL.pathExtension == "png" } == true, "raw screenshot receives stable PNG filename")

            board.clearContents()
            guard let representation = NSBitmapImageRep(data: originalImage) else {
                throw Failure(message: "fixture image decoder failed")
            }
            board.setData(representation.tiffRepresentation!, forType: .tiff)
            let tiff = await intake.ingest(pasteboard: board)
            try check(tiff.attachments.count == 1 && tiff.errors.isEmpty, "native TIFF screenshot converts to PNG: \(tiff.errors)")
            let tiffFile = sourceDirectory.appendingPathComponent("Photo.tiff")
            try representation.tiffRepresentation!.write(to: tiffFile)
            let tiffFileResult = await intake.ingest(urls: [tiffFile])
            try check(tiffFileResult.attachments.first?.name == "Photo.png"
                && tiffFileResult.attachments.first?.isImage == true, "TIFF files normalize to portable PNG vision input")

            board.clearContents()
            board.setString("normal selected text", forType: .string)
            try check(!AttachmentIntake.accepts(board), "ordinary text drag is not an attachment")
            let text = await intake.ingest(pasteboard: board)
            try check(text.attachments.isEmpty && !text.errors.isEmpty, "unsupported drop reports an error")

            board.clearContents()
            board.setData(Data("not an image".utf8), forType: .png)
            let invalidImage = await intake.ingest(pasteboard: board)
            try check(invalidImage.attachments.isEmpty && invalidImage.errors.count == 1, "corrupt screenshot rejected")

            let directoryResult = await intake.ingest(urls: [sourceDirectory])
            try check(directoryResult.attachments.isEmpty && !directoryResult.errors.isEmpty, "directories rejected")
            let missingResult = await intake.ingest(urls: [sourceDirectory.appendingPathComponent("missing.pdf")])
            try check(missingResult.attachments.isEmpty && !missingResult.errors.isEmpty, "missing files rejected")
            let remoteResult = await intake.ingest(urls: [URL(string: "https://example.invalid/image.png")!])
            try check(remoteResult.attachments.isEmpty && !remoteResult.errors.isEmpty, "remote URL is not fetched")
            let symlink = sourceDirectory.appendingPathComponent("linked.txt")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: note)
            let symlinkResult = await intake.ingest(urls: [symlink])
            try check(symlinkResult.attachments.isEmpty && !symlinkResult.errors.isEmpty, "symlinks rejected")
            let tooMany = await intake.ingest(urls: Array(repeating: note, count: 13))
            try check(tooMany.attachments.isEmpty && tooMany.errors.count == 1, "attachment count bounded")
            let huge = sourceDirectory.appendingPathComponent("too-large.pdf")
            FileManager.default.createFile(atPath: huge.path, contents: nil)
            let hugeHandle = try FileHandle(forWritingTo: huge)
            try hugeHandle.truncate(atOffset: UInt64(AttachmentIntake.maximumFileBytes + 1))
            try hugeHandle.close()
            let hugeResult = await intake.ingest(urls: [huge])
            try check(hugeResult.attachments.isEmpty && hugeResult.errors.count == 1, "large file rejected before copying")
            let mixed = await intake.ingest(urls: [note, huge, png])
            try check(mixed.attachments.count == 2 && mixed.errors.count == 1, "mixed valid and invalid files preserve successes")

            // On this macOS host the exact Apple sample does not fulfill a
            // native NSFilePromiseProvider on a private, non-drag pasteboard
            // (also checked cross-process and in a bundle). Verify the genuine
            // provider's decode and bounded failure path. This is not evidence
            // that a live floating screenshot-thumbnail gesture was performed.
            let delegate = ScreenshotPromise(data: originalImage)
            let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: delegate)
            let otherDelegate = ScreenshotPromise(data: originalImage, name: "Second screenshot.png")
            let otherProvider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: otherDelegate)
            board.clearContents()
            try check(board.writeObjects([provider, otherProvider]), "two modern native promises written to private pasteboard")
            try check(AttachmentIntake.accepts(board), "modern native promise type registered")
            let decoded = board.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            try check(decoded?.first is NSFilePromiseReceiver, "modern promise decodes as native receiver")
            let modern = await intake.ingest(pasteboard: board)
            withExtendedLifetime((delegate, provider, otherDelegate, otherProvider)) {}
            if modern.attachments.isEmpty {
                try check(modern.errors.contains { $0.contains("zaman aşımına") }, "unresolved promise returns actionable bounded error")
                print("ATTACHMENT LIVE-DRAG BOUNDARY: native provider decoded; private-board timeout handled. Live screenshot-thumbnail gesture remains unverified.")
            } else {
                try check(delegate.writeCount == 1 && otherDelegate.writeCount == 1 && modern.attachments.count == 2
                    && modern.errors.isEmpty, "modern promises fulfilled by native providers")
            }
            let afterUnresolvedPromise = await intake.ingest(urls: [note])
            try check(afterUnresolvedPromise.attachments.count == 1 && afterUnresolvedPromise.errors.isEmpty,
                      "two unresolved file promises do not starve both workers and stall later imports")

            // Native host identity and mouse hit testing are independent of a
            // drag overlay; message selection must remain available underneath.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 350),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let container = AttachmentDropContainer(content: Text("Attachment drop fixture"),
                isEnabled: true, onHoverChanged: { _ in }, onDrop: { _ in true })
            window.contentView = container
            container.layoutSubtreeIfNeeded()
            try check(Set(AttachmentIntake.acceptedTypes).isSubset(of: Set(container.registeredDraggedTypes)),
                      "native drop container registers promise, file, and bitmap types")
            let nativeText = NSTextView(frame: NSRect(x: 20, y: 20, width: 200, height: 80))
            nativeText.string = "Selectable chat text"
            nativeText.registerForDraggedTypes([.string, .fileURL, .png])
            container.host.addSubview(nativeText)
            container.needsLayout = true
            container.layoutSubtreeIfNeeded()
            let nativeTextPoint = nativeText.convert(NSPoint(x: 20, y: 20), to: container.superview)
            try check(container.hitTest(nativeTextPoint) === nativeText,
                      "drop surface does not swallow native text selection")
            try check(nativeText.registeredDraggedTypes.contains(.string)
                && !nativeText.registeredDraggedTypes.contains(.fileURL), "file drops bubble up while native text drops remain")
            let oldHost = container.host
            container.host.rootView = Text("Updated attachment drop fixture")
            try check(oldHost === container.host, "native content host survives updates")

            try FileManager.default.removeItem(at: png)
            try FileManager.default.removeItem(at: note)
            for attachment in picked.attachments {
                try check(FileManager.default.isReadableFile(atPath: attachment.path), "temporary source deletion does not invalidate queued attachment")
            }
            print("BAVBAV ATTACHMENT INTAKE CHECK PASSED: \(checks) checks (native pasteboards, promise decoding/timeout, private stable copies, limits and hit testing)")
            return true
        } catch {
            print("BAVBAV ATTACHMENT INTAKE CHECK FAILED after \(checks) checks: \((error as? Failure)?.message ?? error.localizedDescription)")
            return false
        }
    }

    private static func createPNG(at url: URL) throws {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        if !CGImageDestinationFinalize(destination) { throw Failure(message: "could not create PNG fixture") }
    }

    private final class ScreenshotPromise: NSObject, NSFilePromiseProviderDelegate {
        let data: Data
        let name: String
        private let lock = NSLock()
        private let queue = OperationQueue()
        private var writes = 0
        var writeCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
        init(data: Data, name: String = "Promised screenshot.png") { self.data = data; self.name = name }
        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            name
        }
        func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                 completionHandler: @escaping (Error?) -> Void) {
            lock.lock(); writes += 1; lock.unlock()
            do {
                try data.write(to: url)
                completionHandler(nil)
            }
            catch { completionHandler(error) }
        }
    }
}
