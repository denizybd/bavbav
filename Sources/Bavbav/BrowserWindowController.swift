import AppKit
import Combine
import SwiftUI
import WebKit

/// One policy for typed addresses, redirects, frames and new-window requests.
/// No URL handled here is sent to another application.
enum BrowserNavigationPolicy {
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              !url.absoluteString.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return false }
        return true
    }

    static func destination(for input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        if value.lowercased().hasPrefix("https:") || value.lowercased().hasPrefix("http:") {
            guard let url = URL(string: value), allows(url) else { return nil }
            return url
        }
        // A bare host (including local development ports) is an address. Check
        // this before the scheme test because localhost:8080 is not a scheme.
        if !value.contains(where: \.isWhitespace), !value.contains("@"),
           let components = URLComponents(string: "https://" + value),
           let host = components.host, host == "localhost" || host.contains(".") || host.contains(":"),
           let url = components.url, allows(url) {
            return url
        }
        if value.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil || value.contains("://") {
            return nil
        }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: value)]
        return search.url
    }
}

@MainActor
private final class BrowserPresentation: ObservableObject {
    @Published var hasPage = false
    @Published var loading = false
    @Published var progress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var title = "BAVBAV / WEB"
    @Published var error: String?
}

/// A bounded, application-owned browser. Closing the window drops the live
/// WebKit view; reopening creates a fresh view using only this browser's store.
@MainActor
final class BrowserWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate, WKNavigationDelegate, WKUIDelegate {
    static let identifier = "bavbav.browser"
    private static let dataStoreIdentifier = UUID(uuidString: "8E04DEB3-EBBF-42DF-886A-850E6B025BB8")!

    let window: NSWindow
    let preferences: AppPreferences
    private(set) var webView: WKWebView?
    private(set) var addressField: NSTextField?
    private let presentation = BrowserPresentation()
    private let ephemeral: Bool
    private var observations: [NSKeyValueObservation] = []
    private var appearanceSubscription: AnyCancellable?
    private var keyMonitor: Any?
    private var generation = UUID()
    private var lastURL: URL?
    private var consumedKeys = Set<UInt16>()
    private var editingKeys = Set<UInt16>()
    private var probingKeys = Set<UInt16>()
    private var deferredKeyUps: [UInt16: NSEvent] = [:]
    private var pendingShortcut: (stroke: ShortcutStroke, tap: ShortcutDefinition?, chords: [ShortcutDefinition])?

