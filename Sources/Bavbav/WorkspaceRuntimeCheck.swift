import Foundation

/// Filesystem fixtures only: no engine, private account, network, GUI or physical cable is used.
enum WorkspaceRuntimeCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func run() -> Bool {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("Bavbav.WorkspaceRuntime.\(UUID().uuidString)", isDirectory: true)
        var assertions = 0
        var report: [String: Any] = ["success": false, "validationKind": "filesystem-runtime-contract-fixtures",
            "productionDataUsed": false, "runtimeStarted": false, "networkUsed": false,
            "physicalCableTested": false, "tccTested": false,
            "minimumEngineVersion": WorkspaceRuntimeContract.minimumEngineVersion]
        defer { try? manager.removeItem(at: directory) } // This invocation's UUID fixtures only.

        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            if !value() { throw Failure(message) }
        }
        func write(_ bytes: Data, _ url: URL) throws {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try bytes.write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        func json(_ value: [String: Any], _ url: URL) throws {
            try write(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), url)
        }
        func fixture(_ name: String, engineVersion: String = "0.7.3") throws -> URL {
            let root = directory.appendingPathComponent(name, isDirectory: true)
            for relative in WorkspaceRuntimeContract.requiredRelativePaths {
                try write(Data("// Synthetic package-shape fixture; never executed.\n".utf8), root.appendingPathComponent(relative))
            }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("runtime/node").path)
            try json(["version": engineVersion], root.appendingPathComponent("engine/package.json"))
            try json(["version": "0.16.0", "build": 72], root.appendingPathComponent("app-version.json"))
            return root
        }
        func reject(_ root: URL, _ message: String, hostVersion: String? = "0.16.0", hostBuild: Int? = 72) throws {
            do {
                _ = try WorkspaceRuntimeContract.validate(resourcesURL: root, expectedHostVersion: hostVersion, expectedHostBuild: hostBuild)
            } catch is WorkspaceRuntimeContract.Failure {
                try check(true, message); return
            }
            try check(false, message)
        }

        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let valid = try fixture("minimum-version")
            let result = try WorkspaceRuntimeContract.validate(resourcesURL: valid, expectedHostVersion: "0.16.0", expectedHostBuild: 72)
            try check(result.engineVersion == "0.7.3" && result.hostVersion == "0.16.0" && result.hostBuild == 72,
                      "minimum supported version and matching host accepted")
            let future = try fixture("newer-version", engineVersion: "0.8.0")
            let futureResult = try WorkspaceRuntimeContract.validate(resourcesURL: future)
            try check(futureResult.engineVersion == "0.8.0", "newer stable engine accepted")
            for version in ["0.7.0", "0.7.2", "0.7.3-beta.1", "garbage"] {
                try reject(try fixture("version-\(version)", engineVersion: version), "old or malformed engine rejected: \(version)")
            }
            let badJSON = try fixture("bad-json")
            try write(Data("{broken".utf8), badJSON.appendingPathComponent("engine/package.json"))
            try reject(badJSON, "malformed package JSON rejected")
            let missingCable = try fixture("missing-cable")
            try manager.removeItem(at: missingCable.appendingPathComponent("engine/src/thunderbolt.mjs"))
            try reject(missingCable, "missing cable module rejected despite current version")
            try reject(valid, "stale host version rejected", hostVersion: "0.16.1")
            try reject(valid, "stale host build rejected", hostBuild: 73)
            let badHostJSON = try fixture("bad-host-json")
            try write(Data("[]".utf8), badHostJSON.appendingPathComponent("app-version.json"))
            try reject(badHostJSON, "nonobject host metadata rejected")
            let booleanBuild = try fixture("boolean-build")
            try json(["version": "0.16.0", "build": true], booleanBuild.appendingPathComponent("app-version.json"))
            try reject(booleanBuild, "boolean host build rejected")
            let oversize = try fixture("oversize-json")
            try write(Data(repeating: 32, count: 65_537), oversize.appendingPathComponent("engine/package.json"))
            try reject(oversize, "oversize metadata rejected before JSON parsing")
            let unexecutable = try fixture("nonexecutable-node")
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unexecutable.appendingPathComponent("runtime/node").path)
            try reject(unexecutable, "nonexecutable Node rejected")
            let linkedFile = try fixture("symlink-file")
            let link = linkedFile.appendingPathComponent("engine/src/thunderbolt.mjs")
            try manager.removeItem(at: link)
            try manager.createSymbolicLink(at: link, withDestinationURL: valid.appendingPathComponent("engine/src/thunderbolt.mjs"))
            try reject(linkedFile, "symlink critical module rejected")
            let linkedDirectory = try fixture("symlink-directory")
            let sourceDirectory = linkedDirectory.appendingPathComponent("engine/src")
            try manager.removeItem(at: sourceDirectory)
            try manager.createSymbolicLink(at: sourceDirectory, withDestinationURL: valid.appendingPathComponent("engine/src"))
            try reject(linkedDirectory, "symlink intermediate directory rejected")
            let linkedRoot = directory.appendingPathComponent("symlink-root")
            try manager.createSymbolicLink(at: linkedRoot, withDestinationURL: valid)
            try reject(linkedRoot, "symlink resource root rejected")

            if let bundled = Bundle.main.resourceURL?.appendingPathComponent("IkiWorkspace", isDirectory: true),
               manager.fileExists(atPath: bundled.path) {
                let localNetworkPurpose = Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String ?? ""
                try check(!localNetworkPurpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          "full app declares its local-network purpose without claiming permission was granted")
                guard let hostVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                      let hostBuildText = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                      let hostBuild = Int(hostBuildText) else { throw Failure("bundled Bavbav host version/build missing") }
                let actual = try WorkspaceRuntimeContract.validate(resourcesURL: bundled, expectedHostVersion: hostVersion, expectedHostBuild: hostBuild)
                try check(actual.hostVersion == hostVersion && actual.hostBuild == hostBuild, "actual bundled resources match this host")
                report["bundledResourceValidation"] = "passed"
                report["bundledEngineVersion"] = actual.engineVersion
            } else { report["bundledResourceValidation"] = "absent-public-build" }
            report["success"] = true
            print("BAVBAV WORKSPACE RESOURCE CHECK PASSED: \(assertions) assertions; filesystem fixtures only, no physical cable/TCC test")
        } catch {
            report["error"] = error.localizedDescription
            print("BAVBAV WORKSPACE RESOURCE CHECK FAILED: \(error.localizedDescription)")
        }
        report["assertions"] = assertions
        if let index = CommandLine.arguments.firstIndex(of: "--workspace-resource-report"), index + 1 < CommandLine.arguments.count,
           let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
        }
        return report["success"] as? Bool == true
    }
}
