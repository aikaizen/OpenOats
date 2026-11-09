import AppKit
import SwiftUI

// MARK: - History View

/// Full scrollable history of a single Sidecast persona's messages for the session.
/// Used both inside a popover and as the content of a detached NSWindow.
struct SidecastPersonaHistoryView: View {
    let persona: SidecastPersona
    let engine: SidecastEngine
    /// Called when the user taps "Open in Window" (only shown inside the popover).
    var onOpenInWindow: (() -> Void)?
    /// Called when the user taps the close/dismiss button inside the popover.
    var onDismiss: (() -> Void)?

    private static let absoluteTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func timeAgoString(for message: SidecastMessage) -> String {
        let elapsed = Int(Date.now.timeIntervalSince(message.timestamp))
        if elapsed < 5  { return "just now" }
        if elapsed < 60 { return "\(elapsed)s ago" }
        if elapsed < 3600 { return "\(elapsed / 60)m ago" }
        return "\(elapsed / 3600)h ago"
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────────────
            HStack(spacing: 10) {
                PersonaAvatarCircle(persona: persona, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(persona.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)

                    Text(persona.subtitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(persona.avatarTint.bubbleColor.opacity(0.55)))
                }

                Spacer()

                if let openInWindow = onOpenInWindow {
                    Button(action: openInWindow) {
                        Label("Open in Window", systemImage: "arrow.up.forward.app")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(.white.opacity(0.10))
                            .stroke(.white.opacity(0.15), lineWidth: 1)
                    )
                }

                if let dismiss = onDismiss {
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().opacity(0.25)

            // ── Message list ─────────────────────────────────────────────────
            let msgs = engine.allMessages(for: persona.id)

            if msgs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "ellipsis.bubble")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.25))
                    Text("No messages yet this session.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(msgs.enumerated()), id: \.element.id) { index, msg in
                            MessageRow(
                                message: msg,
                                engine: engine,
                                isNewest: index == 0,
                                absoluteTime: Self.absoluteTimeFormatter.string(from: msg.timestamp),
                                timeAgo: timeAgoString(for: msg),
                                accentColor: persona.avatarTint.bubbleColor
                            )
                            if index < msgs.count - 1 {
                                Divider()
                                    .opacity(0.12)
                                    .padding(.horizontal, 16)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .background(Color(red: 0.08, green: 0.08, blue: 0.12))
    }
}

// MARK: - Message Row

private struct MessageRow: View {
    let message: SidecastMessage
    let engine: SidecastEngine
    let isNewest: Bool
    let absoluteTime: String
    let timeAgo: String
    let accentColor: Color

    @State private var copied = false

    private var feedback: MoteFeedback? { engine.feedback(for: message.id) }
    private var displayText: String { feedback?.editedText ?? message.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Text (full, selectable) — shows editedText if present
            Text(displayText)
                .font(.system(size: 13))
                .foregroundStyle(isNewest ? .white.opacity(0.95) : .white.opacity(0.70))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            // "edited" tag
            if feedback?.editedText != nil {
                Text("edited")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }

            // Meta row
            HStack(spacing: 6) {
                if message.confidence >= 0.7 {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 5, height: 5)
                    Text("High confidence")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue.opacity(0.7))
                    Text("·")
                        .foregroundStyle(.white.opacity(0.2))
                }

                Text(absoluteTime)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))

                Text("·")
                    .foregroundStyle(.white.opacity(0.2))

                Text(timeAgo)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))

                Spacer()

                // Per-message copy button
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(displayText, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }

            // Feedback controls — always visible in pop-open/history
            MoteFeedbackControls(
                messageID: message.id,
                originalText: message.text,
                engine: engine,
                alwaysVisible: true
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isNewest ? accentColor.opacity(0.07) : .clear)
    }
}

// MARK: - Mote Feedback Controls

/// Shared component: thumbs up/down (toggle, tinted when set), pencil (inline edit),
/// note bubble. `alwaysVisible` false = appear on hover (card); true = always shown (history).
struct MoteFeedbackControls: View {
    let messageID: UUID
    let originalText: String
    let engine: SidecastEngine
    var alwaysVisible: Bool = false

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editDraft = ""
    @State private var isShowingNote = false
    @State private var noteDraft = ""

