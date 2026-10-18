// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Public builds are self-contained. Authorized Workspace builds explicitly opt
// in after staging the matching private module and runtime.
let withWorkspace = ProcessInfo.processInfo.environment["BAVBAV_WITH_WORKSPACE"] == "1"
let workspaceTargets: [Target] = withWorkspace
    ? [.target(name: "IkiWorkspaceKit", path: "Sources/IkiWorkspaceKit")]
    : []
let workspaceDependencies: [Target.Dependency] = withWorkspace ? ["IkiWorkspaceKit"] : []

let package = Package(
    name: "Bavbav",
    platforms: [
        .macOS(.v14)
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
                           .product(name: "SwiftMath", package: "SwiftMath")] + workspaceDependencies,
            path: "Sources/Bavbav",
            swiftSettings: withWorkspace ? [.define("BAVBAV_WORKSPACE")] : [],
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
    ] + workspaceTargets,
    swiftLanguageModes: [.v5]
)
