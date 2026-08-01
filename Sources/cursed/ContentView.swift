import SwiftUI
import AppKit
import QuartzCore

enum Metrics {
    /// Width of the glass shapes themselves.
    static let contentWidth: CGFloat = 300
    /// Breathing room so the glass edges and their shading are never clipped by the window.
    static let inset: CGFloat = 12
    static let rowHeight: CGFloat = 48
    static let rowSpacing: CGFloat = 7
    static let emptyHeight: CGFloat = 38
    static let overflowHeight: CGFloat = 22
    static let maxRows = 8

    static var windowWidth: CGFloat { contentWidth + inset * 2 }

    static func windowHeight(rowCount: Int) -> CGFloat {
        let shown = min(rowCount, maxRows)
        let body: CGFloat
        if shown == 0 {
            body = emptyHeight
        } else {
            body = CGFloat(shown) * rowHeight + CGFloat(shown - 1) * rowSpacing
        }
        let overflow: CGFloat = rowCount > maxRows ? overflowHeight + rowSpacing : 0
        return body + overflow + inset * 2
    }
}

extension TurnStatus {
    var tint: Color {
        switch self {
        case .running: return Color(red: 0.29, green: 0.68, blue: 1.0)
        case .stalled: return Color(red: 1.0, green: 0.74, blue: 0.28)
        case .done(let success):
            return success
                ? Color(red: 0.30, green: 0.85, blue: 0.52)
                : Color(red: 1.0, green: 0.45, blue: 0.42)
        }
    }

    /// Live runs carry a hint of colour in the glass itself; finished ones fade back to neutral
    /// so attention lands on what is still working. Kept faint because adjacent rows merge into
    /// one glass shape, and strong tints would blend into mud where they meet.
    var glassTint: Color {
        switch self {
        case .running: return tint.opacity(0.14)
        case .stalled: return tint.opacity(0.16)
        case .done: return tint.opacity(0.04)
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    var onSelect: (Store.Row) -> Void
    var onQuit: () -> Void

    @Namespace private var glass

    /// Structural changes should animate; the per-second timer tick should not. Keying the
    /// animation on identity and state only is what keeps the morph from firing every second.
    private var shape: [String] {
        store.rows.map { "\($0.id):\($0.status)" }
    }

    var body: some View {
        GlassEffectContainer(spacing: 20) {
            VStack(spacing: Metrics.rowSpacing) {
                if store.rows.isEmpty {
                    EmptyPill()
                        .glassEffectID("empty", in: glass)
                } else {
                    ForEach(store.rows.prefix(Metrics.maxRows)) { row in
                        RowView(row: row, onSelect: onSelect)
                            .glassEffect(
                                .regular.tint(row.glassTint).interactive(),
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
        .animation(.smooth(duration: 0.5, extraBounce: 0.18), value: shape)
        .contextMenu {
            Button("Quit cursed", action: onQuit)
        }
    }
}

private extension Store.Row {
    var glassTint: Color { status.glassTint }
}

private struct RowView: View {
    let row: Store.Row
    var onSelect: (Store.Row) -> Void

    private var detail: String {
        guard let subtitle = row.subtitle, !subtitle.isEmpty else { return row.project }
        return "\(row.project) · \(subtitle)"
    }

    var body: some View {
        HStack(spacing: 11) {
            StatusIndicator(status: row.status)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(row.status.isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 6)

            Text(Format.duration(row.duration))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(row.status == .running ? AnyShapeStyle(row.status.tint) : AnyShapeStyle(.secondary))
                .contentTransition(.numericText())
        }
        .padding(.leading, 15)
        .padding(.trailing, 16)
        .frame(height: Metrics.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(row) }
        .help(detail)
    }
}

private struct EmptyPill: View {
    var body: some View {
        Text("No active runs")
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(height: Metrics.emptyHeight)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .capsule)
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

private struct StatusIndicator: View {
    let status: TurnStatus

    var body: some View {
        switch status {
        case .running:
            PulsingDot(color: status.tint, diameter: 8)
                .frame(width: 8, height: 8)
        case .stalled:
            Circle()
                .strokeBorder(status.tint, lineWidth: 1.8)
                .frame(width: 9, height: 9)
        case .done(let success):
            Image(systemName: success ? "checkmark" : "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(status.tint)
        }
    }
}

/// A dot that breathes while a run is in flight.
///
/// Deliberately not a SwiftUI `repeatForever` animation: that re-evaluates the view every
/// frame and measured at ~5% of a core for a window meant to sit there all day. A Core
/// Animation layer animation is handed to the render server and costs the app nothing.
private struct PulsingDot: NSViewRepresentable {
    let color: Color
    let diameter: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        view.wantsLayer = true
        guard let layer = view.layer else { return view }
        layer.backgroundColor = NSColor(color).cgColor
        layer.cornerRadius = diameter / 2

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.28
        pulse.duration = 0.75
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "pulse")
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.layer?.backgroundColor = NSColor(color).cgColor
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