    private var feedback: MoteFeedback? { engine.feedback(for: messageID) }
    private var currentRating: MoteRating? { feedback?.rating }
    private var currentNote: String { feedback?.note ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditing {
                // Inline editor
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $editDraft)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .background(Color.white.opacity(0.07))
                        .foregroundStyle(.white)
                        .cornerRadius(6)
                        .frame(minHeight: 60)

                    HStack(spacing: 8) {
                        Button("Save") {
                            let trimmed = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            let existing = feedback
                            engine.setFeedback(
                                messageID: messageID,
                                rating: existing?.rating,
                                editedText: trimmed.isEmpty ? nil : trimmed,
                                note: existing?.note
                            )
                            isEditing = false
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("Cancel") { isEditing = false }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            } else {
                // Control row
                if alwaysVisible || isHovered {
                    HStack(spacing: 8) {
                        // Thumbs up
                        Button {
                            let newRating: MoteRating? = currentRating == .up ? nil : .up
                            let existing = feedback
                            engine.setFeedback(
                                messageID: messageID,
                                rating: newRating,
                                editedText: existing?.editedText,
                                note: existing?.note
                            )
                        } label: {
                            Image(systemName: "hand.thumbsup\(currentRating == .up ? ".fill" : "")")
                                .font(.system(size: 12))
                                .foregroundStyle(currentRating == .up ? Color.green : Color.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .help("Like")

                        // Thumbs down
                        Button {
                            let newRating: MoteRating? = currentRating == .down ? nil : .down
                            let existing = feedback
                            engine.setFeedback(
                                messageID: messageID,
                                rating: newRating,
                                editedText: existing?.editedText,
                                note: existing?.note
                            )
                        } label: {
                            Image(systemName: "hand.thumbsdown\(currentRating == .down ? ".fill" : "")")
                                .font(.system(size: 12))
                                .foregroundStyle(currentRating == .down ? Color.red : Color.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .help("Dislike")

                        // Pencil (edit)
                        Button {
                            editDraft = feedback?.editedText ?? originalText
                            isEditing = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 12))
                                .foregroundStyle(feedback?.editedText != nil ? Color.yellow.opacity(0.8) : Color.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .help("Edit text")
                        .contextMenu {
                            if feedback?.editedText != nil {
                                Button("Revert to original") {
                                    let existing = feedback
                                    engine.setFeedback(
                                        messageID: messageID,
                                        rating: existing?.rating,
                                        editedText: nil,
                                        note: existing?.note
                                    )
                                }
                            }
                        }

                        // Note bubble
                        Button {
                            noteDraft = currentNote
                            isShowingNote = true
                        } label: {
                            Image(systemName: currentNote.isEmpty ? "bubble" : "bubble.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(currentNote.isEmpty ? Color.white.opacity(0.4) : Color.blue.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .help("Add note")
                        .popover(isPresented: $isShowingNote, arrowEdge: .bottom) {
                            NotePopover(
                                draft: $noteDraft,
                                onSave: {
                                    let existing = feedback
                                    let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                    engine.setFeedback(
                                        messageID: messageID,
                                        rating: existing?.rating,
                                        editedText: existing?.editedText,
                                        note: trimmed.isEmpty ? nil : trimmed
                                    )
                                    isShowingNote = false
                                },
                                onCancel: { isShowingNote = false }
                            )
                        }
                    }
                }
            }
        }
        .onHover { isHovered = $0 }
    }
}

// MARK: - Note Popover

private struct NotePopover: View {
    @Binding var draft: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Note")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))

            TextField("Add a note…", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { onSave() }

            HStack(spacing: 6) {
                Button("Save", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(red: 0.12, green: 0.12, blue: 0.16))
    }
}

// MARK: - Shared Avatar Circle

/// Reusable avatar circle extracted here so both the history view and the card can share it.
struct PersonaAvatarCircle: View {
    let persona: SidecastPersona
    let size: CGFloat

    private var avatarImage: NSImage? {
        guard persona.avatarUsesImage else { return nil }
        return NSImage(contentsOfFile: persona.avatarImagePath)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(persona.avatarTint.bubbleColor.opacity(0.3))
            Circle()
                .stroke(persona.avatarTint.bubbleColor.opacity(0.5), lineWidth: 1.5)

            if let image = avatarImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
                    .padding(2)
            } else {
                Image(systemName: persona.avatarSymbol)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(persona.avatarTint.bubbleColor)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Window Manager

/// Manages one detached NSWindow per persona so the history view can remain open
/// beside the call. Windows are identified by persona ID. Reopening focuses the
/// existing window. Held as a shared singleton so it outlives any SwiftUI view.
@MainActor
final class SidecastWindowManager {
    static let shared = SidecastWindowManager()
    private init() {}

    private var windows: [UUID: NSWindow] = [:]

    // Singleton window for the history list (one per session)
    private var historyWindow: NSWindow?

    // Recap windows keyed by recap entry ID
    private var recapWindows: [UUID: NSWindow] = [:]

    func openWindow(for persona: SidecastPersona, engine: SidecastEngine) {
        if let existing = windows[persona.id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: false)
            return
        }

        let view = SidecastPersonaHistoryView(
            persona: persona,
            engine: engine,
            onOpenInWindow: nil,
            onDismiss: nil
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "\(persona.name) — Sidecast"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 480, height: 520))
        window.minSize = NSSize(width: 420, height: 360)
        window.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)
        window.isReleasedWhenClosed = false
        window.center()

        // Remove from our registry when the window closes so it can be re-created.
        let personaID = persona.id
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.windows.removeValue(forKey: personaID)
            }
        }

        windows[persona.id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    func openRecap(_ entry: RecapEntry) {
        if let existing = recapWindows[entry.id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: false)
            return
        }

        let view = SidecastRecapView(entry: entry)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)

        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        window.title = "\(entry.windowLabel) — Recap \(tf.string(from: entry.createdAt))"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 400))
        window.minSize = NSSize(width: 420, height: 300)
        window.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)
        window.isReleasedWhenClosed = false
        window.center()

        let entryID = entry.id
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recapWindows.removeValue(forKey: entryID)
            }
        }

        recapWindows[entry.id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    func openHistory(engine: SidecastEngine) {
        if let existing = historyWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: false)
            return
        }

        let view = SidecastHistoryView(engine: engine)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Sidecast History"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 620, height: 520))
        window.minSize = NSSize(width: 520, height: 420)
        window.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)
        window.isReleasedWhenClosed = false
        window.center()

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.historyWindow = nil
            }
        }

        historyWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }
}
