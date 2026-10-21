import Foundation
import CryptoKit
import Darwin

public enum OfflineSecretRedactor {
    /// A narrow additional safeguard, not a claim that arbitrary source files are secret-free.
    public static func redact(_ text: String) throws -> String {
        if text.range(of: "-----BEGIN(?: [A-Z0-9]+)* PRIVATE KEY-----", options: [.regularExpression, .caseInsensitive]) != nil {
            throw OfflineError.invalidRequest("Özel anahtar içeren metin yerel modele veya devir raporuna aktarılmadı.")
        }
        var result = text
        for pattern in [#"(?i)\bsk-(?:proj-)?[A-Za-z0-9_-]{12,}\b"#, #"(?i)\bBearer[ \t]+[A-Za-z0-9._~+/\-]{8,}={0,2}"#] {
            let expression = try NSRegularExpression(pattern: pattern)
            result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[REDACTED_SECRET]")
        }
        return result
    }
}

/// Deliberately read-only tools. A proposed replacement is returned as data, never applied.
public struct OfflineFileTools: Sendable {
    public struct Observation: Sendable {
        public let content: String
        public let evidence: String
    }

    private let root: URL
    private let inputRootPath: String
    private var bytesRead = 0
    private var reads = 0
    private let byteBudget: Int
    private let fileByteLimit: Int
    private let readLimit: Int

    public init(workspacePath: String, byteBudget: Int = 262_144, fileByteLimit: Int = 65_536, readLimit: Int = 64) throws {
        guard workspacePath.hasPrefix("/"), !workspacePath.utf8.contains(0), workspacePath.count <= 4_096 else {
            throw OfflineError.invalidRequest("Çalışma klasörü mutlak ve geçerli bir dosya yolu olmalı.")
        }
        let supplied = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
        let candidate = try Self.physicalURL(supplied)
        var directory: ObjCBool = false
        guard candidate.path != "/", FileManager.default.fileExists(atPath: candidate.path, isDirectory: &directory), directory.boolValue else {
            throw OfflineError.invalidRequest("Yerel çalışma klasörü geçerli, dar kapsamlı bir dizin olmalı.")
        }
        self.root = candidate
        self.inputRootPath = supplied.path
        self.byteBudget = max(1, min(byteBudget, 1_048_576))
        self.fileByteLimit = max(1, min(fileByteLimit, 131_072))
        self.readLimit = max(1, min(readLimit, 128))
    }

    public mutating func listFiles(path: String = "", limit: Int = 120) throws -> Observation {
        let directory = try checkedURL(path, allowRoot: true)
        try validateDirectory(directory)
        let (paths, truncated) = try files(in: directory, maximum: max(1, min(limit, 256)))
        return observation(content: paths.joined(separator: "\n"), metadata: [
            "tool": "list_files", "path": path, "count": paths.count,
            "truncated": truncated, "excluded": "hidden, secrets, build/runtime/dependency directories and symbolic links",
            "coverage": "bounded listing; inaccessible entries may be omitted"
        ])
    }

    public mutating func readFile(path: String, startLine: Int = 1, maxLines: Int = 160) throws -> Observation {
        let data = try read(path)
        let text = try decodedText(data, path: path)
        let lines = text.components(separatedBy: "\n")
        let start = min(max(1, startLine), max(1, lines.count)) - 1
        let end = min(lines.count, start + max(1, min(maxLines, 240)))
        let excerpt = lines[start..<end].enumerated().map { "\(start + $0.offset + 1): \($0.element)" }.joined(separator: "\n")
        return observation(content: excerpt, metadata: [
            "tool": "read_file", "path": path, "sha256": digest(data), "bytes": data.count,
            "startLine": start + 1, "endLine": end, "totalLines": lines.count,
            "truncated": start > 0 || end < lines.count, "contentRedacted": String(data: data, encoding: .utf8) != text
        ])
    }

