import SwiftUI
import AppKit

enum Metrics {
    static let width: CGFloat = 296
    static let headerHeight: CGFloat = 26
    static let rowHeight: CGFloat = 38
    static let emptyHeight: CGFloat = 34
    static let bottomPadding: CGFloat = 6
    static let maxRows = 8

    static func height(rowCount: Int) -> CGFloat {
        let body = rowCount == 0 ? emptyHeight : CGFloat(min(rowCount, maxRows)) * rowHeight
        let overflow: CGFloat = rowCount > maxRows ? 18 : 0
        return headerHeight + body + overflow + bottomPadding
    }
}

extension TurnStatus {
    var tint: Color {
        switch self {
        case .running: return Color(red: 0.36, green: 0.78, blue: 1.0)
        case .stalled: return Color(red: 1.0, green: 0.72, blue: 0.26)
        case .done(let success):
            return success
                ? Color(red: 0.35, green: 0.85, blue: 0.47)
                : Color(red: 1.0, green: 0.43, blue: 0.41)
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    var onSelect: (Store.Row) -> Void
    var onQuit: () -> Void

    private var runningCount: Int { store.rows.filter { $0.status == .running }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if store.rows.isEmpty {
                emptyState
            } else {
                ForEach(store.rows.prefix(Metrics.maxRows)) { row in
                    RowView(row: row, onSelect: onSelect)
                }
                if store.rows.count > Metrics.maxRows {
                    Text("+\(store.rows.count - Metrics.maxRows) more")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 12)
                        .frame(height: 18, alignment: .leading)
                }
            }
        }
        .padding(.bottom, Metrics.bottomPadding)
        .frame(width: Metrics.width, alignment: .leading)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        )
        .contextMenu {
            Button("Quit cursed", action: onQuit)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("cursed")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Spacer()
            Text(summary)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.headerHeight)
    }

    private var summary: String {
        if runningCount > 0 { return "\(runningCount) running" }
        return store.rows.isEmpty ? "idle" : "done"
    }

    private var emptyState: some View {
        Text("No active conversations")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .frame(height: Metrics.emptyHeight, alignment: .leading)
    }
}

private struct RowView: View {
    let row: Store.Row
    var onSelect: (Store.Row) -> Void

    @State private var hovering = false
    private var now: Date { Date() }

    /// Cursor's own activity line is the most useful thing to show while a run is going;
    /// once it finishes, the project is what tells rows apart.
    private var detail: String {
        guard let subtitle = row.subtitle, !subtitle.isEmpty else { return row.project }
        return "\(row.project) · \(subtitle)"
    }

    var body: some View {
        HStack(spacing: 9) {
            StatusDot(status: row.status)
                .frame(width: 10)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(row.status.isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            Text(Format.duration(row.duration))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(row.status == .running ? row.status.tint : Color.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.rowHeight)
        .background(background)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onSelect(row) }
        .help(detail)
    }

    private var background: some View {
        ZStack {
            if hovering { Color.white.opacity(0.06) }
            if let flash = row.flashUntil, flash > now {
                row.status.tint.opacity(0.16)
            }
        }
    }

}

private struct StatusDot: View {
    let status: TurnStatus

    var body: some View {
        switch status {
        case .running:
            PulsingDot(color: status.tint, diameter: 7)
                .frame(width: 7, height: 7)
        case .stalled:
            Circle()
                .strokeBorder(status.tint, lineWidth: 1.6)
                .frame(width: 8, height: 8)
        case .done(let success):
            Image(systemName: success ? "checkmark" : "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(status.tint)
        }
    }
}

/// A dot that breathes while a run is in flight.
///
/// Deliberately not a SwiftUI `repeatForever` animation: that re-evaluates the view every
/// frame and measured at ~5% of a core for a window that is meant to sit there all day.
/// A Core Animation layer animation is handed to the render server and costs the app nothing.
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

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
