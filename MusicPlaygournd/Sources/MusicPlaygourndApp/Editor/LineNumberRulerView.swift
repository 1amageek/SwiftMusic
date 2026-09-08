import AppKit

/// Draws source line numbers from the editor's native text layout.
@MainActor
final class LineNumberRulerView: NSRulerView {
    private let labelFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private let backgroundColor = NSColor(calibratedRed: 0.045, green: 0.055, blue: 0.065, alpha: 1)
    private let separatorColor = NSColor(calibratedWhite: 1, alpha: 0.08)
    private let labelColor = NSColor.secondaryLabelColor

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        clipsToBounds = true
        ruleThickness = 44
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
        ruleThickness = 44
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
    }

    override func draw(_ dirtyRect: NSRect) {
        let clippedRect = dirtyRect.intersection(bounds)
        guard !clippedRect.isNull, !clippedRect.isEmpty else { return }
        backgroundColor.setFill()
        clippedRect.fill()
        drawLineNumbers(in: clippedRect)
        separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: clippedRect.minY, width: 1, height: clippedRect.height).intersection(bounds).fill()
    }

    private func drawLineNumbers(in dirtyRect: NSRect) {
        guard orientation == .verticalRuler,
              let textView = clientView as? NSTextView,
              let layout = textView.layoutManager,
              let container = textView.textContainer else { return }

        layout.ensureLayout(for: container)
        let source = textView.string as NSString
        let starts = lineStarts(in: source)
        let documentRects = lineRects(for: starts, source: source, textView: textView, layout: layout)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: labelColor
        ]

        for (index, rect) in documentRects.enumerated() {
            let point = textView.convert(NSPoint(x: 0, y: rect.midY), to: self)
            let label = "\(index + 1)"
            let size = (label as NSString).size(withAttributes: attributes)
            let drawRect = NSRect(
                x: bounds.maxX - size.width - 8,
                y: point.y - size.height * 0.5,
                width: size.width,
                height: size.height
            )
            guard drawRect.intersects(dirtyRect) else { continue }
            (label as NSString).draw(in: drawRect, withAttributes: attributes)
        }
    }

    private func lineStarts(in source: NSString) -> [Int] {
        guard source.length > 0 else { return [0] }
        var starts = [0]
        var offset = 0
        while offset < source.length {
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            let next = NSMaxRange(range)
            guard next > offset else { break }
            offset = next
            if offset < source.length { starts.append(offset) }
        }

        let final = source.character(at: source.length - 1)
        if final == 0x0A || final == 0x0D || final == 0x85 || final == 0x2028 || final == 0x2029 {
            starts.append(source.length)
        }
        return starts
    }

    private func lineRects(
        for starts: [Int],
        source: NSString,
        textView: NSTextView,
        layout: NSLayoutManager
    ) -> [NSRect] {
        let origin = textView.textContainerOrigin
        let defaultHeight = layout.defaultLineHeight(for: textView.font ?? labelFont)
        var result = [NSRect]()
        result.reserveCapacity(starts.count)
        var lastRect: NSRect?

        for start in starts {
            var rect: NSRect?
            if start < source.length {
                let glyphs = layout.glyphRange(
                    forCharacterRange: NSRange(location: start, length: 0),
                    actualCharacterRange: nil
                )
                if glyphs.location < layout.numberOfGlyphs {
                    rect = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                }
            } else {
                let extra = layout.extraLineFragmentRect
                if !extra.isEmpty { rect = extra }
            }

            if let rect {
                // Paragraph spacing reserves inline results; only the text line receives a number.
                var documentRect = rect.offsetBy(dx: origin.x, dy: origin.y)
                documentRect.size.height = min(rect.height, defaultHeight)
                result.append(documentRect)
                lastRect = documentRect
            } else if let previous = lastRect {
                let next = NSRect(
                    x: previous.minX,
                    y: previous.maxY,
                    width: previous.width,
                    height: defaultHeight
                )
                result.append(next)
                lastRect = next
            } else {
                let first = NSRect(x: origin.x, y: origin.y, width: 1, height: defaultHeight)
                result.append(first)
                lastRect = first
            }
        }
        return result
    }
}
