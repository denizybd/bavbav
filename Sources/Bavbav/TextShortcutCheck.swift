import AppKit

@MainActor
enum TextShortcutCheck {
    static func run(router: InputRouter) -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let message = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        message.isEditable = false
        message.isSelectable = true
        message.string = "Merhaba 👋\nİkinci satır"
        window.contentView?.addSubview(message)
        window.makeFirstResponder(message)
        func key(_ letter: String, code: UInt16) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                        characters: letter, charactersIgnoringModifiers: letter,
                                        isARepeat: false, keyCode: code)!
            _ = router.handle(event)
        }
        key("a", code: 0)
        guard message.selectedRange() == NSRange(location: 0, length: message.string.utf16.count) else {
            fputs("TEXT SHORTCUT CHECK FAILED: message selection\n", stderr)
            return false
        }
        key("c", code: 8)
        guard pasteboard.string(forType: .string) == message.string else { return false }
        key("v", code: 9)
        guard message.string == "Merhaba 👋\nİkinci satır" else { return false }
        let composer = NSTextView(frame: NSRect(x: 0, y: 100, width: 300, height: 100))
        composer.isRichText = false
        composer.string = "replace me"
        window.contentView?.addSubview(composer)
        window.makeFirstResponder(composer)
        key("a", code: 0)
        key("v", code: 9)
        guard composer.string == message.string else {
            fputs("TEXT SHORTCUT CHECK FAILED: composer paste/replace\n", stderr)
            return false
        }
        print("BAVBAV TEXT SHORTCUT CHECK PASSED: select message, copy, paste, Unicode")
        return true
    }
}
