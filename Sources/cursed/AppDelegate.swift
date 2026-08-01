import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = Store()
    private var panel: FloatingPanel!
    private var cancellables = Set<AnyCancellable>()
    /// Snapshot runs are throwaway windows and must not overwrite the real one's position.
    private let isSnapshot = CommandLine.arguments.contains("--snapshot")

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.onFinished = { [weak self] row in self?.announce(row) }

        let content = ContentView(
            store: store,
            onSelect: { CursorLink.reveal(project: $0.project) },
            onQuit: { NSApp.terminate(nil) }
        )

        let size = NSSize(width: Metrics.windowWidth, height: Metrics.windowHeight(rowCount: 0))
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = NSHostingView(rootView: content)
        panel.delegate = self
        panel.restorePosition(defaultSize: size)
        panel.orderFrontRegardless()

        log("launched at \(panel.frame.origin.x.rounded()),\(panel.frame.origin.y.rounded())")

        store.$rows
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] count in
                guard let self else { return }
                self.panel.resizeKeepingTopLeft(
                    to: NSSize(
                        width: Metrics.windowWidth,
                        height: Metrics.windowHeight(rowCount: count)
                    )
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
        let succeeded: Bool
        if case .done(let success) = row.status { succeeded = success } else { succeeded = true }

        log("finished \(succeeded ? "ok" : "error"): \(row.title) (\(row.project)) after \(Format.duration(row.duration))")

        guard let sound = NSSound(named: succeeded ? "Glass" : "Basso") else { return }
        sound.volume = 0.35
        sound.play()
    }

    private func log(_ message: String) { Log.write(message) }
}
