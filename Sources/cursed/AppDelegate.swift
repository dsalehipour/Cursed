import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = Store()
    private let drag = PanelDrag()
    private var menuBar: MenuBar!
    private var panel: FloatingPanel!
    private var cancellables = Set<AnyCancellable>()
    /// Snapshot runs are throwaway windows and must not overwrite the real one's position.
    private let isSnapshot = CommandLine.arguments.contains("--snapshot")

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.onFinished = { [weak self] row in self?.announce(row) }
        store.onAsked = { [weak self] row in self?.announceQuestion(row) }

        let content = ContentView(
            store: store,
            drag: drag,
            onSelect: { [weak self] row in
                self?.store.acknowledge(row.id)
                self?.log("reveal \(row.project): \(row.title)")
                switch row.source {
                case .cursor:
                    CursorLink.reveal(project: row.project, title: row.title)
                case .chatGPT:
                    ChatGPTLink.reveal(id: row.id)
                case .claudeCode:
                    ClaudeCodeLink.reveal(id: row.id, openID: row.openID)
                }
            },
            onDismiss: { [weak self] row in
                self?.log("dismissed \(row.project): \(row.title)")
                self?.store.dismiss(row.id)
            },
            onQuit: { NSApp.terminate(nil) }
        )

        let size = NSSize(width: Metrics.windowWidth, height: Metrics.windowHeight(rowCount: 0))
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = NSHostingView(rootView: content)
        panel.delegate = self
        drag.panel = panel
        panel.restorePosition(defaultSize: size)
        panel.orderFrontRegardless()

        // Snapshot runs are throwaway and should not flash an icon into the menu bar.
        if !isSnapshot { menuBar = MenuBar() }

        log("launched at \(panel.frame.origin.x.rounded()),\(panel.frame.origin.y.rounded())")

        // Row heights vary with content, so the window follows the rows themselves rather
        // than just how many there are.
        //
        // The hop to the next runloop pass is load-bearing: @Published fires during willSet, so
        // resizing here synchronously would force SwiftUI to lay out while `rows` still holds the
        // previous value. That render satisfies the pending invalidation, and the new rows never
        // reach the screen.
        store.$rows
            .map { Metrics.windowHeight(rowCount: $0.count) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] height in
                guard let self else { return }
                self.panel.resizeKeepingTopLeft(
                    to: NSSize(width: Metrics.windowWidth, height: height)
                )
            }
            .store(in: &cancellables)

        if CommandLine.arguments.contains("--demo") {
            store.startDemo()
        } else {
            store.start()
        }

        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
           index + 1 < CommandLine.arguments.count {
            scheduleSnapshot(to: CommandLine.arguments[index + 1])
        }
    }

    /// Gives the store a couple of polls to populate before capturing.
    private func scheduleSnapshot(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let view = self?.panel.contentView else { exit(1) }
            view.layoutSubtreeIfNeeded()
            let ok = Snapshot.capture(view, to: path)
            FileHandle.standardError.write(Data("snapshot \(ok ? "written" : "failed"): \(path)\n".utf8))
            exit(ok ? 0 : 1)
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard !isSnapshot, panel.isUserMove else { return }
        panel.savePosition()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isSnapshot else { return }
        panel.savePosition()
    }

    private func announce(_ row: Store.Row) {
        let completed = row.status == .done(success: true)
        // Logged the moment the run ends, when time-since-your-message is still the run's length.
        log("finished \(completed ? "ok" : "aborted"): \(row.title) (\(row.project))"
            + " after \(Format.duration(row.sinceLastMessage))")

        // An aborted run was stopped by hand, so it is not news worth a chime.
        guard completed, let sound = NSSound(named: "Glass") else { return }
        sound.volume = 0.35
        sound.play()
    }

    /// Deliberately not the completion chime. The two mean different things — one says work is
    /// there to look at, the other says work has stopped and cannot go on without you — and a
    /// question is the one you would want to answer straight away, so it is worth being able to
    /// tell them apart without looking.
    private func announceQuestion(_ row: Store.Row) {
        log("asking: \(row.title) (\(row.project))")
        guard let sound = NSSound(named: "Purr") else { return }
        sound.volume = 0.5
        sound.play()
    }

    private func log(_ message: String) { Log.write(message) }
}
