import AppKit
import SwiftUI

/// One native TextKit document per message preserves whole-message selection.
struct MessageTextView: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    var markdown = true
    @Environment(\.panelBackdropOpacity) private var backgroundOpacity

    func makeNSView(context: Context) -> RichMessageTextView { RichMessageTextView() }

    func updateNSView(_ view: RichMessageTextView, context: Context) {
        view.configure(text: text, fontSize: fontSize, markdown: markdown)
        view.setBackgroundOpacity(backgroundOpacity)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RichMessageTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return nsView.fittingSize(width: width)
    }
}

final class RichMessageTextView: NSTextView, NSTextViewDelegate {
    private(set) var rendered: RenderedMessage?
    private var latestSource = ""
    private var appliedSource: String?
    private var messageFontSize: CGFloat = 12
    private var usesMarkdown = true
    private var renderWidth: CGFloat = 0
    private var applying = false
    private var copyButtons: [MessageCodeCopyButton] = []
    private var ownedTextStorage: NSTextStorage?
    private(set) var backgroundOpacity = 1.0

    func setBackgroundOpacity(_ value: Double) {
        guard value != backgroundOpacity else { return }
        let wasApplying = applying
        applying = true
        defer { applying = wasApplying }
        backgroundOpacity = value
        let contrast = ForegroundContrast.strength(backgroundOpacity: value)
        linkTextAttributes = [.foregroundColor: ForegroundContrast.color(RichMessageRenderer.linkColor, strength: contrast),
                              .underlineStyle: NSUnderlineStyle.single.rawValue]
        for button in copyButtons {
            button.contentTintColor = ForegroundContrast.color(RichMessageRenderer.mutedColor, strength: contrast)
            button.contrastStrength = contrast
        }
        let selection = selectedRange()
        if let rendered { textStorage?.setAttributedString(rendered.textWithBackgroundOpacity(value)) }
        setSelectedRange(selection)
        needsDisplay = true
    }

    convenience init() { self.init(frame: .zero, textContainer: nil) }

