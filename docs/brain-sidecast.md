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

Display (`Views/SidecastPanelContent.swift`, `Views/SidecastSettingsTab.swift`)

- New `PersonaVerbosity.long` (480 characters). Existing: terse 80, short 140,
  medium 220.
- `sidecastBubbleLifetimeSeconds` (Double). `0` means a bubble stays until the
  persona's next message replaces it. This is the new default. The Sidecast
  settings tab exposes it as "Bubble Lifetime".
- The newest message per persona renders in full. Older ones sit below it,
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
