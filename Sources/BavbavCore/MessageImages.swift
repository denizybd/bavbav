import Foundation
import CryptoKit

public struct CodexMessageImage: Hashable, Codable, Sendable {
    public let source: String
    public let title: String
    public init(source: String, title: String = "Görsel") { self.source = source; self.title = title }
}

/// Extract only explicit image payloads, never arbitrary strings in tool JSON.
/// Encoded images become bounded, content-addressed cache files so transcript
/// equality, snapshots and SwiftUI never retain megabytes of base64 per row.
public enum MessageImagePayload {
    public static let maximumBytes = 25 * 1_024 * 1_024
    public static let maximumImages = 8
    public static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bavbav/ReceivedImages", isDirectory: true)
    }
    private static let lock = NSLock()

    public static func images(in item: [String: Any], directory: URL? = nil) -> [CodexMessageImage] {
        let type = item["type"] as? String ?? ""
        var sources: [String] = []
        if type == "imageView", let path = item["path"] as? String { sources = [path] }
        if type == "imageGeneration" {
            if let path = item["savedPath"] as? String, !path.isEmpty { sources = [path] }
            else if let result = item["result"] as? String, !result.isEmpty {
                sources = [result.hasPrefix("data:") || result.hasPrefix("/") || result.hasPrefix("https://")
                           ? result : "data:image/png;base64," + result]
            }
        }
        let result = item["result"] as? [String: Any]
        let content: [[String: Any]]
        switch type {
        case "mcpToolCall": content = result?["content"] as? [[String: Any]] ?? []
        case "dynamicToolCall": content = item["contentItems"] as? [[String: Any]] ?? []
        case "functionCallOutput": content = item["output"] as? [[String: Any]] ?? []
        case "userMessage", "message": content = item["content"] as? [[String: Any]] ?? []
        default: content = []
        }
        for part in content.prefix(64) {
            guard sources.count < maximumImages else { break }
            switch part["type"] as? String {
            case "image", "input_image", "inputImage":
                if let data = part["data"] as? String, let mime = part["mimeType"] as? String {
                    sources.append("data:\(mime);base64,\(data)")
                } else if let url = part["url"] as? String ?? part["imageUrl"] as? String ?? part["image_url"] as? String {
                    sources.append(url)
                }
            case "localImage": if let path = part["path"] as? String { sources.append(path) }
            default: break
            }
        }
        var seen = Set<String>()
        return sources.prefix(maximumImages).map { source in
            guard source.hasPrefix("data:") else {
                return CodexMessageImage(source: source.utf8.count <= 32_768 ? source : "unavailable:oversized-reference")
            }
            let stored = persist(dataURL: source, directory: directory ?? cacheDirectory)
            return CodexMessageImage(source: stored?.path ?? "unavailable:invalid-image", title: stored == nil ? "Görsel verisi okunamadı" : "Görsel")
        }.filter { seen.insert($0.source).inserted }
    }

    public static func persist(dataURL: String, directory: URL) -> URL? {
        guard dataURL.utf8.count <= maximumBytes * 4 / 3 + 128,
              let comma = dataURL.firstIndex(of: ",") else { return nil }
        let header = String(dataURL[..<comma]).lowercased()
        let extensions = ["data:image/png;base64": "png", "data:image/jpeg;base64": "jpg",
                          "data:image/webp;base64": "webp", "data:image/gif;base64": "gif",
                          "data:image/heic;base64": "heic", "data:image/tiff;base64": "tiff"]
        guard let ext = extensions[header],
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              !data.isEmpty, data.count <= maximumBytes else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(hash).appendingPathExtension(ext)
        lock.lock(); defer { lock.unlock() }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            if !manager.fileExists(atPath: file.path) {
                try data.write(to: file, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            // Only evict files with our exact content-addressed name. Originals
            // are never moved or deleted; history can recreate evicted payloads.
            let files = (try? manager.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
            let entries = files.compactMap { url -> (URL, Int, Date)? in
                guard url.deletingPathExtension().lastPathComponent.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }.sorted { $0.2 < $1.2 }
            var bytes = entries.reduce(0) { $0 + $1.1 }
            for entry in entries where bytes > 128 * 1_024 * 1_024 && entry.0 != file {
                if (try? manager.removeItem(at: entry.0)) != nil { bytes -= entry.1 }
            }
            return file
        } catch { return nil }
    }
}
