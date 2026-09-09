import AppKit

enum AppIconAppearance: String, CaseIterable {
    case light, dark

    var resourceName: String { "BavbavIcon-v3-\(rawValue)" }

    static func matching(_ appearance: NSAppearance) -> Self {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}

/// Updates only the running app's icon. The signed bundle remains immutable;
/// Finder and launchers which use the bundle icon keep the rounded ICNS fallback.
@MainActor
final class AppIconController {
    typealias ImageLoader = @MainActor (AppIconAppearance) -> NSImage?
    typealias ImagePublisher = @MainActor (NSImage) -> Void

    private let images: [AppIconAppearance: NSImage]
    private let publish: ImagePublisher
    private var appearanceObservation: NSKeyValueObservation?
    private var generation = 0
    private(set) var publishedAppearance: AppIconAppearance?

    init(resourceDirectory: URL? = Bundle.main.resourceURL,
         imageLoader: ImageLoader? = nil,
         publish: @escaping ImagePublisher = { NSApp.applicationIconImage = $0 }) {
        var loaded: [AppIconAppearance: NSImage] = [:]
        for appearance in AppIconAppearance.allCases {
            let image: NSImage?
            if let imageLoader {
                image = imageLoader(appearance)
            } else if let resourceDirectory {
                let url = resourceDirectory.appendingPathComponent(appearance.resourceName)
                    .appendingPathExtension("png")
                image = NSImage(contentsOf: url)
            } else {
                image = nil
            }
            if let image, image.isValid, image.size.width > 0, image.size.height > 0 {
                loaded[appearance] = image
            }
        }
        images = loaded
        self.publish = publish
    }

    func start(observing requestedApplication: NSApplication? = nil) {
        let application = requestedApplication ?? .shared
        guard appearanceObservation == nil else { return }
        generation += 1
        let observedGeneration = generation
        appearanceObservation = application.observe(\.effectiveAppearance, options: [.initial, .new]) {
            [weak self, weak application] _, _ in
            // AppKit normally delivers appearance changes on the main thread.
            // Always hop to the main actor, and resolve the latest appearance,
            // so delayed notifications cannot restore a stale icon.
            Task { @MainActor [weak self, weak application] in
                guard let self, let application,
                      self.appearanceObservation != nil,
                      self.generation == observedGeneration else { return }
                self.update(for: application.effectiveAppearance)
            }
        }
    }

    func stop() {
        generation += 1
        appearanceObservation?.invalidate()
        appearanceObservation = nil
    }

    private func update(for appearance: NSAppearance) {
        let requested = AppIconAppearance.matching(appearance)
        let resolved = images[requested] != nil ? requested : AppIconAppearance.allCases.first { images[$0] != nil }
        guard let resolved, resolved != publishedAppearance, let image = images[resolved] else {
            // Missing artwork never replaces a valid system/bundle icon with
            // an empty image; a sole valid variant is safe in either theme.
            return
        }
        publish(image)
        publishedAppearance = resolved
    }
}
