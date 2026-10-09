import AppKit
import SwiftUI
import WebKit
import BavbavCompanion

@MainActor final class CompanionWindowController: NSObject, NSWindowDelegate {
    let session: CompanionSession
    let window: NSWindow
    private let webSession: ChatGPTWebSession
    init(webSession: ChatGPTWebSession) {
        self.webSession = webSession
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bavbav/Companion", isDirectory: true)
        session = CompanionSession(conversation: CodexCompanionConversation(directory: directory),
                                   screen: SelectedWindowSource(), directory: directory)
        window = CompanionWindow(contentRect: NSRect(x: 0, y: 0, width: 670, height: 810),
                                 styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Bavbav · Companion"
        window.identifier = NSUserInterfaceItemIdentifier("bavbav.companion")
        window.level = .normal; window.minSize = NSSize(width: 560, height: 520)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: CompanionHostView(session: session, webSession: webSession))
        let previousClose = webSession.onClose
        webSession.onClose = { [weak self, weak webSession] in
            if let self, webSession?.webView?.window === self.window { self.window.performClose(nil) }
            else { previousClose?() }
        }
        window.center()
    }
    func show() {
        NSApp.unhide(nil); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        webSession.companionVoiceVisible = webSession.webView?.window === window
    }
    func exportPreview() {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("bavbav-companion-panel-\(UUID()).png")
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: path) }
        print("COMPANION PANEL: visible=\(window.isVisible) key=\(window.isKeyWindow) level=\(window.level.rawValue) pid=\(ProcessInfo.processInfo.processIdentifier)")
        print("COMPANION PANEL PREVIEW: \(path.path)")
        print("COMPANION PREFLIGHT: \(session.speech.permissionSummary) screen=\(CGPreflightScreenCaptureAccess())")
        fflush(stdout)
    }
    func verifyVisibleWebRoute() async {
        // Observe only capability/control presence in the visible session.
        // Never inspect auth storage, cookies, conversation bodies or tokens.
        let original = window.contentView
        let web = webSession.prepare()
        session.stop(); window.contentView = web
        webSession.companionVoiceVisible = true; webSession.open()
        defer {
            webSession.stopCompanionMedia(); window.contentView = original
            DispatchQueue.main.async { [weak self] in self?.exportPreview() }
        }
        for _ in 0..<100 {
            if web.url != nil, !web.isLoading { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        var report: [String: Any] = ["host": web.url?.host ?? "none", "loading": web.isLoading,
                                   "visible": window.isVisible, "nativeVoiceCall": "unverified: no microphone/audio call started"]
        if let error = webSession.error { report["navigationError"] = error }
        if web.url?.host == "chatgpt.com", !web.isLoading {
            let script = """
            ({secureContext: window.isSecureContext,
              getUserMediaAvailable: typeof navigator.mediaDevices?.getUserMedia === 'function',
              composerPresent: !!document.querySelector('#prompt-textarea'),
              voiceControlPresent: !!document.querySelector('[data-testid="voice-mode-button"], button[aria-label="Start voice mode"], button[aria-label="Start voice chat"]'),
              loginControlPresent: !!document.querySelector('[data-testid="login-button"]')})
            """
            if let value = try? await web.evaluateJavaScript(script) as? [String: Any] { report["visiblePageProbe"] = value }
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("bavbav-companion-web-\(UUID()).json")
            try? data.write(to: path)
            print("COMPANION WEB PROBE: \(String(decoding: data, as: UTF8.self))")
            print("COMPANION WEB REPORT: \(path.path)"); fflush(stdout)
        }
    }
    func windowWillClose(_ notification: Notification) { stop() }
    func stop() {
        session.stop()
        webSession.stopCompanionMedia()
    }
}

private final class CompanionWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "q", event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           (firstResponder as? NSTextView)?.isEditable != true {
            performClose(nil); return
        }
        super.keyDown(with: event)
    }
}

private struct CompanionHostView: View {
    @ObservedObject var session: CompanionSession
    @ObservedObject var webSession: ChatGPTWebSession
    @State private var web = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                routeButton("Bavbav · Mac sesi", useWeb: false)
                routeButton("ChatGPT web · doğrulama", useWeb: true)
            }.padding(12).background(Color(red: 0.045, green: 0.055, blue: 0.06))
            if web {
                HStack {
                    Text("Görünür mevcut web oturumu. Voice kullanılabilirliği ve giriş ayrıca doğrulanmalı.")
                        .font(.caption)
                    Button("Sesi durdur") { webSession.stopCompanionMedia() }
                    Button("Yenile") { webSession.retry() }
                }.padding(10)
                CompanionWebView(web: webSession.prepare())
            } else { CompanionPanelView(session: session) }
        }
        .preferredColorScheme(.dark)
        .onChange(of: web) { value in
            if value { session.stop(); webSession.companionVoiceVisible = true; webSession.open() }
            else { webSession.stopCompanionMedia() }
        }
    }
    private func routeButton(_ title: String, useWeb: Bool) -> some View {
        Button { web = useWeb } label: {
            Text(title).font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(web == useWeb ? Color.mint : Color.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(web == useWeb ? Color.mint.opacity(0.10) : Color.white.opacity(0.03),
                            in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(web == useWeb ? Color.mint.opacity(0.4) : Color.clear))
        }.buttonStyle(.plain)
    }
}

private struct CompanionWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
