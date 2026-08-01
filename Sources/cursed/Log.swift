import Foundation

/// Appends to `~/Library/Logs/cursed.log`.
///
/// The app owns its log rather than relying on shell redirection, because it is normally
/// started detached (via `open` or a LaunchAgent) where there is no stderr to capture.
enum Log {
    static let path = NSHomeDirectory() + "/Library/Logs/cursed.log"

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))

        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
