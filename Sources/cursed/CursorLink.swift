import AppKit
import ApplicationServices

/// Brings a conversation's Cursor window forward.
///
/// Cursor only registers deep links for automations and background agents, so there is no URL
/// that opens a specific chat. The best available behaviour is to activate Cursor and, when
/// Accessibility is already granted, raise the window belonging to that conversation's project.
enum CursorLink {
    static let bundleID = "com.todesktop.230313mzl4w4u92"

    static func reveal(project: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return }

        raiseWindow(pid: app.processIdentifier, matching: project)
        app.activate(options: [])
    }

    /// Silently does nothing without Accessibility permission; the app never prompts, since
    /// activating Cursor alone is a reasonable outcome.
    private static func raiseWindow(pid: pid_t, matching project: String) {
        guard AXIsProcessTrusted(), project != "home" else { return }

        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return }

        for window in windows {
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                  let title = titleValue as? String,
                  title.localizedCaseInsensitiveContains(project)
            else { continue }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return
        }
    }
}
