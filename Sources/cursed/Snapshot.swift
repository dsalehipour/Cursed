import AppKit

/// Renders the panel's own content to a PNG.
///
/// This captures our view directly rather than reading the screen, so it needs no Screen
/// Recording permission. The window's blur comes from the compositor and cannot be captured
/// this way, so the result is composited onto a dark backdrop to approximate what is seen.
enum Snapshot {
    static func capture(_ view: NSView, to path: String) -> Bool {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds)
        else { return false }

        view.cacheDisplay(in: bounds, to: rep)

        let composited = NSImage(size: bounds.size)
        composited.lockFocus()
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        bounds.fill()
        rep.draw(in: bounds)
        composited.unlockFocus()

        guard let tiff = composited.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return false }

        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
