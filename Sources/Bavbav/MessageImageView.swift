import AppKit
import SwiftUI
import Markdown
import ImageIO
import BavbavCore

private struct MessageDirectoryKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct MessageCommandsKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var messageDirectory: String? {
        get { self[MessageDirectoryKey.self] }
        set { self[MessageDirectoryKey.self] = newValue }
    }
    var messageCommandsVisible: Bool {
        get { self[MessageCommandsKey.self] }
        set { self[MessageCommandsKey.self] = newValue }
    }
}

enum MessageImageReferences {
    private final class Entry: NSObject {
        let images: [CodexMessageImage]
        init(_ images: [CodexMessageImage]) { self.images = images }
    }
    @MainActor private static let cache: NSCache<NSString, Entry> = {
        let value = NSCache<NSString, Entry>(); value.countLimit = 80; value.totalCostLimit = 2 * 1_024 * 1_024; return value
    }()
    @MainActor static func markdown(_ text: String) -> [CodexMessageImage] {
        guard text.utf8.count <= 256 * 1_024, text.contains("![") else { return [] }
        if let cached = cache.object(forKey: text as NSString) { return cached.images }
        var images: [CodexMessageImage] = []
        func visit(_ node: Markup, depth: Int) {
            guard depth < 64, images.count < MessageImagePayload.maximumImages else { return }
            if let image = node as? Markdown.Image, let source = image.source {
                images.append(CodexMessageImage(source: source, title: image.plainText.isEmpty ? "Görsel" : image.plainText))
            } else if !(node is CodeBlock) && !(node is InlineCode) {
                for child in node.children { visit(child, depth: depth + 1) }
            }
        }
        visit(Document(parsing: text), depth: 0)
        cache.setObject(Entry(images), forKey: text as NSString, cost: text.utf8.count)
        return images
    }
    @MainActor static func images(for message: CodexMessage) -> [CodexMessageImage] {
        var seen = Set<String>()
        let markdownImages = message.kind.isConversation ? markdown(message.text) : []
        return Array(((message.images ?? []) + markdownImages).filter { seen.insert($0.source).inserted }
            .prefix(MessageImagePayload.maximumImages))
    }
    static func localURL(_ source: String, directory: String?) -> URL? {
        guard !source.hasPrefix("//"), !source.contains("\0") else { return nil }
        if source.hasPrefix("/") || source.hasPrefix("file:") { return MessageLinkPolicy.destination(source).flatMap { $0.isFileURL ? $0 : nil } }
        // Sandbox artifacts are not guessed to be on this Mac. Unsupported or
        // missing artifacts get an honest fallback rather than a blank image.
        guard URL(string: source)?.scheme == nil, let directory, directory.hasPrefix("/"),
              !source.isEmpty else { return nil }
        return URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(source.removingPercentEncoding ?? source).standardizedFileURL
    }
    static func remoteURL(_ source: String) -> URL? {
        guard let url = URL(string: source), url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

/// All decoding is off the main thread; only downsampled, orientation-corrected
/// raster data enters SwiftUI. No NSImage(contentsOf: remoteURL) implicit IO.
final class MessageImageLoader: @unchecked Sendable {
    static let shared = MessageImageLoader()
    private final class Entry: NSObject { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    private let cache = NSCache<NSString, Entry>()
    private let workers = OperationQueue()
    init() {
        cache.countLimit = 48; cache.totalCostLimit = 24 * 1_024 * 1_024
        workers.name = "Bavbav.MessageImages"; workers.qualityOfService = .utility; workers.maxConcurrentOperationCount = 2
    }
    func load(source: String, directory: String?, remoteData: Data? = nil) async -> CGImage? {
        await withCheckedContinuation { continuation in
            workers.addOperation { [self] in
                // Resolve local paths in the worker too; metadata IO must not
                // happen on every transcript layout/scroll pass.
                let local: URL?
                if source.hasPrefix("data:") { local = MessageImagePayload.persist(dataURL: source, directory: MessageImagePayload.cacheDirectory) }
                else { local = MessageImageReferences.localURL(source, directory: directory) }
                let values = try? local?.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey])
                let version = "\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                let location = local?.path ?? source
                let baseDirectory = directory ?? ""
                let key = "\(location)|\(baseDirectory)|\(version)" as NSString
                if remoteData == nil, let value = cache.object(forKey: key) { continuation.resume(returning: value.image); return }
                let data: Data?
                if let remoteData { data = remoteData }
                else if let local, let values,
                        values.isRegularFile == true, let size = values.fileSize, size <= MessageImagePayload.maximumBytes {
                    data = try? Data(contentsOf: local, options: .mappedIfSafe)
                } else { data = nil }
                let image = data.flatMap(Self.decode)
                if let image { cache.setObject(Entry(image), forKey: key, cost: image.bytesPerRow * image.height) }
                continuation.resume(returning: image)
            }
        }
    }
    static func decode(_ data: Data) -> CGImage? {
        guard !data.isEmpty, data.count <= MessageImagePayload.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg", "public.tiff", "public.heic", "public.heif", "org.webmproject.webp", "com.compuserve.gif"].contains(type),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Double,
              let height = props[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0, width * height <= 60_000_000 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_200, kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}

/// A remote image requires a click. The request has no account cookies, cache,
/// credentials or referrer, refuses redirects, and stops at the byte limit.
final class RemoteMessageImage: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var data = Data()
    private var continuation: CheckedContinuation<Data?, Never>?
    private var session: URLSession?
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false
    static func fetch(_ url: URL, configuration: URLSessionConfiguration = .ephemeral) async -> Data? {
        let receiver = RemoteMessageImage()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in receiver.start(url, configuration: configuration, continuation: continuation) }
        }, onCancel: { receiver.cancel() })
    }
    private func start(_ url: URL, configuration: URLSessionConfiguration, continuation: CheckedContinuation<Data?, Never>) {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { continuation.resume(returning: nil); return }
            self.continuation = continuation
            let config = configuration
            config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil; config.httpShouldSetCookies = false
            config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
            session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            task = session?.dataTask(with: url)
            task?.resume()
    }
    private func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true; task?.cancel()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.mimeType?.hasPrefix("image/") == true,
              response.expectedContentLength <= MessageImagePayload.maximumBytes else { completionHandler(.cancel); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= MessageImagePayload.maximumBytes else { dataTask.cancel(); return }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        continuation?.resume(returning: error == nil ? data : nil); continuation = nil
        data = Data()
        session.finishTasksAndInvalidate(); self.session = nil
    }
}

