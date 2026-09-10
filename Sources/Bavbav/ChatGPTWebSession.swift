import AppKit
import Combine
import SwiftUI
import WebKit

struct ChatGPTConversationLink: Codable, Equatable, Identifiable {
    let id: String
    let title: String

    var url: URL { URL(string: "https://chatgpt.com/c/\(id)")! }

    static func from(url: URL, title: String) -> Self? {
        guard url.scheme == "https", url.host == "chatgpt.com",
              url.query == nil, url.fragment == nil else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "c", UUID(uuidString: String(parts[1])) != nil else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Self(id: String(parts[1]), title: String(trimmed.prefix(160)))
    }
}

/// A user-visible ChatGPT website session. No Codex credentials, private API,
/// Safari cookies, or desktop automation are used to access Chat history.
@MainActor
final class ChatGPTWebSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    @Published private(set) var recents: [ChatGPTConversationLink] = []
    @Published private(set) var status = "CHATGPT"
    @Published private(set) var error: String?
    private(set) var webView: WKWebView?
    var onRecentsChanged: (([ChatGPTConversationLink]) -> Void)?
    var onClose: (() -> Void)?
    var onWindowDirection: ((WindowDirection) -> Void)?
    private var popupWindows: [NSWindow] = []
    private var backgroundOpacity = 1.0

    func setBackgroundOpacity(_ value: Double, force: Bool = false) {
        let next = min(1, max(0, value))
        guard force || next != backgroundOpacity else { return }
        backgroundOpacity = next
        guard webView?.url?.host == "chatgpt.com" else { return }
        webView?.evaluateJavaScript("window.__bavbavSetBackdrop?.(\(backgroundOpacity))", completionHandler: nil)
    }

    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var owner: ChatGPTWebSession?
        init(_ owner: ChatGPTWebSession) { self.owner = owner }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            owner?.userContentController(controller, didReceive: message)
        }
    }

    func prepare(ephemeral: Bool = false) -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = ephemeral ? .nonPersistent() : .default()
        configuration.userContentController.add(WeakHandler(self), name: "bavbavChat")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.pageBridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true
        ))
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.appearance = NSAppearance(named: .darkAqua)
        web.underPageBackgroundColor = .clear
        web.allowsBackForwardNavigationGestures = true
        webView = web
        return web
    }

    func open(_ conversation: ChatGPTConversationLink? = nil) {
        error = nil
        let web = prepare()
        let url = conversation?.url ?? URL(string: "https://chatgpt.com/")!
        if web.url == url, !web.isLoading { return }
        status = "LOADING"
        web.load(URLRequest(url: url))
    }

    func retry() {
        error = nil
        if let webView, webView.url != nil { webView.reload() } else { open() }
    }

    func focusComposer() {
        guard webView?.url?.host == "chatgpt.com" else { return }
        webView?.window?.makeFirstResponder(webView)
        webView?.evaluateJavaScript("document.querySelector('#prompt-textarea')?.focus()", completionHandler: nil)
    }

    func hasWebFocus(in window: NSWindow?) -> Bool {
        guard let webView, let view = window?.firstResponder as? NSView else { return false }
        return view === webView || view.isDescendant(of: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        status = webView.url?.host == "chatgpt.com" ? "CHATGPT" : "SIGN IN"
        error = nil
        setBackgroundOpacity(backgroundOpacity, force: true)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        self.error = "Could not load ChatGPT: \(error.localizedDescription)"
        status = "OFFLINE"
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        status = "RELOAD NEEDED"
        error = "The ChatGPT view closed. Refresh to reopen it."
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        guard ["https", "about"].contains(url.scheme ?? "") else {
            error = "This link cannot be opened inside the app."
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // Sign-in providers may request a separate window. Keep that window inside
    // Bavbav and use WebKit's supplied configuration to preserve the login flow.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 620, height: 760), configuration: configuration)
        popup.uiDelegate = self
        let window = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "ChatGPT · \(navigationAction.request.url?.host ?? "Link")"
        window.isReleasedWhenClosed = false
        window.contentView = popup
        window.center()
        window.makeKeyAndOrderFront(nil)
        popupWindows.removeAll { !$0.isVisible }
        popupWindows.append(window)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        webView.window?.close()
        popupWindows.removeAll { $0.contentView === webView }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === webView,
              message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == "chatgpt.com",
              let body = message.body as? [String: Any] else { return }
        if body["action"] as? String == "close" { onClose?(); return }
        if body["action"] as? String == "navigate" {
            let directions: [String: WindowDirection] = ["up": .up, "left": .left, "down": .down, "right": .right]
            if let name = body["direction"] as? String, let direction = directions[name] {
                onWindowDirection?(direction)
            }
            return
        }
        guard let rows = body["links"] as? [[String: String]] else { return }
        var seen = Set<String>()
        let links = rows.prefix(12).compactMap { row -> ChatGPTConversationLink? in
            guard let raw = row["url"], let url = URL(string: raw),
                  let link = ChatGPTConversationLink.from(url: url, title: row["title"] ?? ""),
                  seen.insert(link.id).inserted else { return nil }
            return link
        }
        let newRecents = Array(links.prefix(3))
        guard newRecents != recents else { return }
        recents = newRecents
        onRecentsChanged?(newRecents)
    }

    // Read only rendered conversation links. Never read cookies, auth storage,
    // passwords, or message contents. Reconcile at most once per DOM burst.
    static let pageBridge = #"""
    (() => {
      if (location.origin !== 'https://chatgpt.com' || window.__bavbavChatBridge) return;
      window.__bavbavChatBridge = true;
      document.documentElement.classList.remove('light');
      document.documentElement.classList.add('dark');
      document.documentElement.style.colorScheme = 'dark';
      let backdropOpacity = 1;
      const contrastStyle = document.createElement('style');
      contrastStyle.id = 'bavbav-foreground-contrast';
      document.head.appendChild(contrastStyle);
      const backdrops = new WeakMap();
      const applyBackdrops = () => {
        const nodes = backdropOpacity === 1
          ? document.querySelectorAll('[data-bavbav-backdrop]')
          : document.querySelectorAll('*');
        for (const node of nodes) {
          let saved = backdrops.get(node);
          if (backdropOpacity === 1) {
            if (saved) {
              if (saved.inline) node.style.setProperty('background-color', saved.inline, saved.priority);
              else node.style.removeProperty('background-color');
              node.removeAttribute('data-bavbav-backdrop'); backdrops.delete(node);
            }
            continue;
          }
          if (!saved) {
            const color = getComputedStyle(node).backgroundColor;
            const components = color.match(/^rgba?\(([^)]+)\)$/)?.[1].split(',').map(Number);
            if (!components || components.length < 3 || components[3] === 0) continue;
            saved = {components, inline: node.style.getPropertyValue('background-color'), priority: node.style.getPropertyPriority('background-color')};
            backdrops.set(node, saved); node.setAttribute('data-bavbav-backdrop', '');
          }
          const c = saved.components;
          node.style.setProperty('background-color', `rgba(${c[0]},${c[1]},${c[2]},${(c[3] ?? 1) * backdropOpacity})`, 'important');
        }
      };
      window.__bavbavSetBackdrop = value => {
        backdropOpacity = Math.max(0, Math.min(1, Number(value)));
        const strength = Math.max(0, Math.min(1, (0.65 - backdropOpacity) / 0.65));
        contrastStyle.textContent = strength > 0
          ? `body, body * { text-shadow: 0 0 1px rgba(0,0,0,${strength}), 0 0 2px rgba(0,0,0,${strength}) !important; -webkit-text-stroke: ${0.2 * strength}px rgba(0,0,0,${strength * 0.9}); }`
          : '';
        applyBackdrops();
      };
      let timer = null, last = '';
      const emit = () => {
        timer = null;
        applyBackdrops();
        const links = [], seen = new Set();
        for (const a of document.querySelectorAll('nav a[href], aside a[href]')) {
          const u = new URL(a.href, location.href);
          if (u.origin !== location.origin || !/^\/c\/[0-9a-f-]{36}$/i.test(u.pathname)) continue;
          const title = (a.textContent || '').trim();
          if (!title || seen.has(u.pathname)) continue;
          seen.add(u.pathname);
          links.push({url: u.origin + u.pathname, title: title.slice(0, 160)});
          if (links.length === 3) break;
        }
        const encoded = JSON.stringify(links);
        if (encoded !== last) {
          last = encoded;
          window.webkit.messageHandlers.bavbavChat.postMessage({links});
        }
      };
      new MutationObserver(() => {
        if (timer === null) timer = setTimeout(emit, 800);
      }).observe(document.body, {childList: true, subtree: true});
      emit();
      document.addEventListener('keydown', e => {
        const t = e.target;
        const typing = t instanceof Element && (t.isContentEditable || !!t.closest('input, textarea, [contenteditable]:not([contenteditable="false"]), [role="textbox"]'));
        if (e.metaKey || e.ctrlKey || e.altKey || e.isComposing || typing) return;
        const direction = {KeyW: 'up', KeyA: 'left', KeyS: 'down', KeyD: 'right'}[e.code];
        if (e.shiftKey && direction) {
          e.preventDefault(); e.stopPropagation();
          window.webkit.messageHandlers.bavbavChat.postMessage({action: 'navigate', direction});
        } else if (e.key.toLowerCase() === 'q') {
          e.preventDefault(); e.stopPropagation();
          window.webkit.messageHandlers.bavbavChat.postMessage({action: 'close'});
        } else if (e.key === 'Enter') {
          const input = document.querySelector('#prompt-textarea');
          if (input) { e.preventDefault(); input.focus(); }
        }
      }, true);
    })();
    """#
}

struct ChatGPTWebContent: NSViewRepresentable {
    let session: ChatGPTWebSession
    @Environment(\.panelBackdropOpacity) private var backgroundOpacity
    func makeNSView(context: Context) -> WKWebView { session.prepare() }
    func updateNSView(_ view: WKWebView, context: Context) { session.setBackgroundOpacity(backgroundOpacity) }
}
