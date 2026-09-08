import Foundation

struct MessageMathFragment {
    let source: String
    let latex: String
    let display: Bool
}

struct MessageMathTokenization {
    let markdown: String
    let fragments: [String: MessageMathFragment]
}

/// Protects complete LaTeX expressions before Markdown consumes their backslashes.
/// Unfinished streaming input and unusually large expressions remain ordinary text.
enum MessageMathTokenizer {
    private static let maximumInputBytes = 1_048_576
    private static let maximumExpressionLength = 16_384
    private static let maximumFragments = 256

    static func tokenize(_ source: String) -> MessageMathTokenization {
        guard source.utf8.count <= maximumInputBytes else {
            return MessageMathTokenization(markdown: source, fragments: [:])
        }
        let characters = Array(source)
        guard !characters.isEmpty else {
            return MessageMathTokenization(markdown: source, fragments: [:])
        }
        let escaped = escapedCharacters(characters)
        let protected = protectedCharacters(characters, escaped: escaped)
        var pieces: [String] = []
        var fragments: [String: MessageMathFragment] = [:]
        var unchangedStart = 0
        var index = 0
        // Adversarial streams containing thousands of unmatched openers cannot
        // force quadratic searches. Once exhausted, the remaining text is literal.
        var searchBudget = min(4_194_304, max(1_024, characters.count * 8))
        var markerPrefix = "\u{E000}BAVMATH"
        if source.contains(markerPrefix) {
            markerPrefix.append(UUID().uuidString)
            guard !source.contains(markerPrefix) else {
                return MessageMathTokenization(markdown: source, fragments: [:])
            }
        }

        while index < characters.count, fragments.count < maximumFragments, searchBudget > 0 {
            guard !protected[index], !escaped[index] else {
                index += 1
                continue
            }
            let opener: String
            let closer: String
            let display: Bool
            if matches("\\(", at: index, in: characters) {
                opener = "\\("
                closer = "\\)"
                display = false
            } else if matches("\\[", at: index, in: characters) {
                opener = "\\["
                closer = "\\]"
                display = true
            } else if matches("$$", at: index, in: characters),
                      (index == 0 || characters[index - 1] != "$"),
                      (index + 2 == characters.count || characters[index + 2] != "$") {
                opener = "$$"
                closer = "$$"
                display = true
            } else if characters[index] == "$", isSingleDollarOpener(index, in: characters) {
                opener = "$"
                closer = "$"
                display = false
            } else {
                index += 1
                continue
            }
            let contentStart = index + opener.count
            guard let close = closingDelimiter(closer, from: contentStart,
                                               characters: characters, protected: protected, escaped: escaped,
                                               budget: &searchBudget) else {
                index += opener.count
                continue
            }
            let end = close + closer.count
            let latex = String(characters[contentStart..<close])
            guard !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                index = end
                continue
            }
            let marker = "\(markerPrefix)\(fragments.count)\u{E001}"
            pieces.append(String(characters[unchangedStart..<index]))
            pieces.append(display ? "\n\n\(marker)\n\n" : marker)
            fragments[marker] = MessageMathFragment(source: String(characters[index..<end]),
                                                   latex: latex, display: display)
            unchangedStart = end
            index = end
        }
        pieces.append(String(characters[unchangedStart...]))
        return MessageMathTokenization(markdown: pieces.joined(), fragments: fragments)
    }

    private static func closingDelimiter(_ delimiter: String, from start: Int,
                                         characters: [Character], protected: [Bool], escaped: [Bool],
                                         budget: inout Int) -> Int? {
        let limit = min(characters.count, start + maximumExpressionLength)
        var index = start
        while index < limit, budget > 0 {
            budget -= 1
            guard !protected[index] else { return nil }
            if matches(delimiter, at: index, in: characters), !escaped[index] {
                if delimiter == "$" {
                    // Never cross a different dollar delimiter or interpret a
                    // price range such as "$5–$10" as mathematical notation.
                    guard index > start, !characters[index - 1].isWhitespace,
                          (index + 1 == characters.count ||
                           (!characters[index + 1].isNumber && characters[index + 1] != "$"))
                    else { return nil }
                } else if delimiter == "$$" {
                    guard (index == 0 || characters[index - 1] != "$"),
                          (index + 2 == characters.count || characters[index + 2] != "$")
                    else { return nil }
                }
                // All characters of a multi-character delimiter must be outside
                // Markdown code/destinations too.
                guard !(index..<(index + delimiter.count)).contains(where: { protected[$0] }) else {
                    return nil
                }
                return index
            }
            // Single-dollar math is inline; a new paragraph is never its end.
            if delimiter == "$", characters[index].isNewline { return nil }
            index += 1
        }
        return nil
    }

    private static func isSingleDollarOpener(_ index: Int, in characters: [Character]) -> Bool {
        guard index + 1 < characters.count,
              characters[index + 1] != "$", !characters[index + 1].isWhitespace else { return false }
        if index > 0 {
            let previous = characters[index - 1]
            if previous == "$" || previous.isLetter || previous.isNumber { return false }
        }
        return true
    }

    private static func matches(_ text: String, at index: Int, in characters: [Character]) -> Bool {
        let pattern = Array(text)
        guard index + pattern.count <= characters.count else { return false }
        return pattern.indices.allSatisfy { characters[index + $0] == pattern[$0] }
    }

    private static func escapedCharacters(_ characters: [Character]) -> [Bool] {
        var result = [Bool](repeating: false, count: characters.count)
        var previousSlashEscapes = false
        for index in characters.indices {
            result[index] = previousSlashEscapes
            previousSlashEscapes = characters[index] == "\\" && !previousSlashEscapes
        }
        return result
    }

    private static func protectedCharacters(_ characters: [Character], escaped: [Bool]) -> [Bool] {
        var protected = [Bool](repeating: false, count: characters.count)
        func protect(_ range: Range<Int>) {
            for index in range { protected[index] = true }
        }
        var lineStart = 0
        var fence: (character: Character, length: Int)?
        while lineStart < characters.count {
            var lineEnd = lineStart
            while lineEnd < characters.count, !characters[lineEnd].isNewline { lineEnd += 1 }
            let endIncludingNewline = min(characters.count, lineEnd + 1)
            var contentStart = lineStart
            while contentStart < lineEnd, characters[contentStart] == " " { contentStart += 1 }
            var indent = contentStart - lineStart
            // Fenced code may itself live in a quote/list. Strip only their
            // structural prefix for recognizing fences; the original text stays intact.
            while indent <= 3, contentStart < lineEnd, characters[contentStart] == ">" {
                contentStart += 1
                if contentStart < lineEnd, characters[contentStart] == " " { contentStart += 1 }
                let start = contentStart
                while contentStart < lineEnd, characters[contentStart] == " " { contentStart += 1 }
                indent = contentStart - start
            }
            var fenceStart = contentStart
            if indent <= 3, fenceStart + 1 < lineEnd {
                var markerEnd = fenceStart
                if ["-", "+", "*"].contains(characters[fenceStart]) {
                    markerEnd += 1
                } else {
                    while markerEnd < lineEnd, characters[markerEnd].isNumber,
                          markerEnd - fenceStart < 9 { markerEnd += 1 }
                    if markerEnd > fenceStart, markerEnd < lineEnd,
                       characters[markerEnd] == "." || characters[markerEnd] == ")" { markerEnd += 1 }
                    else { markerEnd = fenceStart }
                }
                if markerEnd > fenceStart, markerEnd < lineEnd, characters[markerEnd] == " " {
                    fenceStart = markerEnd + 1
                    while fenceStart < lineEnd, characters[fenceStart] == " ",
                          fenceStart - markerEnd <= 3 { fenceStart += 1 }
                }
            }
            var fenceLength = 0
            if fenceStart < lineEnd, characters[fenceStart] == "`" || characters[fenceStart] == "~" {
                let character = characters[fenceStart]
                while fenceStart + fenceLength < lineEnd,
                      characters[fenceStart + fenceLength] == character { fenceLength += 1 }
            }
            if let open = fence {
                protect(lineStart..<endIncludingNewline)
                if indent <= 3, fenceLength >= open.length, characters[fenceStart] == open.character,
                   characters[(fenceStart + fenceLength)..<lineEnd].allSatisfy({ $0.isWhitespace }) {
                    fence = nil
                }
            } else if indent <= 3, fenceLength >= 3,
                      (characters[fenceStart] != "`" ||
                       !characters[(fenceStart + fenceLength)..<lineEnd].contains("`")) {
                fence = (characters[fenceStart], fenceLength)
                protect(lineStart..<endIncludingNewline)
            } else if indent >= 4 || (contentStart < lineEnd && characters[contentStart] == "\t") {
                protect(lineStart..<endIncludingNewline)
            } else if contentStart < lineEnd, characters[contentStart] == "[" {
                // Reference-definition destinations may contain dollar signs.
                var cursor = contentStart + 1
                while cursor + 1 < lineEnd {
                    if characters[cursor] == "]", characters[cursor + 1] == ":",
                       !escaped[cursor] {
                        protect(lineStart..<endIncludingNewline)
                        break
                    }
                    cursor += 1
                }
            }
            lineStart = endIncludingNewline
        }

        var index = 0
        var autolinkBudget = min(4_194_304, max(1_024, characters.count * 8))
        while index < characters.count {
            guard !protected[index], !escaped[index] else { index += 1; continue }
            if characters[index] == "`" {
                var length = 1
                while index + length < characters.count, characters[index + length] == "`" { length += 1 }
                var cursor = index + length
                var end = characters.count
                while cursor < characters.count {
                    if protected[cursor] { end = cursor; break }
                    if characters[cursor] == "`" {
                        var closeLength = 1
                        while cursor + closeLength < characters.count,
                              characters[cursor + closeLength] == "`" { closeLength += 1 }
                        if closeLength == length { end = cursor + length; break }
                        cursor += closeLength
                    } else { cursor += 1 }
                }
                protect(index..<end)
                index = end
            } else if matches("](", at: index, in: characters) {
                var cursor = index + 2
                var depth = 1
                while cursor < characters.count {
                    if protected[cursor] || characters[cursor].isNewline { break }
                    if !escaped[cursor] {
                        if characters[cursor] == "(" { depth += 1 }
                        if characters[cursor] == ")" { depth -= 1 }
                    }
                    cursor += 1
                    if depth == 0 { break }
                }
                protect(index..<cursor)
                index = cursor
            } else if characters[index] == "<", index + 1 < characters.count,
                      characters[index + 1].isLetter {
                // Protect actual autolink destinations, not mathematical less-than
                // comparisons. A bounded lookahead also handles incomplete input.
                var cursor = index + 1
                let limit = min(characters.count, index + 2_048)
                while cursor < limit, characters[cursor] != ">", !characters[cursor].isWhitespace,
                      autolinkBudget > 0 {
                    autolinkBudget -= 1
                    cursor += 1
                }
                if autolinkBudget == 0 {
                    protect(index..<characters.count)
                    break
                }
                let destination = String(characters[(index + 1)..<cursor])
                if cursor < characters.count, characters[cursor] == ">",
                   destination.contains(":") || destination.contains("@") {
                    protect(index..<(cursor + 1))
                    index = cursor + 1
                } else { index += 1 }
            } else { index += 1 }
        }
        return protected
    }

    /// Pure, deterministic checks also used by the application's rendering check.
    static func selfCheckFailures() -> [String] {
        var failures: [String] = []
        func expect(_ name: String, _ source: String, count: Int, display: Int = 0) {
            let result = tokenize(source)
            if result.fragments.count != count || result.fragments.values.filter({ $0.display }).count != display {
                failures.append(name)
            }
            // Replacing markers with their source must preserve all literal text;
            // block expressions deliberately add paragraph breaks.
            if count == 0, result.markdown != source { failures.append("\(name): literal text changed") }
        }
        expect("explicit inline", #"Area \(a^2 + b^2\)."#, count: 1)
        expect("display multiline", "Before\\[\\frac{1}{2}\n+ x\\]after", count: 1, display: 1)
        expect("dollar forms", "$x^2$ and $$\\int_0^1 x\\,dx$$", count: 2, display: 1)
        expect("currency", "Costs $5 and $10; range $5–$10, USD$20.", count: 0)
        expect("escaped dollars", #"\$5 plus \$x\$; \(x\)"#, count: 1)
        expect("escaped explicit opener", #"\\(x\\) and \\[x\\]"#, count: 0)
        expect("unclosed", #"Pending \(x + and \[y + $$z + $w"#, count: 0)
        expect("backticks", #"`$x$` and ``\(y\) ` z`` then $z$"#, count: 1)
        expect("unfinished code", #"`code $x$"#, count: 0)
        expect("fences", "```latex\n$$x$$\n```\n~~~\n\\(y\\)\n~~~\n$z$", count: 1)
        expect("Windows line endings", "```\r\n$x$\r\n```\r\n$y$", count: 1)
        expect("quoted fence", "> ~~~latex\n> $x$\n> ~~~\n$y$", count: 1)
        expect("list fence", "- ~~~latex\n  $x$\n  ~~~\n$y$", count: 1)
        expect("indented code", "    $x$\n\t\\(y\\)\n$z$", count: 1)
        expect("link destinations", #"[a](https://a.test/$x$) ![b](image/\(y\)) <https://a.test/$z$> $w$"#, count: 1)
        expect("comparison symbols", #"\(x<y>z\)"#, count: 1)
        expect("reference destinations", "[a]: https://a.test/$x$\n$y$", count: 1)
        expect("single dollar newline", "$x\ny$", count: 0)
        expect("math cannot consume code", #"\(x `code` y\)"#, count: 0)
        expect("empty delimiters", #"\(\) \[ \] $$ $$"#, count: 0)
        expect("oversized input", String(repeating: "x", count: maximumInputBytes + 1) + "$x$", count: 0)
        let collision = tokenize("\u{E000}BAVMATH0\u{E001} $x$")
        if collision.fragments.keys.contains("\u{E000}BAVMATH0\u{E001}") { failures.append("marker collision") }
        let display = tokenize(#"before \[x\] after"#)
        if let marker = display.fragments.keys.first,
           !display.markdown.contains("\n\n\(marker)\n\n") { failures.append("display paragraph") }
        return failures
    }
}
