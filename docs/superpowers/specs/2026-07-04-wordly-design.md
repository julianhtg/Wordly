# Wordly — Local Voice Dictation for macOS (Design)

Date: 2026-07-04
Status: Approved

## Goal

A free, 100% local Wispr Flow replacement for Apple Silicon Macs. Hold a key,
speak, release — cleaned text appears at the cursor in whatever app has focus.
No cloud calls, no API keys, no accounts, no per-word cost.

## Non-Goals

- Cross-device sync, mobile apps, any server component
- Command Mode (voice-editing selected text), voice snippets
- Per-app tone adaptation, VAD auto-stop, settings UI, launch-at-login,
  transcript history

These are deliberate v1 exclusions, not oversights. Any can be added later.

## Approach

Swift/AppKit menu bar app, built as an SPM executable and wrapped into a
`Wordly.app` bundle by a small script (a bundle gives TCC a stable permission
identity). whisper.cpp is linked in-process as an SPM dependency with Metal
enabled — the model loads once and stays in RAM. Optional transcript cleanup
goes through Ollama on localhost. All user-editable state is plain files in
`~/.config/wordly/`.

Rejected alternatives:
- `whisper-server` over HTTP (brew): simpler linking, but a second process to
  babysit, a port, and brew version drift.
- Python (rumps + pywhispercpp): fastest to write, but global event taps and
  text injection from Python are unreliable, and it contradicts the "no slow
  Python wrapper" requirement.

Risk: if whisper.cpp's `Package.swift` no longer builds cleanly via SPM at
implementation time, fall back to building `libwhisper` as an XCFramework via
the script whisper.cpp ships, or (last resort) approach B with
`whisper-server`.

## Activation — hotkey semantics

Key: `^` (German ISO layout, top-left, keycode 10 / `kVK_ISO_Section`).
Keycode lives in the config file so other keyboards work by editing one
number.

Implemented with an active `CGEventTap` (requires Accessibility permission)
and a state machine:

| Gesture | Behavior |
|---|---|
| Hold ≥ 300 ms | Push-to-talk: record while held; release → transcribe + inject. Key events suppressed. |
| Double-tap < 300 ms | Hands-free toggle ON; recording runs without holding. Next single tap stops → transcribe + inject. |
| Single quick tap | After the 300 ms disambiguation window, the `^` character is re-posted and types normally (≈300 ms delay on a rarely typed key). |
| Any other key while holding | Cancel: recording discarded, all events pass through (protects normal typing). |

The state machine is pure logic in its own type, unit-tested with synthetic
timestamped events.

## Components

Single Swift target, ~8 small files:

1. **AppDelegate** — accessory app (no Dock icon). `NSStatusItem` with three
   icon states: idle (mic), recording (red mic), processing (spinner/hourglass).
   Menu: Cleanup on/off (checkmark), Language submenu (Auto ✓ / Deutsch /
   English), Edit Dictionary (opens `dictionary.txt` in default editor), Quit.
2. **HotkeyMonitor** — owns the event tap; feeds the state machine; emits
   `startRecording` / `stopAndProcess` / `cancel`.
3. **Recorder** — `AVAudioEngine` capture, converted to 16 kHz mono Float32,
   accumulated in RAM (dictation is seconds to minutes; no temp files). Plays
   short start/stop ping sounds.
4. **Transcriber** — wraps a whisper.cpp context. Loads
   `ggml-large-v3-turbo.bin` (~1.6 GB) once at launch from
   `~/.config/wordly/models/`; auto-downloads from Hugging Face on first run
   with progress shown in the menu bar. Parameters: `language` from menu
   (default `auto`), `no_timestamps`, dictionary contents passed as
   `initial_prompt` to bias recognition toward user jargon.
5. **Cleaner** (optional, off by default) — POST to
   `http://localhost:11434/api/chat`, model `gemma3:4b`. System prompt: fix
   punctuation, remove filler words, keep language and meaning, preserve
   dictionary terms verbatim, output only the cleaned text. 10 s timeout.
   **Any failure returns the raw transcript — dictation never blocks on
   Ollama.**
6. **Injector** — clipboard-paste with restore: save current pasteboard string
   contents → write transcript → synthesize ⌘V via `CGEvent` → restore prior
   pasteboard after ~200 ms. Chosen over synthesized unicode keystrokes
   deliberately: keystroke injection requires ~20-char chunking and drops
   events in Electron/Java apps; paste is atomic at any length. (Wispr Flow
   also pastes.) Known trade-offs: clipboard managers see transcripts; target
   app must accept ⌘V.
7. **Dictionary** — `~/.config/wordly/dictionary.txt`, one term per line,
   `#` comments allowed. Hot-reloaded via mtime check before each dictation.
   Used in both the whisper `initial_prompt` and the cleanup prompt.
8. **Config** — `~/.config/wordly/config.json`:
   `{ "keyCode": 10, "whisperModel": "large-v3-turbo", "ollamaModel": "gemma3:4b", "cleanupEnabled": false, "language": "auto" }`.
   Created with defaults on first run. Menu toggles write back to it.

## Data Flow

```
hold ^ ──ping──▶ Recorder (red icon) ──release──▶ (processing icon)
  ──▶ Transcriber (whisper.cpp, Metal, in-process)
  ──▶ [Cleaner via Ollama, only if enabled]
  ──▶ Injector (paste at cursor) ──▶ idle icon
```

Expected per-utterance latency on Apple Silicon with large-v3-turbo:
~0.3–1.5 s for typical dictation lengths. Model load at launch: a few seconds,
once.

## Error Handling

- **Microphone permission missing** → alert with a button deep-linking to
  System Settings → Privacy & Security → Microphone.
- **Accessibility permission missing** → `AXIsProcessTrustedWithOptions`
  prompt at launch; menu shows a warning state until granted (event tap and
  ⌘V synthesis both need it).
- **Model file missing/corrupt** → auto-(re)download with menu progress;
  dictation disabled until ready.
- **Empty/silence transcription** → inject nothing, return to idle.
- **Ollama unreachable/timeout/error** → raw transcript passes through.
- **Recording while another recording processes** → ignored (single-flight).

## Testing

- Unit tests: hotkey state machine (tap/hold/double-tap/cancel timing paths),
  pasteboard save/restore, config load/default-creation, dictionary parsing.
- Manual smoke checklist in README: PTT into TextEdit, toggle mode, `^` still
  types, umlauts/German text, dictionary term recognized, cleanup on/off,
  clipboard restored after paste.
- whisper.cpp itself and AVAudioEngine capture are not unit-tested (external,
  exercised by the smoke checklist).

## Setup (one-time, documented in README)

1. Build: `make` (runs `swift build -c release` + wraps `Wordly.app`).
2. Launch, grant **Microphone** and **Accessibility** when prompted.
3. Model downloads automatically on first run (~1.6 GB).
4. Optional cleanup: `brew install ollama && ollama pull gemma3:4b`.

No Homebrew requirement for the core app. No API keys. Nothing leaves the
machine.
