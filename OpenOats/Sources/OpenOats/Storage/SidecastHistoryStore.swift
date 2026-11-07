import Foundation

// MARK: - SidecastHistoryStore

/// Appends each SidecastHistoryEntry as one JSON line to
/// `<sessionsDirectory>/<sessionID>/sidecast.jsonl` (0600).
/// Loaded by the engine on sessionID set so relaunch mid-session keeps the log.
@MainActor
final class SidecastHistoryStore {

    private(set) var sessionsDirectoryURL: URL?
    private var currentSessionID: String?

    // File handle kept open for appending; closed when session changes.
    private var fileHandle: FileHandle?

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(sessionsDirectoryURL: URL? = nil) {
        self.sessionsDirectoryURL = sessionsDirectoryURL
    }

    // MARK: - Session lifecycle

    /// Set both the sessions directory URL and the session ID at once.
    func setSession(id: String, sessionsDirectoryURL: URL) {
        closeHandle()
        self.sessionsDirectoryURL = sessionsDirectoryURL
        self.currentSessionID = id
    }

    /// Switch to a new session ID, keeping the existing sessions directory URL.
    func setCurrentSessionID(_ id: String) {
        guard currentSessionID != id else { return }
        closeHandle()
        currentSessionID = id
    }

    func clearSession() {
        closeHandle()
        currentSessionID = nil
    }

    // MARK: - Write

    func append(_ entry: SidecastHistoryEntry) {
        guard let url = jsonlURL() else { return }
        guard let data = try? Self.encoder.encode(entry) else { return }
        var line = data
        line.append(contentsOf: [0x0A]) // newline

        if fileHandle == nil {
            openHandle(at: url)
        }
        fileHandle?.write(line)
    }

    // MARK: - Read

    func load(sessionID: String) -> [SidecastHistoryEntry] {
        guard let base = sessionsDirectoryURL else { return [] }
        let url = base
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("sidecast.jsonl")
        guard let raw = try? Data(contentsOf: url) else { return [] }
        var results: [SidecastHistoryEntry] = []
        for line in raw.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let entry = try? Self.decoder.decode(SidecastHistoryEntry.self, from: Data(line)) {
                results.append(entry)
            }
        }
        return results
    }

    // MARK: - Export

    /// Writes `<session>/sidecast.md` and returns the URL.
    @discardableResult
    func exportMarkdown(sessionID: String) -> URL? {
        guard let base = sessionsDirectoryURL else { return nil }
        let sessionDir = base.appendingPathComponent(sessionID, isDirectory: true)
        let outURL = sessionDir.appendingPathComponent("sidecast.md")
        let entries = load(sessionID: sessionID)
        let tf = SidecastHistoryStore.absoluteFormatter

        var lines: [String] = ["# Sidecast history — \(sessionID)", ""]
        for entry in entries {
            let timeStr = tf.string(from: entry.timestamp)
            lines.append("### \(timeStr) · \(entry.title)")
            lines.append("")
            lines.append(entry.text)
            lines.append("")
        }
        let markdown = lines.joined(separator: "\n")
        try? markdown.write(to: outURL, atomically: true, encoding: .utf8)
        return outURL
    }

    // MARK: - Private helpers

    private func jsonlURL() -> URL? {
        guard let base = sessionsDirectoryURL, let sid = currentSessionID else { return nil }
        let dir = base.appendingPathComponent(sid, isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let url = dir.appendingPathComponent("sidecast.jsonl")
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return url
    }

    private func openHandle(at url: URL) {
        guard let fh = try? FileHandle(forWritingTo: url) else { return }
        fh.seekToEndOfFile()
        fileHandle = fh
    }

    private func closeHandle() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
