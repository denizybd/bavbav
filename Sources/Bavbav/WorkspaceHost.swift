import AppKit
#if BAVBAV_WITH_WORKSPACE && canImport(IkiWorkspaceKit)
import IkiWorkspaceKit

/// The Workspace UI is linked into Bavbav. Only its private stdio engine is a
/// child process; no second application, menu bar or application delegate exists.
@MainActor
final class WorkspaceHost {
    static let isAvailable = true
    static let windowIdentifier = "bavbav.workspace"
    private(set) var controller: IkiWorkspaceWindowController?
    private let makeController: () throws -> IkiWorkspaceWindowController

    init(makeController: (() throws -> IkiWorkspaceWindowController)? = nil) {
        self.makeController = makeController ?? {
            IkiWorkspaceWindowController(resourcesURL: try Self.resourcesURL())
        }
    }

    static func resourcesURL() throws -> URL {
        guard let resources = Bundle.main.resourceURL else {
            throw NSError(domain: "Bavbav.Workspace", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Bavbav kaynakları bulunamadı."])
        }
        let root = resources.appendingPathComponent("IkiWorkspace", isDirectory: true)
        let required = ["runtime/node", "engine/src/native-bridge.mjs", "app-version.json"]
        guard required.allSatisfy({ FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }) else {
            throw NSError(domain: "Bavbav.Workspace", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Workspace bileşenleri eksik. Tam Bavbav paketini yeniden kurun; eşleştirme ve proje kayıtlarınız korunur."])
        }
        return root
    }

    var isVisible: Bool {
        NSApp.windows.contains { $0.identifier?.rawValue == Self.windowIdentifier && $0.isVisible }
    }

    func prepare() throws -> IkiWorkspaceWindowController {
        if let controller { return controller }
        let result = try makeController()
        controller = result
        return result
    }

    /// Conversation-channel operations only; never expose the Workspace's general RPC surface.
    func accountRequest(_ method: String, args: [String: Any] = [:]) async throws -> [String: Any] {
        let allowed: Set<String> = ["accountState", "accountHeartbeat", "accountSend", "accountTake", "accountReply", "accountPoll", "accountCancel"]
        guard allowed.contains(method) else {
            throw NSError(domain: "Bavbav.AccountChat", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Hesap sohbeti işlemi geçersiz."])
        }
        return try await prepare().accountRequest(method, args: args)
    }

    func show() {
        do { try prepare().show() }
        catch {
            let alert = NSAlert()
            alert.messageText = "Workspace açılamadı"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    func prepareIfConfigured() {
        let configURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IkiWorkspace/config.json")
        guard let metadata = try? configURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              metadata.isRegularFile == true, let size = metadata.fileSize, size <= 32_768,
              let data = try? Data(contentsOf: configURL),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let members = config["members"] as? [String: Any],
              members["deniz"] != nil, members["emir"] != nil else { return }
        do { try prepare().start() }
        catch { NSLog("[Bavbav] Workspace startup failed: %@", error.localizedDescription) }
    }

    func shutdown() async {
        await controller?.shutdown()
        controller = nil
    }
}
#else
/// Public-source builds deliberately omit the separately distributed private component.
@MainActor
final class WorkspaceHost {
    static let isAvailable = false
    static let windowIdentifier = "bavbav.workspace"
    var controller: AnyObject? { nil }
    var isVisible: Bool { false }

    func show() {
        let alert = NSAlert()
        alert.messageText = "Workspace bu derlemede bulunmuyor"
        alert.informativeText = "Bu, Bavbav'ın herkese açık kaynak derlemesidir. Deniz ve Emir Workspace bileşeni ayrı, özel kaynaklar gerektirir. Mevcut eşleştirme ve proje kayıtları değiştirilmedi."
        alert.runModal()
    }

    func prepareIfConfigured() { }
    func accountRequest(_ method: String, args: [String: Any] = [:]) async throws -> [String: Any] {
        throw NSError(domain: "Bavbav.AccountChat", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Deniz/Emir hesap paylaşımı bu derlemede bulunmuyor. Yerel AI seçeneği hesap veya Workspace bağlantısı gerektirmez."])
    }
    func shutdown() async { }
}
#endif
