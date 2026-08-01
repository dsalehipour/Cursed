import AppKit

/// A borderless HUD that floats above other applications without ever taking focus.
///
/// `.nonactivatingPanel` is what makes it usable while you work: clicking a row does not
/// activate this app, so whatever you were typing in keeps its keyboard focus.
final class FloatingPanel: NSPanel {
    private static let originKey = "panelOrigin"

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        // Above normal and floating windows, but below the menu bar and system alerts.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        // A HUD that floats over arbitrary content reads better dark regardless of the
        // system setting, the same way the system's own overlays do.
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Keeps the panel pinned to its top-left corner while its height changes with the row count,
    /// since macOS window origins are measured from the bottom.
    func resizeKeepingTopLeft(to size: NSSize) {
        guard frame.size != size else { return }
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        setFrame(
            NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height),
            display: true
        )
    }

    func restorePosition(defaultSize: NSSize) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(
            x: screen.maxX - defaultSize.width - 20,
            y: screen.maxY - defaultSize.height - 20
        )
        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            let point = NSPointFromString(saved)
            // Ignore a saved position that no longer lands on an attached display.
            if NSScreen.screens.contains(where: { $0.frame.intersects(NSRect(origin: point, size: defaultSize)) }) {
                origin = point
            }
        }
        setFrame(NSRect(origin: origin, size: defaultSize), display: false)
    }

    func savePosition() {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
    }
}
