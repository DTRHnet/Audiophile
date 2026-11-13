# Changelog

All notable changes to Audiophile. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
[Semantic Versioning](https://semver.org/).

Measured numbers quoted here are from the LG G7 ThinQ (`LM-G710`, Android 10,
Termux) where this was built and tested; the measurements and the defects they
exposed are in [`docs/JOURNAL.md`](docs/JOURNAL.md), and what is coming next is
in [`docs/ROADMAP.md`](docs/ROADMAP.md).

## [Unreleased]

### Documentation

* Public-facing documentation rebuilt as a set: a decisive `README.md` with a
  verified / experimental / does-not-work status split, `docs/ARCHITECTURE.md`
  (how it works and what was rejected), `docs/OPERATIONS.md` (install, daily use,
  tuning by symptom, verification checklist, new-device bring-up) and
  `docs/EXPORTS.md` (the plan for using the transcripts: time ranges, digests,
  summaries, delivery targets, privacy tiers). `docs/ROADMAP.md` rewritten around
  that plan; `JOURNAL.md` reframed as the lab notebook and its checklist pointed at
  OPERATIONS so there is one copy.

### Added

* **`--replay PATH`** — runs the whole pipeline (VAD, whisper, journal) over a
  file or directory of recorded audio instead of the microphone. Each source
  file writes its own journal under `<work>/replay/`, and replay transcribes
  inline so a file's journal is complete before the next one starts. This is how
  to tune thresholds or compare models when nobody is talking.
* **`--doctor`** — one command that checks binaries, model, Silero model, script
  files, transcript directory writability, free space, whether the microphone
  actually delivers audio (it records 3 s and reports the peak, catching the
  Android "digital silence" case) and how fast whisper runs. Exits non-zero on
  failure.
* **Optional audio retention** (`DTRH_RETAIN_AUDIO=1`) — each utterance's WAV is
  archived to the SD card (`<card>/audiophile/audio/YYYY-MM-DD/`) instead of
  being deleted, with `DTRH_AUDIO_DIR`, `DTRH_RETAIN_DAYS` pruning and a
  `DTRH_RETAIN_MIN_FREE_MB` guard that switches archiving off rather than fill
  the card. The audit trail now records the retained path per utterance.
  Verified: two utterances archived to `/storage/7BFE-5787/audiophile/audio/`.
* `audiophile-retranscribe.sh` — re-runs whisper over kept audio with one or more
  models and reports latency, realtime factor and the transcripts side by side,
  so model choice can be settled on real speech instead of synthetic clips.
* `audiophile-model-bench.sh` — benchmarks every `ggml-*.bin` it can find (or the
  models you name) on this phone with this microphone: word error rate, latency,
  realtime factor and cold load time, per model. It builds its clips by having
  the phone speak known sentences and record itself, so no human input is
  needed, and it prints the realtime factor because "can this keep up with how
  much I talk" is the question that actually decides a default.

## [3.2.1] — 2026-11-12

A one-line bug that made the new queue a no-op in real use — found by a real
20-minute recording, not by the unit test.

### Fixed

* **The queue worker exited immediately.** `transcribe_worker` opened the queue
  on file descriptor 8 but the `read` had no `-u 8`, so bash read **stdin** —
  which is at EOF under `nohup` — and the worker fell straight out of its loop.
  Every utterance then took the inline fallback path (88 times in a 20-minute
  run, logged as `worker gone - transcribing inline`). Behaviour stayed correct
  because the fallback is real, but the asynchronous design was never exercised.
  Now `read -r -u 8`; verified 3 utterances queued, 3 received by the worker,
  **0 fallbacks**, single worker, clean exit at shutdown.

## [3.2.0] — 2026-11-12

Transcription stops blocking the listener, and the model can stay resident.

### Added

* **Asynchronous transcription queue** (`DTRH_ASYNC`, default on). Utterances
  are written to a queue and a worker transcribes them serially, so the VAD
  event loop keeps handling levels, rotation and notifications instead of
  waiting on whisper. Journal order is preserved because exactly one worker
  writes. Verified: two utterances in, two out, in order, with no stray
  processes after shutdown.
* **Optional resident model** (`DTRH_ENGINE=server`, `DTRH_SERVER_PORT=8087`).
  Starts `whisper-server` on loopback, health-checks it, and falls back to
  `whisper-cli` if it will not answer. Measured on a 20.5 s clip:
  cli 2701/2687/2680 ms vs server 2352/2287/2258 ms — **~390 ms saved per
  utterance**, and one fewer process spawn.
* `DTRH_ASYNC`, `DTRH_ENGINE`, `DTRH_SERVER_PORT` in the settings banner and
  the README table.

### Fixed

* Whisper's own chatter (`read_audio_data: …`, `output_txt: saving…`) no longer
  floods `DTRH-Audiophile.log`; the transcript still comes from the `.txt` file,
  and server mode parses the HTTP response instead.
* Non-speech annotations attached to real speech are stripped instead of
  journalled: `"[typing] First few words"` → `"First few words"`, `"Hello
  (laughs)"` → `"Hello"`. Text that is *only* an annotation is still dropped.
* `audiophile-pocket-calibrate.sh` could leave the media volume low: its
  `PREV_VOL` sed was greedy and captured the *last* stream's volume in the JSON
  rather than music's. It now matches the music entry explicitly and never
  lowers the stream. (Found because TTS-based test clips started transcribing
  as silence.)

## [3.1.0] — 2026-11-12

A second, semantic gate in front of whisper, plus the measurements needed to
decide the model question.

### Added

* **Silero VAD as whisper's own second gate** (`--vad -vm <model> -vt <thr>`),
  auto-detected from `~/whisper.cpp/models/*silero*.bin`. Measured on 6 s clips
  of pink noise and of 440+660 Hz tones: without VAD they were transcribed as
  `(dramatic music)` / `(beeping)` in ~3.5 s; with Silero the output is empty
  and the whole call takes **0.42–0.46 s**. Real speech is unaffected (same
  verbatim text, ~170 ms extra).
  New configuration: `DTRH_WHISPER_VAD` (`auto` | `off` | explicit path) and
  `DTRH_WHISPER_VAD_THRESHOLD` (default `0.5`), plus
  `DTRH_WHISPER_VAD_THRESHOLD` in the settings banner.
* Graceful degradation: if no Silero model is found (or the configured path is
  wrong) the pipeline logs a warning and keeps transcribing without the second
  gate instead of failing.
* `docs/ROADMAP.md` — direction, queued work, and the ideas deliberately
  rejected.

### Measured, no code change

* **`base.en` vs `tiny.en`**, 6 spoken sentences through the microphone,
  aggregate word error rate over 63 words: `tiny.en` **9.5 %** at **4.1 s** per
  utterance, `base.en` **6.3 %** at **8.3 s** per utterance — i.e. 2× the time
  and slower than realtime, for one sentence fixed out of six. `tiny.en` stays
  the default; `base.en` is documented as an opt-in for accuracy over latency.
  Both models mis-hear "audiophile" as "audio file", which points at the
  microphone chain rather than the model.

### Changed

* Script and banner version string `3.0.0` → `3.1.0`.

## [3.0.0] — 2026-11-12

The "silence gating" rewrite. v2 transcribed a fixed 30-second slice whether or
not anyone was speaking; v3 records one continuous stream and lets a voice
activity detector decide where an utterance begins and ends.

### Changed — user visible

* **No more 30 s slices.** An utterance is handed to whisper 1.5–2 s after the
  speaker stops, with 2 s of pre-roll so the first consonant is never clipped.
* **Silence costs nothing.** No transcription, no disk and no invented text
  while the room is quiet: measured 0 whisper calls and 0 written entries in a
  silent minute.
* **Transcripts carry their own timing**: `## HH:MM:SS (N.Ns)` per utterance,
  and a per-utterance audit trail in `transcripts/.audiophile/index.jsonl`.
* Whisper is no longer fed music, noise or doors as if it were speech.

### Added

* `audiophile-vad.py` — PCM voice activity detector and segmenter: per-100 ms
  RMS, tracking noise floor, hysteresis, pre-roll, end-silence, 120 s cap,
  short-blip and too-quiet rejection, writes 16 kHz mono WAV per utterance.
* `audiophile-follow.py` — byte-exact follower that lets one long-lived ffmpeg
  decode the live Ogg/Opus container. (`tail -f` cannot be used: ffmpeg fails
  with `Error opening input: End of file`.)
* `audiophile-calibrate.sh` — records a sample, prints the dBFS distribution and
  suggests `DTRH_SPEECH_DB` (`noise floor + 20 dB`).
* `docs/JOURNAL.md` — every measurement behind every decision, the approaches
  that were measured and rejected, the defects found during bring-up, the honest
  limits, and a §9 verification checklist.
* CLI: `--status`, `--stop`, `--tail`, `--selftest`, `--debug`, `--no-notify`,
  `--work DIR`, `--model FILE`.
* Environment overrides for every threshold (`DTRH_SPEECH_DB`,
  `DTRH_END_SILENCE_MS`, `DTRH_PREROLL_MS`, `DTRH_MIN_SPEECH_MS`,
  `DTRH_MIN_VOICED_DB`, `DTRH_WARMUP_MS`, `DTRH_MAX_SEGMENT_MS`,
  `DTRH_ROTATE_IDLE_S`, `DTRH_ROTATE_MAX_MB`, `DTRH_THREADS`, `DTRH_WORK`,
  `DTRH_MODEL`, `DTRH_ENC`, `DTRH_BITRATE`, `DTRH_RATE`, `DTRH_NOTIFY`,
  `LOG_LEVEL`).
* Live notification, wakelock, PID lock with stale detection, graceful
  shutdown, and a loud warning when the microphone returns digital silence
  (Android 10 hands all-zero buffers to capture started while the Termux app is
  not running).

### Fixed — found by running it, not by reading it

* Junk in the journal: whisper describes non-speech with bracketed annotations,
  so `[BLANK_AUDIO]`, `(birds chirping)`, `(keyboard clicking)` and `(mumbling)`
  were being written as if they were notes. Any transcript that is entirely
  `(...)` or `[...]` is now dropped, plus a small canned-phrase list.
* Transients (doors, keyboards, the phone being picked up) produced 0.4–0.8 s
  "utterances". Added a voiced-level gate, raised the minimum speech duration
  and added a 1.5 s warm-up that ignores MediaRecorder's own start transient.
* **Idle CPU was 21.5 % of one core**, because the bash feeder forked
  `stat`+`tail`+`head`+`sleep` ~7×/s. Replaced by `audiophile-follow.py`:
  **7.8 %** with a video playing in the room, **5.7 %** in a silent room
  (ffmpeg ~4 %, VAD ~3 %).
* The capture-size cap was only evaluated from the idle event, and a noisy room
  never reports idle, so the capture file could grow unbounded. The cap now also
  runs from the level event every 15 s.
* `audiophile-calibrate.sh` piped PCM into `python3 - <<PY`, where the
  here-document replaces stdin — python read its program and the samples were
  discarded. It now decodes to a file and passes the path as an argument. Its
  threshold heuristic was also rebuilt (it used the p10 of a single-cluster
  recording, which landed *below* the transients it should have cleared).

### Removed

* The `m4a → wav` conversion step (the VAD writes 16 kHz mono WAV directly) and
  the fixed-interval main loop.

## [2.0.0] — 2025-05-05

Upstream state this work started from (`DTRH-Audiophile.sh` v2.0.0).

* Fixed 30-second recording slices (`termux-microphone-record -f … -l 0` plus
  `sleep 30`), transcribed in the background while the next slice records.
* `ffmpeg` converts each `.m4a` to 16 kHz mono `.wav`; `whisper-cli` writes a
  `.txt`; the text is appended to `YYYY-MM-DD.md` under a `## HH:MM:SS` heading;
  the temporary audio is deleted.
* ASCII banner, colourised levelled logging to console and file, a settings
  block, PID lock, `termux-wake-lock`, optional notification, `--tail`, and
  `DTRH-Session.sh` for a tmux split view.
* Documented integrations: Tasker via Termux:Tasker, Obsidian vault, Syncthing.
