import AppKit

enum ImageThumbnailer {
    /// Decode image bytes and resize to a square-bounded thumbnail.
    /// Returns nil when data cannot be decoded into an image.
    static func makeThumbnail(from data: Data, maxSide: CGFloat = 56) -> NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        let original = image.size
        guard original.width > 0, original.height > 0 else { return nil }

        let scale = min(maxSide / original.width, maxSide / original.height, 1.0)
        let target = NSSize(width: floor(original.width * scale), height: floor(original.height * scale))
        guard target.width > 0, target.height > 0 else { return nil }

        let thumbnail = NSImage(size: target)
        thumbnail.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: original),
            operation: .copy,
            fraction: 1.0
        )
        thumbnail.unlockFocus()
        return thumbnail
    }
}
