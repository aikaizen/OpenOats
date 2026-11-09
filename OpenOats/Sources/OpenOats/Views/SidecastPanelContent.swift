import AppKit
import SwiftUI

/// Full-height sidecast sidebar with persona cards and bottom controls.
struct SidecastPanelContent: View {
    @Bindable var settings: AppSettings
    let engine: SidecastEngine?
    let onCollapse: () -> Void


    var body: some View {
        VStack(spacing: 0) {
            // Header
            SidecastHeader(engine: engine, isGenerating: engine?.isGenerating ?? false, onCollapse: onCollapse)


            Divider().opacity(0.3)

            // Persona cards — use a task-driven timer instead of TimelineView so
            // we don't keep a CADisplayLink running at 60 Hz when the panel is hidden.
            PersonaCardList(settings: settings, engine: engine)

            Spacer(minLength: 0)

            Divider().opacity(0.3)

            // Bottom bar
            SidecastBottomBar(settings: settings)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color(red: 0.08, green: 0.08, blue: 0.12)
                .opacity(0.92)
        )
    }
}

// MARK: - Persona Card List (1-second task timer, no display link)

private struct PersonaCardList: View {
    @Bindable var settings: AppSettings
    let engine: SidecastEngine?
    @State private var now: Date = .now

    var body: some View {
        let effectiveLifetime: Double = settings.sidecastBubbleLifetimeSeconds > 0
            ? settings.sidecastBubbleLifetimeSeconds
            : Double.infinity
        let isGenerating = engine?.isGenerating ?? false

        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(settings.enabledSidecastPersonas) { persona in
                    SidecastPersonaCard(
                        persona: persona,
                        engine: engine,
                        messages: engine?.messages(for: persona.id) ?? [],
                        now: now,
                        lifetime: effectiveLifetime,
                        isGenerating: isGenerating
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                now = .now
            }
        }
    }
}

// MARK: - Header

private struct SidecastHeader: View {
    let engine: SidecastEngine?
    let isGenerating: Bool
    let onCollapse: () -> Void


    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))

            Text("AI Enhanced")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)

            Text("LIVE")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(isGenerating ? Color.orange : Color.green)
                )
            Spacer()

            // Collapse to bar button
            Button {
                onCollapse()
            } label: {
                Image(systemName: "rectangle.compress.vertical")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Collapse to bar")

            // Recap buttons (disabled when no session or already recapping)
            let hasSession = engine?.sessionID != nil
            let isRecapping = engine?.isRecapping ?? false

            if isRecapping {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
                    .help("Generating recap…")
            }

            ForEach([RecapWindow.minutes(5), RecapWindow.minutes(10), RecapWindow.sinceStart], id: \.label) { window in
                Button(window.shortLabel) {
                    guard let eng = engine else { return }
                    Task { await eng.requestRecap(window) }
                }
                .font(.system(size: 10, weight: .semibold))
                .disabled(!hasSession || isRecapping)
                .help(window.label)
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(hasSession && !isRecapping ? 0.12 : 0.05))
                )
                .foregroundStyle(.white.opacity(hasSession && !isRecapping ? 0.85 : 0.35))
            }

            // History button
            Button {
                if let eng = engine {
                    SidecastWindowManager.shared.openHistory(engine: eng)
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(hasSession ? 0.85 : 0.35))
            }
            .buttonStyle(.plain)
            .disabled(!hasSession)
            .help("Sidecast history")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)

        // Inline recap error
        if let errMsg = engine?.lastRecapError {
            Text(errMsg)
                .font(.system(size: 10))
                .foregroundStyle(Color.red.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
        }

        Text("Live on-screen commentary from AI personas")
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
    }
}

// MARK: - Persona Card

private struct SidecastPersonaCard: View {
    let persona: SidecastPersona
    let engine: SidecastEngine?
    let messages: [SidecastMessage]
    let now: Date
    let lifetime: TimeInterval
    let isGenerating: Bool

