import AppKit
import Combine

/// Event-driven: no timer, server request or dependency on visible windows.
@MainActor
final class RunningChatStatus {
    private var subscription: AnyCancellable?

    init(store: OverlayStore, button: NSButton) {
        subscription = store.$runningChatCount.removeDuplicates().sink { [weak button] count in
            guard let button else { return }
            Self.apply(count: count, to: button)
        }
    }

    static func apply(count: Int, to button: NSButton) {
        let count = max(0, count)
        let label = String(count)
        // NSStatusBarButton can override attributed title colors with the
        // system menu-bar foreground. A non-template image preserves our ink.
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: BavbavTheme.focusAccent
        ])
        let size = NSSize(width: ceil(text.size().width) + 4, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            text.draw(at: NSPoint(x: 2, y: (rect.height - text.size().height) / 2))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = label
        button.title = ""
        button.alternateTitle = ""
        button.image = image
        button.alternateImage = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.contentTintColor = nil
        button.toolTip = "\(count) sohbet çalışıyor"
        button.setAccessibilityLabel("Bavbav · \(count) sohbet çalışıyor")
    }
}
