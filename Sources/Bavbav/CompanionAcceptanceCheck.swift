import AppKit
import AVFoundation
import BavbavCompanion
import Speech

/// Opt-in real-account acceptance. No private window is ever selected here: the
/// image test owns a synthetic NSWindow and resolves that exact PID/window ID.
@MainActor enum CompanionAcceptanceCheck {
    static func printPreflight() {
        let speech = CompanionSpeech()
        let report: [String: Any] = [
            "microphoneAuthorization": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
            "speechAuthorization": SFSpeechRecognizer.authorizationStatus().rawValue,
            "speechPreflight": speech.permissionSummary,
            "turkishOnDeviceAvailable": speech.supportsLocalTurkish,
            "turkishVoiceAvailable": speech.hasTurkishVoice,
            "screenPermission": CGPreflightScreenCaptureAccess(),
            "permissionsRequested": false,
            "microphoneOpened": false,
            "captureAttempted": false
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            print("COMPANION PREFLIGHT: \(String(decoding: data, as: UTF8.self))")
        }
    }

    static func run() async -> Bool {
        guard ProcessInfo.processInfo.environment["BAVBAV_CODEX_BIN"] == nil else {
            print("COMPANION LIVE: refused executable override; fixture is not live evidence"); return false
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bavbav-companion-acceptance-\(UUID())")
        let conversation = CodexCompanionConversation(directory: folder, ephemeral: true)
        let speech = CompanionSpeech()
        var report: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()),
            "accountMessage": "unverified", "selectedWindowToModel": "unverified",
            "turkishMicrophoneRecognition": "unverified: requires spoken user phrase",
            "audibleTurkishResponse": "unverified: requires listening on this Mac",
            "speechPreflight": speech.permissionSummary,
            "screenPermission": CGPreflightScreenCaptureAccess(),
            "nativeChatGPTVoice": "unverified: visible web session is a separate route"]
        var verification = CompanionVerification()
        do {
            _ = try await conversation.connect()
            let reply = try await conversation.send(text: "Bu bir bağlantı testi. Hiçbir araç kullanmadan yalnızca MERHABA BAVBAV yaz.", image: nil)
            guard reply.uppercased().contains("MERHABA BAVBAV") else { throw CompanionFailure("Gerçek hesap beklenen test yanıtını vermedi: \(reply)") }
            report["accountMessage"] = "passed: MERHABA BAVBAV received from authenticated inference"
            verification.accountMessage = true
            if CGPreflightScreenCaptureAccess() {
                let marker = String(Int.random(in: 100000...999999))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 340),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.title = "Bavbav · Companion görüntü doğrulaması"
                let label = NSTextField(labelWithString: "PENCERE TESTİ\n\n\(marker)")
                label.font = .monospacedSystemFont(ofSize: 42, weight: .bold)
                label.alignment = .center; label.textColor = .black
                label.frame = NSRect(x: 20, y: 55, width: 560, height: 230)
                window.backgroundColor = .white; window.contentView?.addSubview(label)
                window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                defer { window.close() }
                try await Task.sleep(nanoseconds: 350_000_000)
                let source = SelectedWindowSource()
                guard let choice = try await source.windows().first(where: {
                    $0.id == UInt32(window.windowNumber) && $0.pid == ProcessInfo.processInfo.processIdentifier
                }) else { throw CompanionFailure("Doğrulama penceresi listede yok; başka pencere seçilmedi.") }
                let png = try await source.capture(choice)
                let image = folder.appendingPathComponent(UUID().uuidString + ".png")
                try png.write(to: image, options: .atomic)
                // The random answer is present ONLY in the actual captured pixels.
                let answer = try await conversation.send(text: "Bu görseldeki altı basamaklı sayıyı söyle. Araç kullanma; yalnızca görüntüye bak.", image: image)
                verification.selectedWindowToModel = answer.contains(marker)
                report["selectedWindowToModel"] = verification.selectedWindowToModel
                    ? "passed: random six-digit marker identified from the captured selected window"
                    : "failed: model did not identify the random image-only marker"
                report["capturedPNG"] = image.path
            } else {
                report["selectedWindowToModel"] = "blocked: macOS Screen Recording permission not granted; no capture attempted"
            }
        } catch { report["error"] = error.localizedDescription }
        await conversation.stop()
        report["automatedGatesPassed"] = verification.automatedGatesPassed
        report["productComplete"] = verification.productComplete
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            let path = folder.appendingPathComponent("report.json")
            try? data.write(to: path, options: .atomic)
            print(String(decoding: data, as: UTF8.self)); print("COMPANION LIVE REPORT: \(path.path)")
        }
        // This command tests account + image, not live microphone/listening.
        // A blocked or failed image test must produce a nonzero exit status.
        return verification.automatedGatesPassed
    }
}
