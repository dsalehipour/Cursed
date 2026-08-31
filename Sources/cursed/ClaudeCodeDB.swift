import Foundation

/// Read-only adapter for Claude Code sessions from the CLI and the Claude Desktop app.
///
/// Both write the same transcripts under `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`.
/// Desktop additionally keeps sidebar metadata (titles, and its own `local_*` ids) under
/// `~/Library/Application Support/Claude/claude-code-sessions/`. Reading the JSONL is enough for
/// run / done / asking; the metadata is only consulted for a better title and for opening a
/// session back in the Desktop app.
final class ClaudeCodeDB {
    private static var root: String {
        ProcessInfo.processInfo.environment["CURSED_CLAUDE_DIR"]
            ?? NSHomeDirectory() + "/.claude"
    }

    private static var desktopSessionsRoot: String {
        ProcessInfo.processInfo.environment["CURSED_CLAUDE_DESKTOP_SESSIONS"]
            ?? NSHomeDirectory() + "/Library/Application Support/Claude/claude-code-sessions"
    }

    private static var legacyDesktopSessionsRoot: String {
        NSHomeDirectory() + "/Library/Application Support/Claude/local-agent-mode-sessions"
    }

    private let processes = ClaudeCodeProcesses()
    /// Transcripts grow for as long as their session runs and are re-read every poll, so the walk
    /// is resumed from where the last one finished rather than started again. See
    /// `TranscriptCache`.
    private let transcripts = TranscriptCache<TranscriptState>()

    /// Takes the first process reading, so a caller with only one poll in it can still tell a
    /// session waiting on you from one working. The panel needs nothing: its next poll is a
    /// second away, and the reading it measures against is the one this poll just took.
    func primeActivityBaseline() { processes.primeBaseline() }

    private let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let isoBasic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func fetch(since window: TimeInterval, now: Date = Date()) -> [ConversationSnapshot] {
        let cutoff = now.addingTimeInterval(-window)
        let desktop = desktopIndex()
        let files = sessionFiles()
            .compactMap { url -> (URL, Date)? in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                guard let modified = values?.contentModificationDate, modified > cutoff else {
                    return nil
                }
                return (url, modified)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(40)

        transcripts.prune(keeping: Set(files.map { $0.0.path }))
        let parsed = files.map { (url: $0.0, modified: $0.1, state: transcriptState(at: $0.0)) }
        // Only a CLI session with a turn still open can turn out to be one waiting on you, and
        // walking the process table is not free, so it is walked only when there is such a
        // session to explain. A Desktop session is not a candidate: it has no terminal, and so
        // nothing for `ClaudeCodeProcesses` to find.
        var openTurns: [String: Int] = [:]
        for parsed in parsed where parsed.state.running
            && desktop[parsed.url.deletingPathExtension().lastPathComponent] == nil {
            if let cwd = parsed.state.cwd { openTurns[cwd, default: 0] += 1 }
        }
        // An idling process says *a* session in that directory is waiting on you, never which
        // one, so a directory holding two unfinished CLI transcripts is left alone — as it is
        // when it holds two running processes. An abandoned session keeps its turn open forever,
        // and without this it would take the verdict earned by a live session beside it.
        let parked: Set<String> = openTurns.isEmpty ? []
            : Set(processes.parkedDirectories(now: now).filter { openTurns[$0] == 1 })

        return parsed.compactMap { parsed in
            snapshot(at: parsed.url, modified: parsed.modified, state: parsed.state,
                     desktop: desktop, parked: parked)
        }
        // The window has to bound what comes back, not merely which files are opened. mtime says
        // a file was written to, not that the conversation moved, and these are rewritten for
        // hours after their last turn — so the filter above keeps handing back conversations that
        // have been silent since the morning, and they never age out of the fetch the way every
        // other reader's do. The panel leans on that: a view time is allowed to expire precisely
        // because the conversation it belongs to has stopped being fetched by then. Left
        // unbounded, the acknowledgement expires while the row is still being served, and a
        // conversation you dealt with hours ago earns a fresh dot for having been dealt with too
        // long ago.
        .filter { $0.lastSignOfLife > cutoff }
    }

    /// Locates a session's working directory by reading its transcript, for reveal.
    func workspacePath(of id: String) -> String? {
        guard let url = sessionFiles().first(where: { $0.deletingPathExtension().lastPathComponent == id })
        else { return nil }
        return transcriptState(at: url).cwd
    }

    /// Desktop's own session id (`local_…`) when this CLI transcript is one it knows about.
    func desktopSessionID(of id: String) -> String? {
        desktopIndex()[id]?.desktopID
    }

    struct DesktopMeta {
        var title: String?
        var desktopID: String
        /// The transcript this entry describes, which is only known once the file is read.
        var cliID: String
    }

    private func desktopIndex() -> [String: DesktopMeta] {
        var result: [String: DesktopMeta] = [:]
        for root in [Self.desktopSessionsRoot, Self.legacyDesktopSessionsRoot] {
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.lastPathComponent.hasPrefix("local_"),
                      url.pathExtension == "json",
                      let meta = Self.parseDesktopEntry(at: url) else { continue }

                // One transcript can have two Desktop entries: importing a session Desktop already
                // knows adds a second, untitled one rather than reusing the original. Prefer the
                // named entry, which is the one that reads as the conversation in the sidebar.
                if result[meta.cliID] != nil, meta.title == nil { continue }
                result[meta.cliID] = meta
            }
        }
        return result
    }

