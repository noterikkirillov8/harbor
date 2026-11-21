import AppKit

/// The menu bar mark: a small key (keycap outline) with the number of running dev servers in wide
/// figures inside. With nothing running it is just the key outline. Drawn, so it is crisp at 1x and 2x.
enum StatusImage {
    static func make(count: Int) -> NSImage {
        let text = count > 0 ? String(count) : ""
        let font = wideFont(size: 10.5)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let label = NSAttributedString(string: text, attributes: attrs)
        let textSize = label.size()
        let width = max(18, ceil(textSize.width) + 10)
        let image = NSImage(size: NSSize(width: width, height: 16), flipped: false) { rect in
            let body = rect.insetBy(dx: 1, dy: 1.5)
            NSColor.black.setStroke()
            let key = NSBezierPath(roundedRect: body, xRadius: 4, yRadius: 4)
            key.lineWidth = 1.5
            key.stroke()
            if count > 0 { label.draw(at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2 + 0.5)) }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func wideFont(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        let desc = base.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.width: 0.4,
                                                                 NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold.rawValue]])
        return NSFont(descriptor: desc, size: size) ?? base
    }
}
