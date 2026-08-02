<div align="center">

# 🎙️ Wordly

**Push-to-talk dictation for macOS that runs entirely on your Mac.**
Hold a key, speak, release — the text appears at your cursor, in any app.

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20Apple%20Silicon-lightgrey)](#-install)
[![Swift](https://img.shields.io/badge/Swift-6-orange)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

No cloud, no account, no API key, no per-word cost. Nothing you say leaves the
machine — the only network requests Wordly ever makes are the one-time model
downloads on first launch.

Cloud dictation is fast and costs a subscription and your voice. Local dictation
is private and usually slow enough to break your train of thought. Wordly is an
attempt at both: for the languages most people dictate in, the transcript is
ready **before you let go of the key** — 196 ms end-to-end for a 7-second
sentence on an M4 MacBook Air.

---

### Contents

| | |
|---|---|
| [✨ Features](#-features) | What it does |
| [⚡ Speed](#-speed) | The numbers, and how to reproduce them |
| [📦 Install](#-install) | Build, run, permissions |
| [🔑 Usage](#-usage) | The four gestures |
| [🌍 Languages](#-languages) | 100 of them, and which are worth using |
| [🧩 How it works](#-how-it-works) | Architecture in one diagram |
| [🔧 Configuration](#-configuration) | Config file, dictionary, cleanup |
| [🧪 Development](#-development) | Tests and the benchmark harness |
| [🩺 Troubleshooting](#-troubleshooting) | Reading the log |

---

## ✨ Features

- **Two speech engines, picked for you** — Parakeet TDT v3 on the Neural Engine
  for ~30 European languages, Whisper large-v3-turbo for all 100. You choose
  languages, not engines.
- **100 languages**, listed from the model's own table, with the ones Whisper
  actually handles well shown first and the rest honestly labelled.
- **Detection you can trust** — recognition is *clamped* to the languages you
  tick, so clean German never comes back as Welsh.
- **One key, three gestures** — push-to-talk, hands-free toggle, or just typing
  the character.
- **Nothing gets lost** — if the focused spot won't take text, the transcript
  moves into a panel with a Copy button instead of vanishing.
- **Custom vocabulary** for names and jargon, plus optional filler-word cleanup
  through a local Ollama model that fails open.
- **Measured, not asserted** — the benchmark harness ships with the app.

---

## ⚡ Speed

M4 MacBook Air, 11-clip corpus in 8 languages, 3 runs each:

| engine | median | p95 | word error |
|---|---|---|---|
| **Parakeet** | **105 ms** | 169 ms | 0.0 % on the short clips |
| Whisper, one language ticked | 2474 ms | 2754 ms | 10.4 % |
| Whisper, *Auto — all languages* | 4796 ms | 5194 ms | 10.4 % |

```bash
scripts/make-bench-audio.sh                   # builds the corpus with macOS TTS
swift run -c release WordlyBench bench/audio  # both engines, timings + WER
```

**Tick your languages.** With *Auto*, Whisper runs its encoder twice — once only
to work out which language you spoke, once to transcribe — and that first pass is
half the wait.

**Whisper is slow here for a structural reason, not a tuning one.** Its encoder
always processes a full 30-second window, so a two-second "yes, send it" costs
exactly as much as half a minute of talking. Shortening that window is the
obvious fix and it doubles the error rate — that experiment and three others
that failed are written up in the
[design note](docs/superpowers/specs/2026-08-02-wordly-speech-pipeline-design.md).

---

## 📦 Install

**Requirements:** Apple Silicon Mac · macOS 14+ · `xcode-select --install` ·
~1 GB free for models.

```bash
git clone https://github.com/julianhtg/Wordly.git
cd Wordly
make vendor   # one-time: prebuilt whisper.xcframework (v1.9.1)
make run      # builds Wordly.app into build/ and opens it
```

Models download on first launch — progress shows in the menu bar. Parakeet's are
~400 MB; Whisper's 1.6 GB is only fetched if you select a language Parakeet
doesn't cover. After that Wordly is fully offline.

### Permissions

1. **Microphone** — macOS prompts on first recording.
2. **Accessibility** — needed for the global hotkey and for pasting. Enable
   Wordly under System Settings → Privacy & Security → Accessibility. The menu
   bar icon shows a struck-through mic until it's granted, and the app picks it
   up without a restart.

<details>
<summary><b>Make permissions stick across rebuilds</b></summary>

Ad-hoc signed builds get a new code hash every time, so macOS treats each
rebuild as a new app and asks again. Create a stable self-signed identity once:

```bash
make sign-setup   # asks for your login password once, to trust the certificate
make app          # now signs with that identity
```

Grant Accessibility one final time, then quit and relaunch so the event tap
picks up the permission. If the hotkey stays dead, remove every stale "Wordly"
row from the Accessibility list first — old ad-hoc builds leave duplicates.

</details>

---

## 🔑 Usage

| Gesture | Effect |
|---|---|
| Hold `^` (≥ 0.3 s), speak, release | Transcribe and paste at the cursor |
| Double-tap `^` | Hands-free recording; a single tap stops it |
| Quick single tap `^` | Types a normal `^` |
| Any other key while holding | Cancels — protects normal typing |

Menu bar: mic = idle, **red** mic = recording, hourglass = transcribing. The
info line shows the last result, e.g. `Ready — last: de · 0.2 s`.

`^` is keycode 10, left of `1` on a German ISO keyboard. Change `keyCode` in the
config for other layouts.

---

## 🌍 Languages

Menu → **Language** is a checklist, not a single choice:

| Ticked | Behaviour |
|---|---|
| **One** | Pinned. Fastest and most accurate — on Whisper it skips an entire encoder pass. |
| **Several** | The engine detects, but may only answer with one of your languages. |
| **None** (*Auto — all languages*) | All 100, unclamped. Always Whisper. |

The first language in your list is the fallback when detection isn't confident
(below 50 %). Fresh installs start from your macOS language order.

The shortlist at the top holds the languages Whisper transcribes at under ~10 %
word error; the other ~80 live under *All languages…*. They all work, but
quality varies enormously — Welsh, Icelandic and Amharic are in the list because
the model claims them, not because they're good.

Menu → **Engine** forces Parakeet or Whisper if you want to compare them on your
own voice.

---

## 🧩 How it works

```
^ held ──► HotkeyMonitor ──► Recorder ──► AudioTrim ──► SpeechEngine ──► Injector
        (CGEventTap +     (AVAudioEngine,  (silence)   (Parakeet or    (clipboard
         state machine)    16 kHz mono                  Whisper)        swap + restore)
                           Float32 in RAM)
```

- **HotkeyMonitor** owns a `CGEventTap` and feeds a pure state machine that
  separates hold / double-tap / quick-tap — so the gesture logic is unit-tested
  without any event plumbing.
- **Recorder** converts every buffer to the 16 kHz mono Float32 both engines
  want and keeps it in RAM; a generation counter drops straggling callbacks from
  a previous recording.
- **SpeechEngine** is a one-method protocol. `EngineRouting` picks the
  implementation from your language selection: Parakeet only gets the job when
  it covers *every* selected language, because it cannot report "that wasn't one
  of mine" and would otherwise return confident nonsense.
- **Injector** pastes through the clipboard and restores the previous contents,
  images included — dictating never costs you what you had copied.

---

## 🔧 Configuration

`~/.config/wordly/config.json` — missing keys keep their defaults, so upgrading
never resets your file.

| Key | Meaning |
|---|---|
| `keyCode` | Hotkey (10 = `^` on German ISO) |
| `languages` | Your languages, most-used first; `[]` means all 100 |
| `engine` | `auto`, `parakeet` or `whisper` |
| `whisperModel` | Default `large-v3-turbo`; `small` trades accuracy for speed |
| `cleanupEnabled`, `ollamaModel` | Optional Ollama post-processing |
| `showIndicator` | Floating pill on/off |
| `inputDeviceUID` | Microphone; `null` = system default |

<details>
<summary><b>Custom dictionary</b></summary>

Menu → *Edit Dictionary…* opens `~/.config/wordly/dictionary.txt` — one name or
term per line, `#` for comments. Terms bias recognition and are protected during
cleanup.

This affects the **Whisper** engine only: Parakeet is a transducer with no
prompt to bias. If a name has to come out right every time, force Whisper in
Menu → *Engine*.

</details>

<details>
<summary><b>Optional cleanup (filler words, punctuation)</b></summary>

```bash
brew install ollama
brew services start ollama
ollama pull gemma3:4b
```

Enable *Cleanup (Ollama)* in the menu. It removes filler words, fixes
punctuation and merges self-corrections — and is told which language to answer
in, so a small model can't drift into English. If Ollama is stopped or slow the
raw transcript is used; dictation never blocks on it. Off by default.

</details>

---

## 🧪 Development

```bash
make build   # debug build
make test    # 51 unit tests, no model required
make app     # signed app bundle in build/
```

The tests cover what's worth covering: the hotkey state machine, clipboard
restore, language clamping and its confidence threshold, engine routing, config
migration, silence trimming, and the floating panel's geometry.

---

## 🩺 Troubleshooting

Everything the app does is logged under its own subsystem:

```bash
/usr/bin/log show --predicate 'subsystem == "dev.wordly.Wordly"' \
  --last 10m --style compact
```

*(The full path matters — `log` is a zsh builtin.)*

- `dictation …ms end-to-end` is the wait you actually felt; the `parakeet` or
  `whisper` line above it is the model's share.
- A Whisper run over 1.5 s prints its own breakdown. `encode time` dominating is
  normal and structural; a non-zero `fallbacks` count means that clip was hard
  enough to be re-decoded up to six times — the usual cause of a dictation that
  was suddenly slow.
- **No pill?** `pill ok` means it was genuinely on screen; `pill NOT ON SCREEN`
  names the failed check and is followed by `pill window rebuilt`. No pill line
  at all means the indicator was never asked to show.
- **Hotkey does nothing?** Accessibility permission — see
  [Install](#permissions).

---

## 📄 Credits

Wordly itself is MIT ([LICENSE](LICENSE)). Neither model is redistributed here —
both download on first launch — so their terms apply to what you fetch, not to
this repository:

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT) with OpenAI's
  `large-v3-turbo` weights (MIT)
- [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0) running
  NVIDIA's [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
  — weights are CC-BY-4.0