    init(preferences: AppPreferences, ephemeral: Bool = false) {
        self.preferences = preferences
        self.ephemeral = ephemeral
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 740),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Bavbav Browser"
        window.identifier = NSUserInterfaceItemIdentifier(Self.identifier)
        window.level = .normal
        window.minSize = NSSize(width: 560, height: 380)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        window.animationBehavior = .documentWindow
        PanelWindowAppearance.apply(to: window, opacity: preferences.backgroundOpacity)
        window.center()
    }

    func show(_ url: URL? = nil) {
        _ = prepare()
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let url { navigate(url) }
        else if !presentation.hasPage, let lastURL { navigate(lastURL) }
        else if !presentation.hasPage { focusAddress() }
    }

    func navigate(_ input: String) {
        guard let url = BrowserNavigationPolicy.destination(for: input) else {
            _ = prepare()
            presentation.error = "Enter an HTTP or HTTPS address, or a search."
            return
        }
        navigate(url)
    }

    private func navigate(_ url: URL) {
        guard BrowserNavigationPolicy.allows(url) else {
            presentation.error = "This address cannot be opened in Bavbav."
            return
        }
        let web = prepare()
        presentation.hasPage = true
        presentation.error = nil
        lastURL = url
        addressField?.stringValue = url.absoluteString
        window.makeFirstResponder(web)
        web.load(URLRequest(url: url))
    }

    /// Also used by the native diagnostic to load a local HTML document while
    /// the window stays hidden. Preparing alone never initiates a network load.
    @discardableResult
    func prepare() -> WKWebView {
        if let webView { return webView }
        generation = UUID()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = ephemeral ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: Self.dataStoreIdentifier)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        // No native script-message handlers or access to the ChatGPT store.
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.appearance = NSAppearance(named: .darkAqua)
        web.underPageBackgroundColor = NSColor(BavbavTheme.background)
        web.allowsBackForwardNavigationGestures = true
        web.allowsLinkPreview = false
        web.setAccessibilityIdentifier("browser.page")
        webView = web

        let field = NSTextField(string: "")
        field.placeholderString = "Search Google or enter address"
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.textColor = NSColor(BavbavTheme.text)
        field.backgroundColor = .clear
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingMiddle
        field.delegate = self
        field.target = self
        field.action = #selector(submitAddress(_:))
        field.setAccessibilityLabel("Search or enter address")
        field.setAccessibilityIdentifier("browser.address")
        addressField = field

        let container = CornerResizeContainer(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        container.setContent(NSHostingView(rootView: PanelAppearanceRoot(preferences: preferences,
            content: BrowserHostView(presentation: presentation, preferences: preferences, field: field, web: web,
                back: { [weak self] in self?.goBack() }, forward: { [weak self] in self?.goForward() },
                reload: { [weak self] in self?.reload() }))))
        window.contentView = container
        // KVO uses separate tokens because each observation has a different
        // value type. Install them with a shared, weak main-actor callback.
        observations.append(web.observe(\.url, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() })
        observations.append(web.observe(\.title, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() })
        observations.append(web.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() })
        observations.append(web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() })
        observations.append(web.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() })
        observations.append(web.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() })
        appearanceSubscription = preferences.$transparencyPercent.sink { [weak self] percent in
            guard let self else { return }
            PanelWindowAppearance.apply(to: self.window, opacity: 1 - percent / 100)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
        return web
    }

    nonisolated private func scheduleRefresh() {
        Task { @MainActor [weak self] in self?.refreshPresentation() }
    }

    private func refreshPresentation() {
        guard let web = webView else { return }
        presentation.loading = web.isLoading
        presentation.progress = web.estimatedProgress
        presentation.canGoBack = web.canGoBack
        presentation.canGoForward = web.canGoForward
        presentation.title = web.title.flatMap { $0.isEmpty ? nil : $0 } ?? "BAVBAV / WEB"
        window.title = web.title.flatMap { $0.isEmpty ? nil : "\($0) — Bavbav" } ?? "Bavbav Browser"
        if let url = web.url, BrowserNavigationPolicy.allows(url) {
            lastURL = url
            if !isAddressEditing { addressField?.stringValue = url.absoluteString }
        }
    }

    var isAddressEditing: Bool { addressField?.currentEditor() != nil }
    var hasKeyMonitor: Bool { keyMonitor != nil }
    var observationCount: Int { observations.count }

    func focusAddress() {
        guard let field = addressField else { return }
        window.makeFirstResponder(field)
        field.selectText(nil)
    }

    @objc private func submitAddress(_ sender: NSTextField) { navigate(sender.stringValue) }

    func reload() {
        presentation.error = nil
        if let webView, webView.url != nil { webView.reload() }
        else if let lastURL { navigate(lastURL) }
        else { focusAddress() }
    }

    func goBack() { if webView?.canGoBack == true { presentation.error = nil; webView?.goBack() } }
    func goForward() { if webView?.canGoForward == true { presentation.error = nil; webView?.goForward() } }

    /// The application router exempts this window. Resolve only browser-owned
    /// actions here so ordinary native selection, clipboard and page keys work.
    func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.windowNumber == window.windowNumber else { return event }
        if event.type == .keyUp {
            if probingKeys.contains(event.keyCode) {
                deferredKeyUps[event.keyCode] = event
                return nil
            }
            editingKeys.remove(event.keyCode)
            if let pending = pendingShortcut, pending.stroke.code == event.keyCode {
                pendingShortcut = nil
                if let tap = pending.tap { perform(tap.operation) }
            }
            return consumedKeys.remove(event.keyCode) != nil ? nil : event
        }
        guard event.type == .keyDown else { return event }
        let stroke = ShortcutStroke(event)
        let definitions = ShortcutCatalog.all.filter {
            ($0.scope == "browser.read" || $0.scope == "*read") && !preferences.keyBindings.binding($0).disabled
        }
        let candidates = definitions.filter { preferences.keyBindings.binding($0).strokes.first == stroke }
        let matchesPending = pendingShortcut?.chords.contains { preferences.keyBindings.binding($0).strokes.last == stroke } == true
        guard !candidates.isEmpty || matchesPending else { return event }
        if event.isARepeat {
            if editingKeys.contains(event.keyCode) { return event }
            return consumedKeys.contains(event.keyCode) ? nil : event
        }
        let readingOnly = candidates.contains { $0.scope == "*read" }
            || pendingShortcut?.chords.contains { $0.scope == "*read" && preferences.keyBindings.binding($0).strokes.last == stroke } == true
        if !stroke.strongModifier || readingOnly {
            if isAddressEditing || (window.firstResponder as? NSTextView)?.isEditable == true { return event }
            if hasWebFocus {
                let token = generation
                let responder = window.firstResponder
                consumedKeys.insert(event.keyCode)
                probingKeys.insert(event.keyCode)
                Task { @MainActor [weak self, weak responder] in
                    guard let self else { return }
                    let editing = await self.pageIsEditing()
                    guard self.generation == token, self.webView != nil else { return }
                    self.probingKeys.remove(event.keyCode)
                    let keyUp = self.deferredKeyUps.removeValue(forKey: event.keyCode)
                    if editing {
                        self.consumedKeys.remove(event.keyCode)
                        if keyUp == nil { self.editingKeys.insert(event.keyCode) }
                        if let responder, self.window.firstResponder === responder {
                            responder.keyDown(with: event)
                            if let keyUp { responder.keyUp(with: keyUp) }
                        }
                    } else {
                        self.dispatchShortcut(stroke, candidates: candidates)
                        if let keyUp { _ = self.handleKey(keyUp) }
                    }
                }
                return nil
            }
        }
        consumedKeys.insert(event.keyCode)
        dispatchShortcut(stroke, candidates: candidates)
        return nil
    }

    private func dispatchShortcut(_ stroke: ShortcutStroke, candidates: [ShortcutDefinition]) {
        if let pending = pendingShortcut,
           let chord = pending.chords.first(where: { preferences.keyBindings.binding($0).strokes.last == stroke }) {
            pendingShortcut = nil
            perform(chord.operation)
            return
        }
        pendingShortcut = nil
        let tap = candidates.first { preferences.keyBindings.binding($0).strokes.count == 1 }
        let chords = candidates.filter { preferences.keyBindings.binding($0).strokes.count == 2 }
        if !chords.isEmpty { pendingShortcut = (stroke, tap, chords) }
        else if let tap { perform(tap.operation) }
    }

    private func perform(_ operation: String) {
        switch operation {
        case "address": focusAddress()
        case "reload": reload()
        case "back": goBack()
        case "forward": goForward()
        case "close": window.close()
        case "focusUp": postDirection(.up)
        case "focusLeft": postDirection(.left)
        case "focusDown": postDirection(.down)
        case "focusRight": postDirection(.right)
        case "focusUpLeft": postDirection(.upLeft)
        case "focusUpRight": postDirection(.upRight)
        case "focusDownLeft": postDirection(.downLeft)
        case "focusDownRight": postDirection(.downRight)
        default: break
        }
    }

    private func postDirection(_ direction: WindowDirection) {
        NotificationCenter.default.post(name: Notification.Name("Bavbav.BrowserDirection"), object: direction)
    }

    private var hasWebFocus: Bool {
        guard let webView, let responder = window.firstResponder as? NSView else { return false }
        return responder === webView || responder.isDescendant(of: webView)
    }

    /// Read only a boolean about focused element types in an isolated WebKit
    /// world. Never read input values, page text, credentials or cookie data.
    /// Unknown/cross-origin frame focus conservatively preserves the key.
    func pageIsEditing() async -> Bool {
        guard let webView else { return false }
        let result = try? await webView.callAsyncJavaScript(Self.editableFocusScript, arguments: [:], in: nil, contentWorld: .defaultClient)
        return result as? Bool ?? true
    }

    private static let editableFocusScript = """
    let root = document;
    for (let depth = 0; depth < 16; depth++) {
      const element = root.activeElement;
      if (!element) return false;
      if (element.isContentEditable || element.matches('input, textarea, select, [role="textbox"], [role="searchbox"], [role="combobox"]')) return true;
      if (element.shadowRoot) { root = element.shadowRoot; continue; }
      if (element.tagName === 'IFRAME' || element.tagName === 'FRAME') {
        try { if (element.contentDocument) { root = element.contentDocument; continue; } } catch (_) {}
        return true;
      }
      return false;
    }
    return true;
    """

    func windowWillClose(_ notification: Notification) { releasePage() }
    func shutdown() { window.close(); releasePage() }

    private func releasePage() {
        generation = UUID()
        pendingShortcut = nil
        consumedKeys.removeAll()
        editingKeys.removeAll()
        probingKeys.removeAll()
        deferredKeyUps.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        observations.removeAll()
        appearanceSubscription = nil
        if let web = webView {
            web.stopLoading()
            web.setMicrophoneCaptureState(.none, completionHandler: nil)
            web.setCameraCaptureState(.none, completionHandler: nil)
            web.pauseAllMediaPlayback(completionHandler: nil)
            web.navigationDelegate = nil
            web.uiDelegate = nil
            web.removeFromSuperview()
        }
        window.contentView = nil
        webView = nil
        addressField = nil
        presentation.hasPage = false
        presentation.loading = false
        presentation.error = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, BrowserNavigationPolicy.allows(url), !action.shouldPerformDownload else {
            presentation.error = "This link or download cannot be opened in Bavbav."
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let url = response.response.url, BrowserNavigationPolicy.allows(url), response.canShowMIMEType else {
            presentation.error = "This response cannot be displayed in Bavbav."
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url, BrowserNavigationPolicy.allows(url),
           action.navigationType == .linkActivated, !action.shouldPerformDownload {
            // A user-clicked target=_blank stays in this bounded native window.
            navigate(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        presentation.error = "Camera and microphone access are disabled in this browser."
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        presentation.hasPage = true
        presentation.error = nil
        refreshPresentation()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { refreshPresentation() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        presentation.loading = false
        presentation.error = "The page stopped. Reload to continue."
    }
    private func report(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        presentation.loading = false
        presentation.error = "Could not load this page: \(error.localizedDescription)"
    }
}

private struct BrowserAddressView: NSViewRepresentable {
    let field: NSTextField
    func makeNSView(context: Context) -> NSTextField { field }
    func updateNSView(_ view: NSTextField, context: Context) {}
}

private struct BrowserPageView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

private struct BrowserHostView: View {
    @ObservedObject var presentation: BrowserPresentation
    @ObservedObject var preferences: AppPreferences
    let field: NSTextField
    let web: WKWebView
    let back: () -> Void
    let forward: () -> Void
    let reload: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                control("chevron.left", "Back", "back", enabled: presentation.canGoBack, action: back)
                control("chevron.right", "Forward", "forward", enabled: presentation.canGoForward, action: forward)
                control("arrow.clockwise", "Reload", "reload", action: reload)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(BavbavTheme.muted)
                    BrowserAddressView(field: field).frame(minWidth: 160, maxWidth: .infinity, minHeight: 21)
                }.padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(BavbavTheme.raised).panelBackdrop())
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(BavbavTheme.border))
            }.padding(.horizontal, 14).padding(.vertical, 10)
                .background(BavbavTheme.surface.panelBackdrop())
            ZStack(alignment: .leading) {
                Rectangle().fill(BavbavTheme.border).frame(height: 1)
                if presentation.loading {
                    GeometryReader { proxy in
                        Rectangle().fill(BavbavTheme.accent).frame(width: proxy.size.width * max(0.03, presentation.progress), height: 1)
                    }.frame(height: 1)
                }
            }.frame(height: 1)
            if let error = presentation.error {
                Text(error).font(.system(size: 11)).foregroundStyle(BavbavTheme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(BavbavTheme.surface.panelBackdrop()).accessibilityIdentifier("browser.status")
            }
            ZStack {
                BrowserPageView(web: web).opacity(presentation.hasPage ? 1 : 0)
                if !presentation.hasPage {
                    VStack(spacing: 16) {
                        Image(systemName: "globe").font(.system(size: 34, weight: .light)).foregroundStyle(BavbavTheme.accent)
                        Text("Bavbav Browser").font(.system(size: 23, weight: .medium)).foregroundStyle(BavbavTheme.text)
                        Text("Search or enter an address above.").font(.system(size: 13)).foregroundStyle(BavbavTheme.muted)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(BavbavTheme.background.panelBackdrop())
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(presentation.title).lineLimit(1)
                Spacer()
                Text("\(preferences.keyBindings.label("browser.read.address.key")) ADDRESS   \(preferences.keyBindings.label("browser.read.close.key")) CLOSE")
            }.font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(BavbavTheme.muted).padding(.horizontal, 14).padding(.vertical, 7)
                .background(BavbavTheme.surface.panelBackdrop())
        }.frame(minWidth: 520, minHeight: 300)
    }

    private func control(_ symbol: String, _ label: String, _ operation: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? BavbavTheme.text : BavbavTheme.muted.opacity(0.45))
                .frame(width: 20, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled)
            .help("\(label) · \(preferences.keyBindings.label("browser.read.\(operation).key"))")
            .accessibilityLabel(label).accessibilityIdentifier("browser.\(operation)")
    }
}
