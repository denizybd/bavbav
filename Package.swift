// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The public checkout is self-contained. Optional private Workspace sources
// are linked only when present locally, or when explicitly required by a build.
let workspaceMode = ProcessInfo.processInfo.environment["BAVBAV_WITH_WORKSPACE"] ?? "auto"
let workspaceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Sources/IkiWorkspaceKit", isDirectory: true)
var workspaceIsDirectory: ObjCBool = false
let workspaceSourcesPresent = FileManager.default.fileExists(atPath: workspaceDirectory.path,
                                                              isDirectory: &workspaceIsDirectory)
    && workspaceIsDirectory.boolValue
guard ["auto", "0", "1"].contains(workspaceMode) else {
    fatalError("BAVBAV_WITH_WORKSPACE must be auto, 0, or 1.")
}
guard workspaceMode != "1" || workspaceSourcesPresent else {
    fatalError("BAVBAV_WITH_WORKSPACE=1 requires the private Sources/IkiWorkspaceKit sources. Public builds use BAVBAV_WITH_WORKSPACE=0.")
}
let workspaceEnabled = workspaceMode == "1" || (workspaceMode == "auto" && workspaceSourcesPresent)
let workspaceTargets: [Target] = workspaceEnabled
    ? [.target(name: "IkiWorkspaceKit", path: "Sources/IkiWorkspaceKit")] : []
let workspaceDependencies: [Target.Dependency] = workspaceEnabled ? ["IkiWorkspaceKit"] : []

let package = Package(
    name: "Bavbav",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "BavbavOffline", targets: ["BavbavOffline"]),
        .library(name: "BavbavCompanion", targets: ["BavbavCompanion"]),
        .executable(name: "Bavbav", targets: ["Bavbav"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
        .package(path: "Vendor/SwiftMath")
    ],
    targets: [
        .target(name: "BavbavOffline", path: "Sources/BavbavOffline"),
        .executableTarget(name: "BavbavOfflineChecks", dependencies: ["BavbavOffline"], path: "Tests/BavbavOfflineChecks", swiftSettings: [.unsafeFlags(["-parse-as-library"])]),
        .target(name: "CompanionSafety", exclude: ["NOTICE.md"]),
        .target(name: "BavbavCompanion", dependencies: ["BavbavCore", "CompanionSafety"]),
        .executableTarget(name: "BavbavCompanionChecks", dependencies: ["BavbavCompanion", "CompanionSafety"], path: "Tests/BavbavCompanionTests"),
        .target(
            name: "BavbavCore",
            path: "Sources/BavbavCore"
        ),
    ] + workspaceTargets + [
        .executableTarget(
            name: "Bavbav",
            dependencies: [.byName(name: "BavbavCore"), .byName(name: "BavbavCompanion"), .byName(name: "BavbavOffline")]
                + workspaceDependencies + [.product(name: "Markdown", package: "swift-markdown"),
                                            .product(name: "SwiftMath", package: "SwiftMath")],
            path: "Sources/Bavbav",
            swiftSettings: workspaceEnabled ? [.define("BAVBAV_WITH_WORKSPACE")] : [],
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