    public mutating func searchText(query: String, path: String = "", maxMatches: Int = 40) throws -> Observation {
        guard !query.isEmpty, query.count <= 256 else { throw OfflineError.invalidRequest("Arama metni 1–256 karakter olmalı.") }
        guard try OfflineSecretRedactor.redact(query) == query else { throw OfflineError.invalidRequest("Gizli anahtar arama metnine eklenemez.") }
        let directory = try checkedURL(path, allowRoot: true)
        try validateDirectory(directory)
        let (paths, enumerationTruncated) = try files(in: directory, maximum: 128)
        var matches: [String] = []
        var scanned = 0
        var skipped = 0
        var limited = enumerationTruncated
        let matchLimit = max(1, min(maxMatches, 80))
        for relative in paths {
            try Task.checkCancellation()
            if reads >= readLimit || bytesRead >= byteBudget || matches.count >= matchLimit { limited = true; break }
            do {
                let data = try read(relative)
                let text = try decodedText(data, path: relative)
                scanned += 1
                for (offset, line) in text.components(separatedBy: "\n").enumerated() where line.localizedCaseInsensitiveContains(query) {
                    matches.append("\(relative):\(offset + 1): \(String(line.prefix(700)))")
                    if matches.count >= matchLimit { limited = true; break }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { skipped += 1 }
        }
        return observation(content: matches.isEmpty ? "İzin verilen ve taranan metin dosyalarında eşleşme yok." : matches.joined(separator: "\n"), metadata: [
            "tool": "search_text", "path": path, "query": query, "matches": matches.count,
            "scannedFiles": scanned, "skippedFiles": skipped, "truncated": limited,
            "coverage": "bounded allowed UTF-8 text files only; not a complete repository search"
        ])
    }

    public mutating func proposeChange(path: String, newText: String) throws -> Observation {
        guard !newText.utf8.contains(0), newText.utf8.count <= 6_000 else {
            throw OfflineError.limitExceeded("Değişiklik önerisi en fazla 6.000 bayt UTF-8 metin olabilir.")
        }
        guard try OfflineSecretRedactor.redact(newText) == newText else { throw OfflineError.invalidRequest("Gizli anahtar içeren değişiklik önerisi kaydedilmedi.") }
        let existing = try read(path)
        _ = try decodedText(existing, path: path)
        let result = observation(content: "Yalnızca öneri kaydedildi. Kaynak dosya DEĞİŞTİRİLMEDİ.\n\(newText)", metadata: [
            "tool": "propose_change", "path": path, "sourceSHA256": digest(existing),
            "replacement": newText, "replacementSHA256": digest(Data(newText.utf8)), "applied": false
        ])
        guard result.evidence.count <= 7_800 else { throw OfflineError.limitExceeded("Öneri kalıcı kanıt boyutu sınırına sığmıyor; kaynak dosya değiştirilmedi.") }
        return result
    }

    /// Attachments are never silently ignored, nor read from outside the approved workspace.
    public mutating func attachment(path: String) throws -> Observation {
        let relative: String
        if path.hasPrefix("/") {
            let supplied = URL(fileURLWithPath: path).standardizedFileURL
            let base: String
            if supplied.path.hasPrefix(root.path + "/") { base = root.path }
            else if supplied.path.hasPrefix(inputRootPath + "/") { base = inputRootPath }
            else {
                throw OfflineError.invalidRequest("Ek yerel çalışma klasörünün dışında; otomatik olarak gönderilmedi.")
            }
            relative = String(supplied.path.dropFirst(base.count + 1))
        } else { relative = path }
        let unsupported = Set(["pdf", "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "mov", "mp4", "mp3", "wav", "docx", "xlsx", "pptx"])
        guard !unsupported.contains(URL(fileURLWithPath: relative).pathExtension.lowercased()) else {
            throw OfflineError.invalidRequest("Bu yerel model yolu görsel/PDF/ofis/ses eki işlemiyor; bulut veya uygun bir model gerekiyor.")
        }
        return try readFile(path: relative, maxLines: 240)
    }

    private func checkedURL(_ path: String, allowRoot: Bool = false) throws -> URL {
        if path.isEmpty, allowRoot { return root }
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.utf8.contains(0) else {
            throw OfflineError.invalidRequest("Araç yolu çalışma klasörüne göreli olmalı.")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !isDenied($0) }) else {
            throw OfflineError.invalidRequest("Gizli, hassas, bağımlılık/çalıştırıcı veya üst dizin yolu engellendi.")
        }
        var current = root
        for component in components {
            current.appendPathComponent(component)
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw OfflineError.invalidRequest("Sembolik bağlantılar yerel araçlarda izlenmez.") }
        }
        let resolved = try Self.physicalURL(current)
        guard resolved.path.hasPrefix(root.path + "/") else { throw OfflineError.invalidRequest("Çalışma klasörü dışına erişim engellendi.") }
        return current
    }

    private static func physicalURL(_ url: URL) throws -> URL {
        // Foundation may abbreviate /private/var back to /var while its enumerator does not.
        guard let pointer = Darwin.realpath(url.path, nil) else { throw OfflineError.invalidRequest("Yerel dosya yolu çözümlenemedi.") }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer))
    }

