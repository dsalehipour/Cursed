import AppKit
import ApplicationServices

/// Opens a conversation in Cursor.
///
/// Cursor registers deep links only for automations and background agents, so there is no URL
/// that opens one specific chat. What it does publish is its "Recent Agents" menu — the one in
/// the menu bar extra — with an item per conversation. Pressing the right item is what actually
/// moves Cursor to that chat, and it is the only route that works when every conversation lives
/// in a single Agents window, which is how Cursor now arranges them.
enum CursorLink {
    static let bundleID = "com.todesktop.230313mzl4w4u92"

    @MainActor
    static func reveal(project: String, title: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { Log.write("reveal failed: Cursor is not running"); return }

        // The panel never becomes key, so this app is never the active one, and macOS ignores
        // activation requests from an inactive app unless they are asked for emphatically.
        // Accessibility can front an app outright, which is the reliable route when it is
        // granted; activate() is kept as the fallback for when it is not.
        let trusted = AXIsProcessTrusted()
        if trusted {
            if !selectChat(pid: app.processIdentifier, titled: title) {
                // Either the conversation has aged out of the recent list, or this is the older
                // one-window-per-folder layout, where the window itself is the best target.
                Log.write("reveal: no agent entry for \(title), falling back to the window")
                raiseWindow(pid: app.processIdentifier, matching: project)
            }
            setFrontmost(pid: app.processIdentifier)
        }
        let activated = app.activate(options: [.activateAllWindows])

        if !trusted {
            Log.write("reveal: no Accessibility permission — grant it in System Settings >"
                + " Privacy & Security > Accessibility, or clicking a row can only bring Cursor"
                + " forward on whatever chat it was already showing")
            requestAccessibility()
        } else if !activated {
            Log.write("reveal: activate() refused, relying on the Accessibility route")
        }
    }

    /// Asked for at most once a launch, and only after a click has actually needed it. Clicking
    /// a row is the one feature that depends on Accessibility, so prompting on launch would be
    /// asking for a permission the app might never use.
    @MainActor private static var hasPrompted = false

    @MainActor
    private static func requestAccessibility() {
        guard !hasPrompted else { return }
        hasPrompted = true
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// Fronts Cursor through Accessibility, which works from a background app in a way that
    /// `activate` alone does not.
    @discardableResult
    private static func setFrontmost(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        return AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString,
                                            kCFBooleanTrue) == .success
    }

    /// Presses the conversation's entry in Cursor's Recent Agents menu, which is what moves the
    /// Agents window to that chat. The menu hangs off a second `AXMenuBar` belonging to the menu
    /// bar extra, not the application's own menus, so `kAXMenuBarAttribute` never sees it and it
    /// has to be found by walking the app element.
    private static func selectChat(pid: pid_t, titled title: String) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        for bar in children(appElement) where role(of: bar) == "AXMenuBar" {
            guard let item = menuItem(in: bar, titled: title, depth: 0) else { continue }
            return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        }
        return false
    }

    /// Entries read `<title>` or `<title>, <status>`, an unread one is bulleted, and everything
    /// past the third is tucked behind a "View More" submenu — hence the trimming and the
    /// recursion. Anchored at the start so one conversation cannot match another whose title
    /// merely contains it.
    private static func menuItem(in element: AXUIElement, titled title: String,
                                 depth: Int) -> AXUIElement? {
        guard depth < 6 else { return nil }
        for child in children(element) {
            if role(of: child) == "AXMenuItem", let name = label(of: child),
               name == title || name.hasPrefix(title + ",") {
                return child
            }
            if let found = menuItem(in: child, titled: title, depth: depth + 1) { return found }
        }
        return nil
    }

    /// Only meaningful once Accessibility is granted, which the caller checks.
    private static func raiseWindow(pid: pid_t, matching project: String) {
        guard project != "home" else { return }

        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return }

        for window in windows {
            guard let title = string(window, kAXTitleAttribute),
                  title.localizedCaseInsensitiveContains(project)
            else { continue }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return
        }
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func role(of element: AXUIElement) -> String {
        string(element, kAXRoleAttribute) ?? ""
    }

    /// The title with any unread bullet taken off the front.
    private static func label(of element: AXUIElement) -> String? {
        guard let title = string(element, kAXTitleAttribute) else { return nil }
        return title.trimmingCharacters(in: CharacterSet(charactersIn: "•· ").union(.whitespaces))
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }
}
