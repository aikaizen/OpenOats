# PRD: Sidecast recap windows, wider context, persistent advisor history

Project tag: `[brain]`    Work type: app    Date: 2026-11-07    Author: Claude (board owner)
Repo: /Users/adilislam/Desktop/OpenOats (SwiftPM package in ./OpenOats), branch `feature/brain-sidecast` (6 commits ahead of a9c6e75). Do not push. Do NOT install, launch, quit or signal /Applications/OpenOats.app; the user may be recording. Build only to dist/.

## 1. Outcome
During a call the host can (a) rely on the Recap persona actually seeing the last several minutes of transcript, (b) press "5 min", "10 min" or "Since start" and get a structured recap of exactly that window, and (c) open a History window that lists everything every advisor has said this session, searchable and filterable, persisted to the session folder so it survives relaunch and can be exported.

## 2. Context
- Engine: `Intelligence/SidecastEngine.swift`. Today `buildPrompt` gets `recentExchange` (last 6 utterances) and `recentUtterances` (last 10) from `Models/TranscriptStore.swift`. `client.complete(...)` is the LLM call (line ~100); reuse it.
- Panel: `Views/SidecastPanelContent.swift` (`SidecastHeader`, `PersonaCardList`, `SidecastPersonaCard`), pop-open view `Views/SidecastPersonaHistoryView.swift` (+ `SidecastWindowManager`, `PersonaAvatarCircle`). Settings: `Settings/SettingsStore.swift` (manual `access`/`withMutation` pattern, UserDefaults keys), `Views/SidecastSettingsTab.swift`.
- Session plumbing: `App/LiveSessionController.swift` owns `currentSessionID`, calls `coordinator.sidecastEngine?.clear()` on session start (~line 354) and `coordinator.sessionRepository.appendLiveUtterance(sessionID:…)` per utterance. `Storage/SessionRepository.swift` has `sessionsDirectoryURL`; session folders are `<sessionsDirectoryURL>/<sessionID>/` (contain transcript.live.jsonl, notes.md).
- Models: `Models/SidecastModels.swift` (`SidecastMessage`, `SidecastPersona`).
- Docs to update: `docs/brain-sidecast.md`.

## 3. Interfaces (fixed)
Settings (UserDefaults keys, add to SettingsStore + SidecastSettingsTab):
- `sidecastContextSeconds: Double`, default 300. Picker: 1 min / 3 min / 5 min / 10 min / 20 min.
- `sidecastContextMaxUtterances: Int`, default 80 (hard cap on utterances sent as context).

Models (new file `Models/SidecastHistoryModels.swift`):
```swift
enum RecapWindow: Equatable, Sendable { case minutes(Int); case sinceStart
    var label: String  // "Last 5 min", "Last 10 min", "Since start"
}
struct RecapEntry: Identifiable, Codable, Sendable, Equatable {
    let id: UUID; let createdAt: Date; let windowLabel: String
    let coversFrom: Date; let coversTo: Date; let utteranceCount: Int; let truncated: Bool; let text: String
}
enum SidecastHistoryEntry: Identifiable, Codable, Sendable, Equatable {
    case message(SidecastMessage)   // SidecastMessage must become Codable (all fields are plain)
    case recap(RecapEntry)
    var id: UUID; var timestamp: Date; var text: String; var title: String  // persona name or windowLabel
}
```
Engine additions (`SidecastEngine`):
- `var sessionID: String?` set by LiveSessionController when a session starts (same place it calls `clear()`); `clear()` keeps writing to the previous file until the new ID is set, then switches.
- `private(set) var history: [SidecastHistoryEntry]` (observable, chronological, whole session, no cap). Every accepted message is appended here as well as to the existing per-persona stores. Every recap is appended.
- `func requestRecap(_ window: RecapWindow) async` and `private(set) var isRecapping: Bool`, `private(set) var lastRecapError: String?`. Only one recap in flight; a second request while one runs is ignored.
- Context: `buildPrompt` replaces `widerContext` (last 10) with utterances whose timestamp is within `sidecastContextSeconds` of the latest utterance, capped at `sidecastContextMaxUtterances` most recent, formatted `HH:mm Speaker: text` one per line, under a heading `Transcript, last N min (M utterances)`. `recentExchange` (6) stays for retrieval queries and for the "latest exchange" block. Total context text is additionally capped at 16,000 characters (drop oldest).
Persistence (new `Storage/SidecastHistoryStore.swift`, actor or @MainActor class owned by the engine):
- Appends each entry as one JSON line to `<sessionsDirectoryURL>/<sessionID>/sidecast.jsonl` (create dir if missing, 0600). Engine gets `sessionsDirectoryURL` injected (add an init parameter with a default of nil and set it where the engine is constructed; find with `grep -rn "SidecastEngine(" Sources`).
- `load(sessionID:) -> [SidecastHistoryEntry]` reads the file (tolerant of bad lines). On `sessionID` set, the engine loads existing entries into `history` so a relaunch mid-session keeps the log.
- `exportMarkdown(sessionID:) -> URL` writes `<session>/sidecast.md`: `# Sidecast history — <sessionID>` then one `### HH:mm · <title>` + text per entry, chronological.

