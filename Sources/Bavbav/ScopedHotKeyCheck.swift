import AppKit

/// Pure registration-configuration checks; never instantiate HotKeyCenter or
/// register/inject a global shortcut during this diagnostic.
@MainActor enum ScopedHotKeyCheck {
    static func run() -> Bool {
        let definitions = ShortcutCatalog.all.filter(\.global)
        let full = HotKeyCenter.configuration([:])
        var assertions = 0
        func check(_ value: Bool, _ message: String) -> Bool {
            assertions += 1
            if !value { print("SCOPED HOTKEY CHECK FAILED: \(message)") }
            return value
        }
        guard let companionIndex = definitions.firstIndex(where: { $0.operation == "companion" }),
              let journalIndex = definitions.firstIndex(where: { $0.operation == "journal" }) else { return false }
        let companionNumber = companionIndex + 1
        let journalNumber = journalIndex + 1
        let companion = definitions[companionIndex]
        let journal = definitions[journalIndex]

        guard check(HotKeyCenter.configuration([:], onlyOperations: nil) == full, "nil preserves the complete registration set"),
              check(HotKeyCenter.configuration([:], onlyOperations: Set(definitions.map(\.operation))) == full,
                    "all operations preserve full configuration"),
              check(companionNumber == 6 && journalNumber == 5, "stable Companion 6 and calendar 5 event numbers"),
              check(HotKeyCenter.configuration([:], onlyOperations: ["companion"]) == [companionNumber: .init(22, .command)],
                    "Companion-only keeps Command 6 and excludes all coding/calendar registrations"),
              check(HotKeyCenter.configuration([:], onlyOperations: ["journal"]) == [journalNumber: .init(23, .command)],
                    "journal-only keeps its full-catalog number"),
              check(HotKeyCenter.configuration([:], onlyOperations: []) == [:], "empty filter registers nothing"),
              check(HotKeyCenter.configuration([:], onlyOperations: ["unknown"]) == [:], "unknown operation registers nothing"),
              check(HotKeyCenter.configuration([:], onlyOperations: ["preferences"]) == [:], "local operation cannot become global") else { return false }

        for (index, definition) in definitions.enumerated() {
            guard check(HotKeyCenter.configuration([:], onlyOperations: [definition.operation]) == [index + 1: full[index + 1]!],
                        "every single-operation scope retains its existing event number") else { return false }
        }
        let sparse = HotKeyCenter.configuration([:], onlyOperations: ["projects", "companion"])
        guard check(Set(sparse.keys) == [1, companionNumber], "sparse scopes never renumber retained operations") else { return false }

        let custom: ShortcutStroke = .init(22, [.command, .control])
        var overrides: [String: ShortcutBinding] = [companion.id: .init(strokes: [custom])]
        guard check(HotKeyCenter.configuration(overrides, onlyOperations: ["companion"]) == [companionNumber: custom],
                    "scope respects customized Companion shortcut") else { return false }
        var disabled = companion.defaultBinding; disabled.disabled = true
        overrides[companion.id] = disabled
        guard check(HotKeyCenter.configuration(overrides, onlyOperations: ["companion"]).isEmpty,
                    "disabled scoped shortcut remains disabled") else { return false }
        overrides[companion.id] = .init(strokes: [custom])
        var disabledJournal = journal.defaultBinding; disabledJournal.disabled = true
        overrides[journal.id] = disabledJournal
        guard check(HotKeyCenter.configuration(overrides, onlyOperations: ["companion"]) == [companionNumber: custom],
                    "disabled excluded operations cannot shift scoped event numbers"),
              check(HotKeyCenter.configuration(overrides)[companionNumber] == custom &&
                    HotKeyCenter.configuration(overrides)[journalNumber] == nil,
                    "unfiltered default behavior still applies all overrides") else { return false }
        print("SCOPED HOTKEY CHECK PASSED: \(assertions) assertions; configuration only, no Carbon registration or injected keys")
        return true
    }
}
