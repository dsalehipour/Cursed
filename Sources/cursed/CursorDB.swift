import Foundation
import SQLite3

/// Live conversation state, read straight from the database Cursor keeps its chats in.
///
/// The signal that matters is `unfinishedRunAt` inside each conversation's stored blob: Cursor
/// sets it to the exact moment a run begins and clears it when the run ends. That makes
/// "is it still going, and for how long" a direct lookup rather than a guess.
///
/// Two other columns fill in the rest of the picture:
///   * `lastUpdatedAt` — when the most recent run started, which is the moment you sent the
///                       message that began it, and which outlives the run itself.
///   * `checkpointAt`  — a heartbeat written while a conversation is live, so it doubles as the
///                       finish time of a completed run and as a liveness check for a stuck one.
///
/// Everything is opened read-only, so Cursor never contends with us for a write lock.
struct ConversationSnapshot {
    enum Source: String {
        case cursor
        case chatGPT

        var bundleID: String {
            switch self {
            case .cursor: return CursorLink.bundleID
            case .chatGPT: return ChatGPTLink.bundleID
            }
        }
    }

    let id: String
    let name: String
    let workspacePath: String?
    /// Non-nil exactly when a run is in flight; the value is that run's start time.
    let unfinishedRunAt: Date?
    let status: String
    /// Start of the most recent run, and so the moment you last sent a message here. Matches
    /// `unfinishedRunAt` to the millisecond while a run is in flight, and stays put once it ends.
    let lastRunStart: Date
    let checkpoint: Date
    /// Cursor's own one-line description of recent activity, e.g. "Edited main.swift".
    let subtitle: String?
    /// Kept separate so the Cursor reader and all of its existing SQL remain unchanged.
    var source: Source = .cursor
    /// Sources which already have a cheap transcript-derived answer can provide it here.
    var sourceHistory: ConversationHistory? = nil
    /// The source application's own unread state, when it publishes one.
    var sourceIsUnread: Bool? = nil

    var project: String {
        guard let workspacePath, !workspacePath.isEmpty else { return "home" }
        return (workspacePath as NSString).lastPathComponent
    }

    /// The most recent evidence that this conversation is alive.
    ///
    /// A run that has only just begun has not written a heartbeat yet, so `checkpoint` still
    /// belongs to the previous turn and can be hours old. Judging quiet time by the checkpoint
    /// alone therefore reports a run that started seconds ago as stalled.
    var lastSignOfLife: Date {
        guard let unfinishedRunAt else { return checkpoint }
        return max(checkpoint, unfinishedRunAt)
    }
}

/// What walking a conversation's history turns up, beyond what its header row already says.
struct ConversationHistory {
    /// When you last said something here: a message you typed, or an answer you gave.
    let spokeAt: Date?
    /// A question is on screen in Cursor with no answer yet, so the conversation is stuck on you
    /// rather than merely finished.
    let awaitingAnswer: Bool

    /// What a conversation looks like when the lookup is unavailable: silent on both counts, so
    /// callers fall back to header timestamps and nothing is wrongly marked as waiting.
    static let unknown = ConversationHistory(spokeAt: nil, awaitingAnswer: false)
}

final class CursorDB {
    private var handle: OpaquePointer?
    private var statement: OpaquePointer?
    private var selectionStatement: OpaquePointer?
    private var historyStatement: OpaquePointer?

    /// `CURSED_DB` points the reader at a different database, which is how the timing-dependent
    /// states can be reproduced on demand rather than waited for.
    private static var path: String {
        ProcessInfo.processInfo.environment["CURSED_DB"]
            ?? NSHomeDirectory() + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }

    /// Restricting by time keeps the join from touching more than a handful of the (large)
    /// conversation blobs, which is what keeps each poll in the low milliseconds.
    ///
    /// Both timestamps have to be considered. `checkpointAt` is the heartbeat, but it is not
    /// written until a run is underway, so a conversation that has been idle for longer than the
    /// window would stay invisible for the first moments of its next run — exactly when you are
    /// most likely to be looking. `lastUpdatedAt` is set the instant a run starts and closes
    /// that gap.
    ///
    /// The blob is optional, because it lands a beat after the header does. A chat you sent
    /// seconds ago is already in `composerHeaders` with nothing yet under `composerData:`, and
    /// requiring the two kept the newest thing you had running off the panel until Cursor got
    /// around to writing it. The header can stand in: it carries the project and the subtitle
    /// itself, agreeing with the blob's copies wherever both exist.
    ///
    /// Run state is the one thing only the blob knows, and its absence is itself informative.
    /// `unfinishedRunAt` records a run's start and is cleared to record its end, so no blob at all
    /// means a run started at `lastUpdatedAt` with nothing yet saying it ended — which is the
    /// truth of a message you just sent. Should it have finished in the meantime, the blob arrives
    /// saying so within the second; should a header somehow never gain one, the stall timers
    /// retire it as they would any other run that stopped reporting.
    ///
    /// A chat that new has no heartbeat yet either, and `MAX` of a null is null, which sorted it
    /// below every conversation it had just beaten — hence the coalesced ordering key.
    ///
    /// A draft is the one header that must not be read this way. It has no blob either, having
    /// never run at all, and inferring a run would put a row on the panel for a composer box you
    /// typed a word into and abandoned.
    private static let sql = """
        SELECT h.composerId,
               json_extract(h.value, '$.name'),
               COALESCE(json_extract(d.value, '$.workspaceIdentifier.uri.fsPath'),
                        json_extract(h.value, '$.workspaceIdentifier.uri.fsPath')),
               CASE WHEN d.key IS NULL THEN h.lastUpdatedAt
                    ELSE json_extract(d.value, '$.unfinishedRunAt') END,
               json_extract(d.value, '$.status'),
               h.lastUpdatedAt,
               h.checkpointAt,
               COALESCE(json_extract(d.value, '$.subtitle'),
                        json_extract(h.value, '$.subtitle'))
        FROM composerHeaders h
        LEFT JOIN cursorDiskKV d ON d.key = 'composerData:' || h.composerId
        WHERE h.isArchived = 0
          AND h.isSubagent = 0
          AND COALESCE(json_extract(h.value, '$.isDraft'), 0) = 0
          AND (h.checkpointAt > ?1 OR h.lastUpdatedAt > ?1)
        ORDER BY MAX(COALESCE(h.checkpointAt, 0), COALESCE(h.lastUpdatedAt, 0)) DESC
        LIMIT 40
        """

    /// The two things a conversation's header cannot tell you, read in a single walk of its
    /// history because the walk is the expensive part.
    ///
    /// **When you last spoke.** Two things count, recorded very differently. A message you typed
    /// is its own entry, `type: 1`. An answer to one of Cursor's in-chat questions is not an entry
    /// at all: the question's tool call is simply marked answered in place, keeping the
    /// `createdAt` of the moment it was *asked*, which can be many minutes before you got to it.
    /// The entry immediately after an `askQuestionToolCall` is the nearest thing to a record of
    /// your reply, since the model resumes the instant it has one, and it lands within a second or
    /// two. `LAG` is what makes that a single pass: it puts each entry next to the one before it,
    /// so "the entry after a question" is a plain `WHERE` rather than a second walk.
    ///
    /// **Whether a question is still waiting on you.** That is not in the history at all, only in
    /// the question's own bubble, under `toolFormerData`. The field to read is
    /// `additionalData.status`: `pending` while the question sits on screen, `submitted` once you
    /// answer, `cancelled` if you wave it away. Its sibling `status` field is a trap — it reads
    /// `completed` the entire time the question is unanswered, because what completed is the tool
    /// call that posted the question, not the asking. Only the last question is worth consulting,
    /// since any earlier one has necessarily been resolved to get past it.
    private static let historySQL = """
        WITH entry AS (
          SELECT je.key AS idx,
                 json_extract(je.value, '$.type') AS type,
                 json_extract(je.value, '$.createdAt') AS createdAt,
                 json_extract(je.value, '$.bubbleId') AS bubbleId,
                 json_extract(je.value, '$.grouping.toolCallCase') AS toolCase,
                 LAG(json_extract(je.value, '$.grouping.toolCallCase'))
                   OVER (ORDER BY je.key) AS prevCase
          FROM cursorDiskKV d,
               json_each(json_extract(d.value, '$.fullConversationHeadersOnly')) je
          WHERE d.key = 'composerData:' || ?1
        )
        SELECT CAST(strftime('%s', MAX(CASE WHEN type = 1 OR prevCase = 'askQuestionToolCall'
                                            THEN createdAt END)) AS INTEGER) * 1000,
               (SELECT json_extract(json_extract(b.value, '$.toolFormerData.additionalData'),
                                    '$.status')
                FROM cursorDiskKV b
                WHERE b.key = 'bubbleId:' || ?1 || ':'
                      || (SELECT bubbleId FROM entry WHERE toolCase = 'askQuestionToolCall'
                          ORDER BY idx DESC LIMIT 1))
        FROM entry
        """

