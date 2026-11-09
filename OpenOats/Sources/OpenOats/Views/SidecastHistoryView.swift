import AppKit
import SwiftUI

// MARK: - SidecastHistoryView

/// Full-session sidecast history: all advisor messages and recaps, searchable,
/// filterable, sortable. Live-updates from engine.history.
struct SidecastHistoryView: View {
    let engine: SidecastEngine

    @State private var searchText = ""
    @State private var filterChip: FilterChip = .all
    @State private var sortNewestFirst = true

    enum FilterChip: Hashable {
        case all
        case persona(UUID, String)
        case recaps

        var label: String {
            switch self {
            case .all: return "All"
            case .persona(_, let name): return name
            case .recaps: return "Recaps"
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // Build filter chips dynamically from current history
    private var chips: [FilterChip] {
        var seen = Set<UUID>()
        var result: [FilterChip] = [.all]
        for entry in engine.history {
            if case .message(let m) = entry {
                if seen.insert(m.personaID).inserted {
                    result.append(.persona(m.personaID, m.personaName))
                }
            }
        }
        result.append(.recaps)
        return result
    }

    private var filteredEntries: [SidecastHistoryEntry] {
        // Exclude raw feedback entries — they're shown inline on message rows, not as separate rows
        var entries = engine.history.filter { if case .feedback = $0 { return false }; return true }
        // Apply filter chip
        switch filterChip {
        case .all:
            break
        case .persona(let pid, _):
            entries = entries.filter {
                if case .message(let m) = $0 { return m.personaID == pid }
                return false
            }
        case .recaps:
            entries = entries.filter {
                if case .recap = $0 { return true }
                return false
            }
        }

        // Apply search (case-insensitive substring over title + text)
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            entries = entries.filter {
                $0.title.lowercased().contains(q) || $0.text.lowercased().contains(q)
            }
        }

        // Sort
        if sortNewestFirst {
            entries = entries.sorted { $0.timestamp > $1.timestamp }
        } else {
            entries = entries.sorted { $0.timestamp < $1.timestamp }
        }

        return entries
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                TextField("Search…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)

                Button {
                    sortNewestFirst.toggle()
                } label: {
                    Label(
                        sortNewestFirst ? "Newest first" : "Oldest first",
                        systemImage: sortNewestFirst ? "arrow.down" : "arrow.up"
                    )
                    .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .help("Toggle sort order")

                Spacer()

                Button("Export Markdown") {
                    guard let sid = engine.sessionID else { return }
                    if let url = engine.historyStore.exportMarkdown(sessionID: sid) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .font(.system(size: 11))
                .disabled(engine.sessionID == nil)
                .help("Export history to Markdown")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(red: 0.10, green: 0.10, blue: 0.14))

            Divider().opacity(0.3)

            // Filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.self) { chip in
                        Button(chip.label) {
                            filterChip = chip
                        }
                        .font(.system(size: 11, weight: filterChip == chip ? .semibold : .regular))
                        .foregroundStyle(filterChip == chip ? .white : .white.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(filterChip == chip ? Color.white.opacity(0.18) : Color.white.opacity(0.07))
                        )
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            Divider().opacity(0.25)

            // Entry list
            let entries = filteredEntries
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.25))
                    Text("No entries.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            HistoryEntryRow(entry: entry, engine: engine)
                            Divider().opacity(0.12).padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(Color(red: 0.08, green: 0.08, blue: 0.12))
    }
}

// MARK: - HistoryEntryRow

private struct HistoryEntryRow: View {
    let entry: SidecastHistoryEntry
    let engine: SidecastEngine
    @State private var copied = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var badgeColor: Color {
        if case .message(let m) = entry {
            return m.personaID.tintColor
        }
        return Color(red: 0.4, green: 0.45, blue: 0.55) // slate for recaps
    }

    /// For message entries: editedText ?? text. For recaps: text.
    private var displayText: String {
        if case .message(let m) = entry {
            return engine.feedback(for: m.id)?.editedText ?? m.text
        }
        return entry.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))

                Text(entry.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(badgeColor.opacity(0.45)))

                // "edited" tag for messages that have been edited
                if case .message(let m) = entry, engine.feedback(for: m.id)?.editedText != nil {
                    Text("edited")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(displayText, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("Copy")
            }

            Text(displayText)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Feedback controls — always visible in history, only for message entries
            if case .message(let m) = entry {
                MoteFeedbackControls(
                    messageID: m.id,
                    originalText: m.text,
                    engine: engine,
                    alwaysVisible: true
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - UUID tint helper (deterministic colour per persona)

private extension UUID {
    private static let palette: [Color] = [
        Color(red: 0.2, green: 0.5, blue: 0.9),
        Color(red: 0.1, green: 0.7, blue: 0.6),
        Color(red: 0.2, green: 0.7, blue: 0.35),
        Color(red: 0.9, green: 0.55, blue: 0.1),
        Color(red: 0.8, green: 0.25, blue: 0.3),
        Color(red: 0.7, green: 0.25, blue: 0.85),
        Color(red: 0.85, green: 0.35, blue: 0.65),
        Color(red: 0.3, green: 0.55, blue: 0.85),
    ]

    var tintColor: Color {
        let idx = Int(uuidString.unicodeScalars.reduce(0) { $0 &+ $1.value }) % Self.palette.count
        return Self.palette[idx]
    }
}

// MARK: - RecapView

/// Full-text view of a single recap entry shown in a dedicated window.
struct SidecastRecapView: View {
    let entry: RecapEntry
    @State private var copied = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.windowLabel)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)

                    let fromStr = Self.timeFormatter.string(from: entry.coversFrom)
                    let toStr = Self.timeFormatter.string(from: entry.coversTo)
                    Text("\(fromStr) – \(toStr)  ·  \(entry.utteranceCount) utterances\(entry.truncated ? "  · truncated" : "")")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().opacity(0.3)

            ScrollView {
                Text(entry.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(Color(red: 0.08, green: 0.08, blue: 0.12))
    }
}
