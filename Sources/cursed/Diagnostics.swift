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
        let snapshots = db.fetch(since: 24 * 60 * 60, now: now)
        guard !snapshots.isEmpty else {
            print("no conversations active in the last 24h")
            return
        }

        print(line("STATUS", "TITLE", "PROJECT", "ELAPSED", "QUIET", "ACTIVITY"))
        for snapshot in snapshots {
            // Deliberately the panel's own derivation rather than a second copy of it, so this
            // can be trusted to explain what the panel is doing.
            let status = Store.status(for: snapshot, now: now, stallAfter: Store.stallThreshold)
            let label: String
            let elapsed: TimeInterval
            switch status {
            case .running:
                label = "RUNNING"
                elapsed = now.timeIntervalSince(snapshot.unfinishedRunAt ?? now)
            case .stalled:
                label = "STALLED"
                elapsed = now.timeIntervalSince(snapshot.unfinishedRunAt ?? now)
            case .done(let completed):
                label = completed ? "done" : "aborted"
                elapsed = max(0, snapshot.checkpoint.timeIntervalSince(snapshot.lastRunStart))
            }
            print(line(
                label,
                String(snapshot.name.prefix(31)),
                snapshot.project,
                Format.duration(elapsed),
                Format.duration(now.timeIntervalSince(snapshot.lastSignOfLife)),
                String((snapshot.subtitle ?? "").prefix(30))
            ))
        }
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
    }

    private static func line(_ status: String, _ title: String, _ project: String,
                             _ elapsed: String, _ quiet: String, _ activity: String) -> String {
        pad(status, 9) + pad(title, 33) + pad(project, 18) + pad(elapsed, 10)
            + pad(quiet, 9) + activity
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }
}