    /// Cursor records the chat you have open here and rewrites it the moment you switch, which
    /// makes "are you looking at this one" a lookup rather than an inference. The value is the
    /// bare conversation id, and it is global rather than per-window: with several windows open
    /// it names the last chat you selected in any of them.
    private static let selectionSQL = """
        SELECT value FROM ItemTable WHERE key = 'cursor/glass.selectedAgent'
        """

    var isOpen: Bool { handle != nil }

    @discardableResult
    func open() -> Bool {
        guard handle == nil else { return true }
        guard let encoded = Self.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return false }

        var db: OpaquePointer?
        guard sqlite3_open_v2("file://" + encoded + "?mode=ro", &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        sqlite3_busy_timeout(db, 250)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }

        // Prepared separately and allowed to fail: reading which chat is on screen is a
        // convenience, and losing it to a schema change should cost the auto-acknowledge rather
        // than the whole panel.
        var selection: OpaquePointer?
        if sqlite3_prepare_v2(db, Self.selectionSQL, -1, &selection, nil) != SQLITE_OK {
            Log.write("selected-conversation lookup unavailable; rows will need a click")
            sqlite3_finalize(selection)
            selection = nil
        }

        var history: OpaquePointer?
        if sqlite3_prepare_v2(db, Self.historySQL, -1, &history, nil) != SQLITE_OK {
            Log.write("history lookup unavailable; timers will count from the run start and"
                      + " unanswered questions will not be marked")
            sqlite3_finalize(history)
            history = nil
        }

        handle = db
        statement = stmt
        selectionStatement = selection
        historyStatement = history
        return true
    }

    func close() {
        sqlite3_finalize(statement)
        sqlite3_finalize(selectionStatement)
        sqlite3_finalize(historyStatement)
        sqlite3_close(handle)
        statement = nil
        selectionStatement = nil
        historyStatement = nil
        handle = nil
    }

    deinit { close() }

    func fetch(since window: TimeInterval, now: Date = Date()) -> [ConversationSnapshot] {
        guard open(), let statement else { return [] }
        // Reset before use as well as after, so an earlier failure can never leave a read
        // transaction open against Cursor's database.
        sqlite3_reset(statement)
        sqlite3_bind_int64(statement, 1, Int64(now.addingTimeInterval(-window).timeIntervalSince1970 * 1000))

        var results: [ConversationSnapshot] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(statement) }
            guard let idC = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: idC)
            results.append(ConversationSnapshot(
                id: id,
                name: text(statement, 1) ?? String(id.prefix(8)),
                workspacePath: text(statement, 2),
                unfinishedRunAt: date(statement, 3),
                status: text(statement, 4) ?? "unknown",
                lastRunStart: date(statement, 5) ?? now,
                checkpoint: date(statement, 6) ?? now,
                subtitle: text(statement, 7)
            ))
        }
        sqlite3_reset(statement)

        // Restarting Cursor can replace the database underneath us. Drop the connection on any
        // unexpected result so the next poll reconnects instead of failing silently forever.
        if step != SQLITE_DONE {
            Log.write("database read failed (\(step)); reconnecting")
            close()
            return []
        }
        return results
    }

    /// The conversation on screen in Cursor, whether or not Cursor is the app you are actually
    /// looking at. Callers pair it with a frontmost check to decide if it has really been seen.
    func selectedConversationID() -> String? {
        guard open(), let selectionStatement else { return nil }
        sqlite3_reset(selectionStatement)
        defer { sqlite3_reset(selectionStatement) }
        guard sqlite3_step(selectionStatement) == SQLITE_ROW else { return nil }
        return text(selectionStatement, 0)
    }

    /// Costs roughly a hundred times what the main poll does, because it walks every entry in the
    /// conversation's history rather than reading a few columns. Callers are meant to keep the
    /// answer rather than ask again each second: it moves only when you do.
    func history(of id: String) -> ConversationHistory {
        guard open(), let historyStatement else { return ConversationHistory.unknown }
        sqlite3_reset(historyStatement)
        defer { sqlite3_reset(historyStatement) }
        sqlite3_bind_text(historyStatement, 1, id, -1, Self.transient)
        guard sqlite3_step(historyStatement) == SQLITE_ROW else { return .unknown }
        return ConversationHistory(spokeAt: date(historyStatement, 0),
                                   awaitingAnswer: text(historyStatement, 1) == "pending")
    }

    /// SQLite must copy the bound string: the Swift one is not guaranteed to outlive the call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let value = sqlite3_column_text(stmt, index) else { return nil }
        let string = String(cString: value)
        return string.isEmpty ? nil : string
    }

    private func date(_ stmt: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        let millis = sqlite3_column_int64(stmt, index)
        guard millis > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(millis) / 1000)
    }
}
