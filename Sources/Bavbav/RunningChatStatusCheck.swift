import AppKit
import BavbavCore

@MainActor
enum RunningChatStatusCheck {
    static func run() -> Bool {
        let suite = "Bavbav.StatusCountCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OverlayStore(defaults: defaults)
        store.registerUserFacingThreads(["hidden-a", "hidden-b", "released"] + (0..<12).map { "many-\($0)" })
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        var presenter: RunningChatStatus? = RunningChatStatus(store: store, button: button)
        var checks = 0; var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) { checks += 1; if !condition { failures.append(label) } }
        func expectCount(_ count: Int, _ label: String) {
            expect(store.runningChatCount == count && button.image?.accessibilityDescription == String(count), label)
        }
        expectCount(0, "idle shows zero, never an icon")
        expect(button.title.isEmpty && button.imagePosition == .imageOnly, "number only without system-colored title")
        expect(button.image?.isTemplate == false && button.contentTintColor == nil,
               "system template tint cannot replace the focus-ring ink")
        store.handleServerEvent(.turnStarted(threadID: "hidden-a", turnID: "a1"))
        expectCount(1, "hidden chat counts without any open window")
        store.handleServerEvent(.turnStarted(threadID: "hidden-a", turnID: "a1"))
        expectCount(1, "duplicate events cannot double count")
        store.handleServerEvent(.turnStarted(threadID: "hidden-b", turnID: "b1"))
        expectCount(2, "simultaneous independent chats")
        store.registerUserFacingThreads(["third-root"])
        store.handleServerEvent(.turnStarted(threadID: "third-root", turnID: "r3"))
        for index in 0..<6 {
            store.handleServerEvent(.turnStarted(threadID: "child-\(index)", turnID: "child-turn-\(index)"))
        }
        expectCount(3, "three user chats plus six subagents count as three, not nine")
        store.handleServerEvent(.turnCompleted(threadID: "child-0", turnID: "child-turn-0", status: "completed", error: nil))
        expectCount(3, "subagent completion does not decrement main chats")
        store.handleServerEvent(.turnCompleted(threadID: "third-root", turnID: "r3", status: "completed", error: nil))
        expectCount(2, "parent completion is independent of remaining child work")
        store.handleServerEvent(.turnStarted(threadID: "late-catalog-root", turnID: "late"))
        expectCount(2, "unclassified server events cannot inflate the counter")
        store.registerUserFacingThreads(["late-catalog-root"])
        expectCount(3, "late catalog discovery reconciles an already-running user chat")
        store.handleServerEvent(.turnCompleted(threadID: "late-catalog-root", turnID: "late", status: "completed", error: nil))
        expectCount(2, "late-discovered root completes normally")
        store.clearCurrentDetail(threadID: "hidden-a")
        expectCount(2, "Q closing UI does not stop or discount background work")
        let request = CodexInteractionRequest(requestID: .string("ask-a"), threadID: "hidden-a", turnID: "a1", itemID: nil,
            kind: .commandApproval, title: "Fixture", summary: "", detail: "", options: [])
        store.handleServerEvent(.interactionRequested(request))
        expectCount(1, "awaiting user input is waiting, not working")
        store.handleServerEvent(.interactionResolved(requestID: .string("ask-a"), threadID: "hidden-a"))
        expectCount(2, "resumed chat returns immediately")
        store.handleServerEvent(.turnCompleted(threadID: "hidden-a", turnID: "old-turn", status: "completed", error: nil))
        expectCount(2, "stale completion cannot discount a newer running turn")
        store.handleServerEvent(.turnCompleted(threadID: "hidden-a", turnID: "a1", status: "completed", error: nil))
        expectCount(1, "completion decrements immediately")
        store.handleServerEvent(.turnCompleted(threadID: "hidden-a", turnID: "a1", status: "completed", error: nil))
        expectCount(1, "duplicate completion never makes count negative")
        for index in 0..<12 { store.handleServerEvent(.turnStarted(threadID: "many-\(index)", turnID: "t")) }
        expectCount(13, "multi-digit count")
        store.handleServerEvent(.transportClosed(message: "fixture disconnected"))
        expectCount(0, "transport loss clears stale working count")
        presenter = nil
        store.handleServerEvent(.turnStarted(threadID: "released", turnID: "t"))
        expect(button.image?.accessibilityDescription == "0", "presenter releases subscription")
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            button.appearance = NSAppearance(named: name)
            RunningChatStatus.apply(count: 12, to: button)
            expect(button.image?.accessibilityDescription == "12" && button.alternateImage === button.image,
                   "plain digits retained across appearances")
            for count in [0, 1, 12, 123] {
                RunningChatStatus.apply(count: count, to: button)
                var opaque = 0
                var wrongColor = 0
                var sample = ""
                button.effectiveAppearance.performAsCurrentDrawingAppearance {
                    guard let image = button.image,
                          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                            pixelsWide: Int(image.size.width * 2) + 8, pixelsHigh: 36,
                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                        wrongColor += 1
                        return
                    }
                    // Compare ink to a focus-ring swatch in the SAME output
                    // context, avoiding TIFF export/display-profile retagging.
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = context
                    image.draw(in: NSRect(x: 0, y: 0, width: image.size.width * 2, height: 36))
                    BavbavTheme.focusAccent.setFill()
                    NSRect(x: bitmap.pixelsWide - 8, y: 0, width: 8, height: 36).fill()
                    NSGraphicsContext.restoreGraphicsState()
                    guard let expected = bitmap.colorAt(x: bitmap.pixelsWide - 4, y: 18)?.usingColorSpace(.deviceRGB) else {
                        wrongColor += 1
                        return
                    }
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<(bitmap.pixelsWide - 8) {
                            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9 else { continue }
                            opaque += 1
                            if sample.isEmpty { sample = "\(color) expected \(expected)" }
                            if abs(color.redComponent - expected.redComponent) > 0.04
                                || abs(color.greenComponent - expected.greenComponent) > 0.04
                                || abs(color.blueComponent - expected.blueComponent) > 0.04 { wrongColor += 1 }
                        }
                    }
                    if count == 12, let data = bitmap.representation(using: .png, properties: [:]) {
                        let path = FileManager.default.temporaryDirectory.appendingPathComponent("bavbav-green-count-\(name.rawValue).png")
                        do {
                            try data.write(to: path)
                            print("STATUS COUNT UI ARTIFACT: \(path.path)")
                        } catch { wrongColor += 1 }
                    }
                }
                expect(opaque > 0 && wrongColor == 0, "actual digit pixels match focus green: \(name.rawValue), \(count); opaque=\(opaque), wrong=\(wrongColor), \(sample)")
                expect(button.image?.isTemplate == false && button.title.isEmpty, "colored digits never use system text tint")
            }
        }
        withExtendedLifetime(presenter) {}
        if failures.isEmpty { print("BAVBAV STATUS COUNT CHECK PASSED: \(checks) checks; lifecycle, background, waiting, duplicates and light/dark digit pixels") }
        else { failures.forEach { print("STATUS COUNT CHECK FAILED: \($0)") } }
        return failures.isEmpty
    }
}
