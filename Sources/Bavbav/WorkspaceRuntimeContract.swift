import Foundation

/// Public, dependency-free preflight for the separately supplied private runtime.
/// This validates package shape/version, not pairing, network reachability, TCC,
/// code signatures or a physical Thunderbolt connection. It never starts Node.
enum WorkspaceRuntimeContract {
    static let minimumEngineVersion = "0.7.3"
    static let requiredRelativePaths = [
        "runtime/node",
        "engine/package.json",
        "engine/src/ui-client.mjs",
        "engine/src/engine-service.mjs",
        "engine/src/engine-version.mjs",
        "engine/src/native-bridge.mjs",
        "engine/src/thunderbolt.mjs",
        "engine/src/peer.mjs",
        "engine/src/account-chat.mjs",
        "app-version.json"
    ]

    struct Validation {
        let resourcesURL: URL
        let engineVersion: String
        let hostVersion: String
        let hostBuild: Int
    }

    enum Failure: LocalizedError {
        case invalidResource(String)
        case invalidMetadata(String)
        case obsoleteEngine(String)
        case hostMismatch(String)

        var errorDescription: String? {
            let detail: String
            switch self {
            case .invalidResource(let value): detail = "Eksik veya geçersiz kaynak: \(value)."
            case .invalidMetadata(let value): detail = "Geçersiz Workspace sürüm kaydı: \(value)."
            case .obsoleteEngine(let value):
                detail = "Workspace motoru \(value) eski; en az \(WorkspaceRuntimeContract.minimumEngineVersion) gerekli."
            case .hostMismatch(let value): detail = "Workspace ve Bavbav paket sürümleri uyuşmuyor: \(value)."
            }
            return "\(detail) Güncel ve tam Bavbav paketini yeniden kurun. Eşleştirme ve proje kayıtlarınız değiştirilmedi."
        }
    }

    static func validate(resourcesURL: URL, expectedHostVersion: String? = nil,
                         expectedHostBuild: Int? = nil) throws -> Validation {
        guard resourcesURL.isFileURL else { throw Failure.invalidResource("dosya URL'si gerekli") }
        // Inspect the supplied root itself: canonicalizing first could hide a symlink.
        let root = resourcesURL
        let manager = FileManager.default
        let rootAttributes = try attributes(root, manager: manager)
        guard rootAttributes[.type] as? FileAttributeType == .typeDirectory else {
            throw Failure.invalidResource("IkiWorkspace klasörü normal bir klasör olmalı; sembolik bağlantı kullanılamaz")
        }
        for relative in requiredRelativePaths {
            let maximum: UInt64
            switch relative {
            case "runtime/node": maximum = 256 * 1_024 * 1_024
            case "engine/package.json": maximum = 65_536
            case "app-version.json": maximum = 32_768
            default: maximum = 2 * 1_024 * 1_024
            }
            let file = try regularResource(relative, root: root, maximumSize: maximum, manager: manager)
            if relative == "runtime/node" {
                let permissions = (file.attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
                guard permissions & 0o111 != 0, manager.isExecutableFile(atPath: file.url.path) else {
                    throw Failure.invalidResource("runtime/node çalıştırılabilir değil")
                }
            }
        }

        let package = try jsonObject(root.appendingPathComponent("engine/package.json"), maximumSize: 65_536)
        guard let engineVersion = package["version"] as? String,
              let engine = versionComponents(engineVersion),
              let minimum = versionComponents(minimumEngineVersion) else {
            throw Failure.invalidMetadata("engine/package.json version alanı")
        }
        guard !engine.lexicographicallyPrecedes(minimum) else { throw Failure.obsoleteEngine(engineVersion) }

        let metadata = try jsonObject(root.appendingPathComponent("app-version.json"), maximumSize: 32_768)
        guard let hostVersion = metadata["version"] as? String, versionComponents(hostVersion) != nil,
              let number = metadata["build"] as? NSNumber,
              String(cString: number.objCType) != "c", // JSON true is not a build number.
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue > 0, number.doubleValue <= 2_147_483_647 else {
            throw Failure.invalidMetadata("app-version.json version/build alanları")
        }
        let hostBuild = number.intValue
        if let expectedHostVersion {
            guard versionComponents(expectedHostVersion) != nil else { throw Failure.invalidMetadata("Bavbav sürümü") }
            guard hostVersion == expectedHostVersion else {
                throw Failure.hostMismatch("\(hostVersion) yerine \(expectedHostVersion) bekleniyor")
            }
        }
        if let expectedHostBuild {
            guard expectedHostBuild > 0 else { throw Failure.invalidMetadata("Bavbav derleme numarası") }
            guard hostBuild == expectedHostBuild else {
                throw Failure.hostMismatch("derleme \(hostBuild) yerine \(expectedHostBuild) bekleniyor")
            }
        }
        return Validation(resourcesURL: root, engineVersion: engineVersion, hostVersion: hostVersion, hostBuild: hostBuild)
    }

    private static func attributes(_ url: URL, manager: FileManager) throws -> [FileAttributeKey: Any] {
        do { return try manager.attributesOfItem(atPath: url.path) }
        catch { throw Failure.invalidResource(url.lastPathComponent) }
    }

    private static func regularResource(_ relative: String, root: URL, maximumSize: UInt64,
                                        manager: FileManager) throws -> (url: URL, attributes: [FileAttributeKey: Any]) {
        let components = relative.split(separator: "/").map(String.init)
        var current = root
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component)
            let value = try attributes(current, manager: manager)
            if index < components.count - 1 {
                guard value[.type] as? FileAttributeType == .typeDirectory else {
                    throw Failure.invalidResource("\(relative) yolunda normal olmayan klasör")
                }
            } else {
                guard value[.type] as? FileAttributeType == .typeRegular,
                      let size = (value[.size] as? NSNumber)?.uint64Value, size > 0, size <= maximumSize else {
                    throw Failure.invalidResource("\(relative) normal, boş olmayan ve boyutu sınırlı bir dosya olmalı")
                }
                return (current, value)
            }
        }
        throw Failure.invalidResource(relative)
    }

    private static func jsonObject(_ url: URL, maximumSize: Int) throws -> [String: Any] {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            // Bound the read as well as the preceding stat; do not load an arbitrarily growing file.
            let bytes = try handle.read(upToCount: maximumSize + 1) ?? Data()
            guard !bytes.isEmpty, bytes.count <= maximumSize,
                  let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw Failure.invalidMetadata(url.lastPathComponent)
            }
            return object
        } catch let error as Failure { throw error }
        catch { throw Failure.invalidMetadata(url.lastPathComponent) }
    }

    /// Stable numeric triples only; prerelease labels cannot accidentally pass a release gate.
    private static func versionComponents(_ value: String) -> [Int]? {
        guard value.utf8.count <= 32 else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  part.count == 1 || part.first != "0", let number = Int(part), number <= 1_000_000 else { return nil }
            result.append(number)
        }
        return result
    }
}
