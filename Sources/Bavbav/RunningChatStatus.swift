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
        button.image = nil
        button.alternateImage = nil
        button.imagePosition = .noImage
        button.title = label
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: BavbavTheme.focusAccent
        ])
        button.attributedTitle = text
        button.attributedAlternateTitle = text
        button.contentTintColor = BavbavTheme.focusAccent
        button.toolTip = "\(count) sohbet çalışıyor"
        button.setAccessibilityLabel("Bavbav · \(count) sohbet çalışıyor")
    }
}