Recap prompt (new `Intelligence/RecapPrompt.swift`, a static func returning system + user strings):
- System: "You produce a recap of a live call for the host, from the transcript only. Plain text, no markdown headers or bullets symbols other than a leading dash, no emoji. Sections in this order, each on its own line as `Thread:`, `Decisions and positions:`, `Open questions and asks of the host:`, `Consider now:`. Attribute to speakers when clear. Be specific and compact; at most 1500 characters. If the window has nothing substantive, say so in one line."
- User: window label, covered time range, utterance count, a note if truncated, then the transcript lines `HH:mm Speaker: text`. Transcript for the recap is capped at 24,000 characters (keep newest, set `truncated`).
- Model/provider: the same `client` and model Sidecast already uses.

UI:
- `SidecastHeader` gains, right-aligned: three small buttons `5 min` `10 min` `Since start` (disabled with a spinner while `isRecapping`) and a `clock.arrow.circlepath` "History" button. Tooltips. Buttons do nothing when there is no session.
- Pressing a recap button runs `requestRecap`, then opens the result in a window via `SidecastWindowManager` (new method `openRecap(_ entry: RecapEntry)`; one window per recap, title "<windowLabel> — Recap HH:mm"), full text selectable, Copy button. Errors show inline in the header as a small red text for 8 s.
- History button opens `SidecastHistoryWindow` (new `Views/SidecastHistoryView.swift`) via `SidecastWindowManager.openHistory(engine:)` (single window, reopening focuses): toolbar with a search field (case-insensitive substring over text and title), filter chips (All, one per enabled persona, Recaps), sort toggle (newest first default / chronological), `Export Markdown` button (calls store export, then `NSWorkspace.shared.activateFileViewerSelecting`). List rows: time (HH:mm:ss), title badge tinted by persona avatarTint (slate for recaps), full text selectable, per-row Copy. Live-updates from `engine.history`. Min size 520x420.

## 4. Slices
Single worker (model premium-ide), in this order, building after each: (1) models + settings, (2) engine context window + history + persistence + sessionID wiring, (3) recap request + prompt, (4) UI header buttons, recap window, history window, (5) docs.

## 5. Review brief (reviewer: premium, after build)
Attack: history duplicates on relaunch (load + append), sessionID nil paths (no session yet), file handle leaks, main-actor violations in the store, context cap arithmetic (seconds vs count vs chars), recap button spam, window manager retaining engines, Codable of SidecastMessage breaking existing decoding anywhere, settings default migration, and whether `clear()` still resets everything it used to.

## 6. Verification the manager runs
- `cd OpenOats && swift build` passes (Swift 6.3, CLT only; XCTest unavailable, skip tests).
- `DISABLE_SPARKLE=1 SKIP_SIGN=1 SKIP_INSTALL=1 APP_VERSION=1.92.0-brain ./scripts/build_swift_app.sh` completes; `plutil -p dist/OpenOats.app/Contents/Info.plist | grep SU` shows no SUFeedURL.
- `strings dist/OpenOats.app/Contents/MacOS/OpenOats | grep -c "SidecastHistoryStore\|RecapPrompt\|SidecastHistoryView"` ≥ 3.
- Diff read against this PRD.

## 7. Boundaries
No change to message generation filters (dedupe, thresholds, cooldowns), persona JSON schema, kb indexing, recording, notes. No new third-party dependencies. No pushing, no installing, no touching the running app.

## 8. Worker report format
Files changed; commands run and results (paste the plutil and strings output); new settings keys with defaults; how sessionID reaches the engine; anything uncertain or deviating from this PRD and why.
