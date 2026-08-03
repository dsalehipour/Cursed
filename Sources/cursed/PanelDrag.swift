import AppKit
import SwiftUI

/// Clicking a row and dragging the panel are the same press, so which one it becomes is decided
/// here and nowhere else. The panel watches this press to know when to move; the row under the
/// pointer watches it to know whether it was still a click when the button came up.
///
/// A press that travels is a reposition, and a press that does not is a click. Nothing sits
/// between the two, which is the point: any band of travel wide enough to forgive a shaky click is
/// also wide enough to swallow a deliberate nudge, and a press landing in it does the wrong thing
/// whichever way it is read.
@MainActor
final class PanelDrag {
    /// Assigned once the window exists, which is after the view tree that reads this is built.
    weak var panel: FloatingPanel?

    /// Below a point is jitter in the hardware rather than movement in the hand. Holding the line
    /// at zero would let a trackpad's own noise turn every click into a drag of no distance.
    private static let minimumTravel: CGFloat = 1

    /// Where on screen the press began. Screen coordinates are load-bearing: once the panel is
    /// moving it travels with the pointer, so a view-local translation stays near zero and cannot
    /// tell a click from a drag.
    private var pressedAt: CGPoint?

    /// Whether the press has travelled far enough to be a reposition. Deliberately left standing
    /// once the press ends: a row's gesture finishes alongside this one in no guaranteed order,
    /// and needs to be able to ask what the press turned out to be. The next press clears it.
    private(set) var isDragging = false

    /// Covers the parts of the panel no row occupies — the margins, and the gaps between rows.
    var gesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { [self] _ in track() }
            .onEnded { [self] _ in release() }
    }

    func track() {
        let point = NSEvent.mouseLocation
        guard let pressedAt else {
            self.pressedAt = point
            isDragging = false
            // Anchored on the press itself. With no threshold to cross there is no dead zone to
            // absorb, so the window sits exactly under the pointer from the first point it travels.
            panel?.beginDrag(from: point)
            return
        }
        // Sticky once set: a press that wandered and came home again was still a drag, and the
        // window has to be able to follow it back.
        guard isDragging || hypot(point.x - pressedAt.x, point.y - pressedAt.y) >= Self.minimumTravel
        else { return }
        isDragging = true
        panel?.continueDrag(to: point)
    }

    /// A gesture can end without the press having ended: rows come and go under the pointer as the
    /// store polls, and a row torn down mid-drag takes its gesture with it. Ending the press there
    /// would start a fresh one on the next event, and a drag that happened to finish within a point
    /// of that moment would be read as a click on whatever row had replaced the one pressed.
    func release() {
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        pressedAt = nil
    }
}
