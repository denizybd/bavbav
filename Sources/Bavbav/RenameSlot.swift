import AppKit
import SwiftUI

struct RenameLegend: View {
    @Environment(\.shortcutLabels) private var shortcuts
    @ObservedObject var store: OverlayStore
    var body: some View {
        KeyLegend(items: [(shortcuts.key(store.renameScope + ".commitRename.key"),
                           store.renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "CANCEL" : "SAVE"),
                          (shortcuts.key(store.renameScope + ".cancelRename.key"), "CANCEL")], accent: BavbavTheme.warning)
    }
}

struct RenameSlot: View {
    @ObservedObject var store: OverlayStore
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "pencil").foregroundStyle(BavbavTheme.warning).readableForeground()
                RenameNameField(text: $store.renameName, enabled: !store.renameSubmitting)
                    .id((store.renameTarget?.scope ?? "") + ":" + (store.renameTarget?.id ?? ""))
                    .frame(height: 22)
                if store.renameSubmitting { ProgressView().controlSize(.mini).tint(BavbavTheme.warning) }
            }
            Text(store.renameError ?? "RENAME · \(store.renameTarget?.name ?? "")")
                .font(BavbavTheme.mono(8, weight: .medium))
                .foregroundStyle(store.renameError == nil ? BavbavTheme.muted : BavbavTheme.warning).readableForeground()
                .lineLimit(2)
        }
        .padding(10)
        .background(BavbavTheme.raised.panelBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(BavbavTheme.warning.opacity(0.7), lineWidth: 1))
    }
}

/// A native field keeps Option/Command text editing and IME behavior intact.
/// Focus is requested only in its own key window, never after switching away.
struct RenameNameField: NSViewRepresentable {
    @Binding var text: String
    let enabled: Bool
    @Environment(\.panelBackdropOpacity) private var opacity

    func makeNSView(context: Context) -> Field { Field() }
    func updateNSView(_ field: Field, context: Context) {
        field.onChange = { text = $0 }
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = text }
        if enabled && !field.isEnabled { field.needsInitialFocus = true }
        field.isEnabled = enabled
        field.textColor = ForegroundContrast.color(RichMessageRenderer.textColor,
                                                   strength: ForegroundContrast.strength(backgroundOpacity: opacity))
        field.requestInitialFocus()
    }

    final class Field: NSTextField, NSTextFieldDelegate {
        var onChange: ((String) -> Void)?
        var needsInitialFocus = true
        private var focusScheduled = false

        init() {
            super.init(frame: .zero)
            isBordered = false
            drawsBackground = false
            focusRingType = .none
            font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
            isEditable = true
            isSelectable = true
            usesSingleLineMode = true
            delegate = self
            setAccessibilityLabel("Yeni ad")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(requestInitialFocus),
                                                       name: NSWindow.didBecomeKeyNotification, object: window)
                requestInitialFocus()
            }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        @objc func requestInitialFocus() {
            guard needsInitialFocus, !focusScheduled, isEnabled, window?.isKeyWindow == true else { return }
            focusScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.focusScheduled = false
                guard self.needsInitialFocus, self.isEnabled, let window = self.window,
                      window.isKeyWindow, window.isVisible else { return }
                guard window.makeFirstResponder(self) else { return }
                self.needsInitialFocus = false
                self.currentEditor()?.selectAll(nil)
            }
        }
        func controlTextDidChange(_ notification: Notification) { onChange?(stringValue) }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Saving/cancelling belongs to the configurable InputRouter; never
            // let a native Return bypass a remapped save key.
            selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:))
        }
    }
}
