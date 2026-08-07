import Foundation

/// `cursed --list` prints current conversation state and exits, which is the quickest way to
/// sanity-check detection without watching the HUD.
enum Diagnostics {
    static func list() {
        let db = CursorDB()
        guard db.open() else {
            print("could not open Cursor's database — is Cursor installed?")
            return
        }

        let now = Date()
        let snapshots = (db.fetch(since: 24 * 60 * 60, now: now)
            + ChatGPTDB().fetch(since: 24 * 60 * 60, now: now))
            .sorted { $0.checkpoint > $1.checkpoint }
        guard !snapshots.isEmpty else {
            print("no conversations active in the last 24h")
            return
        }

        // The conversation Cursor has open clears its own dot, so naming it here explains why a
        // finished run might never show one.
        if let selected = db.selectedConversationID() {
            print("on screen in Cursor: \(snapshots.first { $0.id == selected }?.name ?? selected)")
            print("")
        }

        print(line("STATUS", "TITLE", "PROJECT", "APP", "ASKED", "QUIET", "ACTIVITY"))
        for snapshot in snapshots {
            // Deliberately the panel's own derivation rather than a second copy of it, so this
            // can be trusted to explain what the panel is doing.
            let status = Store.status(for: snapshot, now: now, stallAfter: Store.stallThreshold)
            let label: String
            switch status {
            case .running: label = "RUNNING"
            case .stalled: label = "STALLED"
            case .done(let completed): label = completed ? "done" : "aborted"
            }
            let history = snapshot.sourceHistory ?? db.history(of: snapshot.id)
            let spoke = history.spokeAt ?? snapshot.unfinishedRunAt ?? snapshot.lastRunStart
            let asked = now.timeIntervalSince(spoke)
            print(line(
                history.awaitingAnswer ? "ASKING" : label,
                String(snapshot.name.prefix(31)),
                snapshot.project,
                snapshot.source == .cursor ? "Cursor" : "ChatGPT",
                Format.duration(max(0, asked)),
                Format.duration(now.timeIntervalSince(snapshot.lastSignOfLife)),
                String((snapshot.subtitle ?? "").prefix(30))
            ))
        }
    }

    /// `cursed --reveal <id or title fragment>` puts one conversation through the same path a
    /// click takes. The fallbacks only run for conversations Cursor has dropped from its recent
    /// list, which is not a state you can sit and wait for, so this is the only practical way to
    /// exercise them.
    @MainActor
    static func reveal(matching needle: String) {
        let db = CursorDB()
        guard db.open() else { print("could not open Cursor's database"); exit(1) }

        let snapshots = db.fetch(since: 24 * 60 * 60)
        guard let match = snapshots.first(where: {
            $0.id.hasPrefix(needle) || $0.name.localizedCaseInsensitiveContains(needle)
        }) else {
            print("no conversation in the last 24h matching \"\(needle)\"")
            exit(1)
        }

        print("target: \(match.name) (\(match.project))")
        print("id:     \(match.id)")

        CursorLink.reveal(project: match.project, title: match.name)

        // The palette route is asynchronous, and without an NSApplication nothing is turning the
        // runloop for it. Whether it worked is a question for the screen: see `drivePalette`.
        RunLoop.main.run(until: Date().addingTimeInterval(6))
        print("done — look at Cursor to see which conversation it is showing")
        exit(0)
    }

    /// Times the database poll in isolation, to separate query cost from UI cost.
    static func bench(iterations: Int = 200) {
        let db = CursorDB()
        guard db.open() else { print("could not open Cursor's database"); return }

        _ = db.fetch(since: 2 * 60 * 60)
        let start = Date()
        var rows = 0
        for _ in 0..<iterations { rows += db.fetch(since: 2 * 60 * 60).count }
        let elapsed = Date().timeIntervalSince(start)

        print(String(format: "%d polls in %.3fs — %.2f ms each (%d rows/poll)",
                     iterations, elapsed, elapsed / Double(iterations) * 1000, rows / iterations))
        print(String(format: "at 1 poll/sec that is %.2f%% of one core", elapsed / Double(iterations) * 100))

        // The timer's anchor is derived separately and costs far more, since it walks a whole
        // conversation rather than reading columns. Timed here so the figure is visible rather
        // than assumed: it is only paid when a live conversation may have moved on, at most once
        // every few seconds each, not once per poll.
        guard let sample = db.fetch(since: 2 * 60 * 60).first else { return }
        let anchorStart = Date()
        for _ in 0..<iterations { _ = db.history(of: sample.id) }
        let each = Date().timeIntervalSince(anchorStart) / Double(iterations) * 1000
        print(String(format: "history lookup: %.2f ms each, for \"%@\"",
                     each, sample.name as NSString))
    }

    private static func line(_ status: String, _ title: String, _ project: String, _ app: String,
                             _ asked: String, _ quiet: String, _ activity: String) -> String {
        pad(status, 9) + pad(title, 33) + pad(project, 18) + pad(app, 9) + pad(asked, 10)
            + pad(quiet, 9) + activity
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }
}