    private static func parseDesktopEntry(at url: URL) -> DesktopMeta? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // VM / Cowork sessions are not local Code sessions.
        if object["vmProcessName"] != nil { return nil }
        if let cwd = object["cwd"] as? String, cwd.hasPrefix("/sessions/") { return nil }
        if object["isArchived"] as? Bool == true { return nil }

        let desktopID = (object["sessionId"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        guard let cliID = object["cliSessionId"] as? String, !cliID.isEmpty else { return nil }
        let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DesktopMeta(
            title: (title?.isEmpty == false) ? title : nil,
            desktopID: desktopID,
            cliID: cliID
        )
    }

    private func sessionFiles() -> [URL] {
        let projects = URL(fileURLWithPath: Self.root).appendingPathComponent("projects", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: projects,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            // Subagent transcripts live under a `subagents/` folder next to the parent session.
            if url.pathComponents.contains("subagents") { continue }
            files.append(url)
        }
        return files
    }

    private func snapshot(at url: URL, modified: Date, state: TranscriptState,
                          desktop: [String: DesktopMeta],
                          parked: Set<String>) -> ConversationSnapshot? {
        let id = url.deletingPathExtension().lastPathComponent
        // Nothing we can show without at least one real user prompt (or a turn still open).
        guard state.spokeAt != nil || state.running || state.awaitingAnswer else { return nil }

        let meta = desktop[id]
        let title = meta?.title
            ?? state.customTitle
            ?? state.aiTitle
            ?? state.lastPrompt.map(Self.shortTitle)
            ?? state.firstPrompt.map(Self.shortTitle)
            ?? String(id.prefix(8))

        // A CLI turn that is open while its process does nothing is one stopped to ask you
        // something: the question itself reaches the transcript only once it has been answered.
        let parkedOnYou = state.running && meta == nil
            && (state.cwd.map(parked.contains) ?? false)
        let awaitingAnswer = state.awaitingAnswer || parkedOnYou
        // Being asked ends the run that asked, the same as a question read from the transcript.
        let running = state.running && !awaitingAnswer

        let started = state.turnStartedAt ?? state.spokeAt ?? state.activityAt
        // When the conversation last did something is the last entry stamped inside the
        // transcript, never the file's own mtime. The two are hours apart: these files are
        // rewritten long after their final turn — appended entries that carry no timestamp,
        // and rewrites by the Desktop app — so a finished run's mtime creeps forward all
        // afternoon. Taken as the finish time it lands after the moment you clicked the row,
        // which reads as a completion you have not seen and hands the dot straight back.
        let checkpoint = state.activityAt == .distantPast ? modified : state.activityAt
        return ConversationSnapshot(
            id: id,
            name: title,
            workspacePath: state.cwd,
            unfinishedRunAt: running ? started : nil,
            status: state.success ? "completed" : "aborted",
            lastRunStart: started,
            checkpoint: checkpoint,
            subtitle: nil,
            source: .claudeCode,
            sourceHistory: ConversationHistory(spokeAt: state.spokeAt,
                                               awaitingAnswer: awaitingAnswer),
            openID: meta?.desktopID
        )
    }

    private struct TranscriptState {
        var cwd: String?
        var activityAt: Date = .distantPast
        var spokeAt: Date?
        var turnStartedAt: Date?
        var firstPrompt: String?
        var lastPrompt: String?
        var customTitle: String?
        var aiTitle: String?
        var running = false
        var success = true
        var awaitingAnswer = false
        var openTools: Set<String> = []
        var pendingAsks: Set<String> = []
        /// True after a typed user message until the assistant finishes that turn with no open tools.
        var awaitingAssistant = false
    }

    /// The transcript's own account of the session, with the verdicts drawn from it afterwards.
    ///
    /// The verdicts are deliberately not folded in: this state is what the cache resumes from, and
    /// one carrying a conclusion would take it into the next batch of lines as though the file had
    /// said so.
    private func transcriptState(at url: URL) -> TranscriptState {
        var result = transcripts.state(of: url, initial: TranscriptState.init) { state, line in
            self.fold(&state, line)
        }
        result.running = result.awaitingAssistant || !result.openTools.isEmpty
        result.awaitingAnswer = !result.pendingAsks.isEmpty
        // A question ends the turn that asked it, the same way Cursor's ask does: the panel
        // should show amber, not a live run that cannot proceed.
        if result.awaitingAnswer { result.running = false }
        return result
    }

    private func fold(_ result: inout TranscriptState, _ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return }

        if let cwd = object["cwd"] as? String, !cwd.isEmpty { result.cwd = cwd }
        if let stamp = parseDate(object["timestamp"] as? String) {
            result.activityAt = stamp
        }

        // Sidechains are exploratory branches; their tool traffic must not keep the parent
        // session looking mid-turn.
        if object["isSidechain"] as? Bool == true { return }

        switch type {
        case "user":
            applyUser(object, to: &result)
        case "assistant":
            applyAssistant(object, to: &result)
        case "custom-title":
            if let title = object["customTitle"] as? String, !title.isEmpty {
                result.customTitle = title
            }
        case "ai-title":
            if let title = object["aiTitle"] as? String, !title.isEmpty {
                result.aiTitle = title
            }
        case "last-prompt":
            if let prompt = object["lastPrompt"] as? String, !prompt.isEmpty {
                result.lastPrompt = prompt
            }
        case "agent-name":
            // Plan-mode naming; treat as a custom title when nothing stronger is set.
            if result.customTitle == nil,
               let name = object["agentName"] as? String, !name.isEmpty {
                result.customTitle = name
            }
        default:
            break
        }
    }

