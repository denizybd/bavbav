import AppKit
#if canImport(IkiWorkspaceKit)
import IkiWorkspaceKit

/// The Workspace UI is linked into Bavbav. Only its private stdio engine is a
/// child process; no second application, menu bar or application delegate exists.
@MainActor
final class WorkspaceHost {
    static let windowIdentifier = "bavbav.workspace"
    var hasController: Bool { controller != nil }
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
/// Public builds do not start or read the private Workspace engine.
@MainActor
final class WorkspaceHost {
    var hasController: Bool { false }
    var isVisible: Bool { false }
    func prepareIfConfigured() {}
    func shutdown() async {}
    func show() {
        let alert = NSAlert()
        alert.messageText = "Workspace is not included in this build"
        alert.informativeText = "Bavbav Workspace is available in authorized builds with the private collaboration module."
        alert.runModal()
    }
}
#endif
