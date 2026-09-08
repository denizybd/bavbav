import AppKit
import SwiftUI

struct ComposerTextView: NSViewRepresentable {
    @Environment(\.panelBackdropOpacity) private var backgroundOpacity
    @Binding var text: String
    let focusToken: Int
    let enabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = CommandTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(
            calibratedRed: 0.847,
            green: 0.875,
            blue: 0.914,
            alpha: 1
        )
        textView.insertionPointColor = NSColor(
            calibratedRed: 0.314,
            green: 0.886,
            blue: 0.722,
            alpha: 1
        )
        textView.textContainerInset = NSSize(width: 9, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CommandTextView else { return }
        textView.isEditable = enabled
        let contrast = ForegroundContrast.strength(backgroundOpacity: backgroundOpacity)
        textView.contrastStrength = contrast
        textView.textColor = ForegroundContrast.color(RichMessageRenderer.textColor, strength: contrast)
        textView.alphaValue = enabled || contrast > 0 ? 1 : 0.55
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                guard enabled, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var lastFocusToken = -1

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

private final class CommandTextView: NSTextView {
    var contrastStrength = 0.0 { didSet { if oldValue != contrastStrength { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        if contrastStrength > 0 { ForegroundContrast.shadow(strength: contrastStrength).set() }
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
    }
    // Configurable send/newline/cancel commands are owned by InputRouter.
}

struct CompactInputField: NSViewRepresentable {
    @Environment(\.panelBackdropOpacity) private var backgroundOpacity
    @Binding var text: String
    let focusToken: Int
    let secure: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = NSColor(
            calibratedRed: 0.055,
            green: 0.065,
            blue: 0.078,
            alpha: 1
        )
        field.textColor = NSColor(
            calibratedRed: 0.847,
            green: 0.875,
            blue: 0.914,
            alpha: 1
        )
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        field.focusRingType = .none
        field.placeholderString = secure ? "••••••••" : "Type answer…"
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.backgroundColor = field.backgroundColor?.withAlphaComponent(backgroundOpacity)
        field.textColor = ForegroundContrast.color(RichMessageRenderer.textColor,
            strength: ForegroundContrast.strength(backgroundOpacity: backgroundOpacity))
        context.coordinator.onSubmit = onSubmit
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                window.makeFirstResponder(field)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var onSubmit: () -> Void
        var lastFocusToken = -1

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            _text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text = field.stringValue
        }

        @objc func submit() {
            onSubmit()
        }
    }
}