    override init(frame frameRect: NSRect, textContainer suppliedContainer: NSTextContainer?) {
        let container = suppliedContainer ?? NSTextContainer(containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        let storage = container.layoutManager?.textStorage ?? NSTextStorage()
        if container.layoutManager == nil {
            let layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
        }
        super.init(frame: frameRect, textContainer: container)
        ownedTextStorage = storage
        configureTextSystem()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureTextSystem()
    }

    private func configureTextSystem() {
        isEditable = false
        isSelectable = true
        isRichText = true
        importsGraphics = false
        drawsBackground = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        isHorizontallyResizable = false
        isVerticallyResizable = true
        delegate = self
        linkTextAttributes = [.foregroundColor: RichMessageRenderer.linkColor,
                              .underlineStyle: NSUnderlineStyle.single.rawValue]
        selectedTextAttributes = [.backgroundColor: NSColor(calibratedRed: 0.18, green: 0.32, blue: 0.39, alpha: 1)]
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityLabel("Sohbet mesajı")
    }

    func configure(text: String, fontSize: CGFloat, markdown: Bool) {
        guard latestSource != text || messageFontSize != fontSize || usesMarkdown != markdown || rendered == nil else { return }
        latestSource = text
        if messageFontSize != fontSize || usesMarkdown != markdown { appliedSource = nil }
        messageFontSize = fontSize
        usesMarkdown = markdown
        updateRendering(width: max(80, renderWidth > 0 ? renderWidth : 500))
    }

    func fittingSize(width: CGFloat) -> CGSize {
        updateRendering(width: max(80, floor(width)))
        guard let container = textContainer, let layout = layoutManager else { return NSSize(width: width, height: 20) }
        container.containerSize = NSSize(width: max(80, width), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = max(messageFontSize + 5, ceil(layout.usedRect(for: container).height) + 8)
        return NSSize(width: width, height: height)
    }

    private func updateRendering(width: CGFloat, ignoreSelection: Bool = false) {
        guard !applying else { return }
        // Keep a selection stable while delimiters arrive during streaming.
        // Coalesce to the latest source, then flush when selection is cleared.
        let activelySelecting = !ignoreSelection && selectedRange().length > 0 && window?.firstResponder === self
        let source = activelySelecting ? (appliedSource ?? latestSource) : latestSource
        guard appliedSource != source || renderWidth != width || rendered == nil else { return }
        applying = true
        defer { applying = false }
        let selection = selectedRange()
        let next = RichMessageRenderer.render(source, fontSize: messageFontSize, width: width, markdown: usesMarkdown)
        textStorage?.setAttributedString(next.textWithBackgroundOpacity(backgroundOpacity))
        rendered = next
        appliedSource = source
        renderWidth = width
        let location = min(selection.location, next.text.length)
        setSelectedRange(NSRange(location: location, length: min(selection.length, next.text.length - location)))
        rebuildCopyButtons()
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !applying, selectedRange().length == 0, latestSource != appliedSource else { return }
        updateRendering(width: max(80, renderWidth))
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { updateRendering(width: max(80, renderWidth), ignoreSelection: true) }
        return resigned
    }

    override func copy(_ sender: Any?) {
        guard let rendered, selectedRange().length > 0 else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rendered.copyText(in: selectedRange()), forType: .string)
    }

    func copyCodeBlock(at index: Int, to pasteboard: NSPasteboard = .general) {
        guard let blocks = rendered?.codeBlocks, blocks.indices.contains(index) else { return }
        pasteboard.clearContents()
        pasteboard.setString(blocks[index].code, forType: .string)
        guard pasteboard === NSPasteboard.general, copyButtons.indices.contains(index) else { return }
        let button = copyButtons[index]
        button.title = "KOPYALANDI"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak button] in button?.title = "KOPYALA" }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL { MessageLinkPolicy.open(url) }
        else if let raw = link as? String, let url = MessageLinkPolicy.destination(raw) { MessageLinkPolicy.open(url) }
        return true // Block AppKit's unrestricted default URL dispatch.
    }

    private func rebuildCopyButtons() {
        let count = rendered?.codeBlocks.count ?? 0
        while copyButtons.count > count { copyButtons.removeLast().removeFromSuperview() }
        while copyButtons.count < count {
            let button = MessageCodeCopyButton(title: "KOPYALA", target: self, action: #selector(copyBlockClicked(_:)))
            button.font = NSFont.monospacedSystemFont(ofSize: 8, weight: .semibold)
            button.bezelStyle = .inline
            button.isBordered = false
            let contrast = ForegroundContrast.strength(backgroundOpacity: backgroundOpacity)
            button.contentTintColor = ForegroundContrast.color(RichMessageRenderer.mutedColor, strength: contrast)
            button.contrastStrength = contrast
            button.toolTip = "Yalnızca bu kodu veya promptu kopyala"
            button.setAccessibilityLabel("Kutunun içeriğini kopyala")
            button.tag = copyButtons.count
            addSubview(button)
            copyButtons.append(button)
        }
    }

    @objc private func copyBlockClicked(_ sender: NSButton) { copyCodeBlock(at: sender.tag) }

    private func rect(for range: NSRange) -> NSRect {
        guard let layout = layoutManager, let container = textContainer, let rendered else { return .zero }
        let safe = NSIntersectionRange(range, NSRange(location: 0, length: rendered.text.length))
        guard safe.length > 0 else { return .zero }
        let glyphs = layout.glyphRange(forCharacterRange: safe, actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    override func layout() {
        super.layout()
        guard let rendered else { return }
        for (index, block) in rendered.codeBlocks.enumerated() where copyButtons.indices.contains(index) {
            let header = rect(for: block.headerRange)
            copyButtons[index].frame = NSRect(x: max(0, bounds.width - 91), y: header.minY - 2, width: 82, height: 17)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let rendered {
            for block in rendered.codeBlocks {
                let glyphRect = rect(for: block.range)
                let background = NSRect(x: 0, y: max(0, glyphRect.minY - 7), width: bounds.width,
                                        height: glyphRect.height + 14)
                guard background.intersects(dirtyRect) else { continue }
                RichMessageRenderer.codeColor.withAlphaComponent(CGFloat(backgroundOpacity)).setFill()
                let path = NSBezierPath(roundedRect: background, xRadius: 6, yRadius: 6)
                path.fill()
                NSColor(calibratedWhite: 0.20, alpha: 0.65).setStroke()
                path.lineWidth = 0.6
                path.stroke()
            }
        }
        // A graphics shadow also covers vector math attachments, not just glyphs.
        let contrast = ForegroundContrast.strength(backgroundOpacity: backgroundOpacity)
        NSGraphicsContext.saveGraphicsState()
        if contrast > 0 { ForegroundContrast.shadow(strength: contrast).set() }
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class MessageCodeCopyButton: NSButton {
    var contrastStrength = 0.0 { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        if contrastStrength > 0 { ForegroundContrast.shadow(strength: contrastStrength).set() }
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
    }
}