struct MessageImageCard: View {
    let reference: CodexMessageImage
    @Environment(\.messageDirectory) private var directory
    @State private var image: CGImage?
    @State private var attempted = false
    @State private var loading = false
    @State private var expanded = false
    @State private var loadRemote = false
    @State private var retry = 0
    private var remote: URL? { MessageImageReferences.remoteURL(reference.source) }
    private var identity: String { reference.source + "|" + (directory ?? "") + "|\(loadRemote)|\(retry)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                BavbavTheme.background.panelBackdrop()
                if let image {
                    Button { expanded.toggle() } label: {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }.buttonStyle(.plain).accessibilityLabel("\(reference.title) · \(expanded ? "Küçült" : "Büyüt")")
                } else if loading { ProgressView().controlSize(.small) }
                else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo").font(.system(size: 24, weight: .light))
                        Text(remote != nil && !attempted ? "Web görseli" : "Görsel yüklenemedi")
                        if remote != nil && !attempted {
                            Button("Görseli yükle") { loadRemote = true }
                            Text("\(remote?.host ?? "") · Yalnızca tıklayınca indirilir")
                        } else {
                            Text("Dosya taşınmış, erişilemiyor veya biçimi desteklenmiyor olabilir.")
                                .multilineTextAlignment(.center)
                            Button("Tekrar dene") { retry += 1 }
                        }
                    }.font(BavbavTheme.mono(10)).foregroundStyle(BavbavTheme.muted).readableForeground().padding(12)
                }
            }
            .frame(height: expanded ? 440 : 220)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Text(reference.title).lineLimit(1)
                Spacer()
                if image != nil { Text(expanded ? "KÜÇÜLT ↑" : "BÜYÜT ↗") }
                if let url = MessageImageReferences.localURL(reference.source, directory: directory) {
                    Button("Finder’da göster") { MessageLinkPolicy.open(url) }.buttonStyle(.plain)
                } else if let remote {
                    Button("Bağlantıyı aç") { MessageLinkPolicy.open(remote) }.buttonStyle(.plain)
                }
            }.font(BavbavTheme.mono(8)).foregroundStyle(BavbavTheme.cyan).readableForeground()
        }
        .padding(8)
        .background(BavbavTheme.surface.panelBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(BavbavTheme.border, lineWidth: 0.7).allowsHitTesting(false))
        .task(id: identity) {
            image = nil; attempted = false
            guard remote == nil || loadRemote else { return }
            loading = true
            let bytes: Data?
            if let remote { bytes = await RemoteMessageImage.fetch(remote) }
            else { bytes = nil }
            guard !Task.isCancelled else { return }
            let result = remote != nil && bytes == nil ? nil : await MessageImageLoader.shared.load(source: reference.source, directory: directory, remoteData: bytes)
            guard !Task.isCancelled else { return }
            image = result; loading = false; attempted = true
        }
        .onDisappear { image = nil }
    }
}
