import AppKit
import Combine
import Security

/// Describes the GUI host, not a Codex subprocess or the separately installed
/// Desktop Companion. Reading this object never requests or changes permissions.
@MainActor final class CompanionAppIdentity: ObservableObject {
    enum SigningKind: Equatable {
        case certificate
        case adHoc
        case unsigned
        case unavailable
    }

    struct Snapshot {
        let bundleURL: URL
        let bundleIdentifier: String
        let version: String
        let build: String
        let processIdentifier: Int32
        let screenAccess: Bool
        let signingKind: SigningKind
        let signingIdentifier: String?

        var versionLabel: String { "v\(version) · \(build)" }
        var signatureLabel: String {
            switch signingKind {
            case .certificate: return "İmza: sertifikalı"
            case .adHoc: return "İmza: ad-hoc (geçici)"
            case .unsigned: return "İmza: yok"
            case .unavailable: return "İmza: doğrulanamadı"
            }
        }
        var permissionGuidance: String {
            let host = "Bu panel ayrı bir uygulama değil; izin yukarıdaki Bavbav uygulamasına aittir."
            switch signingKind {
            case .certificate:
                return host + " Ekran Kaydı ayarında bu dosyayı seç; macOS yeniden başlatma isterse Bavbav’ı kapatıp aç."
            case .adHoc:
                return host + " Bu derlemenin ad-hoc imzası güncellemelerde değişebilir; macOS eski izni kabul etmeyebilir."
            case .unsigned, .unavailable:
                return host + " İmza kimliği doğrulanamadığından ekran izninin güncellemelerde korunacağı garanti edilemez."
            }
        }
        var isApplicationBundle: Bool { bundleURL.pathExtension.lowercased() == "app" }
    }

    @Published private(set) var snapshot: Snapshot

    init() { snapshot = Self.readSnapshot() }

    func refresh() { snapshot = Self.readSnapshot() }

    /// This is a user-invoked Finder selection, not a permission grant or launch.
    func revealApplication() {
        guard snapshot.isApplicationBundle else { return }
        NSWorkspace.shared.activateFileViewerSelecting([snapshot.bundleURL])
    }

    private static func readSnapshot() -> Snapshot {
        let bundle = Bundle.main
        let signing = readSigningInformation()
        return Snapshot(bundleURL: bundle.bundleURL.standardizedFileURL,
                        bundleIdentifier: bundle.bundleIdentifier ?? "bilinmiyor",
                        version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                        build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
                        processIdentifier: ProcessInfo.processInfo.processIdentifier,
                        screenAccess: CGPreflightScreenCaptureAccess(),
                        signingKind: signing.0, signingIdentifier: signing.1)
    }

    private static func readSigningInformation() -> (SigningKind, String?) {
        var runningCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &runningCode) == errSecSuccess,
              let runningCode else { return (.unavailable, nil) }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(runningCode, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return (.unavailable, nil) }
        var dictionary: CFDictionary?
        let status = SecCodeCopySigningInformation(staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary)
        if status == errSecCSUnsigned { return (.unsigned, nil) }
        guard status == errSecSuccess, let information = dictionary as? [String: Any] else {
            return (.unavailable, nil)
        }
        guard let identifier = information[kSecCodeInfoIdentifier as String] as? String else {
            return (.unsigned, nil)
        }
        guard let flags = information[kSecCodeInfoFlags as String] as? NSNumber else {
            return (.unavailable, identifier)
        }
        if flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue != 0 {
            return (.adHoc, identifier)
        }
        let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate]
        return (certificates?.isEmpty == false ? .certificate : .unavailable, identifier)
    }
}
