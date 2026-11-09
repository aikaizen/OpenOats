# Sidecast over a personal knowledge base ("brain" Sidecast)

This branch (`feature/brain-sidecast`) tunes Sidecast so a folder of personal
notes (a wiki of people, projects and meetings) can act as a live advisor during
calls. It also documents how to configure OpenOats entirely from the command
line, with no UI, including building the knowledge-base cache externally.

## What the branch changes

Retrieval (`Intelligence/SidecastEngine.swift`)

- Evidence is retrieved with several queries per utterance instead of one: the
  latest utterance, the last six utterances joined, the current topic, the short
  summary, and up to six proper-noun phrases extracted from the recent exchange.
  Results are merged and de-duplicated by file path, top 8.
- Each persona keeps its own message history (`sidecastHistoryPerPersona`,
  default 3). `messages(for:)` returns newest first.

Knowledge base (`App/LiveSessionController.swift`)

- On launch, if the cached index cannot be restored (stale or missing) and
  folders are configured, the app re-indexes instead of silently running with
  no knowledge base.

Display (`Views/SidecastPanelContent.swift`, `Views/SidecastSettingsTab.swift`,
`Views/SidecastHistoryView.swift`)

- New `PersonaVerbosity.long` (480 characters). Existing: terse 80, short 140,
  medium 220.
- `sidecastBubbleLifetimeSeconds` (Double). `0` means a bubble stays until the
  persona's next message replaces it. This is the new default. The Sidecast
  settings tab exposes it as "Bubble Lifetime".
- The newest message per persona renders in full. Older ones sit below it,
- The panel header gains a **Collapse** button (`rectangle.compress.vertical`) that shrinks the sidebar to a 40-pt bar pinned to its top edge (animated); the bar shows a sparkles icon, "Sidecast", a green live dot while a session is active, a "N new" badge for messages received since collapse, and an **Expand** button (`rectangle.expand.vertical`); double-clicking the bar also expands. Collapsed state and the pre-collapse frame are persisted in `sidecastCollapsed` / `sidecastExpandedFrame` (UserDefaults) and restored on relaunch.
  dimmer, clipped to three lines, with a time-ago label.
- Clicking the newest message text or the expand icon (⤡) in a card header opens a
  **popover** with the persona's full session history: every message newest first,
  full text (selectable), absolute timestamp plus time-ago, and a per-message copy
  button. Escape or clicking the icon again closes it. An "Open in Window" button
  in the popover header detaches it into a resizable **NSWindow** titled
  "<persona name> — Sidecast"; each persona gets its own window; reopening focuses
  the existing one. The engine retains up to max(50, sidecastHistoryPerPersona)
  messages per persona for the pop-open view (the card still shows only
  sidecastHistoryPerPersona).
- The panel header gains three **recap buttons** (`5 min`, `10 min`, `Since start`)
  and a **History** (`clock.arrow.circlepath`) button, right-aligned. Recap
  buttons are disabled while a recap is in flight (spinner shown) or when no
  session is active. A red inline error clears after 8 s.
- Pressing a recap button calls `SidecastEngine.requestRecap(_:)`, which generates
  a structured recap via the LLM and opens the result in a dedicated
  **NSWindow** titled `"<windowLabel> — Recap HH:mm"`. The recap is full-text
  selectable with a Copy button.
- The History button opens `SidecastHistoryView` (`Views/SidecastHistoryView.swift`)
  in a single **NSWindow** (min 520×420; reopening focuses). It shows all advisor
  messages and recaps for the session, live-updating from `engine.history`.
  Features: search field (case-insensitive substring over title + text), filter
  chips (All / one per active persona / Recaps), sort toggle (newest-first default
  / chronological), Export Markdown button (writes `<session>/sidecast.md` and
  opens the folder in Finder). Each row shows HH:mm:ss, a tinted title badge, the
  full selectable text, and a per-row Copy button.

## Recaps and history

`SidecastEngine` keeps a whole-session `history: [SidecastHistoryEntry]`
(observable, no cap). Every accepted advisor message and every completed recap is
appended here and simultaneously written to disk.

**Persistence** (`Storage/SidecastHistoryStore.swift`): each entry is appended as
one JSON line to `<sessionsDirectory>/<sessionID>/sidecast.jsonl` (mode 0600).
On session start the engine loads any existing entries from that file, so
relaunching mid-session keeps the full log intact. Bad lines are silently skipped.

**Recap prompt** (`Intelligence/RecapPrompt.swift`): builds system + user strings
for a time-windowed recap. Transcript is filtered to the window, capped at 24,000
characters (newest kept, `truncated` flag set). The same `client` and model that
Sidecast uses for live messages handles the recap LLM call; only one recap runs at
a time (a second request while one is in flight is ignored).

**Context window settings** (new UserDefaults keys):

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `sidecastContextSeconds` | Double | 300 | Seconds of transcript sent as wider context in the Sidecast prompt |
| `sidecastContextMaxUtterances` | Int | 80 | Hard cap on utterances in that wider context |