    @State private var isExpanded = false

    private var visibleMessages: [SidecastMessage] {
        guard lifetime > 0 else { return messages }
        return messages.filter { now.timeIntervalSince($0.timestamp) <= lifetime }
    }

    private var visibleMessage: SidecastMessage? { visibleMessages.first }

    private func timeAgoString(for message: SidecastMessage) -> String? {
        let elapsed = Int(now.timeIntervalSince(message.timestamp))
        if elapsed < 5 { return "just now" }
        if elapsed < 60 { return "\(elapsed)s ago" }
        return "\(elapsed / 60)m ago"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Avatar
            PersonaAvatarCircle(persona: persona, size: 56)

            // Content
            VStack(alignment: .leading, spacing: 6) {
                // Name + subtitle badge + expand button
                HStack(spacing: 8) {
                    Text(persona.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)

                    Text(persona.subtitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(persona.avatarTint.bubbleColor)
                        )

                    Spacer()

                    // Expand / collapse toggle
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Collapse" : "Expand history")
                }

                // Message text — tapping it also opens the popover
                if let visibleMessage {
                    let newestFeedback = engine?.feedback(for: visibleMessage.id)
                    let newestDisplayText = newestFeedback?.editedText ?? visibleMessage.text

                    Text(newestDisplayText)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .onTapGesture { isExpanded.toggle() }

                    // "edited" tag
                    if newestFeedback?.editedText != nil {
                        Text("edited")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }

                    // Confidence + time
                    HStack(spacing: 6) {
                        if visibleMessage.confidence >= 0.7 {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 6, height: 6)
                            Text("High confidence")
                                .font(.system(size: 10))
                                .foregroundStyle(.blue.opacity(0.8))
                            Text("·")
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        if let timeAgo = timeAgoString(for: visibleMessage) {
                            Spacer()
                            Text(timeAgo)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }

                    // Feedback controls — hover-only on the card
                    if let engine {
                        MoteFeedbackControls(
                            messageID: visibleMessage.id,
                            originalText: visibleMessage.text,
                            engine: engine,
                            alwaysVisible: false
                        )
                    }

                    // Older messages
                    ForEach(Array(visibleMessages.dropFirst()), id: \.id) { older in
                        let olderFeedback = engine?.feedback(for: older.id)
                        let olderDisplayText = olderFeedback?.editedText ?? older.text
                        VStack(alignment: .leading, spacing: 3) {
                            Text(olderDisplayText)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(3)
                            if let timeAgo = timeAgoString(for: older) {
                                Text(timeAgo)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                            if let engine {
                                MoteFeedbackControls(
                                    messageID: older.id,
                                    originalText: older.text,
                                    engine: engine,
                                    alwaysVisible: false
                                )
                            }
                        }
                        .padding(.top, 6)
                    }
                } else {
                    Text(isGenerating ? "Thinking…" : "Listening…")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.25))
                        .italic()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(persona.avatarTint.bubbleColor.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(persona.avatarTint.bubbleColor.opacity(isExpanded ? 0.55 : 0.25), lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.3), value: visibleMessage?.id)
        .popover(isPresented: $isExpanded, arrowEdge: .trailing) {
            if let engine {
                SidecastPersonaHistoryView(
                    persona: persona,
                    engine: engine,
                    onOpenInWindow: {
                        isExpanded = false
                        SidecastWindowManager.shared.openWindow(for: persona, engine: engine)
                    },
                    onDismiss: { isExpanded = false }
                )
                .onKeyPress(.escape) {
                    isExpanded = false
                    return .handled
                }
            }
        }
    }
}

// MARK: - Bottom Bar

private struct SidecastBottomBar: View {
    @Bindable var settings: AppSettings

    var body: some View {
        HStack(spacing: 12) {
            // Intensity picker
            Menu {
                ForEach(SidecastIntensity.allCases) { intensity in
                    Button {
                        settings.sidecastIntensity = intensity
                    } label: {
                        HStack {
                            Text(intensity.displayName)
                            if settings.sidecastIntensity == intensity {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(settings.sidecastIntensity.displayName + " Mix")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(.white.opacity(0.1))
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)

            Spacer()

            // Persona toggle circles
            HStack(spacing: -4) {
                ForEach(settings.sidecastPersonas.indices, id: \.self) { index in
                    PersonaToggleCircle(
                        persona: settings.sidecastPersonas[index],
                        isEnabled: settings.sidecastPersonas[index].isEnabled,
                        onToggle: {
                            settings.toggleSidecastPersona(at: index)
                        }
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct PersonaToggleCircle: View {
    let persona: SidecastPersona
    let isEnabled: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            ZStack(alignment: .bottomTrailing) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(persona.avatarTint.bubbleColor.opacity(isEnabled ? 0.6 : 0.15))
                    Circle()
                        .stroke(.white.opacity(isEnabled ? 0.4 : 0.1), lineWidth: 1.5)

                    if let image = avatarImage {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .clipShape(Circle())
                            .padding(2)
                            .opacity(isEnabled ? 1 : 0.35)
                    } else {
                        Image(systemName: persona.avatarSymbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(
                                isEnabled
                                    ? persona.avatarTint.bubbleColor
                                    : .white.opacity(0.2)
                            )
                    }
                }
                .frame(width: 32, height: 32)

                // Check/uncheck badge
                ZStack {
                    Circle()
                        .fill(isEnabled ? Color.blue : Color.red.opacity(0.7))
                    Image(systemName: isEnabled ? "checkmark" : "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 14, height: 14)
                .offset(x: 2, y: 2)
            }
        }
        .buttonStyle(.plain)
        .help(isEnabled ? "Disable \(persona.name)" : "Enable \(persona.name)")
    }

    private var avatarImage: NSImage? {
        guard persona.avatarUsesImage else { return nil }
        return NSImage(contentsOfFile: persona.avatarImagePath)
    }
}

// MARK: - Color extension for bubbles

extension PersonaAvatarTint {
    var bubbleColor: Color {
        switch self {
        case .slate: Color(red: 0.35, green: 0.38, blue: 0.42)
        case .blue: Color(red: 0.22, green: 0.42, blue: 0.72)
        case .teal: Color(red: 0.18, green: 0.52, blue: 0.55)
        case .green: Color(red: 0.22, green: 0.55, blue: 0.32)
        case .orange: Color(red: 0.78, green: 0.48, blue: 0.15)
        case .red: Color(red: 0.72, green: 0.22, blue: 0.22)
        case .pink: Color(red: 0.72, green: 0.28, blue: 0.52)
        case .indigo: Color(red: 0.35, green: 0.28, blue: 0.65)
        }
    }
}

// MARK: - Collapsed Bar

/// Thin 40-pt bar shown when the sidebar is collapsed.
/// Owns the expand button, live recording dot, and new-motes badge.
struct SidecastCollapsedBar: View {
    let engine: SidecastEngine?
    let motesAtCollapse: Int
    let onExpand: () -> Void

    private var isRecording: Bool { engine?.sessionID != nil }

    private var newMotesCount: Int {
        guard let eng = engine else { return 0 }
        let total = eng.messagesByPersona.values.reduce(0) { $0 + $1.count }
        return max(0, total - motesAtCollapse)
    }

    var body: some View {
        ZStack {
            // Double-click anywhere on the bar to expand
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onExpand() }

            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))

                Text("Sidecast")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))

                // Live recording dot
                if isRecording {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                }

                // New-motes badge
                let count = newMotesCount
                if count > 0 {
                    Text("\(count) new")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.blue.opacity(0.75)))
                }

                Spacer()

                // Expand button
                Button {
                    onExpand()
                } label: {
                    Image(systemName: "rectangle.expand.vertical")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Expand")
            }
            .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.08, green: 0.08, blue: 0.12).opacity(0.95))
    }
}
