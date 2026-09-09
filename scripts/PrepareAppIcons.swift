import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The source artwork is full-bleed. Apply one deterministic native macOS
// silhouette to both appearances instead of relying on painted transparency.
// Runtime code only loads the finished PNGs; it never renders or writes icons.
let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let iconset = resources.appendingPathComponent("Bavbav-v3.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ artwork: CGImage, pixels: Int, to destination: URL) throws {
    let width = CGFloat(pixels)
    guard let context = CGContext(data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: pixels * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let output = CGImageDestinationCreateWithURL(destination as CFURL,
            UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "Bavbav.IconBuild", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Cannot prepare \(destination.lastPathComponent)"])
    }
    context.clear(CGRect(x: 0, y: 0, width: width, height: width))
    // Match the 824-point artwork area on the traditional 1024-point Mac grid.
    let inset = width * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: width - 2 * inset, height: width - 2 * inset)
    let radius = tile.width * 0.225
    let silhouette = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.addPath(silhouette)
    context.clip()
    context.interpolationQuality = .high
    context.draw(artwork, in: tile)
    guard let image = context.makeImage() else {
        throw NSError(domain: "Bavbav.IconBuild", code: 2)
    }
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else {
        throw NSError(domain: "Bavbav.IconBuild", code: 3)
    }
}

for variant in ["light", "dark"] {
    let sourceURL = resources.appendingPathComponent("BavbavArtwork-v3-\(variant).png")
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil),
          artwork.width == artwork.height else {
        throw NSError(domain: "Bavbav.IconBuild", code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Missing square artwork: \(sourceURL.path)"])
    }
    try render(artwork, pixels: 1024,
        to: resources.appendingPathComponent("BavbavIcon-v3-\(variant).png"))
    // The signed bundle's fallback is light, for launchers that only read ICNS.
    // Both runtime appearance images share exactly the same native silhouette.
    if variant == "light" {
        for points in [16, 32, 128, 256, 512] {
            try render(artwork, pixels: points,
                to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
            try render(artwork, pixels: points * 2,
                to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
        }
    }
}
print("Prepared native rounded RGBA icons: light, dark and 10 ICNS sizes")
