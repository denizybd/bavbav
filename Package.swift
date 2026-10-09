// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bavbav",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "BavbavCompanion", targets: ["BavbavCompanion"]),
        .executable(name: "Bavbav", targets: ["Bavbav"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
        .package(path: "Vendor/SwiftMath")
    ],
    targets: [
        .target(name: "CompanionSafety", exclude: ["NOTICE.md"]),
        .target(name: "BavbavCompanion", dependencies: ["BavbavCore", "CompanionSafety"]),
        .executableTarget(name: "BavbavCompanionChecks", dependencies: ["BavbavCompanion", "CompanionSafety"], path: "Tests/BavbavCompanionTests"),
        .target(
            name: "BavbavCore",
            path: "Sources/BavbavCore"
        ),
        .executableTarget(
            name: "Bavbav",
            dependencies: ["BavbavCore", "BavbavCompanion", .product(name: "Markdown", package: "swift-markdown"),
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
