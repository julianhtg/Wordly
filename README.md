# Wordly

100% local voice dictation for Apple Silicon Macs. Hold `^`, speak, release —
the transcript pastes at your cursor in whatever app has focus. whisper.cpp
(Metal) does the transcription on-device; optional cleanup runs through a
local Ollama model. No cloud, no accounts, no per-word anything.

## Build & run

```bash
make vendor   # one-time: downloads prebuilt whisper.xcframework (v1.9.1)
make run      # builds Wordly.app into build/ and opens it
```

First launch downloads `ggml-large-v3-turbo.bin` (~1.6 GB) to
`~/.config/wordly/models/` — progress shows in the menu. After that the app is
fully offline.

## Permissions (one-time)

1. **Microphone** — macOS prompts on first recording. Approve.
2. **Accessibility** — needed for the global hotkey and pasting. macOS prompts
   at first launch; enable Wordly in System Settings → Privacy & Security →
   Accessibility. The menu bar icon shows a struck-through mic until granted
   (the app retries automatically — no restart needed).

Rebuilding the app (ad-hoc signature) can invalidate the Accessibility grant:
remove and re-add Wordly in that list if the hotkey goes dead after a rebuild.

## Usage

| Gesture | Effect |
|---|---|
| Hold `^` (≥0.3 s), speak, release | Transcribe + paste at cursor |
| Double-tap `^` | Hands-free recording; single tap stops |
| Quick single tap `^` | Types a normal `^` (after ~0.3 s) |
| Press any other key while holding | Cancels the recording |

Menu bar: mic = idle, red mic = recording, hourglass = processing.

## Custom dictionary

Menu → *Edit Dictionary…* opens `~/.config/wordly/dictionary.txt` — one name
or jargon term per line, `#` for comments. Terms bias Whisper's recognition
and are protected during cleanup.

## Optional cleanup (filler removal, punctuation repair)

```bash
brew install ollama
brew services start ollama
ollama pull gemma3:4b
```

Then enable *Cleanup (Ollama)* in the menu. If Ollama is stopped or slow, the
raw transcript is used — dictation never blocks. Off by default; Whisper
output is usually already clean.

## Config

`~/.config/wordly/config.json`: `keyCode` (10 = `^` on German ISO; change for
other layouts), `whisperModel`, `ollamaModel`, `cleanupEnabled`, `language`
(`auto`/`de`/`en` — also in the menu).

## Smoke checklist (manual)

1. `make run` → mic icon in menu bar, info line reaches "Ready".
2. TextEdit: hold `^`, say a German sentence, release → text pastes.
3. Quick-tap `^` → a `^` character appears.
4. Double-tap `^` → red icon stays; speak; single tap → text pastes.
5. Hold `^`, press `a` while holding → recording cancels, "a" types.
6. Add a distinctive name to the dictionary → dictate it → spelled right.
7. Copy an image (Preview), dictate into TextEdit, paste in Preview → image
   still on the clipboard.
8. Enable Cleanup with Ollama running → "ähm" and fillers disappear.
9. Quit Wordly → `^` types instantly again.
