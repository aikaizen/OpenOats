import Foundation

// MARK: - RecapPrompt

enum RecapPrompt {
    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Build system + user prompt pair for a recap request.
    /// - Parameters:
    ///   - window: The window being recapped.
    ///   - utterances: All utterances in the session (will be filtered by window).
    ///   - sessionStart: When the session started (for sinceStart).
    ///   - now: Current time.
    static func build(
        window: RecapWindow,
        utterances: [Utterance],
        sessionStart: Date?,
        now: Date
    ) -> (system: String, user: String, entry: (coversFrom: Date, coversTo: Date, count: Int, truncated: Bool)) {
        // Determine coverage
        let coversTo = now
        let coversFrom: Date
        switch window {
        case .minutes(let n):
            coversFrom = now.addingTimeInterval(-Double(n) * 60)
        case .sinceStart:
            coversFrom = sessionStart ?? now.addingTimeInterval(-3600)
        }

        // Filter to window
        let windowUtterances = utterances.filter {
            $0.timestamp >= coversFrom && $0.timestamp <= coversTo
        }

        // Build transcript lines
        var transcriptLines = windowUtterances.map { u in
            "\(absoluteFormatter.string(from: u.timestamp)) \(u.speaker.displayLabel): \(u.text)"
        }

        // Cap at 24,000 chars (keep newest, set truncated)
        let cap = 24_000
        var transcriptText = transcriptLines.joined(separator: "\n")
        var truncated = false
        if transcriptText.count > cap {
            truncated = true
            // Drop oldest lines until under cap
            while transcriptText.count > cap && !transcriptLines.isEmpty {
                transcriptLines.removeFirst()
                transcriptText = transcriptLines.joined(separator: "\n")
            }
        }

        let utteranceCount = windowUtterances.count

        let system = """
        You produce a recap of a live call for the host, from the transcript only. Plain text, no markdown headers or bullets symbols other than a leading dash, no emoji. Sections in this order, each on its own line as `Thread:`, `Decisions and positions:`, `Open questions and asks of the host:`, `Consider now:`. Attribute to speakers when clear. Be specific and compact; at most 1500 characters. If the window has nothing substantive, say so in one line.
        """

        let fromStr = absoluteFormatter.string(from: coversFrom)
        let toStr = absoluteFormatter.string(from: coversTo)
        var userParts: [String] = []
        userParts.append("Window: \(window.label)")
        userParts.append("Time range: \(fromStr) – \(toStr)")
        userParts.append("Utterances: \(utteranceCount)")
        if truncated {
            userParts.append("Note: transcript was truncated to fit; oldest utterances omitted.")
        }
        userParts.append("")
        userParts.append(transcriptText.isEmpty ? "(no transcript in this window)" : transcriptText)

        let user = userParts.joined(separator: "\n")

        return (
            system: system,
            user: user,
            entry: (coversFrom: coversFrom, coversTo: coversTo, count: utteranceCount, truncated: truncated)
        )
    }
}
