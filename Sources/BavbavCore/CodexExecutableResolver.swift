import Foundation

/// Resolve again for every new process: desktop updates can relocate the CLI.
public enum CodexExecutableResolver {
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationDirectories: [String]? = nil,
        isExecutable: ((String) -> Bool)? = nil
    ) throws -> URL {
        let executable = isExecutable ?? { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
        }
        if let override = environment["BAVBAV_CODEX_BIN"], !override.isEmpty {
            // An explicit selection must never silently launch a different CLI
            // (especially when a test was supposed to launch the fake server).
            guard (override as NSString).isAbsolutePath, executable(override) else {
                throw CodexClientError.processFailed("BAVBAV_CODEX_BIN must point to an executable file at an absolute path: \(override)")
            }
            return URL(fileURLWithPath: override)
        }

        let roots = applicationDirectories ?? [
            "/Applications",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        ]
        var candidates: [String] = []
        for root in roots {
            for app in ["ChatGPT.app", "Codex.app"] {
                let resources = URL(fileURLWithPath: root).appendingPathComponent("\(app)/Contents/Resources")
                for relative in ["codex-cli/CodexCLI.app/Contents/MacOS/codex", "codex-cli/bin/codex", "codex"] {
                    candidates.append(resources.appendingPathComponent(relative).path)
                }
            }
        }
        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        // Finder may have a minimal PATH. Known app bundles above do not depend
        // on shell setup; an absolute PATH entry also supports custom installs.
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let path = String(directory)
            guard (path as NSString).isAbsolutePath else { continue }
            candidates.append(URL(fileURLWithPath: path).appendingPathComponent("codex").path)
        }
        var visited = Set<String>()
        for path in candidates where visited.insert(path).inserted && executable(path) {
            return URL(fileURLWithPath: path)
        }
        throw CodexClientError.executableNotFound
    }
}
