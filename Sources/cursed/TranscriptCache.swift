import Foundation

/// What reading a transcript produced, kept against the file it was read from and brought up to
/// date from the bytes that have been appended since.
///
/// Both JSONL readers answer every question by folding a file line by line into a small state, and
/// both are asked once a second for as long as the panel is up. That was affordable while the
/// transcripts were small and stopped being affordable as they grew: these files are appended to
/// for the life of a session and never rotated, so the conversation you have been working in all
/// day — the one most likely to be on the panel — is also the most expensive one to read. A Codex
/// rollout reaches hundreds of megabytes, and walking one costs seconds where the whole poll has a
/// second to spend.
///
/// Remembering the answer against the file's size and modification time is most of the fix, but on
/// its own it is the wrong half. A file that has not changed is the cheap case either way; the
/// expensive one is the session actually running, and that file is written to every few
/// hundredths of a second. Keyed on the file's identity alone the cache would miss on every poll
/// on exactly the transcript that costs the most, which is the case the panel exists to cover.
///
/// So the fold is resumed rather than restarted. The state is kept alongside the offset it was
/// folded up to, always a line boundary, and a later poll reads only from there to the end. A
/// running session appends a few hundred bytes between polls and costs a few hundred bytes of
/// work, whatever the file has grown to behind it.
///
/// Resuming is only sound if the earlier bytes really are the same bytes, and these files are not
/// purely append-only — Claude's Desktop app rewrites transcripts long after their last turn. The
/// bytes immediately before the offset are kept as a seam and checked before the tail is trusted;
/// anything that does not match is read again from the beginning. A file that shrank fails the
/// same test by being shorter than the offset it is supposed to continue from.
final class TranscriptCache<State> {
    private struct Entry {
        let modified: Date
        let size: Int
        /// How much of the file has been folded into `state`, always just past a newline.
        let consumed: Int
        /// The bytes immediately before `consumed`, which is how a rewrite is told from an
        /// append. Short enough to re-read for nothing, long enough that a file rewritten in
        /// place cannot land on the same ones by accident.
        let seam: Data
        let state: State
    }

    private static var seamLength: Int { 4096 }

    private var entries: [String: Entry] = [:]

    /// The file folded into a state, reading only what has been appended since it was last asked.
    ///
    /// `line` is handed each complete line in order and never a partial one: a poll that catches a
    /// half-written line stops at the newline before it and picks the rest up next time. Empty
    /// lines are skipped, as both readers already did.
    func state(of url: URL, initial: () -> State, line fold: (inout State, Data) -> Void) -> State {
        // Without a size and a timestamp there is nothing to say a remembered answer still
        // describes the file, and serving a stale run state is worse than paying for the read.
        guard let stamp = stamp(of: url) else {
            var state = initial()
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return state }
            _ = consume(data, into: &state, fold: fold)
            return state
        }

        let cached = entries[url.path]
        if let cached, cached.modified == stamp.modified, cached.size == stamp.size {
            return cached.state
        }

        var state: State
        var start: Int
        var chunk: Data

        if let cached, stamp.size >= cached.consumed, seamHolds(cached, at: url) {
            state = cached.state
            start = cached.consumed
            guard let tail = read(url, from: start) else { return state }
            chunk = tail
        } else {
            state = initial()
            start = 0
            // Mapped rather than read: a first pass over a file this size should not also cost
            // its length in resident memory.
            guard let whole = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return state
            }
            chunk = whole
        }

        let used = consume(chunk, into: &state, fold: fold)
        // A poll that arrived mid-line leaves the offset where it was, so the line is folded in
        // once, when it is whole, rather than half now and half later.
        let consumed = start + used
        entries[url.path] = Entry(
            modified: stamp.modified,
            size: stamp.size,
            consumed: consumed,
            seam: used > 0 ? seam(of: chunk, endingAt: used) : (cached?.seam ?? Data()),
            state: state
        )
        return state
    }

    /// Forgets every file not named here.
    ///
    /// Sessions are created far more often than they are revisited, so without this the cache
    /// would hold every transcript the app had ever been shown — trading the poll it was built to
    /// speed up for a heap that grows all day, which is the same bug wearing a different hat.
    func prune(keeping paths: Set<String>) {
        entries = entries.filter { paths.contains($0.key) }
    }

    /// Folds every complete line in `chunk`, and reports how many bytes that accounted for.
    private func consume(_ chunk: Data, into state: inout State,
                         fold: (inout State, Data) -> Void) -> Int {
        let newline = UInt8(ascii: "\n")
        guard let lastBreak = chunk.lastIndex(of: newline) else { return 0 }
        let used = chunk.distance(from: chunk.startIndex, to: lastBreak) + 1
        let complete = chunk[chunk.startIndex..<chunk.index(chunk.startIndex, offsetBy: used)]
        for line in complete.split(separator: newline, omittingEmptySubsequences: true) {
            fold(&state, line)
        }
        return used
    }

    private func seam(of chunk: Data, endingAt used: Int) -> Data {
        let length = min(Self.seamLength, used)
        let end = chunk.index(chunk.startIndex, offsetBy: used)
        let start = chunk.index(end, offsetBy: -length)
        return Data(chunk[start..<end])
    }

    /// Whether the bytes before the resume point are still the ones that were folded in.
    private func seamHolds(_ entry: Entry, at url: URL) -> Bool {
        guard entry.consumed > 0 else { return true }
        guard !entry.seam.isEmpty else { return false }
        let start = entry.consumed - entry.seam.count
        guard start >= 0, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(start))) != nil,
              let bytes = try? handle.read(upToCount: entry.seam.count) else { return false }
        return bytes == entry.seam
    }

    private func read(_ url: URL, from offset: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }
        return (try? handle.readToEnd()) ?? Data()
    }

    /// Asked of the filesystem directly rather than through `URL.resourceValues`, which caches
    /// what it read on the `URL` itself: a caller that holds one across polls would be told the
    /// file had never changed, and the panel would freeze on the reading it happened to take
    /// first. Going straight to `stat` also costs a fifth as much, which matters at one call per
    /// transcript per second.
    private func stamp(of url: URL) -> (modified: Date, size: Int)? {
        var info = stat()
        let ok = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return stat(path, &info) == 0
        }
        guard ok else { return nil }
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
            + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return (modified, Int(info.st_size))
    }
}
