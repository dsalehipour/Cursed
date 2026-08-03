import SwiftUI
import AppKit

enum Metrics {
    /// Width of the glass shapes themselves.
    static let contentWidth: CGFloat = 300
    /// Breathing room so the glass edges and their shading are never clipped by the window.
    static let inset: CGFloat = 12
    static let rowHeight: CGFloat = 41
    static let rowSpacing: CGFloat = 7
    static let emptyHeight: CGFloat = 38
    static let overflowHeight: CGFloat = 22
    static let maxRows = 8

    static var windowWidth: CGFloat { contentWidth + inset * 2 }

    static func windowHeight(rowCount: Int) -> CGFloat {
        let shown = min(rowCount, maxRows)
        let body: CGFloat = shown == 0
            ? emptyHeight
            : CGFloat(shown) * rowHeight + CGFloat(shown - 1) * rowSpacing
        let overflow: CGFloat = rowCount > maxRows ? overflowHeight + rowSpacing : 0
        return body + overflow + inset * 2
    }
}

extension Attention {
    /// The whole visual language of the panel. A run in flight looks like plain text; a finished
    /// one you have not seen gets the only mark on screen; everything else recedes to grey.
    /// Values run a little hotter than they would on regular glass: clear glass puts almost no
    /// scrim between the text and whatever is behind the window, so the dimmed states need
    /// help to stay readable rather than merely visible.
    var titleOpacity: Double {
        switch self {
        case .asking, .working, .unseen: return 1
        case .settled: return 0.5
        }
    }

    var projectOpacity: Double {
        switch self {
        case .asking, .working, .unseen: return 0.85
        case .settled: return 0.4
        }
    }

    var timeOpacity: Double {
        switch self {
        case .asking, .working, .unseen: return 0.62
        case .settled: return 0.36
        }
    }

    /// Weight carries the same signal as the dot: bold is reserved for the two states that want
    /// something from you. A run still going, and one you have already dealt with, both stay
    /// regular, so the panel only thickens when it is actually asking.
    var weight: Font.Weight {
        switch self {
        case .asking, .unseen: return .bold
        case .working, .settled: return .regular
        }
    }

    /// The project eyebrow is small enough that regular weight would undersell it, so it sits one
    /// step above the rest of the row until the row goes bold with everything else.
    var projectWeight: Font.Weight {
        switch self {
        case .asking, .unseen: return .bold
        case .working, .settled: return .medium
        }
    }

    /// Kept faint: adjacent rows merge into one glass shape, and a strong tint would turn to mud
    /// where they meet.
    var glassTint: Color? {
        switch self {
        case .asking: return Self.askColor.opacity(0.1)
        case .unseen: return Self.doneColor.opacity(0.1)
        case .working, .settled: return nil
        }
    }

    /// Never more than one dot in a row: a question outranks a completion, so the two colours
    /// cannot collide.
    var dot: Color? {
        switch self {
        case .asking: return Self.askColor
        case .unseen: return Self.doneColor
        case .working, .settled: return nil
        }
    }

    /// Green reads as "done, go and look". Amber reads as "stopped, and it needs you" — the same
    /// distinction a traffic light makes, and worth the second colour in an otherwise monochrome
    /// panel because the two ask for quite different things.
    static let doneColor = Color(red: 0.22, green: 0.80, blue: 0.46)
    static let askColor = Color(red: 1.0, green: 0.62, blue: 0.08)
}

struct ContentView: View {
    @ObservedObject var store: Store
    var onSelect: (Store.Row) -> Void
    var onDismiss: (Store.Row) -> Void
    var onQuit: () -> Void

    @Namespace private var glass

    /// Structural changes should animate; the per-second timer tick should not. Keying the
    /// animation on identity and state only is what keeps the morph from firing every second.
    private var shape: [String] {
        store.rows.map { "\($0.id):\($0.attention.rawValue)" }
    }

