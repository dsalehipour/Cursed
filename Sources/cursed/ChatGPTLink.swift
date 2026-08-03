import AppKit

/// Opens a Codex task in the ChatGPT Mac app. Unlike Cursor, ChatGPT publishes a task-specific
/// URL, so this path needs no Accessibility permission or UI scripting.
enum ChatGPTLink {
    static let bundleID = "com.openai.codex"

    @MainActor
    static func reveal(id: String) {
        guard let url = URL(string: "codex://threads/\(id)") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            if let error { Log.write("reveal failed for ChatGPT task \(id): \(error)") }
        }
    }
}
