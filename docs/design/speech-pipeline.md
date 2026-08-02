# Wordly 1.2 — Speech pipeline: two engines, many languages (Design)

Date: 2026-08-02
Status: Implemented

## Goal

Two complaints after several weeks of daily use: dictation is **sometimes** slow
(irregularly, not always), and the language menu offers only German and English.

## Where the time actually went

Measured on the machine that has the problem (M4 MacBook Air, 4 performance +
6 efficiency cores, 16 GB), corpus in `bench/audio`, harness `WordlyBench`.

The first measurement made the rest obvious:

```
whisper_print_timings:   encode time =  2799.66 ms /  1 runs
whisper_print_timings:   decode time =    30.62 ms /  1 runs
whisper_print_timings:      mel time =     2.76 ms
```

The encoder is ~99 % of the work, and it is a **fixed** cost: Whisper zero-pads
every clip to 30 s (`log_mel_spectrogram`: `stage_1_pad = WHISPER_SAMPLE_RATE *
30`) and always encodes the full 1500-frame context. large-v3-turbo kept
large-v3's entire 32-layer encoder and only shrank the decoder to 4 layers, so
turbo is fast at exactly the part that was already cheap for us.

Four causes were on the list. **One** survived measurement (11 clips, 3 runs
each, `ggml-large-v3-turbo.bin`):

| variant | median | p95 | WER |
|---|---|---|---|
| shipped (auto, 8 threads) | 4796 ms | 5194 ms | 10.4 % |
| auto language, 4 threads | 4832 ms | 5055 ms | 10.4 % |
| **pinned language, 4 threads** | **2474 ms** | **2754 ms** | 10.4 % |
| rejected: audio_ctx ≥768 | 1215 ms | 1950 ms | **21.3 %** |
| rejected: no temperature fallback | 2505 ms | 2811 ms | 10.4 % |

| Cause | Verdict |
|---|---|
| `language: "auto"` runs the encoder **twice** — once for language ID (`whisper.cpp:6836` → `whisper_lang_auto_detect_with_state` → `whisper_encode_with_state`), once to transcribe (`:7041`), with no cache between them | **Real, 1.94×**, and the only change that helped. Fixed by pinning a language whenever one is known. |
| `n_threads = cores - 2` = 8 on a 4P+6E chip, where whisper's own default is `min(4, cores)` | **Noise.** An earlier, dirtier run showed ~10 %; with three repeats on a quiet machine it is 4796 vs 4832 ms. The work is on the GPU. Changed anyway — same speed on four threads instead of eight, on a fanless laptop. |
| Shortening `audio_ctx` to fit the clip | **Rejected.** 2× faster, but word error doubles: 10.4 % → 21.3 % at 768 frames, 39 % at 512, 362 % at 192 (runaway hallucination). Identical with flash attention on and off, so it is the truncated context itself, not a kernel bug. |
| Disabling the temperature fallback (up to 6 re-decodes) | **Unmeasurable here.** Clean speech never triggers it — zero fallbacks across the corpus, and the timing is unchanged. Left at the default; a slow run now logs its own fallback count so a real occurrence names itself. |

So Whisper's floor on this machine is ~2.5 s, and it is the encoder. That is what
motivated the second engine rather than more tuning.

The quantized `large-v3-turbo-q5_0` (574 MB instead of 1.6 GB) was on the list to
fight the page-out that makes the first dictation after a pause slow — 2 GB of
swap is in use on this machine. It was dropped once Parakeet took over the common
languages: Whisper is now the *long-tail* engine, the one used precisely when
accuracy matters most and there is no better model available, so trading accuracy
for resident size is the wrong way round. `whisperModel` in the config still
accepts it.

Also considered and dropped: the Core ML/ANE encoder. It would be a genuine
drop-in — the vendored framework exports `_whisper_coreml_init` and is built with
`-DWHISPER_COREML=ON -DWHISPER_COREML_ALLOW_FALLBACK=ON`, and Hugging Face ships
a prebuilt `ggml-large-v3-turbo-encoder.mlmodelc.zip` — but it is another 1.17 GB
on a machine that is already 2 GB into swap, and the README's ">3× faster" is
against CPU, not Metal. Worth revisiting only if the Whisper path stays hot.

## The real answer: a second engine

