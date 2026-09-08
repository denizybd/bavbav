import AppKit
import WebKit

@MainActor
enum ChatGPTWebCheck {
    static func run(store: OverlayStore, live: Bool) async -> Bool {
        let session = store.chatGPTSession
        let web = session.prepare(ephemeral: true)
        web.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        if live {
            session.open()
            for _ in 0..<150 {
                if !web.isLoading, web.url != nil { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard !web.isLoading, session.error == nil, web.url?.host == "chatgpt.com" else {
                print("CHATGPT LIVE CHECK FAILED: \(session.error ?? "load did not finish")")
                return false
            }
            print("CHATGPT LIVE PAGE: \(web.title ?? "untitled")")
            print("Account sign-in and existing-history access still require the user's session.")
            return true
        }
        let first = "11111111-1111-1111-1111-111111111111"
        let second = "22222222-2222-2222-2222-222222222222"
        let third = "33333333-3333-3333-3333-333333333333"
        guard ChatGPTConversationLink.from(url: URL(string: "https://evil.test/c/\(first)")!, title: "bad") == nil,
              ChatGPTConversationLink.from(url: URL(string: "https://chatgpt.com/codex/\(first)")!, title: "work") == nil,
              store.chatGPTMenuIDs == [OverlayStore.chatGPTLauncherID],
              store.chatGPTInteraction.selectedID == OverlayStore.chatGPTLauncherID
        else { return fail("invalid chat boundary") }
        var closed = 0
        var directions: [WindowDirection] = []
        session.onClose = { closed += 1 }
        session.onWindowDirection = { directions.append($0) }
        web.loadHTMLString("""
        <!doctype html><html><body>
        <nav>
          <a href="/codex/work">CODEX WORK</a>
          <a href="https://evil.test/c/\(first)">Wrong account origin</a>
          <a href="/c/\(first)">Birinci sohbet</a>
          <a href="/c/\(first)">Duplicate</a>
          <a href="/c/\(second)">İkinci sohbet</a>
          <a href="/c/\(third)">Üçüncü sohbet</a>
          <a href="/c/44444444-4444-4444-4444-444444444444">Fourth</a>
        </nav>
        <div id="prompt-textarea" contenteditable="true"></div>
        </body></html>
        """, baseURL: URL(string: "https://chatgpt.com/"))
        for _ in 0..<100 where store.chatGPTRecents.count != 3 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard store.chatGPTRecents.map(\.id) == [first, second, third],
              store.chatGPTMenuIDs.count == 4 else { return fail("history menu not synchronized") }
        store.selectChatGPT(id: first)
        store.navigate(.chatgpt, delta: 1)
        guard store.chatGPTInteraction.selectedID == second else { return fail("W/S selection") }
        _ = store.beginSpace(.chatgpt)
        store.crossLongPressThreshold(.chatgpt)
        store.navigate(.chatgpt, delta: -1)
        store.releaseSpace(.chatgpt)
        _ = store.beginSpace(.chatgpt) // Save local order.
        guard store.chatGPTRecents.first?.id == second else { return fail("held Space reorder") }
        do {
            _ = try await web.evaluateJavaScript("document.body.style.backgroundColor = 'rgb(10,20,30)'; document.body.style.color = 'rgb(220,230,240)'; document.body.style.border = '1px solid rgb(50,60,70)'; window.__bavbavSetBackdrop(0);")
            let backgroundCheck = try await web.evaluateJavaScript("getComputedStyle(document.body).backgroundColor === 'rgba(10, 20, 30, 0)' && getComputedStyle(document.body).color === 'rgb(220, 230, 240)' && getComputedStyle(document.body).borderTopColor === 'rgb(50, 60, 70)' && getComputedStyle(document.body).opacity === '1'") as? Bool
            guard backgroundCheck == true else { return fail("page background fades without changing text/border alpha") }
            let halo = try await web.evaluateJavaScript("getComputedStyle(document.body).textShadow !== 'none'") as? Bool
            guard halo == true else { return fail("transparent page requires text contrast halo") }
            _ = try await web.evaluateJavaScript("window.__bavbavSetBackdrop(1)")
            let restored = try await web.evaluateJavaScript("getComputedStyle(document.body).backgroundColor === 'rgb(10, 20, 30)'") as? Bool
            guard restored == true else { return fail("page background restoration") }
            let resetHalo = try await web.evaluateJavaScript("getComputedStyle(document.body).textShadow === 'none'") as? Bool
            guard resetHalo == true else { return fail("opaque page restores original text styling") }
            _ = try await web.evaluateJavaScript("for (const code of ['KeyW','KeyA','KeyS','KeyD']) document.body.dispatchEvent(new KeyboardEvent('keydown', {key:code.slice(-1),code,shiftKey:true,bubbles:true}));")
            for _ in 0..<20 where directions.count < 4 { try? await Task.sleep(nanoseconds: 20_000_000) }
            guard directions == [.up, .left, .down, .right] else { return fail("Shift WASD window navigation") }
            _ = try await web.evaluateJavaScript("document.querySelector('#prompt-textarea').focus(); for (const code of ['KeyW','KeyA','KeyS','KeyD']) document.activeElement.dispatchEvent(new KeyboardEvent('keydown', {key:code.slice(-1),code,shiftKey:true,bubbles:true}));")
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard directions.count == 4 else { return fail("Shift WASD stole uppercase input") }
            _ = try await web.evaluateJavaScript("document.querySelector('#prompt-textarea').focus(); document.activeElement.dispatchEvent(new KeyboardEvent('keydown', {key:'q',bubbles:true}));")
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard closed == 0 else { return fail("Q closed while typing") }
            _ = try await web.evaluateJavaScript("document.activeElement.blur(); document.body.dispatchEvent(new KeyboardEvent('keydown', {key:'q',bubbles:true}));")
            for _ in 0..<20 where closed == 0 { try? await Task.sleep(nanoseconds: 20_000_000) }
            guard closed == 1 else { return fail("Q did not close reading view") }
            _ = try await web.evaluateJavaScript("document.body.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter',bubbles:true}));")
            let focused = try await web.evaluateJavaScript("document.activeElement.id") as? String
            guard focused == "prompt-textarea" else { return fail("Enter did not focus composer") }
            // A new account/sign-out state removes the prior account's titles.
            _ = try await web.evaluateJavaScript("document.querySelector('nav').remove()")
            for _ in 0..<40 where !store.chatGPTRecents.isEmpty {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard store.chatGPTRecents.isEmpty else { return fail("stale account history") }
        } catch { return fail(error.localizedDescription) }
        guard session.prepare() === web else { return fail("duplicated web session") }
        print("BAVBAV CHATGPT WEB CHECK PASSED: history isolation, three chats, W/S, Shift WASD, uppercase input, reorder, Q/Enter, one session")
        return true
    }

    private static func fail(_ message: String) -> Bool {
        print("BAVBAV CHATGPT WEB CHECK FAILED: \(message)")
        return false
    }
}
