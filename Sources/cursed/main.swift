import AppKit

if CommandLine.arguments.contains("--list") {
    Diagnostics.list()
    exit(0)
}

if CommandLine.arguments.contains("--bench") {
    Diagnostics.bench()
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--reveal"),
   index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { Diagnostics.reveal(matching: CommandLine.arguments[index + 1]) }
}

let app = NSApplication.shared
// Agent apps have no Dock icon and no menu bar, which is what lets the panel behave as a HUD.
app.setActivationPolicy(.accessory)

// Top-level code already runs on the main thread; this just states that to the compiler.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