    private func isDenied(_ component: String) -> Bool {
        let value = component.lowercased()
        if (try? OfflineSecretRedactor.redact(component)) != component { return true }
        if value.hasPrefix(".") { return true }
        if Set(["runtime", "node_modules", "dist", "build", "vendor", "__pycache__", "venv", "keychains", "credentials", "secrets", "private"]).contains(value) { return true }
        if ["secret", "credential", "password", "api_key", "apikey", "access_token", "auth_token", "id_rsa", "id_ed25519"].contains(where: value.contains) { return true }
        return Set(["pem", "key", "p12", "pfx", "kdbx", "sqlite", "sqlite3", "db"]).contains(URL(fileURLWithPath: value).pathExtension)
    }

    private func validateDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw OfflineError.invalidRequest("Listeleme/arama yolu gerçek bir dizin olmalı.") }
    }

    private func files(in directory: URL, maximum: Int) throws -> ([String], Bool) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw OfflineError.workerFailure("Çalışma dizini listelenemedi.")
        }
        var paths: [String] = []
        var visited = 0
        var truncated = false
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            visited += 1
            if visited > 1_024 { truncated = true; break }
            guard url.path.hasPrefix(root.path + "/") else { enumerator.skipDescendants(); continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let components = relative.split(separator: "/").map(String.init)
            let values = try url.resourceValues(forKeys: Set(keys))
            if components.count > 8 || components.contains(where: isDenied) || values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isRegularFile == true {
                if paths.count >= maximum { truncated = true; break }
                paths.append(relative)
            }
        }
        return (paths.sorted(), truncated)
    }

    private mutating func read(_ path: String) throws -> Data {
        try Task.checkCancellation()
        _ = try checkedURL(path)
        guard reads < readLimit, bytesRead < byteBudget else { throw OfflineError.limitExceeded("Yerel dosya okuma bütçesi doldu.") }
        // Walk descriptors with O_NOFOLLOW so a symlink swapped after validation is still refused.
        let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw OfflineError.workerFailure("Çalışma dizini güvenli açılamadı.") }
        var descriptor = rootFD
        defer { Darwin.close(descriptor) }
        let components = path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            let final = index == components.count - 1
            let next = Darwin.openat(descriptor, component, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (final ? 0 : O_DIRECTORY))
            guard next >= 0 else { throw OfflineError.invalidRequest("Dosya güvenli açılamadı; bağlantı veya erişim engeli olabilir.") }
            Darwin.close(descriptor)
            descriptor = next
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw OfflineError.invalidRequest("Yalnızca normal metin dosyaları okunabilir.")
        }
        let allowance = min(fileByteLimit, byteBudget - bytesRead)
        guard metadata.st_size >= 0, metadata.st_size <= allowance else { throw OfflineError.limitExceeded("Dosya, yerel okuma boyutu sınırını aşıyor.") }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(8_192, allowance + 1))
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, min($0.count, allowance + 1 - result.count)) }
            if count < 0 { throw OfflineError.workerFailure("Dosya okunamadı.") }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= allowance else { throw OfflineError.limitExceeded("Okuma sırasında dosya boyutu sınırı aşıldı.") }
        }
        reads += 1
        bytesRead += result.count
        return result
    }

    private func decodedText(_ data: Data, path: String) throws -> String {
        let binaryExtensions = Set(["pdf", "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "mov", "mp4", "mp3", "wav", "docx", "xlsx", "pptx"])
        guard !binaryExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else {
            throw OfflineError.invalidRequest("Görsel/PDF/ofis/ses dosyası metin gibi okunmadı; uygun model gerekir.")
        }
        guard !data.contains(0), let value = String(data: data, encoding: .utf8) else {
            throw OfflineError.invalidRequest("\(path): yalnızca UTF-8 metin destekleniyor; ikili ek sessizce atlanmadı.")
        }
        return try OfflineSecretRedactor.redact(value)
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func observation(content: String, metadata: [String: Any]) -> Observation {
        let encoded = (try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])) ?? Data("{}".utf8)
        return Observation(content: content, evidence: String(decoding: encoded, as: UTF8.self))
    }
}
