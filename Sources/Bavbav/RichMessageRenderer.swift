import AppKit
import Markdown

extension NSAttributedString.Key {
    static let messageCopyReplacement = NSAttributedString.Key("BavbavCopyReplacement")
}

struct MessageCodeBlock {
    let range: NSRange
    let headerRange: NSRange
    let code: String
}

final class RenderedMessage {
    let text: NSAttributedString
    let codeBlocks: [MessageCodeBlock]
    init(text: NSAttributedString, codeBlocks: [MessageCodeBlock]) {
        self.text = text
        self.codeBlocks = codeBlocks
    }

    func copyText(in requested: NSRange) -> String {
        let range = NSIntersectionRange(requested, NSRange(location: 0, length: text.length))
        var result = ""
        text.enumerateAttribute(.messageCopyReplacement, in: range) { replacement, run, _ in
            result += replacement as? String ?? (text.string as NSString).substring(with: run)
        }
        return result
    }

    /// Work on a copy: cached documents and their table blocks are shared.
    func textWithBackgroundOpacity(_ opacity: Double) -> NSAttributedString {
        guard opacity < 1 else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        let contrast = ForegroundContrast.strength(backgroundOpacity: opacity)
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            if contrast > 0 {
                if let color = attributes[.foregroundColor] as? NSColor {
                    result.addAttribute(.foregroundColor, value: ForegroundContrast.color(color, strength: contrast), range: range)
                }
                result.addAttributes(ForegroundContrast.attributes(strength: contrast), range: range)
            }
            if let color = attributes[.backgroundColor] as? NSColor {
                result.addAttribute(.backgroundColor, value: color.withAlphaComponent(color.alphaComponent * opacity), range: range)
            }
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle, !style.textBlocks.isEmpty,
               let copy = style.mutableCopy() as? NSMutableParagraphStyle {
                copy.textBlocks = style.textBlocks.map { block in
                    guard let cloned = block.copy() as? NSTextBlock else { return block }
                    if let color = block.backgroundColor {
                        cloned.backgroundColor = color.withAlphaComponent(color.alphaComponent * opacity)
                    }
                    return cloned
                }
                result.addAttribute(.paragraphStyle, value: copy, range: range)
            }
        }
        return result
    }
}

