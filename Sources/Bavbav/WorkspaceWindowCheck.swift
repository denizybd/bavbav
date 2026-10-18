import AppKit
#if canImport(IkiWorkspaceKit)
import IkiWorkspaceKit

/// Native AppKit diagnostic owned by Bavbav. It uses a UUID data directory,
/// offline engine and synthetic local events, never the paired user store.
@MainActor
enum WorkspaceWindowCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func run() async -> Bool {
        let suite = "Bavbav.WorkspaceCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let originalMenu = NSApp.mainMenu
        let originalWindowsMenu = NSApp.windowsMenu
        let baseline = Set(NSApp.windows.map(ObjectIdentifier.init))
        var report: [String: Any] = ["success": false, "renderKind": "app-owned-native-view",
                                    "physicalUserInteraction": false, "productionDataUsed": false,
                                    "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                                    "hostPID": Int(ProcessInfo.processInfo.processIdentifier)]
        var assertions = 0
        let host = WorkspaceHost(makeController: {
            IkiWorkspaceWindowController(resourcesURL: try WorkspaceHost.resourcesURL(),
                                         dataURL: directory.appendingPathComponent("workspace", isDirectory: true),
                                         offline: true)
        })
        defer {
            defaults.removePersistentDomain(forName: suite)
            NSApp.mainMenu = originalMenu
            NSApp.windowsMenu = originalWindowsMenu
            for window in NSApp.windows where !baseline.contains(ObjectIdentifier(window)) { window.orderOut(nil) }
            try? FileManager.default.removeItem(at: directory)
        }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            if !condition() { throw Failure(message) }
        }
        func argument(_ name: String) -> String? {
            guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
            return CommandLine.arguments[index + 1]
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try check(HotKeyCenter.configuration([:])[7] == .init(26, .command), "global Command 7 maps to Workspace")
            let store = OverlayStore(defaults: defaults, standaloneDirectory: directory.appendingPathComponent("chats"))
            let panels = PanelCoordinator(store: store, windowSizeDefaults: defaults)
            let router = InputRouter(store: store, coordinator: panels, presentWorkspace: { host.show() })
            defer { router.cancelPendingPress() }
            let controller = try host.prepare()
            try check(!host.isVisible, "preparation keeps the native window hidden")
            let source = panels.appSettings.window
            func key(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command, timestamp: 0,
                                windowNumber: source.windowNumber, context: nil, characters: "7",
                                charactersIgnoringModifiers: "7", isARepeat: false, keyCode: 26)!
            }
            try check(router.handle(key(.keyDown)) == nil, "local Command 7 dispatches")
            _ = router.handle(key(.keyUp))
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == WorkspaceHost.windowIdentifier }) else {
                throw Failure("linked Workspace window missing from Bavbav's NSApplication")
            }
            for _ in 0..<200 {
                if controller.backendReady || controller.backendFailureDescription != nil { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            try check(controller.backendReady, "isolated native engine ready: \(controller.backendFailureDescription ?? "timeout")")
            try check(window.isVisible && window.canBecomeKey, "Bavbav owns a visible native Workspace window")
            try check(window.level == .normal, "Workspace participates in normal window stacking")
            host.show()
            try check(NSApp.windows.filter { $0.identifier?.rawValue == WorkspaceHost.windowIdentifier }.count == 1,
                      "repeated Command 7 reuses one window")
            let plainQ = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "q", charactersIgnoringModifiers: "q",
                isARepeat: false, keyCode: 12)!
            try check(router.handle(plainQ) === plainQ, "Workspace text input bypasses coding panel shortcuts")
            ApplicationMenu.install(bindings: panels.appPreferences.keyBindings)
            let menuItem = NSApp.windowsMenu?.items.first { $0.representedObject as? String == "*.workspace.key" }
            try check(menuItem?.keyEquivalent == "7" && menuItem?.keyEquivalentModifierMask == [.command],
                      "native Window menu exposes Command 7")
            try check(menuItem?.action == #selector(BavbavAppDelegate.showWorkspace(_:)), "menu targets the embedded host")
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 300_000_000)
            report["backendReady"] = controller.backendReady
            report["windowIdentifier"] = window.identifier?.rawValue
            report["windowVisible"] = window.isVisible
            report["windowWidth"] = Double(window.frame.width)
            report["windowHeight"] = Double(window.frame.height)
            report["workspaceWindowCount"] = NSApp.windows.filter { $0.identifier?.rawValue == WorkspaceHost.windowIdentifier }.count
            if let render = argument("--workspace-render"), let view = window.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let bytes = bitmap.representation(using: .png, properties: [:]) {
                    try bytes.write(to: URL(fileURLWithPath: render), options: .atomic)
                    report["renderWritten"] = !bytes.isEmpty
                }
            }
            window.close()
            try check(!window.isVisible && controller.backendReady, "closing the window keeps peer engine alive")
            host.show()
            try check(window.isVisible, "Command 7 reopens the same window")
            await host.shutdown()
            try check(!controller.backendReady, "Bavbav shutdown stops its peer engine")
            report["success"] = true
            print("BAVBAV WORKSPACE CHECK PASSED: \(assertions) assertions; native window in Bavbav, isolated offline store")
        } catch {
            report["error"] = error.localizedDescription
            await host.shutdown()
            print("BAVBAV WORKSPACE CHECK FAILED: \(error.localizedDescription)")
        }
        report["assertions"] = assertions
        if let output = argument("--workspace-report"), let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        return report["success"] as? Bool == true
    }
}

#else
@MainActor
enum WorkspaceWindowCheck {
    static func run() async -> Bool {
        print("BAVBAV WORKSPACE CHECK UNAVAILABLE: this build does not include the private module")
        return false
    }
}
#endif
