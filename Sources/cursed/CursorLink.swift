import AppKit
import ApplicationServices

/// Opens a conversation in Cursor.
///
/// Cursor registers deep links only for automations and background agents, so there is no URL
/// that opens one specific chat. The command that would do it, `glass.openAgentById`, takes the
/// very id the panel already holds, but nothing outside the app can reach it: its URI form,
/// `cursor.agent://local/<id>`, is not a registered scheme, and the `/agent` deep link that looks
/// like the way in resolves cloud agents only.
///
/// So there are two routes, tried in that order. Cursor's "Recent Agents" menu — the one in the
/// menu bar extra — has an item per conversation, and pressing the right one moves Cursor to that
/// chat exactly. It is the better route by far, but it is capped at ten entries, five in the menu
/// and five behind "View More", so anything you have not touched recently is simply not in it.
///
/// Everything else falls back to the Agents window's own "Search Agents" palette, which is not
/// capped: front Cursor, open the palette and type the title. It stops there, one keypress short.
/// The palette ranks by its own fuzzy match and nothing here can read back what it has ended up
/// highlighting, and a title whose first word is a common one — "API response delay
/// investigation" — puts an unrelated chat at the top. Pressing Return blind would open that one
/// instead, which is a worse answer than leaving the last press to you.
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
        var needsPalette = false
        if trusted {
            if !selectChat(pid: app.processIdentifier, titled: title) {
                // On the older one-window-per-folder layout the window itself is the best target
                // available, and the palette does not exist there to be typed into.
                needsPalette = !raiseWindow(pid: app.processIdentifier, matching: project)
                Log.write("reveal: no agent entry for \(title)"
                    + (needsPalette ? ", trying the palette" : ", raised the \(project) window"))
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

        if needsPalette { searchPalette(title: title) }
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

    /// Only meaningful once Accessibility is granted, which the caller checks. Reports whether a
    /// window was actually raised, since on the single-window Agents layout no window title
    /// carries the project and there is nothing here to aim at.
    private static func raiseWindow(pid: pid_t, matching project: String) -> Bool {
        guard project != "home" else { return false }

        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return false }

        for window in windows {
            guard let title = string(window, kAXTitleAttribute),
                  title.localizedCaseInsensitiveContains(project)
            else { continue }
            return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
        }
        return false
    }

    /// At most one of these at a time. A single click on a row can arrive as several `onSelect`
    /// calls — rows are rebuilt under the pointer as the store polls — and a second run starting
    /// mid-sequence would type its title into the middle of the first one's.
    @MainActor private static var navigation: Task<Void, Never>?

    @MainActor
    private static func searchPalette(title: String) {
        guard navigation == nil else { return }
        navigation = Task { @MainActor in
            defer { navigation = nil }
            await drivePalette(title: title)
        }
    }

    /// Types into whatever has keyboard focus, so the steps here are all about making sure that
    /// is the palette and not the composer box: a title left sitting in the chat you happen to be
    /// looking at is the failure worth going to some trouble to avoid.
    @MainActor
    private static func drivePalette(title: String) async {
        guard await waitForFrontmost() else {
            Log.write("palette: Cursor never came forward, leaving \(title) alone")
            return
        }
        // Any other modal owns the shortcut while it is up, and would swallow the whole sequence.
        press(.escape)
        try? await Task.sleep(for: .milliseconds(90))
        press(.p, flags: [.maskCommand, .maskAlternate])
        try? await Task.sleep(for: .milliseconds(500))
        await type(query(from: title))

        // Recorded as what was done rather than as what happened. `glass.selectedAgent` is all
        // the database says about what is on screen, and it does not survive being navigated
        // this way, so there is nothing here to check the outcome against.
        Log.write("palette: filled in \(title) — press Return in Cursor to open it")
    }

    /// What actually gets typed. Trimmed of the characters the palette reads as a mode switch,
    /// and capped: a chat that was never given a name is titled with its whole first message,
    /// which runs to thousands of characters.
    private static func query(from title: String) -> String {
        String(title.drop { "><@#:/ ".contains($0) }.prefix(60))
    }

    @MainActor
    private static func waitForFrontmost() async -> Bool {
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private enum Key: CGKeyCode {
        case p = 35
        case escape = 53
    }

    private static func press(_ key: Key, flags: CGEventFlags = []) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key.rawValue,
                                keyDown: isDown)
            // Set every time, empty included: an event picks up whatever modifiers happen to be
            // held otherwise, and a stray Cmd under Return makes it something else entirely.
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Posted as text rather than as key codes, so the query does not depend on the layout the
    /// keyboard happens to be in — and one character per event, because Chromium ignores an
    /// event carrying a whole string and the query never arrives at all.
    private static func type(_ text: String) async {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        for character in text {
            let units = Array(String(character).utf16)
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0,
                                          keyDown: isDown) else { continue }
                event.flags = []
                units.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: units.count,
                                                   unicodeString: buffer.baseAddress)
                }
                event.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(10))
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
