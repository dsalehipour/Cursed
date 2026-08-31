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

        // Telling a Claude CLI session waiting on you from one working is a matter of what its
        // process did between two readings, and one command has no previous poll to borrow the
        // first reading from. So it takes one, waits long enough to divide by, and then looks.
        let claude = ClaudeCodeDB()
        claude.primeActivityBaseline()
        Thread.sleep(forTimeInterval: 0.6)

        let now = Date()
        let snapshots = (db.fetch(since: 24 * 60 * 60, now: now)
            + ChatGPTDB().fetch(since: 24 * 60 * 60, now: now)
            + claude.fetch(since: 24 * 60 * 60, now: now))
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
                appName(snapshot.source),
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
        let now = Date()
        let snapshots = CursorDB().fetch(since: 24 * 60 * 60, now: now)
            + ChatGPTDB().fetch(since: 24 * 60 * 60, now: now)
            + ClaudeCodeDB().fetch(since: 24 * 60 * 60, now: now)
        guard let match = snapshots.first(where: {
            $0.id.hasPrefix(needle) || $0.name.localizedCaseInsensitiveContains(needle)
        }) else {
            print("no conversation in the last 24h matching \"\(needle)\"")
            exit(1)
        }

        print("target: \(match.name) (\(match.project)) [\(appName(match.source))]")
        print("id:     \(match.id)")

        switch match.source {
        case .cursor:
            CursorLink.reveal(project: match.project, title: match.name)
        case .chatGPT:
            ChatGPTLink.reveal(id: match.id)
        case .claudeCode:
            ClaudeCodeLink.reveal(id: match.id, openID: match.openID)
        }

        // The palette route is asynchronous, and without an NSApplication nothing is turning the
        // runloop for it. Whether it worked is a question for the screen: see `drivePalette`.
        RunLoop.main.run(until: Date().addingTimeInterval(6))
        print("done — look at \(appName(match.source)) to see which conversation it is showing")
        exit(0)
    }

    /// Times a poll the way the panel actually makes one — every reader, not just the cheap one.
    ///
    /// It used to time Cursor's alone, and reported a poll costing a fraction of a percent of a
    /// core while the two readers that walk whole files went unmeasured beside it. That is how a
    /// poll came to spend six seconds of a one-second budget without the benchmark ever noticing:
    /// the number it printed was true, and about the wrong thing. Every source is timed here now,
    /// and the first pass is reported separately from the rest, because the gap between them is
    /// the caching working.
    static func bench(iterations: Int = 200) {
        let window: TimeInterval = 2 * 60 * 60
        let cursor = CursorDB()
        let chatGPT = ChatGPTDB()
        let claude = ClaudeCodeDB()

        func time(_ label: String, _ fetch: () -> Int) {
            // The first read of a file is the one that pays for parsing it; every later read is
            // the cache answering. Both are worth seeing, since the first is what a cold launch
            // costs and the second is what sitting on screen all day costs.
            let coldStart = Date()
            let rows = fetch()
            let cold = Date().timeIntervalSince(coldStart)

            let warmStart = Date()
            for _ in 0..<iterations { _ = fetch() }
            let warm = Date().timeIntervalSince(warmStart) / Double(iterations)

            print(String(format: "  %-13@ %8.2f ms first  %8.2f ms cached  %6.2f%% of a core  (%d rows)",
                         label as NSString, cold * 1000, warm * 1000, warm * 100, rows))
        }

        print("poll cost by source, at 1 poll/sec:")
        time("Cursor", { cursor.fetch(since: window).count })
        time("ChatGPT", { chatGPT.fetch(since: window).count })
        time("Claude Code", { claude.fetch(since: window).count })

        guard cursor.isOpen, let sample = cursor.fetch(since: window).first else { return }
        // Cursor's is the one history the panel has to ask for separately, since the other two
        // derive theirs while walking a transcript they had to read anyway. It is only paid when
        // a live conversation may have moved on, at most once every five seconds each.
        let anchorStart = Date()
        for _ in 0..<iterations { _ = cursor.history(of: sample.id) }
        let each = Date().timeIntervalSince(anchorStart) / Double(iterations) * 1000
        print(String(format: "\nCursor history walk: %.2f ms each, for \"%@\"",
                     each, sample.name as NSString))
    }

    private static func appName(_ source: ConversationSnapshot.Source) -> String {
        switch source {
        case .cursor: return "Cursor"
        case .chatGPT: return "ChatGPT"
        case .claudeCode: return "Claude"
        }
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
