import AppKit
import SwiftUI

/// Clicking a row and dragging the panel are the same press, so which one it becomes is decided
/// here and nowhere else. The panel watches this press to know when to move; the row under the
/// pointer watches it to know whether it was still a click when the button came up.
///
/// Owning the threshold is the whole point. `WindowDragGesture`, which used to do the moving,
/// hands off to AppKit after two or three points of travel — well inside the wobble of an ordinary
/// click, and far short of the twenty points a row was willing to forgive. Every press that landed
/// between the two both nudged the window and opened whatever it started on.
@MainActor
final class PanelDrag {
    /// Assigned once the window exists, which is after the view tree that reads this is built.
    weak var panel: FloatingPanel?

    /// Generous enough to absorb the wobble in a real click, far short of a deliberate reposition.
    private static let slop: CGFloat = 20

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
            return
        }
        if isDragging {
            panel?.continueDrag(to: point)
        } else if hypot(point.x - pressedAt.x, point.y - pressedAt.y) >= Self.slop {
            isDragging = true
            // Anchored where the slop was crossed rather than where the press began, so the panel
            // picks up from under the pointer instead of jumping to meet it.
            panel?.beginDrag(from: point)
        }
    }

    func release() {
        pressedAt = nil
    }
}
