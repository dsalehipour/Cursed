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

/// How much of your attention a row is asking for. This, rather than the raw status, is what the
/// panel renders: what gets marked is a conversation that cannot go any further without you.
enum Attention: String {
    /// A question is on screen in Cursor with no answer yet. Outranks every other state, and
    /// unlike them it is not cleared by being seen — reading a question is not answering it.
    case asking
    /// Still going. Reads as ordinary text, with nothing to draw the eye.
    case working
    /// Finished, and you have not acknowledged it yet.
    case unseen
    /// Old news: you clicked it, you stopped it yourself, or you read it in Cursor.
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
        /// How long ago you last said anything here — a message you typed, or an answer you gave
        /// to one of Cursor's in-chat questions.
        var sinceLastMessage: TimeInterval
        /// Last time Cursor touched the conversation; for a finished run this is when it ended.
        var lastActivity: Date
        var source: ConversationSnapshot.Source = .cursor
        /// Claude Desktop's `local_*` id when this row came from a Desktop-linked transcript.
        var openID: String? = nil
    }

    @Published private(set) var rows: [Row] = []

    /// Counts the only two changes the panel treats as news: a run finishing, and a run stopping to
    /// ask. It is what the layout animates on, so the rows move for exactly the events that would
    /// also have chimed, and sit still for a run merely starting or going quiet. A count rather
    /// than a flag, because two completions in a row are two separate pieces of news.
    @Published private(set) var announcements = 0

    /// How long a finished conversation stays listed at all, counted from when it finished.
    private let doneVisibility: TimeInterval = 30 * 60
    /// An open run whose heartbeat is older than this is reported as stalled. The heartbeat can
    /// legitimately lag by up to a minute, so this is deliberately well clear of that.
    nonisolated static let stallThreshold: TimeInterval = 4 * 60
    /// Stalled runs are abandoned rather than pending once they go this cold.
    private let stalledVisibility: TimeInterval = 30 * 60
    /// Only conversations changed this recently are even considered.
    private let queryWindow: TimeInterval = 2 * 60 * 60

    /// Every database and file read the panel makes, and the only place they happen. Held as an
    /// actor so none of it can touch the thread that draws the window.
    private let reader = ConversationReader()
    private var timer: Timer?
    /// One poll at a time. The timer goes on firing while a reading is in flight, and two polls
    /// landing together would each count the same completion as news.
    private var polling = false
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
    /// Completions that finished without you seeing them, kept by their last snapshot so the row
    /// can outlive the query window. This is what makes "unseen" mean it waits for you rather
    /// than for a while: nothing here expires on age, only on being seen or dismissed. Held in
    /// memory only, so a restart forgets them, in keeping with everything else here.
    private var waiting: [String: ConversationSnapshot] = [:]
    private var hasPolled = false

    var onFinished: ((Row) -> Void)?
    var onAsked: ((Row) -> Void)?
    /// Which conversations were already waiting on an answer last poll, so a question announces
    /// itself once when it appears rather than every second it goes unanswered.
    private var askingIDs: Set<String> = []

    func start() {
        Task {
            // Telling a Claude CLI session waiting on you from one working is a matter of what
            // its process did between two readings, and the first poll has no earlier one to
            // measure against.
            await reader.primeActivityBaseline()
            await poll()
        }
        schedule(interval: pollInterval)
    }

    /// Clicking a row is as clear a statement as there is that you have seen it, so the dot goes
    /// straight away.
    func acknowledge(_ id: String) {
        lastViewed[id] = Date()
        Task { await poll() }
    }

    /// Drops a row from the panel until its conversation next starts a run.
    ///
    /// Measured against the run's start rather than its heartbeat, so dismissing something that
    /// is still going hides it for the rest of that run instead of having it reappear a second
    /// later on the next beat. Saying "not interested in this one" should stick until the
    /// conversation does something genuinely new.
    func dismiss(_ id: String) {
        dismissed[id] = Date()
        // Otherwise it would be held indefinitely as an unseen completion, waiting for an
        // acknowledgement that dismissing it has already given.
        waiting.removeValue(forKey: id)
        Task { await poll() }
    }

    /// Fills the panel with one row per state, for judging the design without waiting for real
    /// runs to reach each state.
    func startDemo() {
        let now = Date()
        rows = [
            Row(id: "0", title: "Migrate auth to sessions", project: "utilityprofit",
                status: .running, attention: .asking,
                sinceLastMessage: 412, lastActivity: now),
            Row(id: "1", title: "Refactor payments pipeline", project: "utilityprofit",
                status: .running, attention: .working,
                sinceLastMessage: 1_337, lastActivity: now),
            Row(id: "2", title: "Cursor app status window", project: "cursed",
                status: .running, attention: .working,
                sinceLastMessage: 92, lastActivity: now),
            Row(id: "3", title: "Structured thinking UI", project: "the-architect",
                status: .done(success: true), attention: .unseen,
                sinceLastMessage: 781, lastActivity: now),
            Row(id: "4", title: "Ask page submission lag", project: "the-architect",
                status: .done(success: true), attention: .settled,
                sinceLastMessage: 3_355, lastActivity: now),
            Row(id: "5", title: "Bulk tenant upload inquiry", project: "utilityprofit",
                status: .done(success: false), attention: .settled,
                sinceLastMessage: 148, lastActivity: now),
        ]
    }

    private var pollInterval: TimeInterval {
        rows.contains { $0.status.isActive } ? 1 : 3
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }

        let now = Date()
        let reading = await reader.read(window: queryWindow, now: now)
        let fetched = reading.snapshots
        // A completion you have not seen outlives the query window. Once the conversation stops
        // being fetched it is served from the last snapshot taken of it, so being away for two
        // hours cannot make a waiting dot disappear.
        let present = Set(fetched.map(\.id))
        let snapshots = fetched + waiting.values.filter { !present.contains($0.id) }

        // Anything already finished at launch is adopted as seen. The app cannot have shown you a
        // dot for work that ended before it was watching, and since view times are not persisted,
        // the alternative is every restart opening with a screenful of dots for this afternoon's
        // finished runs — the dot would come to mean "recent" instead of "yours to look at". The
        // time recorded is the moment each one finished rather than now, since now would read as
        // having just dealt with them and keep the lot on screen as grey history.
        let firstPoll = !hasPolled
        if firstPoll {
            hasPolled = true
            for snapshot in snapshots {
                if case .done = status(for: snapshot, now: now) {
                    lastViewed[snapshot.id] = snapshot.checkpoint
                }
            }
        }

        // Before the rows are built, so a conversation you are reading right now is already
        // marked seen by the time this poll decides whether to give it a dot.
        noteConversationOnScreen(now: now, in: snapshots,
                                 selected: reading.selectedConversationID)
        noteChatGPTReadReceipts(now: now, in: snapshots)

        var visible: [Row] = []
        var stillActive: Set<String> = []
        var stillAsking: Set<String> = []

        for snapshot in snapshots {
            let status = status(for: snapshot, now: now)
            if status.isActive { stillActive.insert(snapshot.id) }
            // Ahead of the chime as well as the row, so something you have waved off stays quiet.
            if let waved = dismissed[snapshot.id], snapshot.lastRunStart <= waved { continue }
            let justEnded = activeIDs.contains(snapshot.id) && !status.isActive
            // Resolved by the reader, for every source rather than only the two that get it for
            // free. A snapshot served from `waiting` keeps the one it was stored with, which is
            // the right answer for a conversation that has stopped being fetched at all.
            let history = snapshot.sourceHistory ?? .unknown
            let attention = attention(for: status, id: snapshot.id,
                                      finishedAt: snapshot.checkpoint,
                                      awaitingAnswer: history.awaitingAnswer, now: now)
            // Settled before the filters below, every one of which can skip the rest of this
            // iteration. Leaving a stale snapshot behind would have the next poll serve the row
            // back from it, dot and all, which is precisely what dropping it meant to do.
            if attention == .unseen || attention == .asking {
                waiting[snapshot.id] = snapshot
            } else {
                waiting.removeValue(forKey: snapshot.id)
            }
            var justFinished = false

            // Nothing below applies to a conversation waiting on an answer. It is stuck until you
            // reply, and how long it has been stuck is an argument for showing it rather than
            // against: a question that has gone quiet for an hour is the one most worth surfacing.
            switch status {
            case .running:
                break
            case .stalled:
                if attention != .asking,
                   now.timeIntervalSince(snapshot.lastSignOfLife) > stalledVisibility { continue }
            case .done:
                // Age retires history, never a mark: a completion you have not seen stays until
                // you see it, however long that takes. The clock then runs from when you dealt
                // with it rather than from when it finished, so reading something that has been
                // waiting all afternoon leaves it in view as grey history for a while, instead of
                // deleting the row from under the click that acknowledged it.
                let dealtWith = max(snapshot.checkpoint, lastViewed[snapshot.id] ?? .distantPast)
                if attention != .unseen, attention != .asking,
                   now.timeIntervalSince(dealtWith) > doneVisibility { continue }
                // A run that stopped to ask you something has not finished, whatever the database
                // says, so it is announced as a question and not twice over as a completion.
                justFinished = justEnded && attention != .asking
            }

            let entry = row(snapshot, status: status, attention: attention,
                            spokeAt: history.spokeAt, now: now)
            if justFinished {
                announcements += 1
                onFinished?(entry)
            }
            if attention == .asking {
                stillAsking.insert(snapshot.id)
                // Nothing is announced on the first poll: a question already on screen when the
                // app started is not news, in the same way a run finished before then is not.
                if !askingIDs.contains(snapshot.id), !firstPoll {
                    announcements += 1
                    onAsked?(entry)
                }
            }
            visible.append(entry)
        }

        activeIDs = stillActive
        askingIDs = stillAsking
        // View times outlive the list. A row leaving it is usually the consequence of having been
        // seen, so pruning against what is listed would forget the acknowledgement and hand the
        // row its dot back on the very next poll. They expire by age instead, past the point
        // where the conversation is fetched at all.
        lastViewed = lastViewed.filter { now.timeIntervalSince($0.value) <= queryWindow }
        // Dismissals cannot be pruned against what is listed, since keeping the row out of that
        // list is the whole point. They expire by age instead: beyond the query window the
        // conversation is no longer fetched at all, and one that resumes has a newer run start
        // and is showing again regardless.
        dismissed = dismissed.filter { now.timeIntervalSince($0.value) <= queryWindow }

        let wasActive = rows.contains { $0.status.isActive }
        rows = visible.sorted { a, b in
            let rankA = rank(a), rankB = rank(b)
            if rankA != rankB { return rankA < rankB }
            // Waiting longest first among active runs, since those are likeliest to need
            // attention; most recently finished first among the rest.
            return a.status.isActive
                ? a.sinceLastMessage > b.sinceLastMessage
                : a.lastActivity > b.lastActivity
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
    private func noteConversationOnScreen(now: Date, in snapshots: [ConversationSnapshot],
                                          selected: String?) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == CursorLink.bundleID,
              let id = selected else { return }
        lastViewed[id] = now

        // Logged on change only: this runs every poll for as long as Cursor is in front. Named
        // from the snapshots rather than the rows, which are still empty on the first poll.
        if id != lastNoted {
            lastNoted = id
            Log.write("reading \(snapshots.first { $0.id == id }?.name ?? id)")
        }
    }

    /// ChatGPT publishes an explicit unread-id set. It remains authoritative even if you switch
    /// away before our next poll, unlike a frontmost-window inference.
    private func noteChatGPTReadReceipts(now: Date, in snapshots: [ConversationSnapshot]) {
        for snapshot in snapshots where snapshot.source == .chatGPT
            && snapshot.sourceIsUnread == false {
            lastViewed[snapshot.id] = now
        }
    }

    /// A finished run keeps its dot until you have actually seen it — no sooner, and on no timer.
    /// Letting one lapse on age would have the panel quietly decide you had noticed something you
    /// had not, which is the one thing it exists to prevent. An aborted run is the exception and
    /// never earns a dot: you stopped it yourself, so you already know.
    private func attention(for status: TurnStatus, id: String, finishedAt: Date,
                           awaitingAnswer: Bool, now: Date) -> Attention {
        // An unanswered question outranks the lot, including the status: a conversation that has
        // stopped to ask you something may still hold an open run, and it is neither finished nor
        // getting anywhere. Seeing it is pointedly not enough to clear it, which is the one place
        // this parts company with every other state — you can read a question all day and the
        // conversation stays exactly as stuck as it was.
        if awaitingAnswer { return .asking }

        switch status {
        case .running, .stalled:
            return .working
        case .done(let success):
            // Seen *before* it finished does not count, which is what keeps a run you glanced at
            // and then left from slipping past unnoticed.
            guard success, (lastViewed[id] ?? .distantPast) < finishedAt else { return .settled }
            return .unseen
        }
    }

    private func row(_ snapshot: ConversationSnapshot, status: TurnStatus,
                     attention: Attention, spokeAt: Date?, now: Date) -> Row {
        let asked = spokeAt ?? snapshot.unfinishedRunAt ?? snapshot.lastRunStart
        return Row(
            id: snapshot.id,
            title: snapshot.name,
            project: snapshot.project,
            status: status,
            attention: attention,
            sinceLastMessage: max(0, now.timeIntervalSince(asked)),
            lastActivity: snapshot.checkpoint,
            source: snapshot.source,
            openID: snapshot.openID
        )
    }

    /// Questions first, then runs in flight, then completions still waiting on you, then history.
    ///
    /// A question goes above even a live run because it is the only row in the panel that is
    /// genuinely blocked: everything else is either making progress or already done. The ranks
    /// below it matter for the same reason, since neither questions nor unseen completions expire
    /// — ordered by date alone, something from this morning would sink beneath the afternoon's
    /// work and into the overflow count, which is the one place a row waiting on you must not be.
    private func rank(_ row: Row) -> Int {
        if row.attention == .asking { return 0 }
        switch row.status {
        case .running: return 1
        case .stalled: return 2
        case .done: return row.attention == .unseen ? 3 : 4
        }
    }
}
