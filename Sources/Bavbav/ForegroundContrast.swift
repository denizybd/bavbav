import AppKit
import SwiftUI

enum ForegroundContrast {
    /// Start gently once more than 35% of the background is removed.
    static func strength(backgroundOpacity: Double) -> Double {
        min(1, max(0, (0.65 - backgroundOpacity) / 0.65))
    }

    static func color(_ original: NSColor, strength: Double) -> NSColor {
        guard strength > 0 else { return original }
        return (original.blended(withFraction: strength * 0.45, of: .white) ?? original).withAlphaComponent(1)
    }

    static func shadow(strength: Double) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(strength * 0.95)
        shadow.shadowBlurRadius = 0.65 * strength
        shadow.shadowOffset = .zero
        return shadow
    }

    static func attributes(strength: Double) -> [NSAttributedString.Key: Any] {
        guard strength > 0 else { return [:] }
        return [.shadow: shadow(strength: strength),
                .strokeColor: NSColor.black.withAlphaComponent(strength * 0.9),
                .strokeWidth: -2.8 * strength]
    }
}

private struct ReadableForegroundModifier: ViewModifier {
    @Environment(\.panelBackdropOpacity) private var backgroundOpacity

    func body(content: Content) -> some View {
        let strength = ForegroundContrast.strength(backgroundOpacity: backgroundOpacity)
        content
            .brightness(0.22 * strength)
            .shadow(color: .black.opacity(0.95 * strength), radius: 0.4 * strength)
            .shadow(color: .black.opacity(0.9 * strength), radius: 1.4 * strength)
    }
}

extension View {
    /// Apply to foreground content only, before any background fill is added.
    func readableForeground() -> some View { modifier(ReadableForegroundModifier()) }
}
