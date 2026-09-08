import AppKit
import SwiftMath

/// Local, vector-backed math for TextKit. No page, script engine, or network is
/// involved; failed/unfinished expressions stay readable in the caller's text.
@MainActor
enum MathAttachmentRenderer {
    private final class CachedRender {
        let image: NSImage?
        let descent: CGFloat

        init(image: NSImage? = nil, descent: CGFloat = 0) {
            self.image = image
            self.descent = descent
        }
    }

    private static let cache: NSCache<NSString, CachedRender> = {
        let cache = NSCache<NSString, CachedRender>()
        cache.countLimit = 128
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    static func attachment(latex: String, display: Bool, fontSize: CGFloat,
                           maxWidth: CGFloat) -> NSTextAttachment? {
        guard fontSize.isFinite, maxWidth.isFinite, fontSize >= 8,
              fontSize <= 64, maxWidth >= 24, isBoundedExpression(latex) else { return nil }

        // Whole-point width buckets avoid a fresh typesetting pass for tiny
        // fractional layout changes while never exceeding the proposed width.
        let width = min(4096, floor(maxWidth))
        let key = "\(display)|\(fontSize)|\(width)|\(latex)" as NSString
        if let cached = cache.object(forKey: key) { return attachment(from: cached) }

        let label = MTMathUILabel(frame: .zero)
        label.displayErrorInline = false
        label.labelMode = display ? .display : .text
        label.fontSize = fontSize * (display ? 1.12 : 1)
        label.textColor = NSColor(calibratedRed: 0.847, green: 0.875, blue: 0.914, alpha: 1)
        label.latex = latex
        guard label.error == nil, let mathList = label.mathList,
              hasCompleteArguments(mathList) else {
            cache.setObject(CachedRender(), forKey: key, cost: latex.utf8.count)
            return nil
        }

        let natural = label.fittingSize
        guard natural.width.isFinite, natural.height.isFinite,
              natural.width > 0, natural.height > 0,
              natural.width <= 16_384, natural.height <= 2_048 else { return nil }

        let padding: CGFloat = 2
        let scale = min(1, (width - padding * 2) / natural.width)
        // Do not turn an unusually long equation into illegible miniature text.
        // The fallback is selectable source text, which can wrap normally.
        guard scale >= 0.55 else { return nil }
        let size = NSSize(width: min(width, ceil(natural.width * scale + padding * 2)),
                          height: ceil(natural.height * scale + padding * 2))
        label.frame = NSRect(origin: .zero, size: natural)
        label.layoutSubtreeIfNeeded()
        guard let mathDisplay = label.displayList else { return nil }

        // Retaining PDF drawing commands keeps integrals and fractions sharp
        // on Retina screens, without retaining a view or typesetting tree.
        let bytes = NSMutableData()
        var mediaBox = NSRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: bytes as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        context.beginPDFPage(nil)
        context.translateBy(x: padding, y: padding)
        context.scaleBy(x: scale, y: scale)
        // Some SwiftMath rule/large-delimiter drawing inherits CGContext paint
        // rather than label.textColor. PDF contexts default to black.
        let ink = NSColor(calibratedRed: 0.847, green: 0.875, blue: 0.914, alpha: 1).cgColor
        context.setFillColor(ink)
        context.setStrokeColor(ink)
        // SwiftMath mixes CGContext glyphs with NSBezierPath rules on macOS.
        // Both must target this PDF; otherwise fraction/root bars disappear.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        mathDisplay.draw(context)
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        guard let representation = NSPDFImageRep(data: bytes as Data) else { return nil }
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        let cached = CachedRender(image: image, descent: mathDisplay.descent * scale + padding)
        cache.setObject(cached, forKey: key, cost: bytes.length + latex.utf8.count)
        return attachment(from: cached)
    }

    private static func attachment(from cached: CachedRender) -> NSTextAttachment? {
        guard let image = cached.image else { return nil }
        // A fresh cell per message prevents shared attachment selection/layout
        // state; only the immutable vector image is shared by the bounded cache.
        let attachment = NSTextAttachment()
        attachment.attachmentCell = MathAttachmentCell(image: image, descent: cached.descent)
        return attachment
    }

    private static func isBoundedExpression(_ source: String) -> Bool {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.utf8.count <= 4096 else { return false }
        var depth = 0
        var escaped = false
        var commands = 0
        for character in source {
            if escaped { escaped = false; continue }
            if character == "\\" {
                escaped = true
                commands += 1
                if commands > 256 { return false }
            } else if character == "{" {
                depth += 1
                if depth > 32 { return false }
            } else if character == "}" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0 && !escaped
    }

    /// SwiftMath accepts some partially typed commands (e.g. a fraction whose
    /// second argument has not arrived yet). Keep those as source until complete.
    private static func hasCompleteArguments(_ list: MTMathList) -> Bool {
        var pending: [(MTMathList, Int)] = [(list, 0)]
        var count = 0
        while let (current, depth) = pending.popLast() {
            guard depth <= 48 else { return false }
            for atom in current.atoms {
                count += 1
                guard count <= 2048 else { return false }
                for script in [atom.subScript, atom.superScript].compactMap({ $0 }) {
                    guard !script.atoms.isEmpty else { return false }
                    pending.append((script, depth + 1))
                }
                switch atom {
                case let fraction as MTFraction:
                    guard let numerator = fraction.numerator, !numerator.atoms.isEmpty,
                          let denominator = fraction.denominator, !denominator.atoms.isEmpty else { return false }
                    pending.append(contentsOf: [(numerator, depth + 1), (denominator, depth + 1)])
                case let radical as MTRadical:
                    guard let radicand = radical.radicand, !radicand.atoms.isEmpty else { return false }
                    pending.append((radicand, depth + 1))
                    if let degree = radical.degree { pending.append((degree, depth + 1)) }
                case let inner as MTInner:
                    if let nested = inner.innerList { pending.append((nested, depth + 1)) }
                case let accent as MTAccent:
                    guard let nested = accent.innerList, !nested.atoms.isEmpty else { return false }
                    pending.append((nested, depth + 1))
                case let overline as MTOverLine:
                    guard let nested = overline.innerList, !nested.atoms.isEmpty else { return false }
                    pending.append((nested, depth + 1))
                case let underline as MTUnderLine:
                    guard let nested = underline.innerList, !nested.atoms.isEmpty else { return false }
                    pending.append((nested, depth + 1))
                case let table as MTMathTable:
                    guard table.cells.count <= 64, table.cells.allSatisfy({ $0.count <= 32 }) else { return false }
                    for row in table.cells {
                        for cell in row { pending.append((cell, depth + 1)) }
                    }
                default: break
                }
            }
        }
        return true
    }
}

private final class MathAttachmentCell: NSTextAttachmentCell {
    private let descent: CGFloat

    init(image: NSImage, descent: CGFloat) {
        self.descent = descent
        super.init(imageCell: image)
    }

    required init(coder: NSCoder) {
        self.descent = 0
        super.init(coder: coder)
    }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -descent) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let opacity = (controlView as? RichMessageTextView)?.backgroundOpacity ?? 1
        let contrast = ForegroundContrast.strength(backgroundOpacity: opacity)
        guard contrast > 0, let context = NSGraphicsContext.current?.cgContext else {
            super.draw(withFrame: cellFrame, in: controlView)
            return
        }
        // PDF attachments reset graphics state internally. Composite each vector
        // draw before applying its small keyline; never darken the whole cell.
        let offset = 0.6 * contrast
        for delta in [CGSize(width: offset, height: 0), CGSize(width: -offset, height: 0),
                      CGSize(width: 0, height: offset), CGSize(width: 0, height: -offset)] {
            context.saveGState()
            context.setShadow(offset: delta, blur: 0, color: NSColor.black.withAlphaComponent(contrast).cgColor)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            super.draw(withFrame: cellFrame, in: controlView)
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }
}
