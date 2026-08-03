import AppKit

/// The app's only permanent, findable surface.
///
/// An agent app has no Dock tile to right-click and no menu bar of its own, so until now the way
/// out was a context menu on a floating panel — which works perfectly well once you know it is
/// there, and not at all before. A status item is where anyone would look first.
@MainActor
final class MenuBar {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    init() {
        // Drawn as a template so the system inverts it along with the rest of the menu bar, rather
        // than holding a colour that suits only one background.
        let image = NSImage(systemSymbolName: "ellipsis.bubble", accessibilityDescription: "cursed")
        image?.isTemplate = true
        item.button?.image = image

        let menu = NSMenu()
        // Targeted at the application rather than at a callback of ours, so quitting still runs
        // the ordinary termination the panel relies on to save where it was left.
        let quit = NSMenuItem(title: "Quit cursed",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
    }
}