Both are exposed in the Sidecast settings tab under "Context Window". The picker
for `sidecastContextSeconds` offers 1 min / 3 min / 5 min / 10 min / 20 min.
Previously the prompt used the last 10 utterances as "Wider context"; it now uses
utterances whose timestamp falls within `sidecastContextSeconds` of the latest
utterance, capped at `sidecastContextMaxUtterances`, formatted
`HH:mm Speaker: text` one per line under a heading
`Transcript, last N min (M utterances)`. Total wider-context text is additionally
capped at 16,000 characters (oldest lines dropped). The recent-exchange block
(6 utterances) is unchanged.

**SessionID wiring**: `LiveSessionController` sets `engine.sessionID` immediately
after `_currentSessionID = handle.sessionID`. The engine's `sessionID` `didSet`
tells the history store the new session ID and loads any existing log. `clear()`
(called on session start) resets `history`, `isRecapping`, `lastRecapError`, and
`sessionStartDate`, and closes the store's file handle.

**Export**: `SidecastHistoryStore.exportMarkdown(sessionID:)` writes
`<session>/sidecast.md` — `# Sidecast history — <sessionID>` then one
`### HH:mm · <title>` block per entry, chronological. The History window's
"Export Markdown" button calls this and reveals the file in Finder.

## Echo suppression

`Transcription/AcousticEchoFilter` catches mic utterances that are re-heard
copies of remote speech.

| Parameter | Value | Why |
| --- | --- | --- |
| Time window | ±8 s (either order) | Echo delays measured 1–8 s; remote audio can also arrive slightly after the mic re-hears it |
| Similarity metric | `max(Jaccard, overlapCoefficient)` | Overlap coefficient (`\|A∩B\| / min(\|A\|,\|B\|)`) handles fragments where one side is a subset; Jaccard penalises those cases |
| Threshold | 0.8 | Calibrated on two real sessions: caught 127/150 and 84 echoes; sampled drops were true echoes |
| Minimum length | ≥ 4 words **or** ≥ 20 chars | Avoids false positives on very short utterances |

**Live retroactive drop**: when a remote final utterance is committed to
`TranscriptStore`, any You utterances from the preceding 8 s that match it are
removed from the in-memory store. This catches the case where the mic re-heard
the remote side *before* the remote transcription finished. The live transcript
file (`transcript.live.jsonl`) is not rewritten; the batch re-transcription pass
and the downstream motes pipeline perform an independent dedup pass.

## Feedback on motes

The host can rate, edit, and annotate each on-screen advice bubble ("mote") during
or after the call. Advisors use that feedback to improve within the session and in
later sessions.

### Controls

Each mote row in the **card** (newest message), **pop-open history**, and **History
window** carries four controls:

| Control | Behaviour |
| --- | --- |
| 👍 thumbs-up | Toggle "liked"; tinted green when set. |
| 👎 thumbs-down | Toggle "disliked"; tinted red when set; pair with a note for context. |
| ✏️ pencil | Open an inline `TextEditor` to rewrite the mote. Save commits; Cancel discards. Right-click (or long-press) the pencil shows "Revert to original". A small **edited** badge appears on the mote after saving. |
| 💬 bubble | Open a small popover text field to attach a free-text note. |

Controls appear **on hover** in the card and are **always visible** in the
pop-open history and the History window.

### Persistence

Every feedback action appends a `.feedback(MoteFeedback)` entry to
`<session>/sidecast.jsonl` (append-only; latest per `messageID` wins on load).
Old session files that predate this feature load without errors — unknown entry
types are silently skipped.

Each feedback event is also appended to the cross-session file
`~/Library/Application Support/OpenOats/sidecast-feedback.jsonl` which stores
`personaID`, `personaName`, `originalText`, `editedText`, `rating`, `note`, and
`timestamp` as one JSON line per event.

### Prompt injection

When `SidecastEngine.buildPrompt` runs, it builds a per-persona feedback block
from up to **6** most-recent examples (this session first, then the global file,
newest first, ≤ 1,500 characters total per persona) and appends it to the
persona stanza:

```
Host feedback on your past messages:
    liked: The Fed hiked rates 11 times in 18 months, from near-zero to 5.25–5.5%.
    disliked: Inflation is higher than expected. (too vague — give the exact CPI number)
    host rewrote "Rates are elevated" as "Fed funds rate is 5.25–5.5%, highest since 2001."
Lean toward what was liked; avoid what was disliked.
```

### Markdown export

The History window's **Export Markdown** button writes `<session>/sidecast.md`.
Message blocks now include rating (👍 / 👎) and note inline; edited text replaces
the original in the exported block with an *(edited)* annotation.

### Key types

```swift
enum MoteRating: String, Codable { case up, down }

struct MoteFeedback: Codable, Sendable, Equatable {
    let messageID: UUID
    let personaID: UUID
    var rating: MoteRating?
    var editedText: String?
    var note: String?
    let updatedAt: Date
}
```

`SidecastEngine` exposes:
- `func feedback(for messageID: UUID) -> MoteFeedback?`
- `func setFeedback(messageID:rating:editedText:note:)` — persists to session JSONL and global file; appends `.feedback` to observable `history`.
- `var feedbackByMessageID: [UUID: MoteFeedback]` — observable, keyed by message UUID.

