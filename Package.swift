// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bavbav",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Bavbav", targets: ["Bavbav"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
        .package(path: "Vendor/SwiftMath")
    ],
    targets: [
        .target(
            name: "BavbavCore",
            path: "Sources/BavbavCore"
        ),
        .executableTarget(
            name: "Bavbav",
            dependencies: ["BavbavCore", .product(name: "Markdown", package: "swift-markdown"),
                           .product(name: "SwiftMath", package: "SwiftMath")],
            path: "Sources/Bavbav",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon")
            ]
        ),
        .executableTarget(
            name: "BavbavChecks",
            dependencies: ["BavbavCore"],
            path: "Tests/BavbavChecks"
        ),
        .executableTarget(
            name: "BavbavFakeCodex",
            path: "Tests/BavbavFakeCodex"
        )
    ],
    swiftLanguageModes: [.v5]
)