    var body: some View {
        GlassEffectContainer(spacing: 20) {
            VStack(spacing: Metrics.rowSpacing) {
                if store.rows.isEmpty {
                    EmptyPill()
                        .glassEffectID("empty", in: glass)
                } else {
                    ForEach(store.rows.prefix(Metrics.maxRows)) { row in
                        RowView(row: row, onSelect: onSelect, onDismiss: onDismiss, onQuit: onQuit)
                            .glassEffect(
                                glass(for: row.attention),
                                in: .rect(cornerRadius: 18, style: .continuous)
                            )
                            .glassEffectID(row.id, in: glass)
                            .glassEffectTransition(.matchedGeometry)
                    }
                    if store.rows.count > Metrics.maxRows {
                        OverflowPill(count: store.rows.count - Metrics.maxRows)
                            .glassEffectID("overflow", in: glass)
                    }
                }
            }
            .frame(width: Metrics.contentWidth)
        }
        .padding(Metrics.inset)
        // Rows own the tap; anything that actually travels becomes a window drag. Attached to
        // the container so the whole panel stays draggable, not just the margins.
        .simultaneousGesture(WindowDragGesture())
        .animation(.smooth(duration: 0.5, extraBounce: 0.18), value: shape)
        .contextMenu {
            Button("Quit cursed", action: onQuit)
        }
    }

    private func glass(for attention: Attention) -> Glass {
        guard let tint = attention.glassTint else { return .clear.interactive() }
        return .clear.tint(tint).interactive()
    }
}

private struct RowView: View {
    let row: Store.Row
    var onSelect: (Store.Row) -> Void
    var onDismiss: (Store.Row) -> Void
    var onQuit: () -> Void

    /// Where on screen the press began. The panel travels with the pointer while it is being
    /// dragged, so a view-local translation stays near zero and cannot tell a click from a drag.
    /// Screen coordinates can.
    @State private var pressOrigin: CGPoint?

    /// Generous enough to absorb the wobble in a real click, far short of a deliberate reposition.
    private static let dragSlop: CGFloat = 20

    var body: some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if pressOrigin == nil { pressOrigin = NSEvent.mouseLocation }
                    }
                    .onEnded { _ in
                        let start = pressOrigin
                        pressOrigin = nil
                        guard let start else { return }
                        let end = NSEvent.mouseLocation
                        guard hypot(end.x - start.x, end.y - start.y) < Self.dragSlop else { return }
                        onSelect(row)
                    }
            )
            // Rows have their own menu, so Quit is repeated here: at a full panel there is
            // barely any bare surface left to right-click for the container's version.
            .contextMenu {
                Button("Dismiss") { onDismiss(row) }
                Divider()
                Button("Quit cursed", action: onQuit)
            }
            .help("\(row.project) — \(row.title)")
    }

    private var content: some View {
        HStack(spacing: 9) {
            // The gutter is reserved whether or not a dot is in it, so text stays on the same
            // line down the panel and nothing shifts sideways when a run finishes.
            Group {
                if let dot = row.attention.dot {
                    Circle().fill(dot)
                }
            }
            .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                // The project reads as an eyebrow above the title: smaller, so it stays
                // subordinate, but weighted and opaque enough to actually be read at a glance.
                Text(row.project)
                    .font(.system(size: 10, weight: row.attention.projectWeight))
                    .foregroundStyle(.primary.opacity(row.attention.projectOpacity))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(row.title)
                    .font(.system(size: 12, weight: row.attention.weight))
                    .foregroundStyle(.primary.opacity(row.attention.titleOpacity))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 6)

            Text(Format.duration(row.sinceLastMessage))
                .font(.system(size: 11.5, weight: row.attention.weight, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary.opacity(row.attention.timeOpacity))
                .contentTransition(.numericText())
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .frame(height: Metrics.rowHeight)
        .contentShape(Rectangle())
    }
}

private struct EmptyPill: View {
    var body: some View {
        Text("No active runs")
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(height: Metrics.emptyHeight)
            .frame(maxWidth: .infinity)
            .glassEffect(.clear, in: .capsule)
    }
}

private struct OverflowPill: View {
    let count: Int

    var body: some View {
        Text("+\(count) more")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(height: Metrics.overflowHeight)
            .frame(maxWidth: .infinity)
            .glassEffect(.clear, in: .capsule)
    }
}

enum Format {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m \(total % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
