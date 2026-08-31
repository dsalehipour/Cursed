import Foundation

/// Every read of a database or a file the panel depends on, kept off the main thread.
///
/// The poll used to run wherever it was called from, which was the main thread, because that is
/// where the timer and the store live. That was affordable while Cursor was the only source: its
/// poll is a bounded query over a few columns and costs a couple of milliseconds. It stopped being
/// affordable when two readers arrived that answer by walking whole files. A Codex rollout is
/// appended to for the life of a task and reaches hundreds of megabytes, and reading one on the
/// thread that also lays out the window and delivers clicks is why a click could sit for seconds
/// behind a poll and why dragging the panel stuttered after a long day.
///
/// Caching the parses is what makes that work small — see `TranscriptCache` — and this is what
/// keeps whatever remains of it from landing on the main thread again. Both halves are needed:
/// a cache alone still pays for the first read of every file, which is the one that costs seconds,
/// and a background thread alone would just burn a core somewhere less visible.
///
/// The readers are held here and nowhere else, which is what makes them safe to use without locks:
/// they are only ever touched from inside this actor.
actor ConversationReader {
    private let cursor = CursorDB()
    private let chatGPT = ChatGPTDB()
    private let claudeCode = ClaudeCodeDB()

    /// One poll's worth of answers, and everything in it is a value, so handing it to the main
    /// thread cannot leave the two sharing anything.
    struct Reading: Sendable {
        var snapshots: [ConversationSnapshot] = []
        /// The conversation Cursor has on screen, whether or not Cursor is the app you are
        /// looking at. The store pairs it with a frontmost check, which has to stay on the main
        /// thread because that is where AppKit will answer it.
        var selectedConversationID: String?
    }

    func read(window: TimeInterval, now: Date) -> Reading {
        let fetched = cursor.fetch(since: window, now: now)
            + chatGPT.fetch(since: window, now: now)
            + claudeCode.fetch(since: window, now: now)

        var reading = Reading()
        reading.snapshots.reserveCapacity(fetched.count)
        var active: Set<String> = []
        var scanned: Set<String> = []

        for var snapshot in fetched {
            scanned.insert(snapshot.id)
            let status = Store.status(for: snapshot, now: now, stallAfter: Store.stallThreshold)
            if status.isActive { active.insert(snapshot.id) }
            // ChatGPT and Claude Code derive this while walking the transcript they had to read
            // anyway. Only Cursor has to be asked for it separately, and it is the expensive one.
            if snapshot.sourceHistory == nil {
                // A run ending is the one moment worth reading the history immediately rather
                // than when the throttle next allows: it is how a question announces itself, and
                // waiting even a second would chime for a completion and then correct itself.
                let justEnded = activeIDs.contains(snapshot.id) && !status.isActive
                snapshot.sourceHistory = history(for: snapshot, active: status.isActive,
                                                 force: justEnded, now: now)
            }
            reading.snapshots.append(snapshot)
        }

        activeIDs = active
        // Anchors are kept for everything looked at rather than everything shown, since a row can
        // be dropped and still be worth one: the answer is what decides whether it comes back, so
        // discarding it would mean re-walking that history on the very next poll.
        anchors = anchors.filter { scanned.contains($0.key) }
        reading.selectedConversationID = cursor.selectedConversationID()
        return reading
    }

    /// Takes the process reading that the first real poll measures against, so a Claude CLI
    /// session parked on a question is told from one working on the very first frame.
    func primeActivityBaseline() {
        claudeCode.primeActivityBaseline()
    }

    /// Which conversations held an open run last poll, so the end of one can be noticed.
    private var activeIDs: Set<String> = []

    /// What the last walk of a Cursor conversation's history found, remembered rather than
    /// re-derived. The walk covers every entry in the conversation, which is far too dear to
    /// repeat every second for answers that change only when you type something or answer a
    /// question.
    private struct Anchor {
        let history: ConversationHistory
        /// Re-derived the moment this moves, since a new run means you certainly said something.
        let runStart: Date
        /// Re-derived when this moves too, which is what catches a question appearing. Asking one
        /// *ends* the run, so keying on the run alone leaves the conversation looking merely
        /// finished, with nothing left to prompt another look at it.
        let signOfLife: Date
        let checkedAt: Date
    }
    private var anchors: [String: Anchor] = [:]
    /// How stale a live conversation's anchor may get. An answer given mid-run surfaces within
    /// this, which is well under the resolution anyone reads a minutes-scale timer at.
    private let anchorRefresh: TimeInterval = 5

    /// When you last spoke in a conversation, and whether it is waiting on an answer from you.
    ///
    /// Anything that stirs at all is worth re-reading, not merely anything still running. A
    /// question ends the run that asked it, so a conversation waiting on you looks exactly like
    /// one that finished and is asking for nothing — and keyed on the run alone, the last reading
    /// taken while it was live would stand for as long as the app did. A conversation already
    /// known to be waiting stays on the same clock for the mirror of that reason: answering does
    /// not begin a new run either, so nothing else would notice you had replied.
    private func history(for snapshot: ConversationSnapshot, active: Bool,
                         force: Bool, now: Date) -> ConversationHistory {
        if !force, let cached = anchors[snapshot.id], cached.runStart == snapshot.lastRunStart {
            let stirred = cached.signOfLife != snapshot.lastSignOfLife
                || active || cached.history.awaitingAnswer
            if !(stirred && now.timeIntervalSince(cached.checkedAt) > anchorRefresh) {
                return cached.history
            }
        }
        let fresh = cursor.history(of: snapshot.id)
        anchors[snapshot.id] = Anchor(history: fresh, runStart: snapshot.lastRunStart,
                                      signOfLife: snapshot.lastSignOfLife, checkedAt: now)
        return fresh
    }
}
