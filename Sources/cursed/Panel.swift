import AppKit

/// A borderless HUD that floats above other applications without ever taking focus.
///
/// `.nonactivatingPanel` is what makes it usable while you work: clicking a row does not
/// activate this app, so whatever you were typing in keeps its keyboard focus.
final class FloatingPanel: NSPanel {
    /// Stored as the top-left corner rather than the AppKit origin, so the window stays visually
    /// anchored while its height changes with the number of rows.
    private static let topLeftKey = "panelTopLeft"

    /// Resizing moves the origin, which fires the same notification a user drag does. This
    /// distinguishes the two so only a real drag is remembered.
    private var isAdjustingFrame = false
    var isUserMove: Bool { !isAdjustingFrame }

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
        // Dragging is handled by a WindowDragGesture in the content instead. AppKit's background
        // drag starts on any movement at all, so it ate clicks that drifted by a few points —
        // which is most of them, on targets this small.
        isMovableByWindowBackground = false
        isOpaque = false
        // The window contributes nothing visually: every pixel comes from the Liquid Glass
        // shapes inside it. Its own shadow is switched off so it cannot trail behind them
        // as they morph.
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Keeps the panel pinned to its top-left corner while its height changes with the row count,
    /// since macOS window origins are measured from the bottom.
    func resizeKeepingTopLeft(to size: NSSize) {
        guard frame.size != size else { return }
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        adjustingFrame {
            setFrame(
                NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height),
                display: true
            )
        }
    }

    func restorePosition(defaultSize: NSSize) {
        let topLeft = savedTopLeft(for: defaultSize) ?? defaultTopLeft(for: defaultSize)
        adjustingFrame {
            setFrame(
                NSRect(x: topLeft.x, y: topLeft.y - defaultSize.height,
                       width: defaultSize.width, height: defaultSize.height),
                display: false
            )
        }
    }

    func savePosition() {
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: Self.topLeftKey)
    }

    private func savedTopLeft(for size: NSSize) -> NSPoint? {
        guard let saved = UserDefaults.standard.string(forKey: Self.topLeftKey) else { return nil }
        let topLeft = NSPointFromString(saved)
        let rect = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        // Require the whole window to be on one display, so a disconnected monitor or a stale
        // value can never strand it half (or entirely) off screen.
        guard NSScreen.screens.contains(where: { $0.visibleFrame.contains(rect) }) else { return nil }
        return topLeft
    }

    /// Centred along the top of the primary display. Deliberately not `NSScreen.main`, which
    /// follows keyboard focus and would put the window on a different display depending on what
    /// was active.
    private func defaultTopLeft(for size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: (screen.midX - size.width / 2).rounded(), y: screen.maxY - 16)
    }

    /// Marks a frame change as ours. Cleared on the next turn of the run loop because the move
    /// notification can arrive after `setFrame` returns.
    private func adjustingFrame(_ body: () -> Void) {
        isAdjustingFrame = true
        body()
        DispatchQueue.main.async { [weak self] in self?.isAdjustingFrame = false }
    }
}
