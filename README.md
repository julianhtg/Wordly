# Wordly

100% local voice dictation for Apple Silicon Macs (macOS 14+). Hold `^`, speak,
release — the transcript pastes at your cursor in whatever app has focus.
Optional cleanup runs through a local Ollama model. No cloud, no accounts, no
per-word anything.

Two on-device engines, picked automatically from the languages you select:

| | Parakeet TDT v3 | Whisper large-v3-turbo |
|---|---|---|
| Languages | ~30 European | **100** |
| Speed | tens of milliseconds | seconds |
| Used when | every selected language is one it knows | anything else, including "Auto" |

Whisper's encoder always processes a full 30-second window no matter how briefly
you spoke, which is why it costs seconds even for "yes, send it". Parakeet does
not, so it handles the common case and Whisper covers the long tail.

A floating pill above the Dock shows live audio while you talk and a spinner
while it transcribes. If the focused spot doesn't take text, the transcript
isn't lost — the pill becomes a small panel with a **Copy** button (and it's
always available via *Copy Last Transcript* in the menu).

## Build & run

```bash
make vendor   # one-time: downloads prebuilt whisper.xcframework (v1.9.1)
make run      # builds Wordly.app into build/ and opens it
```

First launch downloads the models for whichever engine your languages need —
progress shows in the menu. Parakeet's are ~400 MB (in
`~/Library/Application Support/FluidAudio/Models/`); Whisper's
`ggml-large-v3-turbo.bin` is ~1.6 GB in
`~/.config/wordly/models/` and is only fetched once you actually select a
language Parakeet doesn't cover. After that the app is fully offline.

## Permissions (one-time)

1. **Microphone** — macOS prompts on first recording. Approve.
2. **Accessibility** — needed for the global hotkey and pasting. macOS prompts
   at first launch; enable Wordly in System Settings → Privacy & Security →
   Accessibility. The menu bar icon shows a struck-through mic until granted
   (the app retries automatically — no restart needed).

### Make permissions stick across rebuilds

By default the app is ad-hoc signed, which gets a new code hash on every
rebuild — macOS treats each rebuild as a new app and re-asks for Accessibility
and Microphone every time. To fix that permanently, create a stable
self-signed identity once:

```bash
make sign-setup   # asks for your login password once, to trust the cert
make app          # now signs with that identity
```

Then grant Accessibility one final time (the identity changed) and it sticks
across all future rebuilds. After granting, quit and relaunch Wordly once so
the event tap picks up the new permission.

If the hotkey is dead even though Wordly looks granted, you likely have stale
duplicate "Wordly" rows from earlier ad-hoc builds: remove every Wordly entry
under System Settings → Privacy & Security → Accessibility, then re-add the
current build and relaunch.

## Usage

| Gesture | Effect |
|---|---|
| Hold `^` (≥0.3 s), speak, release | Transcribe + paste at cursor |
| Double-tap `^` | Hands-free recording; single tap stops |
| Quick single tap `^` | Types a normal `^` (after ~0.3 s) |
| Press any other key while holding | Cancels the recording |

Menu bar: mic = idle, red mic = recording, hourglass = processing. Toggle the
floating pill with *Floating Indicator* in the menu (the rescue panel still
shows when a paste has nowhere to go, so a transcript is never lost).

### Speed

Measured on an M4 MacBook Air over an 11-clip corpus, 3 runs each
(`swift run -c release WordlyBench bench/audio`):

| engine | median | p95 |
|---|---|---|
| Parakeet | **105 ms** | 169 ms |
| Whisper, one language ticked | 2474 ms | 2754 ms |
| Whisper, *Auto — all languages* | 4796 ms | 5194 ms |

Two things follow. **Tick your languages** — with `Auto` Whisper runs its encoder
twice, once just to work out which language you spoke, and that pass is half the
wait. And if your languages are all ones Parakeet knows, you get the top row: the
transcript is there before you've let go of the key.

