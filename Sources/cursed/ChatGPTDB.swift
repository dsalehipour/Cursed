import Foundation
import SQLite3

/// Read-only adapter for Codex tasks shown by the ChatGPT Mac app.
///
/// Task metadata lives in `state_5.sqlite`; live lifecycle events are appended to each task's
/// rollout JSONL. Reading both avoids guessing from a database timestamp that also changes for
/// title and metadata updates.
final class ChatGPTDB {
    private var handle: OpaquePointer?
    private var statement: OpaquePointer?

    private static var path: String {
        ProcessInfo.processInfo.environment["CURSED_CHATGPT_DB"]
            ?? NSHomeDirectory() + "/.codex/state_5.sqlite"
    }

    private static let sql = """
        SELECT id, title, cwd, rollout_path,
               COALESCE(updated_at_ms, updated_at * 1000), source
        FROM threads
        WHERE archived = 0
          AND COALESCE(updated_at_ms, updated_at * 1000) > ?1
          AND preview <> ''
        ORDER BY COALESCE(updated_at_ms, updated_at * 1000) DESC
        LIMIT 40
        """

    @discardableResult
    func open() -> Bool {
        guard handle == nil else { return true }
        guard let encoded = Self.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2("file://" + encoded + "?mode=ro", &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db); return false
        }
        sqlite3_busy_timeout(db, 250)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_close(db); return false
        }
        handle = db
        statement = stmt
        return true
    }

    func close() {
        sqlite3_finalize(statement)
        sqlite3_close(handle)
        statement = nil
        handle = nil
    }

    deinit { close() }

    func fetch(since window: TimeInterval, now: Date = Date()) -> [ConversationSnapshot] {
        guard open(), let statement else { return [] }
        let appState = globalState()
        sqlite3_reset(statement)
        sqlite3_bind_int64(statement, 1,
            Int64(now.addingTimeInterval(-window).timeIntervalSince1970 * 1000))
        defer { sqlite3_reset(statement) }

        var rows: [ConversationSnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0), let rollout = text(statement, 3) else { continue }
            let metadataDate = date(statement, 4) ?? now
            let state = rolloutState(at: rollout, fallback: metadataDate)
            let projectless = appState.projectless.contains(id)
            rows.append(ConversationSnapshot(
                id: id,
                name: text(statement, 1) ?? String(id.prefix(8)),
                workspacePath: projectless ? nil : text(statement, 2),
                unfinishedRunAt: state.running ? state.startedAt : nil,
                status: state.success ? "completed" : "aborted",
                lastRunStart: state.startedAt,
                checkpoint: state.activityAt,
                subtitle: nil,
                source: .chatGPT,
                sourceHistory: ConversationHistory(spokeAt: state.spokeAt,
                                                   awaitingAnswer: state.awaitingAnswer),
                sourceIsUnread: appState.unread.map { $0.contains(id) }
            ))
        }
        return rows
    }

    private struct GlobalState {
        var projectless: Set<String> = []
        /// Nil means the key was unavailable, which must not be interpreted as "all read".
        var unread: Set<String>?
    }

    /// ChatGPT maintains its own read receipts and projectless-task list here. Using those is
    /// more exact than trying to infer the selected React view through Accessibility.
    private func globalState() -> GlobalState {
        let path = NSHomeDirectory() + "/.codex/.codex-global-state.json"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return GlobalState() }

        var result = GlobalState()
        if let ids = root["projectless-thread-ids"] as? [String] {
            result.projectless = Set(ids)
        }
        if let electron = root["electron-persisted-atom-state"] as? [String: Any],
           let byHost = electron["unread-thread-ids-by-host-v1"] as? [String: Any],
           let ids = byHost["local"] as? [String] {
            result.unread = Set(ids)
        }
        return result
    }

    private struct RolloutState {
        var startedAt: Date
        var activityAt: Date
        var spokeAt: Date?
        var running = false
        var success = true
        var awaitingAnswer = false
        var pendingQuestions: Set<String> = []
    }

    private func rolloutState(at path: String, fallback: Date) -> RolloutState {
        var result = RolloutState(startedAt: fallback, activityAt: fallback)
        guard let data = FileManager.default.contents(atPath: path),
              let contents = String(data: data, encoding: .utf8) else { return result }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in contents.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let stamp = object["timestamp"] as? String,
                  let timestamp = formatter.date(from: stamp) else { continue }
            result.activityAt = timestamp
            guard let payload = object["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }

            switch type {
            case "task_started":
                result.startedAt = timestamp
                result.spokeAt = timestamp
                result.running = true
                result.success = true
                result.pendingQuestions.removeAll()
            case "task_complete", "task_completed":
                result.running = false
                result.success = true
            case "turn_aborted", "task_aborted":
                result.running = false
                result.success = false
            case "user_message":
                result.spokeAt = timestamp
                result.pendingQuestions.removeAll()
            case "custom_tool_call":
                let name = payload["name"] as? String
                if name == "request_user_input", let call = payload["call_id"] as? String {
                    result.pendingQuestions.insert(call)
                }
            case "custom_tool_call_output":
                if let call = payload["call_id"] as? String { result.pendingQuestions.remove(call) }
            default:
                break
            }
        }
        result.awaitingAnswer = !result.pendingQuestions.isEmpty
        return result
    }

    private func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let bytes = sqlite3_column_text(stmt, index) else { return nil }
        let value = String(cString: bytes)
        return value.isEmpty ? nil : value
    }

    private func date(_ stmt: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        let millis = sqlite3_column_int64(stmt, index)
        return millis > 0 ? Date(timeIntervalSince1970: Double(millis) / 1000) : nil
    }
}