enum MessageLinkPolicy {
    static func destination(_ raw: String) -> URL? {
        guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        guard !(raw.removingPercentEncoding ?? raw).unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else { return nil }
        if raw.hasPrefix("/"), !raw.hasPrefix("//") {
            // Codex local references often carry a :line suffix. Reveal these
            // in Finder on click; never execute a linked local app/script.
            let path = raw.replacingOccurrences(of: #"(?::\d+(?::\d+)?|#L\d+(?:C\d+)?(?:-L?\d+(?:C\d+)?)?)$"#, with: "", options: .regularExpression)
            return URL(fileURLWithPath: path.removingPercentEncoding ?? path)
        }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "file":
            // Local file URLs are reveal-only, never sent to Workspace.open.
            guard url.host == nil || url.host == "" || url.host == "localhost",
                  url.query == nil else { return nil }
            let path = url.path.replacingOccurrences(of: #":\d+(?::\d+)?$"#, with: "", options: .regularExpression)
            guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return URL(fileURLWithPath: path)
        case "http", "https": return url.host?.isEmpty == false ? url : nil
        case "mailto": return url.path.contains("@") ? url : nil
        default: return nil
        }
    }

    static func open(_ url: URL) {
        guard let allowed = destination(url.absoluteString) else { return }
        if allowed.isFileURL {
            guard FileManager.default.fileExists(atPath: allowed.path) else {
                showOpenFailure("Dosya artık bu konumda bulunmuyor:\n\(allowed.path)")
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([allowed])
        } else if !NSWorkspace.shared.open(allowed) {
            showOpenFailure("Bu bağlantıyı açabilecek bir uygulama bulunamadı:\n\(allowed.absoluteString)")
        }
    }

    private static func showOpenFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Bağlantı açılamadı"
        alert.informativeText = message
        alert.addButton(withTitle: "Tamam")
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}

/// GFM is parsed as data and drawn by TextKit. No HTML import, script execution,
/// remote image fetching or per-message browser process is involved.
@MainActor
final class RichMessageRenderer {
    static let textColor = NSColor(calibratedRed: 0.847, green: 0.875, blue: 0.914, alpha: 1)
    static let mutedColor = NSColor(calibratedRed: 0.470, green: 0.510, blue: 0.565, alpha: 1)
    static let linkColor = NSColor(calibratedRed: 0.310, green: 0.745, blue: 0.875, alpha: 1)
    static let codeColor = NSColor(calibratedRed: 0.043, green: 0.051, blue: 0.063, alpha: 1)
    private static let cache: NSCache<NSString, RenderedMessage> = {
        let cache = NSCache<NSString, RenderedMessage>()
        cache.countLimit = 80
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()

    static func render(_ source: String, fontSize: CGFloat, width: CGFloat, markdown: Bool) -> RenderedMessage {
        let width = max(80, floor(width))
        let key = "\(fontSize)|\(width)|\(markdown)|\(source)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let renderer = RichMessageRenderer(fontSize: fontSize, width: width)
        if markdown && source.utf8.count <= 256 * 1024 {
            let tokenization = MessageMathTokenizer.tokenize(source)
            renderer.fragments = tokenization.fragments
            let document = Document(parsing: tokenization.markdown)
            renderer.blocks(document.children)
        } else {
            renderer.append(source, [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)])
        }
        let result = RenderedMessage(text: NSAttributedString(attributedString: renderer.output),
                                     codeBlocks: renderer.codeBlocks)
        cache.setObject(result, forKey: key, cost: source.utf8.count * 2 + result.text.length * 16)
        return result
    }

    private let fontSize: CGFloat
    private let width: CGFloat
    private let output = NSMutableAttributedString(string: "")
    private var fragments: [String: MessageMathFragment] = [:]
    private var codeBlocks: [MessageCodeBlock] = []
    private var depth = 0
    private var inlineDepth = 0

    private init(fontSize: CGFloat, width: CGFloat) {
        self.fontSize = fontSize
        self.width = width
    }

    private func paragraph(indent: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 7
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        return style
    }

    private func append(_ string: String, _ attributes: [NSAttributedString.Key: Any] = [:]) {
        var base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: Self.textColor,
            .paragraphStyle: paragraph(indent: CGFloat(depth) * 16)
        ]
        base.merge(attributes) { _, rhs in rhs }
        output.append(NSAttributedString(string: string, attributes: base))
    }

    private func blocks(_ children: MarkupChildren, prefix: String? = nil) {
        for (index, child) in children.enumerated() {
            block(child, prefix: index == 0 ? prefix : nil)
        }
    }

    private func listItem(_ item: ListItem, prefix: String) {
        for (index, child) in item.children.enumerated() {
            let nested = child is OrderedList || child is UnorderedList
            if nested { depth += 1 }
            block(child, prefix: index == 0 ? prefix : nil)
            if nested { depth -= 1 }
        }
    }

    private func block(_ markup: Markup, prefix: String? = nil) {
        guard depth < 32 else {
            append(restoringMathSource((markup as? PlainTextConvertibleMarkup)?.plainText ?? markup.format()))
            append("\n")
            return
        }
        switch markup {
        case let heading as Heading:
            let start = output.length
            inlines(heading.children, attributes: [.font: NSFont.systemFont(ofSize: fontSize + CGFloat(max(1, 5 - heading.level)) * 1.6, weight: .semibold)])
            append("\n")
            let style = paragraph(indent: CGFloat(depth) * 16)
            style.paragraphSpacingBefore = 5
            style.paragraphSpacing = 9
            output.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: output.length - start))
        case let para as Paragraph:
            let start = output.length
            if let prefix { append(prefix) }
            inlines(para.children)
            append("\n")
            if prefix != nil {
                let style = paragraph(indent: CGFloat(depth) * 16 + 18)
                style.firstLineHeadIndent = CGFloat(depth) * 16
                output.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: output.length - start))
            }
        case let list as UnorderedList:
            for child in list.children {
                guard let item = child as? ListItem else { continue }
                let marker: String
                if let checkbox = item.checkbox { marker = checkbox == .checked ? "☑  " : "☐  " }
                else { marker = "•  " }
                listItem(item, prefix: marker)
            }
        case let list as OrderedList:
            for (index, child) in list.children.enumerated() {
                guard let item = child as? ListItem else { continue }
                listItem(item, prefix: "\(Int(list.startIndex) + index).  ")
            }
        case let quote as BlockQuote:
            let start = output.length
            depth += 1
            blocks(quote.children)
            depth -= 1
            let range = NSRange(location: start, length: output.length - start)
            output.addAttribute(.foregroundColor, value: Self.mutedColor, range: range)
        case let code as CodeBlock:
            renderCode(code)
        case let table as Markdown.Table:
            renderTable(table)
        case is ThematicBreak:
            append("────────────\n", [.foregroundColor: Self.mutedColor])
        case let html as HTMLBlock:
            append(restoringMathSource(html.rawHTML), [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)])
            append("\n")
        default:
            depth += 1
            blocks(markup.children, prefix: prefix)
            depth -= 1
        }
    }

    private func inlines(_ children: MarkupChildren, attributes: [NSAttributedString.Key: Any] = [:]) {
        for child in children { inline(child, attributes: attributes) }
    }

    private func inline(_ markup: Markup, attributes: [NSAttributedString.Key: Any]) {
        guard inlineDepth < 64 else { append(restoringMathSource(markup.format()), attributes); return }
        inlineDepth += 1
        defer { inlineDepth -= 1 }
        var attributes = attributes
        switch markup {
        case let text as Markdown.Text: appendTextAndMath(text.string, attributes: attributes)
        case let code as InlineCode:
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: fontSize - 0.5, weight: .regular)
            attributes[.backgroundColor] = Self.codeColor
            append(code.code, attributes)
        case let strong as Strong:
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: fontSize)
            attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            inlines(strong.children, attributes: attributes)
        case let emphasis as Emphasis:
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: fontSize)
            attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            inlines(emphasis.children, attributes: attributes)
        case let strike as Strikethrough:
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            inlines(strike.children, attributes: attributes)
        case let link as Markdown.Link:
            if let destination = link.destination, let url = MessageLinkPolicy.destination(destination) {
                attributes[.link] = url
                attributes[.foregroundColor] = Self.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            inlines(link.children, attributes: attributes)
        case let image as Markdown.Image:
            // Alt text stays selectable; external images are never fetched.
            append("[", attributes)
            inlines(image.children, attributes: attributes)
            append("]", attributes)
        case is SoftBreak: append("\n", attributes)
        case is LineBreak: append("\n", attributes)
        case let html as InlineHTML: append(restoringMathSource(html.rawHTML), attributes)
        default: inlines(markup.children, attributes: attributes)
        }
    }

    private func restoringMathSource(_ string: String) -> String {
        fragments.reduce(string) { result, fragment in
            result.replacingOccurrences(of: fragment.key, with: fragment.value.source)
        }
    }

    private func appendTextAndMath(_ string: String, attributes: [NSAttributedString.Key: Any]) {
        var remainder = string[...]
        while !remainder.isEmpty {
            let next = fragments.compactMap { key, value -> (Range<String.Index>, MessageMathFragment)? in
                remainder.range(of: key).map { ($0, value) }
            }.min { $0.0.lowerBound < $1.0.lowerBound }
            guard let (range, fragment) = next else { appendProse(String(remainder), attributes: attributes); break }
            appendProse(String(remainder[..<range.lowerBound]), attributes: attributes)
            let inheritedStyle = attributes[.paragraphStyle] as? NSParagraphStyle
            let columns = (inheritedStyle?.textBlocks.first as? NSTextTableBlock)?.table.numberOfColumns ?? 1
            let mathWidth = (width - CGFloat(depth) * 16) / CGFloat(columns) - 16
            if let attachment = MathAttachmentRenderer.attachment(latex: fragment.latex, display: fragment.display,
                    fontSize: fontSize + (fragment.display ? 4 : 1), maxWidth: mathWidth) {
                let rendered = NSMutableAttributedString(attachment: attachment)
                let style = inheritedStyle?.mutableCopy() as? NSMutableParagraphStyle ?? paragraph(indent: CGFloat(depth) * 16)
                if fragment.display && style.textBlocks.isEmpty {
                    style.alignment = .center
                    style.paragraphSpacingBefore = 7
                    style.paragraphSpacing = 10
                }
                var mathAttributes = attributes
                mathAttributes[.messageCopyReplacement] = fragment.source
                mathAttributes[.paragraphStyle] = style
                mathAttributes[.font] = attributes[.font] ?? NSFont.systemFont(ofSize: fontSize)
                rendered.addAttributes(mathAttributes,
                                       range: NSRange(location: 0, length: rendered.length))
                output.append(rendered)
            } else {
                append(fragment.source, attributes)
            }
            remainder = remainder[range.upperBound...]
        }
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private func appendProse(_ string: String, attributes: [NSAttributedString.Key: Any]) {
        let start = output.length
        append(string, attributes)
        guard attributes[.link] == nil else { return }
        Self.linkDetector?.enumerateMatches(in: string, range: NSRange(location: 0, length: (string as NSString).length)) { match, _, _ in
            guard let match, let raw = match.url?.absoluteString, let url = MessageLinkPolicy.destination(raw) else { return }
            output.addAttributes([.link: url, .foregroundColor: Self.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue],
                                 range: NSRange(location: start + match.range.location, length: match.range.length))
        }
    }

    private func renderCode(_ code: CodeBlock) {
        if output.length > 0 { append("\n") }
        let start = output.length
        let style = paragraph(indent: 12)
        style.tailIndent = -12
        style.paragraphSpacingBefore = 10
        style.paragraphSpacing = 8
        let language = String((code.language ?? "TEXT").prefix(30)).uppercased()
        append(language + "\n", [.font: NSFont.monospacedSystemFont(ofSize: 8, weight: .semibold),
                                  .foregroundColor: Self.mutedColor, .paragraphStyle: style,
                                  .messageCopyReplacement: ""])
        let header = NSRange(location: start, length: output.length - start)
        let body = paragraph(indent: 12)
        body.tailIndent = -12
        body.paragraphSpacing = 0
        body.lineSpacing = 2
        body.lineBreakMode = .byCharWrapping
        append(code.code.isEmpty ? "\n" : code.code,
               [.font: NSFont.monospacedSystemFont(ofSize: fontSize - 0.5, weight: .regular), .paragraphStyle: body])
        if !output.string.hasSuffix("\n") { append("\n", [.paragraphStyle: body]) }
        codeBlocks.append(MessageCodeBlock(range: NSRange(location: start, length: output.length - start),
                                           headerRange: header, code: code.code))
        append("\n")
    }

    private func renderTable(_ table: Markdown.Table) {
        guard table.maxColumnCount > 0, table.maxColumnCount <= 12, table.body.childCount < 250 else {
            append(restoringMathSource(table.format()), [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)])
            append("\n")
            return
        }
        let native = NSTextTable()
        native.numberOfColumns = table.maxColumnCount
        native.layoutAlgorithm = .fixedLayoutAlgorithm
        native.collapsesBorders = true
        native.setValue(width - 4, type: .absoluteValueType, for: .width)
        let rows: [Markup] = [table.head] + Array(table.body.children)
        for (row, element) in rows.enumerated() {
            for (column, cell) in element.children.enumerated() {
                let block = NSTextTableBlock(table: native, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setValue(100 / CGFloat(native.numberOfColumns), type: .percentageValueType, for: .width)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(NSColor(calibratedWhite: 0.23, alpha: 1))
                block.backgroundColor = row == 0 ? NSColor(calibratedWhite: 0.11, alpha: 1) : Self.codeColor
                let style = paragraph()
                style.paragraphSpacing = 0
                style.textBlocks = [block]
                if column < table.columnAlignments.count {
                    switch table.columnAlignments[column] {
                    case .center: style.alignment = .center
                    case .right: style.alignment = .right
                    default: break
                    }
                }
                let attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: style,
                    .font: NSFont.systemFont(ofSize: fontSize - 0.5, weight: row == 0 ? .semibold : .regular)]
                inlines(cell.children, attributes: attributes)
                var newline = attributes
                newline[.messageCopyReplacement] = column == native.numberOfColumns - 1 ? "\n" : "\t"
                append("\n", newline)
            }
        }
        append("\n")
    }
}
