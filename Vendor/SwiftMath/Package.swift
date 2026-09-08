// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "SwiftMath",
    defaultLocalization: "en",
    platforms: [.macOS(.v12)],
    products: [.library(name: "SwiftMath", targets: ["SwiftMath"])],
    targets: [.target(name: "SwiftMath", resources: [.copy("mathFonts.bundle")])]
)
