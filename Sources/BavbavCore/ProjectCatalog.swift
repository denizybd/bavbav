import Foundation

public enum ProjectCatalog {
    public static func loadSavedProjects(codexHome: String? = nil) -> [CodexProject] {
        let home = codexHome ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex").path
        let stateURL = URL(fileURLWithPath: home)
            .appendingPathComponent(".codex-global-state.json")

        guard
            let data = try? Data(contentsOf: stateURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawProjects = root["local-projects"] as? [String: Any]
        else {
            return []
        }

        var projectsByID: [String: CodexProject] = [:]
        for (fallbackID, rawValue) in rawProjects {
            guard let value = rawValue as? [String: Any] else { continue }
            let id = value["id"] as? String ?? fallbackID
            let name = value["name"] as? String ?? "Untitled"
            guard let path = (value["rootPaths"] as? [String])?.first else { continue }
            projectsByID[id] = CodexProject(id: id, name: name, path: canonicalPath(path))
        }

        let preferredOrder = root["project-order"] as? [String] ?? []
        var output: [CodexProject] = preferredOrder.compactMap { projectsByID.removeValue(forKey: $0) }
        output.append(contentsOf: projectsByID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        })
        return output
    }

    public static func mergeProjects(
        saved: [CodexProject],
        threads: [CodexThread]
    ) -> [CodexProject] {
        var byPath = Dictionary(uniqueKeysWithValues: saved.map { (canonicalPath($0.path), $0) })

        for thread in threads {
            let path = canonicalPath(thread.cwd)
            if var existing = byPath[path] {
                existing.chatCount += 1
                byPath[path] = existing
            } else {
                let url = URL(fileURLWithPath: path)
                let name = url.lastPathComponent.isEmpty ? path : url.lastPathComponent
                byPath[path] = CodexProject(
                    id: thread.projectID ?? "cwd:\(path)",
                    name: name,
                    path: path,
                    chatCount: 1
                )
            }
        }

        var result: [CodexProject] = []
        var consumed = Set<String>()
        for project in saved {
            let path = canonicalPath(project.path)
            if let merged = byPath[path] {
                result.append(merged)
                consumed.insert(path)
            }
        }
        result.append(contentsOf: byPath
            .filter { !consumed.contains($0.key) }
            .map(\.value)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        return result
    }

    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
