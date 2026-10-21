// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Public builds are self-contained. Authorized Workspace builds explicitly opt
// in after staging the matching private module and runtime.
let withWorkspace = ProcessInfo.processInfo.environment["BAVBAV_WITH_WORKSPACE"] == "1"
let workspaceTargets: [Target] = withWorkspace
    ? [.target(name: "IkiWorkspaceKit", path: "Sources/IkiWorkspaceKit")] : []
let workspaceDependencies: [Target.Dependency] = withWorkspace ? ["IkiWorkspaceKit"] : []

// Keep manifest expressions explicitly typed and small. Xcode 16.4's manifest
// compiler otherwise times out resolving the large Package/Target overloads.
let packageProducts: [Product] = [
    .library(name: "BavbavOffline", targets: ["BavbavOffline"]),
    .library(name: "BavbavCompanion", targets: ["BavbavCompanion"]),
    .executable(name: "Bavbav", targets: ["Bavbav"])
]
let packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
    .package(path: "Vendor/SwiftMath")
]
let commonTargets: [Target] = [
        .target(name: "BavbavOffline", path: "Sources/BavbavOffline"),
        .executableTarget(name: "BavbavOfflineChecks", dependencies: ["BavbavOffline"], path: "Tests/BavbavOfflineChecks", swiftSettings: [.unsafeFlags(["-parse-as-library"])]),
        .target(name: "CompanionSafety", exclude: ["NOTICE.md"]),
        .target(name: "BavbavCompanion", dependencies: ["BavbavCore", "CompanionSafety"]),
        .executableTarget(name: "BavbavCompanionChecks", dependencies: ["BavbavCompanion", "CompanionSafety"], path: "Tests/BavbavCompanionTests"),
        .target(
            name: "BavbavCore",
            path: "Sources/BavbavCore"
        ),
]
var applicationDependencies: [Target.Dependency] = [
    .byName(name: "BavbavCore"), .byName(name: "BavbavCompanion"), .byName(name: "BavbavOffline")
]
applicationDependencies.append(contentsOf: workspaceDependencies)
applicationDependencies.append(contentsOf: [
    .product(name: "Markdown", package: "swift-markdown"),
    .product(name: "SwiftMath", package: "SwiftMath")
])
let applicationSwiftSettings: [SwiftSetting] = withWorkspace ? [.define("BAVBAV_WORKSPACE")] : []
let applicationTarget: Target = .executableTarget(
            name: "Bavbav",
            dependencies: applicationDependencies,
            path: "Sources/Bavbav",
            swiftSettings: applicationSwiftSettings,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon")
            ]
        )
let checkTargets: [Target] = [
        .executableTarget(
            name: "BavbavChecks",
            dependencies: ["BavbavCore"],
            path: "Tests/BavbavChecks"
        ),
        .executableTarget(
            name: "BavbavFakeCodex",
            path: "Tests/BavbavFakeCodex"
        )
]
var packageTargets: [Target] = commonTargets
packageTargets.append(contentsOf: workspaceTargets)
packageTargets.append(applicationTarget)
packageTargets.append(contentsOf: checkTargets)

let package = Package(
    name: "Bavbav",
    platforms: [.macOS(.v14)],
    products: packageProducts,
    dependencies: packageDependencies,
    targets: packageTargets,
    swiftLanguageModes: [.v5]
)