    private func applyUser(_ object: [String: Any], to result: inout TranscriptState) {
        if object["isMeta"] as? Bool == true { return }

        let stamp = parseDate(object["timestamp"] as? String) ?? result.activityAt
        guard let message = object["message"] as? [String: Any] else { return }
        let content = message["content"]

        // Tool results are delivered as user messages. Clear matching open tools / asks.
        var sawToolResult = false
        if let blocks = content as? [[String: Any]] {
            for block in blocks where (block["type"] as? String) == "tool_result" {
                sawToolResult = true
                if let call = block["tool_use_id"] as? String {
                    result.openTools.remove(call)
                    result.pendingAsks.remove(call)
                }
            }
        }
        if let call = object["sourceToolUseID"] as? String {
            sawToolResult = true
            result.openTools.remove(call)
            result.pendingAsks.remove(call)
        }

        if sawToolResult {
            // Answering a question (or any tool) keeps the turn alive until the assistant
            // finishes; do not treat it as a new human message for the timer.
            result.awaitingAssistant = true
            return
        }

        guard let prompt = typedPrompt(from: content), !prompt.isEmpty else { return }
        if result.firstPrompt == nil { result.firstPrompt = prompt }
        result.spokeAt = stamp
        result.turnStartedAt = stamp
        result.awaitingAssistant = true
        result.openTools.removeAll()
        result.pendingAsks.removeAll()
        result.success = true
    }

    private func applyAssistant(_ object: [String: Any], to result: inout TranscriptState) {
        if object["isApiErrorMessage"] as? Bool == true {
            // Auth / API failures end the turn; they are not aborts you caused.
            result.awaitingAssistant = false
            result.openTools.removeAll()
            return
        }

        guard let message = object["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return }

        var calledTools = false
        for block in blocks where (block["type"] as? String) == "tool_use" {
            calledTools = true
            guard let call = block["id"] as? String else { continue }
            result.openTools.insert(call)
            if (block["name"] as? String) == "AskUserQuestion" {
                result.pendingAsks.insert(call)
            }
        }

        // A text-only assistant message with nothing still open is the end of the turn.
        if !calledTools && result.openTools.isEmpty {
            result.awaitingAssistant = false
        }
    }

    private func typedPrompt(from content: Any?) -> String? {
        if let text = content as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text",
                  let text = block["text"] as? String else { return nil }
            return text
        }
        guard !texts.isEmpty else { return nil }
        return texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return isoFractional.date(from: value) ?? isoBasic.date(from: value)
    }

    private static func shortTitle(_ prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if trimmed.count <= 48 { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: 48)
        return String(trimmed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
