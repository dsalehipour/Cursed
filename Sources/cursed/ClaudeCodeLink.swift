import AppKit

/// Opens a Claude Code session. Desktop and CLI share the same transcript uuid; Desktop also has
/// its own `local_*` id, and `claude://claude.ai/epitaxy/<local id>` is the route that puts that
/// session on screen — the direct counterpart of ChatGPT's `codex://threads/…`. A session Desktop
/// has never seen belongs to the terminal it was started in, and is resumed there with
/// `claude --resume`, which is also the fallback when Desktop is not installed.
///
/// `claude://code/<id>` looks like the obvious route and is not: it carries cloud session ids, and
/// a `local_*` id is rejected without an error the caller can see, so the app merely comes to the
/// front on whatever conversation it was already showing.
enum ClaudeCodeLink {
    static let bundleID = "com.anthropic.claudefordesktop"

    private static let db = ClaudeCodeDB()

    /// What `encodeURIComponent` leaves alone, which is how Desktop spells its own session routes.
    /// A `local_…` id needs none of it; this is only so an unexpected id cannot alter the path.
    private static let idSafe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))

    @MainActor
    static func reveal(id: String, openID: String? = nil) {
        let desktopID = openID ?? db.desktopSessionID(of: id)
        if let desktopID,
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil,
           let escaped = desktopID.addingPercentEncoding(withAllowedCharacters: Self.idSafe),
           let url = URL(string: "claude://claude.ai/epitaxy/\(escaped)") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                if let error {
                    Log.write("reveal via Desktop failed for \(id): \(error); trying CLI resume")
                    Task { @MainActor in resumeInTerminal(id: id) }
                }
            }
            return
        }
        resumeInTerminal(id: id)
    }

    @MainActor
    private static func resumeInTerminal(id: String) {
        let cwd = db.workspacePath(of: id) ?? NSHomeDirectory()
        let escapedCwd = cwd.replacingOccurrences(of: "'", with: "'\\''")
        let escapedID = id.replacingOccurrences(of: "'", with: "'\\''")
        // `claude` may be on PATH from a user install, or only the Desktop-bundled binary.
        let bundled = NSHomeDirectory()
            + "/Library/Application Support/Claude/claude-code"
        let script = """
            tell application "Terminal"
              activate
              do script "cd '\(escapedCwd)' && if command -v claude >/dev/null 2>&1; then exec claude --resume '\(escapedID)'; elif CLAUDE=$(ls -1t '\(bundled)'/*/claude.app/Contents/MacOS/claude 2>/dev/null | head -1); then exec \\"$CLAUDE\\" --resume '\(escapedID)'; else echo 'claude not found on PATH or in Claude Desktop'; fi"
            end tell
            """
        var error: NSDictionary?
        if NSAppleScript(source: script)?.executeAndReturnError(&error) == nil {
            Log.write("reveal via Terminal failed for \(id): \(error ?? [:])")
        }
    }
}
