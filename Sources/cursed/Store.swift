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
    nonisolated static let stallThreshold: TimeInterval = 4 * 60
    /// Stalled runs are abandoned rather than pending once they go this cold.
    private let stalledVisibility: TimeInterval = 30 * 60
    /// Only conversations changed this recently are even considered.
    private let queryWindow: TimeInterval = 2 * 60 * 60

    private let db = CursorDB()
    private var timer: Timer?
    private var activeIDs: Set<String> = []
    /// When each conversation was last in front of you. A timestamp rather than a flag, because
    /// having seen a conversation only means anything relative to when it finished: glance at a
    /// run, walk away, and the completion that lands afterwards is still news.
    private var lastViewed: [String: Date] = [:]
    /// Only so the log records switching chats rather than every poll spent reading one.
    private var lastNoted: String?
    /// Conversations you have waved off, against the moment you did it. Keyed by time for the
    /// same reason as `lastViewed`: it is what lets the row come back when there is genuinely
    /// something new, rather than staying gone for good.
    private var dismissed: [String: Date] = [:]

    var onFinished: ((Row) -> Void)?

    func start() {
        poll()
        schedule(interval: pollInterval)
    }

    /// Clicking a row is as clear a statement as there is that you have seen it, so the dot goes
    /// straight away rather than waiting out the notice window.
    func acknowledge(_ id: String) {
        lastViewed[id] = Date()
        poll()
    }

    /// Drops a row from the panel until its conversation next starts a run.
    ///
    /// Measured against the run's start rather than its heartbeat, so dismissing something that
    /// is still going hides it for the rest of that run instead of having it reappear a second
    /// later on the next beat. Saying "not interested in this one" should stick until the
    /// conversation does something genuinely new.
    func dismiss(_ id: String) {
        dismissed[id] = Date()
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
        // Before the rows are built, so a conversation you are reading right now is already
        // marked seen by the time this poll decides whether to give it a dot.
        noteConversationOnScreen(now: now, in: snapshots)

        var visible: [Row] = []
        var stillActive: Set<String> = []

        for snapshot in snapshots {
            let status = status(for: snapshot, now: now)
            if status.isActive { stillActive.insert(snapshot.id) }
            // Ahead of the chime as well as the row, so something you have waved off stays quiet.
            if let waved = dismissed[snapshot.id], snapshot.lastRunStart <= waved { continue }
            var justFinished = false

            switch status {
            case .running:
                break
            case .stalled:
                if now.timeIntervalSince(snapshot.lastSignOfLife) > stalledVisibility { continue }
            case .done:
                if now.timeIntervalSince(snapshot.checkpoint) > doneVisibility { continue }
                justFinished = activeIDs.contains(snapshot.id)
            }

            let entry = row(snapshot, status: status, now: now)
            if justFinished { onFinished?(entry) }
            visible.append(entry)
        }

        activeIDs = stillActive
        // View times only matter while the row is listed; drop the rest so the map cannot grow
        // for as long as the app is running.
        let listed = Set(visible.map(\.id))
        lastViewed = lastViewed.filter { listed.contains($0.key) }
        // Dismissals cannot be pruned against what is listed, since keeping the row out of that
        // list is the whole point. They expire by age instead: beyond the query window the
        // conversation is no longer fetched at all, and one that resumes has a newer run start
        // and is showing again regardless.
        dismissed = dismissed.filter { now.timeIntervalSince($0.value) <= queryWindow }

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

    /// Shared with `--list` so the diagnostic can never disagree with the panel.
    nonisolated static func status(for snapshot: ConversationSnapshot, now: Date,
                                   stallAfter: TimeInterval) -> TurnStatus {
        guard snapshot.unfinishedRunAt != nil else {
            return .done(success: snapshot.status == "completed")
        }
        return now.timeIntervalSince(snapshot.lastSignOfLife) > stallAfter ? .stalled : .running
    }

    private func status(for snapshot: ConversationSnapshot, now: Date) -> TurnStatus {
        Self.status(for: snapshot, now: now, stallAfter: Self.stallThreshold)
    }

    /// Reading a conversation in Cursor is as good as clicking its row, so the dot clears itself
    /// rather than asking you to dismiss something you have already dealt with.
    ///
    /// Both halves are needed. The database names the chat that is on screen, but says nothing
    /// about whether you are looking at it: that chat stays selected while Cursor sits behind
    /// your browser, and marking it seen then would clear dots for runs you never saw.
    private func noteConversationOnScreen(now: Date, in snapshots: [ConversationSnapshot]) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == CursorLink.bundleID,
              let id = db.selectedConversationID() else { return }
        lastViewed[id] = now

        // Logged on change only: this runs every poll for as long as Cursor is in front. Named
        // from the snapshots rather than the rows, which are still empty on the first poll.
        if id != lastNoted {
            lastNoted = id
            Log.write("reading \(snapshots.first { $0.id == id }?.name ?? id)")
        }
    }

    /// A finished run is worth marking only while it is plausibly still news. An aborted one
    /// never is: you stopped it yourself, so you already know.
    private func attention(for status: TurnStatus, id: String,
                           finishedAt: Date, now: Date) -> Attention {
        switch status {
        case .running, .stalled:
            return .working
        case .done(let success):
            // Seen *before* it finished does not count, which is what keeps a run you glanced at
            // and then left from slipping past unnoticed.
            guard success, now.timeIntervalSince(finishedAt) <= noticeWindow,
                  (lastViewed[id] ?? .distantPast) < finishedAt else { return .settled }
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