## Setting it up without the UI

All settings live in the `com.openoats.app` defaults domain. Quit OpenOats
before writing, relaunch after. Keys used here:

| Key | Type | Example |
| --- | --- | --- |
| `sidebarMode` | string | `sidecast` |
| `sidecastPersonas` | data (UTF-8 JSON) | see `docs/examples/sidecast-personas.example.json` |
| `sidecastSystemPrompt` | string | see `docs/examples/sidecast-system-prompt.example.txt` |
| `sidecastMinValueThreshold` | float | `0.4` |
| `sidecastBubbleLifetimeSeconds` | float | `0` |
| `sidecastHistoryPerPersona` | integer | `3` |
| `kbFolderPaths` | array of strings | `~/notes/wiki` (absolute) |
| `embeddingProvider` | string | `ollama` |
| `ollamaBaseURL` / `ollamaEmbedModel` | string | `http://localhost:11434` / `nomic-embed-text` |
| `llmProvider` | string | `openAICompatible` |
| `openAILLMBaseURL` / `openAILLMModel` | string | any `/v1/chat/completions` endpoint and model |

Writing the persona list:

```sh
defaults write com.openoats.app sidecastPersonas \
  -data "$(xxd -p docs/examples/sidecast-personas.example.json | tr -d '\n')"
defaults write com.openoats.app sidecastSystemPrompt \
  -string "$(cat docs/examples/sidecast-system-prompt.example.txt)"
```

Persona JSON fields: `id` (UUID), `name`, `subtitle`, `prompt`, `avatarSymbol`
(SF Symbol), `avatarTint` (slate, blue, teal, green, orange, red, pink, indigo),
`avatarImagePath`, `verbosity` (terse, short, medium, long), `cadence` (rare,
normal, active), `evidencePolicy` (required, preferred, optional), `isEnabled`,
`webSearchEnabled`.

The system prompt must keep the `{{maxMessagesPerTurn}}` placeholder and the
JSON output schema; the engine parses that schema.

## Building the knowledge-base cache externally

OpenOats only indexes when the folder list or embedding settings change inside
the running app. On launch it loads `~/Library/Application Support/OpenOats/kb_cache.json`
and, on this branch, re-indexes if that fails. If your notes change often (for
example a wiki that another process writes), keep the cache fresh with
`scripts/build_kb_cache.py`, which writes the exact format `KnowledgeBase.swift`
reads and only embeds files whose content hash changed:

```sh
python3 -I scripts/build_kb_cache.py ~/notes/wiki
# env: OLLAMA_URL (default http://localhost:11434), EMBED_MODEL (default nomic-embed-text)
```

Run it from a launchd agent on an interval if you like. Two gotchas:

- launchd jobs using `/usr/bin/python3` are denied access to `~/Desktop` and
  `~/Documents` by macOS privacy controls. Use a Python interpreter that already
  has that access (for example a project virtualenv), or keep the notes outside
  those folders.
- The builder aborts without touching the cache when it finds zero `.md`/`.txt`
  files, so a permission failure cannot wipe a good cache.

## Installing a custom build over the release app

```sh
SKIP_SIGN=1 SKIP_INSTALL=1 APP_VERSION=1.90.0-brain ./scripts/build_swift_app.sh
osascript -e 'tell application "OpenOats" to quit'
codesign --force --deep --sign - \
  --entitlements OpenOats/Sources/OpenOats/OpenOats.entitlements dist/OpenOats.app
ditto dist/OpenOats.app /Applications/OpenOats.app
defaults write com.openoats.app SUEnableAutomaticChecks -bool false
open -a OpenOats
```

Ad-hoc signing changes the code identity, so macOS asks again for microphone,
system audio and calendar access on first launch. Sparkle update checks are
turned off so the release channel cannot overwrite the custom build; pull
upstream changes by rebasing this branch instead. Keep a copy of the signed
release bundle to revert.

## Staying safe across upstream updates

Build with `DISABLE_SPARKLE=1` so the bundle has no Sparkle feed URL. A manual
"Check for Updates" will show an alert instead of contacting the upstream server,
and automatic checks are suppressed regardless of user-defaults state.

Keep the app version above the upstream latest tag. Convention for this branch:
`upstream_major.(upstream_minor+1).0-brain` (e.g. `1.91.1-brain`). Even if a
feed URL somehow becomes present, Sparkle will not offer a *downgrade*, so the
locally built version never gets replaced by the release channel silently.

To pull upstream changes: `git fetch origin && git rebase origin/main` on
`feature/brain-sidecast`, resolve any conflicts, then rebuild and reinstall:

```sh
DISABLE_SPARKLE=1 SKIP_SIGN=1 APP_VERSION=1.91.1-brain ./scripts/build_swift_app.sh
# then re-sign ad-hoc and ditto as shown in "Installing a custom build" above
```

Never install the upstream DMG or the Homebrew cask over the fork — either will
overwrite the binary and drop all branch changes.
