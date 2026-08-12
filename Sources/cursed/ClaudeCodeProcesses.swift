import Darwin
import Foundation

/// Which Claude CLI sessions are parked on you rather than working.
///
/// The CLI does not write a question to its transcript until you answer it: the tool call and its
/// result are flushed together, so a question that sat on screen for eight minutes appears on disk
/// as one write, after the fact. From the transcript alone a waiting question is indistinguishable
/// from a turn still in flight, which is why one reads as a live run for as long as it waits.
///
/// What does distinguish them is the process. A turn in flight animates a spinner, and that alone
/// is expensive — an idling session awaiting the API still burns some 400 million instructions a
/// second. The instant a question goes up the spinner stops, and the process falls to around 12
/// million, the same as one sitting at an empty prompt. Measured across working, waiting-on-the-API,
/// question-pending and idle sessions, the two groups are thirty times apart, so the line between
/// them is drawn well clear of either.
///
/// This only says the process is doing nothing. What makes that mean a question is the transcript
/// saying the turn is still open: idle at a prompt looks identical here, and is told apart by the
/// last turn having ended. A permission prompt reads as waiting too, which is right — it is just
/// as stuck on you as a question is.
final class ClaudeCodeProcesses {
    /// Per second, above which a process is doing something. A session parked on a question costs
    /// 12 million and has been seen to spike to 41 in the moment the question lands; a turn in
    /// flight costs upwards of 420, spinner alone, with nothing streaming. The line sits with
    /// twice the headroom below it and four times above.
    private let busyInstructions: Double = 100_000_000
    /// The same line drawn in wakeups — 5 to 14 parked against 54 and up working — and read
    /// together with the instruction count, so a process has to look quiet by both to count as
    /// waiting. Erring towards busy is the cheap mistake: it costs a dot that arrives a poll late,
    /// where the other kind marks a working run as blocked on you.
    private let busyWakeups: Double = 30
    /// Below this the two samples are too close together to divide by with any confidence.
    private let minimumInterval: TimeInterval = 0.4

    private struct Sample {
        let instructions: Double
        let wakeups: Double
        let cwd: String
        let at: Date
    }
    private var previous: [Int32: Sample] = [:]

    /// Working directories whose only terminal-attached `claude` is idling.
    ///
    /// A directory with more than one session in it is left out rather than guessed at: nothing
    /// on disk says which of them the transcript belongs to, and a dot on the wrong row is worse
    /// than no dot at all.
    func parkedDirectories(now: Date = Date()) -> Set<String> {
        let current = sample(now: now)
        defer { previous = current }

        var counts: [String: Int] = [:]
        for sample in current.values where !sample.cwd.isEmpty {
            counts[sample.cwd, default: 0] += 1
        }

        var parked: Set<String> = []
        for (pid, sample) in current {
            guard !sample.cwd.isEmpty, counts[sample.cwd] == 1,
                  let before = previous[pid] else { continue }
            let elapsed = sample.at.timeIntervalSince(before.at)
            guard elapsed >= minimumInterval else { continue }
            let instructions = (sample.instructions - before.instructions) / elapsed
            let wakeups = (sample.wakeups - before.wakeups) / elapsed
            if instructions < busyInstructions && wakeups < busyWakeups { parked.insert(sample.cwd) }
        }
        return parked
    }

    /// Takes the reading that the next call measures against.
    func primeBaseline() {
        previous = sample(now: Date())
    }

    private func sample(now: Date) -> [Int32: Sample] {
        var result: [Int32: Sample] = [:]
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return result }
        var pids = [Int32](repeating: 0, count: Int(bytes) / MemoryLayout<Int32>.size)
        guard proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bytes) > 0 else { return result }

        for pid in pids where pid > 0 {
            guard isTerminalClaude(pid) else { continue }
            var usage = rusage_info_v4()
            let read = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard read == 0 else { continue }
            result[pid] = Sample(
                instructions: Double(usage.ri_instructions),
                wakeups: Double(usage.ri_interrupt_wkups &+ usage.ri_pkg_idle_wkups),
                cwd: workingDirectory(of: pid),
                at: now
            )
        }
        return result
    }

    /// A `claude` with a controlling terminal, which is what a session you started yourself has and
    /// one the Desktop app spawned does not. The CLI installs as `claude.exe` and Desktop ships
    /// `claude`, and every other process in a Claude install is named something else entirely.
    private func isTerminalClaude(_ pid: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(4 * MAXPATHLEN)) > 0 else { return false }
        let name = (String(cString: buffer) as NSString).lastPathComponent
        guard name == "claude" || name == "claude.exe" else { return false }

        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.e_tdev != UInt32.max
    }

    private func workingDirectory(of pid: Int32) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}
