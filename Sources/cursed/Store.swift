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

/// Polls Cursor's database and publishes the conversations worth showing.
@MainActor
final class Store: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: String
        var title: String
        var project: String
        var status: TurnStatus
        /// Time the current run has been going, or how long the finished one took.
        var duration: TimeInterval
        /// Last time Cursor touched the conversation; for a finished run this is when it ended.
        var lastActivity: Date
        var subtitle: String?
        var flashUntil: Date?
    }

    @Published private(set) var rows: [Row] = []

    /// How long a finished conversation stays on screen, so a completion is never missed.
    private let doneVisibility: TimeInterval = 10 * 60
    /// An open run whose heartbeat is older than this is reported as stalled. The heartbeat can
    /// legitimately lag by up to a minute, so this is deliberately well clear of that.
    private let stallThreshold: TimeInterval = 4 * 60
    /// Stalled runs are abandoned rather than pending once they go this cold.
    private let stalledVisibility: TimeInterval = 30 * 60
    private let flashDuration: TimeInterval = 2.5
    /// Only conversations changed this recently are even considered.
    private let queryWindow: TimeInterval = 2 * 60 * 60

    private let db = CursorDB()
    private var timer: Timer?
    private var activeIDs: Set<String> = []
    private var flashUntil: [String: Date] = [:]

    var onFinished: ((Row) -> Void)?

    func start() {
        poll()
        schedule(interval: pollInterval)
    }

    /// Fills the panel with one row per state, for judging the design without waiting for real
    /// runs to reach each state.
    func startDemo() {
        let now = Date()
        rows = [
            Row(id: "1", title: "Refactor payments pipeline", project: "utilityprofit",
                status: .running, duration: 1_337, lastActivity: now,
                subtitle: "Edited charge.ts, ledger.ts", flashUntil: nil),
            Row(id: "2", title: "Cursor app status window", project: "cursed",
                status: .running, duration: 92, lastActivity: now,
                subtitle: "Edited ContentView.swift", flashUntil: nil),
            Row(id: "3", title: "Ask page submission lag", project: "the-architect",
                status: .stalled, duration: 3_355, lastActivity: now, subtitle: nil, flashUntil: nil),
            Row(id: "4", title: "Structured thinking UI", project: "the-architect",
                status: .done(success: true), duration: 781, lastActivity: now,
                subtitle: nil, flashUntil: nil),
            Row(id: "5", title: "Bulk tenant upload inquiry", project: "utilityprofit",
                status: .done(success: false), duration: 148, lastActivity: now,
                subtitle: nil, flashUntil: nil),
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

            switch status {
            case .running:
                break
            case .stalled:
                if now.timeIntervalSince(snapshot.checkpoint) > stalledVisibility { continue }
            case .done:
                if now.timeIntervalSince(snapshot.checkpoint) > doneVisibility { continue }
                // A run that ended while we were watching earns a flash and a chime.
                if activeIDs.contains(snapshot.id), flashUntil[snapshot.id] == nil {
                    flashUntil[snapshot.id] = now.addingTimeInterval(flashDuration)
                    onFinished?(row(snapshot, status: status, now: now, flash: nil))
                }
            }

            let flash = flashUntil[snapshot.id].flatMap { $0 > now ? $0 : nil }
            visible.append(row(snapshot, status: status, now: now, flash: flash))
        }

        activeIDs = stillActive
        flashUntil = flashUntil.filter { $0.value > now }

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

    private func row(_ snapshot: ConversationSnapshot, status: TurnStatus,
                     now: Date, flash: Date?) -> Row {
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
            duration: duration,
            lastActivity: snapshot.checkpoint,
            subtitle: status.isActive ? snapshot.subtitle : nil,
            flashUntil: flash
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