Whisper is slow here for a structural reason, not a tuning one: its encoder
always processes a 30-second window, so a two-second "yes, send it" costs the
same as half a minute of talking. Shortening that window was tried and doubles
the error rate — see `docs/superpowers/specs/2026-08-02-wordly-speech-pipeline-design.md`.
If you need Whisper's language coverage and want it faster, `"whisperModel":
"small"` in the config trades accuracy for a much smaller encoder.

## Languages

Menu → *Language* is a checklist, not a single choice. Tick the languages you
actually speak:

* **One ticked** — pinned. Fastest and most accurate, and on Whisper it skips an
  entire encoder pass (that pass is roughly half the wait).
* **Several ticked** — the engine detects, but may only answer with one of your
  languages. Welsh and Afrikaans are real attractors for spoken German; clamping
  the choice is what stops a confident wrong answer.
* **Auto — all languages** — all 100, no clamping. Always Whisper, because no
  30-language model can honestly claim the other 70.

The first language in the list is the fallback when detection is not confident
(below 50 %). Fresh installs start from your macOS language order. The languages
Whisper handles well (under ~10 % word error) are listed first; the rest are
under *All languages…* and quality there varies wildly — Welsh, Icelandic and
Amharic are in the list because the model claims them, not because they are good.

*Engine* in the same menu forces Parakeet or Whisper if you want to compare them
on your own voice.

## Custom dictionary

Menu → *Edit Dictionary…* opens `~/.config/wordly/dictionary.txt` — one name
or jargon term per line, `#` for comments. Terms bias Whisper's recognition
and are protected during cleanup.

Note: this only affects the **Whisper** engine. Parakeet is a transducer with no
prompt to bias, so if a name has to come out right every time, force Whisper in
Menu → *Engine*.

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
other layouts), `whisperModel`, `ollamaModel`, `cleanupEnabled`, `languages`
(list of codes, first is the fallback — also in the menu), `engine`
(`auto`/`parakeet`/`whisper`), `showIndicator` (floating pill on/off).
Unknown/missing keys keep their defaults, so upgrading never resets your file. A
pre-1.2 `"language": "de"` migrates to `"languages": ["de"]`; a pre-1.2
`"auto"` migrates to your macOS language order, since back then "auto" was the
default rather than a choice — set the list to `[]` (or pick *Auto — all
languages*) if you really do want all 100.

The app icon is generated once by `make icon` (→ `Resources/AppIcon.icns`);
`make app` regenerates it if missing.

## Credits

* [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT) with OpenAI's
  `large-v3-turbo` weights (MIT).
* [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0) running
  NVIDIA's [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
  — model weights are **CC-BY-4.0**.

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
9. While talking, the floating pill shows moving level bars above the Dock;
   toggle *Floating Indicator* off → no pill next time.
10. Dictate with focus on a non-text spot (e.g. the Desktop) → rescue panel
    appears with the text + a working Copy button; *Copy Last Transcript* in
    the menu copies it too.
11. Menu → *Language*: tick only German → info line reads "Ready — last: de · …"
    after a dictation, and the log says `engine ready — parakeet`.
12. Tick Japanese as well → the app switches to Whisper (and downloads its model
    the first time); dictate German again → still German text.
13. Quit Wordly → `^` types instantly again.

## How fast was that, really

Every dictation logs what it did:

```sh
/usr/bin/log show --predicate 'subsystem == "dev.wordly.Wordly"' --last 10m --style compact
```

`dictation …ms end-to-end` is the number you felt; the `whisper`/`parakeet` line
above it is the model's share. A Whisper run over 1.5 s also dumps its own
breakdown — `encode time` dominating is normal and structural, while a non-zero
`fallbacks` count means that clip was hard enough to be re-decoded up to six
times, which is the usual cause of a dictation that was suddenly slow.

To measure changes rather than guess at them:

```sh
scripts/make-bench-audio.sh                        # synthetic corpus via macOS TTS
swift run -c release WordlyBench bench/audio       # both engines, timings + WER
```

Drop your own recordings into `bench/audio` as `<lang>-<name>.wav` with a
matching `.txt` of what you said — the harness treats them the same and real
speech is what actually decides.

## If the pill doesn't show up

Every dictation logs the panel's real state. Read it with:

```sh
/usr/bin/log show --predicate 'subsystem == "dev.wordly.Wordly"' --last 10m --style compact | grep pill
```

`pill ok` means the window was genuinely on screen. `pill NOT ON SCREEN` names
which check failed (`visible`, `alpha`, `activeSpace`, `screen`, `frame`) and is
followed by `pill window rebuilt` — the app throws the wedged window away and
builds a fresh one, which it also does after every wake and display change. No
line at all for a dictation means the indicator was never asked to show (check
*Floating Indicator* in the menu).
