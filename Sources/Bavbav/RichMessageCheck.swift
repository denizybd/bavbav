import AppKit
import SwiftMath

/// Offline rendering regression checks. Never presents a window or changes focus.
@MainActor
enum RichMessageCheck {
    private static let fixture = #"""
    # Sade bir matematik notu

    **Kalın**, *italik* ve ~~eski~~ metin; satır içinde \(E=mc^2\).

    1. İlk adım: denklemi kur.
    2. İkinci adım: sonucu kontrol et.

    - Kesirler ve integraller
    - [Kaynağı aç](https://example.com/reference)

    > Önemli olan cevabın okunabilir ve seçilebilir kalması.

    \[\frac{-b+\sqrt{b^2-4ac}}{2a}\]

    \[\int_0^1 x^2\,dx=\frac{1}{3}\]

    \[A=\begin{pmatrix}1 & 2\\3 & 4\end{pmatrix}\]

    | Özellik | Durum |
    | :--- | ---: |
    | Matematik | Hazır |
    | Kopyalama | Hazır |

    ```prompt
    Bu denklemi adım adım açıkla.
    Sonucu kısa ve anlaşılır yaz.
    ```

    Son satır: `print("merhaba")`.
    """#

    static func run() -> Bool {
        var failures: [String] = []
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            if !condition() { failures.append(label) }
        }
        func render(_ source: String, width: CGFloat = 500, markdown: Bool = true) -> RenderedMessage {
            RichMessageRenderer.render(source, fontSize: 12, width: width, markdown: markdown)
        }
        func attributes(_ needle: String, in message: RenderedMessage) -> [NSAttributedString.Key: Any] {
            let range = (message.text.string as NSString).range(of: needle)
            guard range.location != NSNotFound else { return [:] }
            return message.text.attributes(at: range.location, effectiveRange: nil)
        }
        func attachments(_ message: RenderedMessage) -> [NSTextAttachment] {
            var result: [NSTextAttachment] = []
            message.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: message.text.length)) {
                attachment, _, _ in
                if let attachment = attachment as? NSTextAttachment { result.append(attachment) }
            }
            return result
        }

        let message = render(fixture)
        expect(message.text.length > 0, "fixture has visible content")
        expect(!message.text.string.contains("BAVMATH"), "math markers are never visible")
        expect((attributes("Sade bir matematik notu", in: message)[.font] as? NSFont)?.pointSize ?? 0 > 12,
               "heading uses larger font")
        if let bold = attributes("Kalın", in: message)[.font] as? NSFont {
            expect(NSFontManager.shared.traits(of: bold).contains(.boldFontMask), "strong text uses bold font")
        } else { failures.append("strong text font missing") }
        if let italic = attributes("italik", in: message)[.font] as? NSFont {
            expect(NSFontManager.shared.traits(of: italic).contains(.italicFontMask), "emphasis uses italic font")
        } else { failures.append("italic text font missing") }
        expect(attributes("eski", in: message)[.strikethroughStyle] != nil, "strikethrough decoration")
        expect(message.text.string.contains("1.  İlk") && message.text.string.contains("2.  İkinci"), "numbered list numbering")
        expect(message.text.string.contains("•  Kesirler"), "unordered list markers")
        expect((attributes("Özellik", in: message)[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first is NSTextTableBlock,
               "table uses native table cells")
        expect(attributes("Kaynağı aç", in: message)[.link] as? URL == URL(string: "https://example.com/reference"),
               "explicit link retains destination")
        expect(message.codeBlocks.count == 1, "prompt has one copyable block")
        expect(message.codeBlocks.first?.code == "Bu denklemi adım adım açıkla.\nSonucu kısa ve anlaşılır yaz.\n",
               "prompt copy preserves exact body")
        for block in message.codeBlocks {
            expect(NSMaxRange(block.range) <= message.text.length && NSMaxRange(block.headerRange) <= message.text.length,
                   "code block ranges are within rendered text")
        }

        let fullCopy = message.copyText(in: NSRange(location: 0, length: message.text.length))
        expect(!fullCopy.contains("\u{FFFC}") && !fullCopy.contains("BAVMATH"), "copy never contains attachment or placeholder characters")
        expect(fullCopy.contains(#"\(E=mc^2\)"#) && fullCopy.contains(#"\[\int_0^1 x^2\,dx=\frac{1}{3}\]"#),
               "copy restores original inline and display LaTeX")
        expect(fullCopy.contains("Özellik\tDurum"), "table copy separates columns")

        let formulas = [#"\frac{1}{2}"#, #"\int_0^1 x^2\,dx"#,
                        #"\begin{pmatrix}1&2\\3&4\end{pmatrix}"#]
        for formula in formulas {
            let rendered = render("\\[\(formula)\\]")
            let images = attachments(rendered)
            expect(images.count == 1, "renders formula: \(formula)")
            if let cell = images.first?.attachmentCell as? NSTextAttachmentCell {
                expect(cell.image?.representations.contains(where: { $0 is NSPDFImageRep }) == true,
                       "math is vector-backed PDF: \(formula)")
                expect(hasReadableMathInk(cell.image), "math rules and delimiters stay pale on dark backgrounds: \(formula)")
                expect(cell.cellSize().height > 10 && cell.cellSize().width > 0, "math has nonzero geometry")
                expect(cell.cellBaselineOffset().y < 0, "math includes descent baseline")
            }
        }
        let ruledFraction = MathAttachmentRenderer.attachment(latex: #"\frac{11111}{22222}"#,
                                                              display: true, fontSize: 18, maxWidth: 500)
        let fractionImage = (ruledFraction?.attachmentCell as? NSTextAttachmentCell)?.image
        expect(hasFractionRule(fractionImage), "fraction PDF includes a continuous horizontal rule, not just numerator and denominator glyphs")
        expect(attachments(message).count == 4, "fixture contains inline, fraction, integral and matrix")
        let mathTable = render(#"""
        | Formula | Link |
        |---|---|
        | \(x^2\) | [\(y^2\)](https://example.com) |
        """#, width: 320)
        var tableMathCount = 0
        mathTable.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: mathTable.text.length)) { value, range, _ in
            guard value is NSTextAttachment else { return }
            tableMathCount += 1
            let attributes = mathTable.text.attributes(at: range.location, effectiveRange: nil)
            expect((attributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first is NSTextTableBlock,
                   "table math retains native cell paragraph")
            if tableMathCount == 2 {
                expect(attributes[.link] as? URL == URL(string: "https://example.com"), "linked math retains clickable destination")
            }
        }
        expect(tableMathCount == 2, "both table math cells render")
        let narrowMathTable = render(#"""
        | Formula | Note |
        |---|---|
        | \(x_1+x_2+x_3+x_4+x_5+x_6+x_7\) | Small cell |
        """#, width: 320)
        for attachment in attachments(narrowMathTable) {
            expect(attachment.attachmentCell?.cellSize().width ?? .infinity <= (320 - 4) / 2 - 12,
                   "table math respects column width rather than whole message width")
        }
        for width in [CGFloat(320), CGFloat(700)] {
            for attachment in attachments(render(fixture, width: width)) {
                expect(attachment.attachmentCell?.cellSize().width ?? .infinity <= width,
                       "attachment fits message width \(width)")
            }
        }

        for invalid in [#"\frac{1}"#, #"\sqrt{"#, #"\unknowncommand{x}"#, "x^",
                        String(repeating: "{", count: 40) + "x" + String(repeating: "}", count: 40),
                        String(repeating: "x", count: 5000)] {
            expect(MathAttachmentRenderer.attachment(latex: invalid, display: true, fontSize: 12, maxWidth: 500) == nil,
                   "invalid/incomplete/oversized math has safe fallback")
        }
        expect(MathAttachmentRenderer.attachment(latex: "x", display: false, fontSize: .nan, maxWidth: 500) == nil,
               "invalid font size is rejected")
        expect(MathAttachmentRenderer.attachment(latex: "x", display: false, fontSize: 12, maxWidth: .infinity) == nil,
               "invalid width is rejected")

        for allowed in ["https://example.com", "http://example.com/a", "mailto:hello@example.com", "/tmp/example.swift:12", "file:///tmp/Run.app"] {
            expect(MessageLinkPolicy.destination(allowed) != nil, "safe link allowed: \(allowed)")
        }
        for blocked in ["javascript:alert(1)", "data:text/html,test", "file://remote/tmp/Run.app", "x-apple.systempreferences:test",
                        "//example.com", "https://example.com\nmalformed"] {
            expect(MessageLinkPolicy.destination(blocked) == nil, "unsafe link rejected: \(blocked)")
        }
        let hostile = render(#"[Bad](javascript:alert) [Safe](https://example.com) <script>alert('x')</script> ![remote](https://example.com/photo.png)"#)
        expect(attributes("Bad", in: hostile)[.link] == nil, "unsafe markdown link remains inert text")
        expect(attributes("Safe", in: hostile)[.link] != nil, "safe markdown link is clickable")
        expect(attachments(hostile).isEmpty, "remote images never create fetched attachments")
        let rawURL = render("Kaynak: https://example.com/reference")
        expect(attributes("https://example.com/reference", in: rawURL)[.link] as? URL == URL(string: "https://example.com/reference"),
               "ordinary raw URL is clickable")
        let codeURL = render("`https://example.com/reference`\n\n```text\nhttps://example.com/reference\n```\n")
        var codeLinkCount = 0
        codeURL.text.enumerateAttribute(.link, in: NSRange(location: 0, length: codeURL.text.length)) { value, _, _ in
            if value != nil { codeLinkCount += 1 }
        }
        expect(codeLinkCount == 0, "inline and fenced code URLs remain literal, nonclickable code")
        for (source, literalMath) in [("<div>\n\\(x^2\\)\n</div>", #"\(x^2\)"#),
                                     (#"<span title="$x$">hello</span>"#, "$x$")] {
            let html = render(source)
            expect(!html.text.string.contains("BAVMATH") && html.text.string.contains(literalMath),
                   "literal HTML never exposes math placeholders")
        }
        let oversizedTable = "| " + (1...13).map { "Column\($0)" }.joined(separator: " | ") + " |\n| " +
            Array(repeating: "---", count: 13).joined(separator: " | ") + " |\n| " +
            Array(repeating: #"\(x^2\)"#, count: 13).joined(separator: " | ") + " |"
        let tableFallback = render(oversizedTable)
        expect(!tableFallback.text.string.contains("BAVMATH") && tableFallback.text.string.contains(#"\(x^2\)"#),
               "wide-table literal fallback restores math source")

        let literal = "**TRACE**\n\\[x^2\\]\n```swift\nlet x = 1\n```\n"
        let trace = render(literal, markdown: false)
        expect(trace.text.string == literal, "TRACE remains byte-for-byte literal including trailing newline")
        expect(attachments(trace).isEmpty && trace.codeBlocks.isEmpty, "TRACE has no rich rendering")
        let finalCode = render("```swift\n  let x = 1\n\n```\n")
        expect(finalCode.codeBlocks.first?.code == "  let x = 1\n\n", "code preserves indentation and final blank lines")
        for block in finalCode.codeBlocks {
            expect(NSMaxRange(block.range) <= finalCode.text.length, "final code range remains valid after trimming")
        }
        for failure in MessageMathTokenizer.selfCheckFailures() { failures.append("tokenizer: \(failure)") }

        let stream = Array(#"""
        ## Yanıt

        Denklem \(\frac{x^2}{2}\) ve \[\int_0^1 x\,dx\].

        ```prompt
        Explain $x$ carefully.
        ```

        - [Kaynak](https://example.com)
        """#)
        for count in stride(from: 1, through: stream.count, by: 3) {
            let prefix = render(String(stream.prefix(count)))
            expect(!prefix.text.string.contains("BAVMATH"), "streaming prefix never leaks tokens at \(count)")
            expect(prefix.text.length < 10_000, "streaming prefix remains bounded at \(count)")
        }
        let large = String(repeating: "Literal **long** message.\n", count: 12_000)
        let largeRender = render(large)
        expect(largeRender.text.string == large, "oversized messages use complete literal fallback")
        if Bundle.main.bundleURL.pathExtension == "app" {
            let expected = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/SwiftMath_SwiftMath.bundle").standardizedFileURL
            expect(SwiftMathResourceLocation.bundleURL.standardizedFileURL == expected,
                   "packaged app loads bundled math resources, never development build fallback")
        }

        runNativeViewChecks(failures: &failures)
        let contrastText = message.textWithBackgroundOpacity(0)
        expect(RichMessageRenderer.textColor.alphaComponent == 1, "message text is fully opaque")
        expect(ForegroundContrast.strength(backgroundOpacity: 1) == 0, "opaque theme has no added contrast")
        expect(ForegroundContrast.strength(backgroundOpacity: 0) == 1, "fully transparent theme has maximum contrast")
        expect(contrastText.string == message.text.string, "contrast does not modify message text")
        var shadowCount = 0
        contrastText.enumerateAttributes(in: NSRange(location: 0, length: contrastText.length)) { attrs, _, _ in
            if let color = attrs[.foregroundColor] as? NSColor {
                expect(color.alphaComponent == 1, "transparent-mode foreground is opaque")
            }
            if attrs[.shadow] is NSShadow { shadowCount += 1 }
        }
        expect(shadowCount > 0, "transparent-mode glyphs have a dark halo")
        expect(message.textWithBackgroundOpacity(1).isEqual(to: message.text), "returning to opaque theme restores cached styling")
        let contrastView = RichMessageTextView()
        contrastView.configure(text: fixture, fontSize: 12, markdown: true)
        let originalSize = contrastView.fittingSize(width: 500)
        let layoutCount = contrastView.fittingLayoutCount
        for index in 0..<100 {
            let size = contrastView.fittingSize(width: 500 + CGFloat(index % 9) / 10)
            expect(size.height == originalSize.height, "fractional width probes keep stable text height")
        }
        expect(contrastView.fittingLayoutCount == layoutCount, "unchanged messages reuse TextKit measurement while scrolling")
        _ = contrastView.fittingSize(width: 320)
        expect(contrastView.fittingLayoutCount == layoutCount + 1, "real width change recomputes measurement")
        _ = contrastView.fittingSize(width: 500)
        contrastView.configure(text: fixture + "\nNew streamed text", fontSize: 12, markdown: true)
        _ = contrastView.fittingSize(width: 500)
        expect(contrastView.fittingLayoutCount == layoutCount + 3, "streamed text invalidates cached height")
        contrastView.configure(text: fixture, fontSize: 12, markdown: true)
        _ = contrastView.fittingSize(width: 500)
        contrastView.setSelectedRange(NSRange(location: 2, length: 8))
        for opacity in [0.0, 0.5, 1.0, 0.0] {
            contrastView.setBackgroundOpacity(opacity)
            expect(contrastView.selectedRange() == NSRange(location: 2, length: 8), "contrast preserves native selection")
            expect(contrastView.fittingSize(width: 500) == originalSize, "contrast preserves text layout")
        }
        if let directory = ProcessInfo.processInfo.environment["BAVBAV_RICH_MESSAGE_SNAPSHOT_DIR"], !directory.isEmpty {
            do {
                try snapshot(in: directory, width: 700); try snapshot(in: directory, width: 320)
                try snapshot(in: directory, width: 700, contrast: true, light: true)
                try snapshot(in: directory, width: 700, contrast: true, light: false)
            }
            catch { failures.append("snapshot: \(error.localizedDescription)") }
        }
        if failures.isEmpty {
            print("BAVBAV RICH MESSAGE CHECK PASSED: \(checks) assertions; native Markdown, vector math, exact copy, safe links, streaming and layout")
            return true
        }
        for failure in failures { fputs("RICH MESSAGE CHECK FAILED: \(failure)\n", stderr) }
        return false
    }

    private static func runNativeViewChecks(failures: inout [String]) {
        let view = RichMessageTextView()
        view.frame = NSRect(x: 0, y: 0, width: 500, height: 100)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        if !window.makeFirstResponder(view) || window.firstResponder !== view {
            failures.append("hidden native test window cannot focus message")
        }
        view.configure(text: fixture, fontSize: 12, markdown: true)
        if view.string.isEmpty || view.textStorage == nil { failures.append("native text system retains nonempty message storage") }
        let wide = view.fittingSize(width: 700)
        let narrow = view.fittingSize(width: 320)
        if !wide.height.isFinite || !narrow.height.isFinite || narrow.height < wide.height {
            failures.append("native layout has invalid width-dependent height")
        }
        let board = NSPasteboard(name: .init("BavbavRichMessageCheck-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        view.copyCodeBlock(at: 0, to: board)
        if board.string(forType: .string) != "Bu denklemi adım adım açıkla.\nSonucu kısa ve anlaşılır yaz.\n" {
            failures.append("native code copy action loses exact prompt body")
        }

        let general = NSPasteboard.general
        let saved = (general.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { general.clearContents(); general.writeObjects(saved) }
        view.selectAll(nil)
        if view.selectedRange() != NSRange(location: 0, length: view.string.utf16.count) {
            failures.append("native Cmd+A does not select the whole message")
        }
        view.copy(nil)
        if general.string(forType: .string)?.contains(#"\(E=mc^2\)"#) != true ||
           general.string(forType: .string)?.contains("\u{FFFC}") == true {
            failures.append("native selected copy loses original math source")
        }
        let before = view.string
        view.configure(text: fixture, fontSize: 12, markdown: true)
        if before != view.string || view.selectedRange().length != view.string.utf16.count {
            failures.append("unchanged view update resets message selection")
        }
        view.configure(text: fixture + "\n\nYeni gelen satır.", fontSize: 12, markdown: true)
        if view.string != before { failures.append("streaming mutates currently selected message text") }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view))
        if !view.string.contains("Yeni gelen satır.") {
            failures.append("streaming content does not flush when selection is cleared")
        }
        view.selectAll(nil)
        let selectedBeforeFocusChange = view.string
        view.configure(text: fixture + "\n\nYazma alanına geçerken gelen satır.", fontSize: 12, markdown: true)
        if view.string != selectedBeforeFocusChange {
            failures.append("pending source changes actively selected message before focus transfer")
        }
        let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        view.addSubview(composer)
        if !window.makeFirstResponder(composer) || window.firstResponder !== composer {
            failures.append("hidden test composer cannot become first responder")
        }
        if !view.string.contains("Yazma alanına geçerken gelen satır.") {
            failures.append("pending response does not flush when focus moves to composer")
        }
        view.configure(text: fixture + "\n\nOdak dışındayken gelen satır.", fontSize: 12, markdown: true)
        if !view.string.contains("Odak dışındayken gelen satır.") {
            failures.append("inactive message selection freezes subsequent streaming response")
        }
    }

    private static func hasReadableMathInk(_ image: NSImage?) -> Bool {
        guard let pdf = image?.representations.first(where: { $0 is NSPDFImageRep }) as? NSPDFImageRep,
              let provider = CGDataProvider(data: pdf.pdfRepresentation as CFData),
              let document = CGPDFDocument(provider), let page = document.page(at: 1) else { return false }
        let box = page.getBoxRect(.mediaBox)
        let width = max(1, Int(ceil(box.width * 2)))
        let height = max(1, Int(ceil(box.height * 2)))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.scaleBy(x: 2, y: 2)
            context.drawPDFPage(page)
            let bytes = buffer.bindMemory(to: UInt8.self)
            var opaqueInk = 0
            for index in stride(from: 0, to: bytes.count, by: 4) where bytes[index + 3] > 220 {
                opaqueInk += 1
                if max(bytes[index], bytes[index + 1], bytes[index + 2]) < 128 { return false }
            }
            return opaqueInk > 0
        }
    }

    /// A row of separated digits cannot satisfy this: the bar must be one
    /// uninterrupted pale run covering at least 70% of the entire formula.
    private static func hasFractionRule(_ image: NSImage?) -> Bool {
        guard let pdf = image?.representations.first(where: { $0 is NSPDFImageRep }) as? NSPDFImageRep,
              let provider = CGDataProvider(data: pdf.pdfRepresentation as CFData),
              let document = CGPDFDocument(provider), let page = document.page(at: 1) else { return false }
        let box = page.getBoxRect(.mediaBox)
        let width = max(1, Int(ceil(box.width * 2)))
        let height = max(1, Int(ceil(box.height * 2)))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.scaleBy(x: 2, y: 2)
            context.drawPDFPage(page)
            let bytes = buffer.bindMemory(to: UInt8.self)
            let requiredLength = Int(ceil(Double(width) * 0.70))
            for row in 0..<height {
                var contiguousLength = 0
                for column in 0..<width {
                    let index = (row * width + column) * 4
                    let alpha = Int(bytes[index + 3])
                    let brightest = Int(max(bytes[index], bytes[index + 1], bytes[index + 2]))
                    // Include antialiased edges while rejecting black strokes.
                    if alpha >= 64 && brightest * 100 >= alpha * 65 {
                        contiguousLength += 1
                        if contiguousLength >= requiredLength { return true }
                    } else {
                        contiguousLength = 0
                    }
                }
            }
            return false
        }
    }

    private static func snapshot(in directory: String, width: CGFloat, contrast: Bool = false, light: Bool = false) throws {
        let view = RichMessageTextView()
        view.frame = NSRect(x: 24, y: 24, width: width, height: 100)
        view.configure(text: fixture, fontSize: 14, markdown: true)
        if contrast { view.setBackgroundOpacity(0) }
        view.setFrameSize(view.fittingSize(width: width))
        let canvas = SnapshotBackground(frame: NSRect(x: 0, y: 0, width: width + 48, height: view.frame.height + 48))
        canvas.light = light
        canvas.addSubview(view)
        canvas.layoutSubtreeIfNeeded()
        guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            throw NSError(domain: "RichMessageCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create snapshot bitmap"])
        }
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "RichMessageCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot encode snapshot PNG"])
        }
        let target = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let suffix = contrast ? (light ? "-contrast-light" : "-contrast-dark") : ""
        try data.write(to: target.appendingPathComponent("rich-message-\(Int(width))\(suffix).png"), options: .atomic)
    }

    private final class SnapshotBackground: NSView {
        var light = false
        override func draw(_ dirtyRect: NSRect) {
            (light ? NSColor.white : NSColor(calibratedRed: 0.070, green: 0.082, blue: 0.102, alpha: 1)).setFill()
            bounds.fill()
        }
    }
}