Tuning Whisper caps out around 2.5 s on this hardware, because the encoder cost
is structural. Parakeet TDT v3 (FluidAudio, CoreML/ANE) is a transducer: no
30-second padding, no autoregressive decode over a large decoder, and no
temperature fallback, so it also has no slow-outlier failure mode. It covers ~30
European languages with language ID built into the model.

Same corpus, same machine, 3 runs per clip:

| clip | Parakeet | WER | | Whisper (pinned) |
|---|---|---|---|---|
| de-short | 101 ms | 0.0 % | | ~2.5 s |
| de-medium | 113 ms | 0.0 % | | |
| de-long (13 s) | 169 ms | 3.2 % | | |
| en-short | 101 ms | 0.0 % | | |
| es / fr / it / pl | 102-107 ms | 0.0 % | | |

**Median 105 ms, p95 169 ms** — 24× faster than the tuned Whisper path, and more
accurate on the languages it covers. (The residual error on the long clips is
inverse text normalisation, not misrecognition: "16 kHz" where the reference
says "sixteen kilohertz".)

Neither engine can do both jobs, so the app has both:

```
languages ⊆ Parakeet's set  →  Parakeet   (fast path, its own language ID)
anything else, incl. "Auto" →  Whisper    (all 100 languages)
```

Routing is deliberately dumb and pure (`EngineRouting`), because the failure mode
it prevents is not subtle: Parakeet has no way to say "that wasn't one of mine",
so handing it Thai would produce confident nonsense. One unsupported language in
the selection disqualifies it.

## Language UX

Wispr Flow's pattern, which its own docs recommend over auto-detect: a checklist
of "languages I speak" rather than one choice.

* one ticked → pinned (fastest, most accurate, and on Whisper it skips a pass)
* several → detect, then **clamp** to the list, falling back to the first entry
  when the best candidate is below 0.5 (faster-whisper's default threshold)
* none → auto over all 100, which forces Whisper

Clamping is free: `language = "auto"` already pays two encoder passes internally,
so doing the detection ourselves via `whisper_pcm_to_mel` +
`whisper_lang_auto_detect` (which fills a probability per language) costs the
same and buys the constraint. whisper.cpp has had an open request for this since
2023 (issue #1242); the API to do it yourself has been there all along.

The menu is generated from whisper's own table (`whisper_lang_max_id` /
`whisper_lang_str_full`), so it cannot drift from the model. The sub-10 %-WER
languages are listed first and the rest live under "All languages…" — the model
claims 100, but Welsh at 33 % and Amharic at 140 % (Whisper paper, Table 13) are
not a demo.

Fresh installs seed the list from the user's macOS language order (first two), so
the default is the fast pinned path rather than the slow honest-but-unnecessary
one.

## Other decisions

* The dictionary is now fed to Whisper as bare terms instead of the English
  sentence `Glossary: …`. It cannot hurt language detection (that only ever
  decodes `<|sot|>`), but it is ordinary in-context text the decoder continues
  from, so an English carrier sentence pulls the output toward English.
* The resolved language is passed into the Ollama cleanup prompt instead of
  hoping "keep the original language" holds for a 4B model.
* Diagnostics moved from `NSLog` to `os.Logger` under the `dev.wordly.Wordly`
  subsystem, so `log show --predicate 'subsystem == "dev.wordly.Wordly"'` returns
  exactly our lines instead of every row the process ever emitted. Interpolation
  is marked `.public`, since os.Logger otherwise redacts values to `<private>`.
  whisper.cpp's own logging is bridged into the same stream (`whisper_log_set`),
  and a run slower than 1.5 s prints its own timing breakdown.
* `platforms` moved from macOS 13.3 to 14.0 — FluidAudio's floor.

## Not done

Apple's `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26): structurally the best
latency story, since it transcribes *while* the key is held, but ~21 languages,
no auto-detect, and it needs the recorder rewritten to stream live. Transcribing
before release, Whisper's Silero VAD, and `params.translate` are also out.

## Verification

* `swift test` — 51 tests, including the pure parts of all of the above:
  audio-context sizing, clamped detection with its threshold fallback, config
  migration from the pre-1.2 `language` key, engine routing, and the fresh-install
  language seeding.
* `swift run -c release WordlyBench bench/audio` — the table above, regenerated.
  `scripts/make-bench-audio.sh` builds a synthetic multi-language corpus with
  macOS TTS; real recordings dropped into the same folder count identically and
  are the ones that decide.
