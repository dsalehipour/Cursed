import Foundation
import AppKit

enum TurnStatus: Equatable {
    case running
    /// A run Cursor still considers open, but whose heartbeat has gone quiet. Usually a crash
    /// or a window that was closed mid-run.
    case stalled
    case done(success: Bool)

    var isActive: Bool {
        switch self {
        case .running, .stalled: return true
        case .done: return false
        }
    }
}

/// How much of your attention a row is asking for. This, rather than the raw status, is what
/// the panel renders: the only thing worth marking is a run that finished without you seeing it.
enum Attention: String {
    /// Still going. Reads as ordinary text, with nothing to draw the eye.
    case working
    /// Finished, and you have not acknowledged it yet. The one state that gets a dot.
    case unseen
    /// Old news: you clicked it, you stopped it yourself, or it has been sitting there a while.
    case settled
}

/// Polls Cursor's database and publishes the conversations worth showing.
@MainActor
final class Store: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: String
        var title: String
        var project: String
        var status: TurnStatus
        var attention: Attention
        /// Time the current run has been going, or how long the finished one took.
        var duration: TimeInterval
        /// Last time Cursor touched the conversation; for a finished run this is when it ended.
        var lastActivity: Date
    }

    @Published private(set) var rows: [Row] = []

    /// How long a finished conversation keeps its dot before it is assumed to have been seen.
    /// Clicking the row says so explicitly and skips the wait.
    private let noticeWindow: TimeInterval = 10 * 60
    /// How long a finished conversation stays listed at all. Comfortably longer than the notice
    /// window, so a completion always gets a spell as quiet history rather than vanishing.
    private let doneVisibility: TimeInterval = 30 * 60
    /// An open run whose heartbeat is older than this is reported as stalled. The heartbeat can
    /// legitimately lag by up to a minute, so this is deliberately well clear of that.
    private let stallThreshold: TimeInterval = 4 * 60
    /// Stalled runs are abandoned rather than pending once they go this cold.
    private let stalledVisibility: TimeInterval = 30 * 60
    /// Only conversations changed this recently are even considered.
    private let queryWindow: TimeInterval = 2 * 60 * 60

    private let db = CursorDB()
    private var timer: Timer?
    private var activeIDs: Set<String> = []
    private var acknowledged: Set<String> = []

    var onFinished: ((Row) -> Void)?

    func start() {
        poll()
        schedule(interval: pollInterval)
    }

    /// Clicking a row is as clear a statement as there is that you have seen it, so the dot goes
    /// straight away rather than waiting out the notice window.
    func acknowledge(_ id: String) {
        guard acknowledged.insert(id).inserted else { return }
        poll()
    }

    /// Fills the panel with one row per state, for judging the design without waiting for real
    /// runs to reach each state.
    func startDemo() {
        let now = Date()
        rows = [
            Row(id: "1", title: "Refactor payments pipeline", project: "utilityprofit",
                status: .running, attention: .working, duration: 1_337, lastActivity: now),
            Row(id: "2", title: "Cursor app status window", project: "cursed",
                status: .running, attention: .working, duration: 92, lastActivity: now),
            Row(id: "3", title: "Structured thinking UI", project: "the-architect",
                status: .done(success: true), attention: .unseen, duration: 781, lastActivity: now),
            Row(id: "4", title: "Ask page submission lag", project: "the-architect",
                status: .done(success: true), attention: .settled, duration: 3_355, lastActivity: now),
            Row(id: "5", title: "Bulk tenant upload inquiry", project: "utilityprofit",
                status: .done(success: false), attention: .settled, duration: 148, lastActivity: now),
        ]
    }

    private var pollInterval: TimeInterval {
        rows.contains { $0.status.isActive } ? 1 : 3
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        let now = Date()
        let snapshots = db.fetch(since: queryWindow, now: now)

        var visible: [Row] = []
        var stillActive: Set<String> = []

        for snapshot in snapshots {
            let status = status(for: snapshot, now: now)
            if status.isActive { stillActive.insert(snapshot.id) }
            var justFinished = false

            switch status {
            case .running:
                break
            case .stalled:
                if now.timeIntervalSince(snapshot.checkpoint) > stalledVisibility { continue }
            case .done:
                if now.timeIntervalSince(snapshot.checkpoint) > doneVisibility { continue }
                justFinished = activeIDs.contains(snapshot.id)
            }

            let entry = row(snapshot, status: status, now: now)
            if justFinished { onFinished?(entry) }
            visible.append(entry)
        }

        activeIDs = stillActive
        // Acknowledgements only matter while the row is on screen; drop the rest so the set
        // cannot grow for as long as the app is running.
        acknowledged.formIntersection(visible.map(\.id))

        let wasActive = rows.contains { $0.status.isActive }
        rows = visible.sorted { a, b in
            let rankA = rank(a.status), rankB = rank(b.status)
            if rankA != rankB { return rankA < rankB }
            // Longest-running first among active runs, since those are likeliest to need
            // attention; most recently finished first among the rest.
            return a.status.isActive ? a.duration > b.duration : a.lastActivity > b.lastActivity
        }

        if wasActive != rows.contains(where: { $0.status.isActive }) {
            schedule(interval: pollInterval)
        }
    }

    private func status(for snapshot: ConversationSnapshot, now: Date) -> TurnStatus {
        guard snapshot.unfinishedRunAt != nil else {
            return .done(success: snapshot.status == "completed")
        }
        return now.timeIntervalSince(snapshot.checkpoint) > stallThreshold ? .stalled : .running
    }

    /// A finished run is worth marking only while it is plausibly still news. An aborted one
    /// never is: you stopped it yourself, so you already know.
    private func attention(for status: TurnStatus, id: String,
                           finishedAt: Date, now: Date) -> Attention {
        switch status {
        case .running, .stalled:
            return .working
        case .done(let success):
            guard success, !acknowledged.contains(id),
                  now.timeIntervalSince(finishedAt) <= noticeWindow else { return .settled }
            return .unseen
        }
    }

    private func row(_ snapshot: ConversationSnapshot, status: TurnStatus, now: Date) -> Row {
        let duration: TimeInterval
        if let start = snapshot.unfinishedRunAt {
            duration = max(0, now.timeIntervalSince(start))
        } else {
            // Aborted runs can record a checkpoint that predates the start, so clamp.
            duration = max(0, snapshot.checkpoint.timeIntervalSince(snapshot.lastRunStart))
        }
        return Row(
            id: snapshot.id,
            title: snapshot.name,
            project: snapshot.project,
            status: status,
            attention: attention(for: status, id: snapshot.id,
                                 finishedAt: snapshot.checkpoint, now: now),
            duration: duration,
            lastActivity: snapshot.checkpoint
        )
    }

    private func rank(_ status: TurnStatus) -> Int {
        switch status {
        case .running: return 0
        case .stalled: return 1
        case .done: return 2
        }
    }
}
