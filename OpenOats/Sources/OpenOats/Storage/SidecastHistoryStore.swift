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

    /// Appends a feedback event to the cross-session global file at
    /// `~/Library/Application Support/OpenOats/sidecast-feedback.jsonl`.
    /// Always enforces 0600. Returns the raw JSONL line written (for the engine to cache),
    /// or nil if encoding/opening failed. Errors are otherwise silently swallowed.
    @discardableResult
    func appendGlobalFeedback(
        feedback: MoteFeedback,
        personaName: String,
        originalText: String
    ) -> Data? {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first
        guard let appSupport else { return nil }
        let dir = appSupport.appendingPathComponent("OpenOats", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let url = dir.appendingPathComponent("sidecast-feedback.jsonl")
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            // Repair permissions on an existing file that may be 0644.
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        // Build a flat record for easy loading
        struct FeedbackRecord: Encodable {
            let messageID: UUID
            let personaID: UUID
            let personaName: String
            let originalText: String
            let editedText: String?
            let rating: MoteRating?
            let note: String?
            let timestamp: Date
        }
        let record = FeedbackRecord(
            messageID: feedback.messageID,
            personaID: feedback.personaID,
            personaName: personaName,
            originalText: originalText,
            editedText: feedback.editedText,
            rating: feedback.rating,
            note: feedback.note,
            timestamp: feedback.updatedAt
        )
        guard let data = try? Self.encoder.encode(record) else { return nil }
        var line = data
        line.append(contentsOf: [0x0A])
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(line)
            try? fh.close()
        } else {
            return nil
        }
        return line
    }

    /// If the global feedback file exceeds 1,000 lines, rewrites it atomically keeping
    /// the newest 1,000. The rewritten file is set 0600.
    func trimGlobalFeedbackIfNeeded() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first
        guard let appSupport else { return }
        let url = appSupport
            .appendingPathComponent("OpenOats", isDirectory: true)
            .appendingPathComponent("sidecast-feedback.jsonl")
        guard let raw = try? Data(contentsOf: url) else { return }
        let lines = raw.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard lines.count > 1_000 else { return }
        let kept = lines.suffix(1_000)
        var newData = Data(kept.joined(separator: Data([0x0A])))
        newData.append(contentsOf: [0x0A])
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("sidecast-feedback.jsonl.tmp")
        let fm = FileManager.default
        do {
            try newData.write(to: tmp, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
        }
    }

    // MARK: - Load global feedback

    /// Struct mirroring the FeedbackRecord written by appendGlobalFeedback.
    struct GlobalFeedbackRecord: Decodable {
        let messageID: UUID
        let personaID: UUID
        let personaName: String
        let originalText: String
        let editedText: String?
        let rating: MoteRating?
        let note: String?
        let timestamp: Date
    }

    func loadGlobalFeedback() -> [GlobalFeedbackRecord] {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first
        guard let appSupport else { return [] }
        let url = appSupport
            .appendingPathComponent("OpenOats", isDirectory: true)
            .appendingPathComponent("sidecast-feedback.jsonl")
        guard let raw = try? Data(contentsOf: url) else { return [] }
        var results: [GlobalFeedbackRecord] = []
        for line in raw.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let record = try? Self.decoder.decode(GlobalFeedbackRecord.self, from: Data(line)) {
                results.append(record)
            }
        }
        return results
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
    /// Feedback entries include rating/note; latest feedback per messageID wins.
    @discardableResult
    func exportMarkdown(sessionID: String) -> URL? {
        guard let base = sessionsDirectoryURL else { return nil }
        let sessionDir = base.appendingPathComponent(sessionID, isDirectory: true)
        let outURL = sessionDir.appendingPathComponent("sidecast.md")
        let entries = load(sessionID: sessionID)
        let tf = SidecastHistoryStore.absoluteFormatter

        // Build a lookup: latest feedback per messageID
        var feedbackByMessageID: [UUID: MoteFeedback] = [:]
        for entry in entries {
            if case .feedback(let f) = entry {
                if let existing = feedbackByMessageID[f.messageID] {
                    if f.updatedAt > existing.updatedAt {
                        feedbackByMessageID[f.messageID] = f
                    }
                } else {
                    feedbackByMessageID[f.messageID] = f
                }
            }
        }

        var lines: [String] = ["# Sidecast history — \(sessionID)", ""]
        for entry in entries {
            switch entry {
            case .feedback:
                continue // skip raw feedback entries; inlined into message blocks
            case .message(let m):
                let timeStr = tf.string(from: m.timestamp)
                lines.append("### \(timeStr) · \(m.personaName)")
                lines.append("")
                if let fb = feedbackByMessageID[m.id], let edited = fb.editedText {
                    lines.append(edited)
                    lines.append("")
                    lines.append("*(edited)*")
                } else {
                    lines.append(m.text)
                }
                if let fb = feedbackByMessageID[m.id] {
                    var meta: [String] = []
                    if let r = fb.rating { meta.append(r == .up ? "👍" : "👎") }
                    if let n = fb.note, !n.isEmpty { meta.append("note: \(n)") }
                    if !meta.isEmpty { lines.append(""); lines.append(meta.joined(separator: "  ·  ")) }
                }
                lines.append("")
            case .recap(let r):
                let timeStr = tf.string(from: r.createdAt)
                lines.append("### \(timeStr) · \(r.windowLabel)")
                lines.append("")
                lines.append(r.text)
                lines.append("")
            }
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
