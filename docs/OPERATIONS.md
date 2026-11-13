# Operations

Everything about running it: first install, daily use, tuning when something
sounds wrong, verifying a change, and bringing up a new phone.

## Install

```bash
# Termux from F-Droid (not the Play Store build)
pkg update && pkg install termux-api ffmpeg python git cmake clang wget

# whisper.cpp + a model
git clone https://github.com/ggerganov/whisper.cpp.git ~/whisper.cpp
cd ~/whisper.cpp
cmake -B build && cmake --build build --config Release
bash ./models/download-ggml-model.sh tiny.en        # 74 MB

# Audiophile
git clone https://github.com/DTRHnet/Audiophile.git ~/Audiophile
cd ~/Audiophile && chmod +x *.sh *.py

# Android storage access
termux-setup-storage
mkdir -p ~/storage/shared/Obsidian/transcripts
```

Then verify before trusting it:

```bash
./DTRH-Audiophile.sh --selftest     # VAD state machine, no microphone
./DTRH-Audiophile.sh --doctor       # dependencies, permissions, levels, speed
```

### Permissions

- **Microphone**: `termux-microphone-record -d -f /dev/null`, accept the prompt.
  Grant it to **both** Termux and Termux:API.
- **Storage**: `termux-setup-storage`, accept.
- **Battery optimisation**: exempt Termux and Termux:API in Android settings, or
  long sessions may be killed.
- **Open the Termux app once.** Android 10 hands *all-zero samples* to a recorder
  started while the app is not running. Without this, recordings are silent and
  everything else looks healthy. `--doctor` reports it.

## Daily use

```bash
cd ~/Audiophile
./DTRH-Audiophile.sh                # foreground; Ctrl+C to stop
./DTRH-Audiophile.sh --debug        # same, with every VAD decision logged
./DTRH-Audiophile.sh --tail         # watch the log from another shell
./DTRH-Audiophile.sh --status       # running?
./DTRH-Audiophile.sh --stop         # stop cleanly
```

For anything longer than a quick test, run it in tmux so it survives the terminal
being closed and the screen going off:

```bash
./DTRH-Session.sh      # transcriber left, live log right; detach with Ctrl+b d
```

Expected log on a healthy start:

```
[INFO] whisper vad: silero (…, threshold 0.5)
[INFO] starting: silence-gated transcription (preroll 2000ms, end-silence 1500ms)
[INFO] capture started: live-210405.ogg
[INFO] vad ready (speech>-55.0dB, floor -70.0dB)
[INFO] utterance 4.10s (voiced 1.70s, -38.4dB, silence) -> queue
[INFO] >> 21:04:05 (4.10s) Did you get my other response?
```

## Tuning by symptom

Run `./audiophile-calibrate.sh 12` first — it prints the room's noise floor and a
suggested `DTRH_SPEECH_DB` (typically `floor + 20 dB`).

| Symptom | Knob | Direction |
| --- | --- | --- |
| Sentence beginnings are clipped | `DTRH_PREROLL_MS` (2000) | up |
| One utterance split into two | `DTRH_END_SILENCE_MS` (1500) | up |
| Two sentences glued together | `DTRH_END_SILENCE_MS` | down |
| Short interjections missed | `DTRH_MIN_SPEECH_MS` (500) | down |
| Doors/keys become entries | `DTRH_MIN_VOICED_DB` (−50) | up (e.g. −45) |
| Nothing detected in a noisy room | `DTRH_SPEECH_DB` (−55) | up (e.g. −45) |
| Quiet/distant speech missed | `DTRH_SPEECH_DB` | down, or `DTRH_MIN_VOICED_DB` down |
| Journal lags behind long speech | `DTRH_ENGINE=server` | on |
| Long files in RAM/disk | `DTRH_MAX_SEGMENT_MS`, `DTRH_ROTATE_IDLE_S` | down |
| Transcription blocks responsiveness | `DTRH_ASYNC` (1) | keep on |

Examples:

```bash
DTRH_SPEECH_DB=-48 DTRH_END_SILENCE_MS=1200 ./DTRH-Audiophile.sh
DTRH_MODEL=~/whisper.cpp/models/ggml-base.en.bin DTRH_ENGINE=server ./DTRH-Audiophile.sh
DTRH_RETAIN_AUDIO=1 DTRH_RETAIN_DAYS=14 ./DTRH-Audiophile.sh
```

## Troubleshooting

| Symptom | Meaning | Fix |
| --- | --- | --- |
| Every level line reads `db=-91.0` | Android handed over silence | open Termux once; grant mic to Termux **and** Termux:API |
| Level lines move, no `utterance` lines | you are below the threshold | `audiophile-calibrate.sh`, then set `DTRH_SPEECH_DB` |
| `dropped … quiet` in the log | a sound crossed onset but was not voice-like | working as designed; raise `DTRH_MIN_VOICED_DB` if too eager |
| Entries with `(music)`/`[typing]` text | non-speech reached whisper | check `--doctor` for the Silero model |
| Nothing in the journal, log looks fine | output path missing | `termux-setup-storage`; check `DTRH_WORK` |
| `no silero model found` | gate disabled | point `DTRH_WHISPER_VAD` at a model, or set `off` to silence the warning |
| Mic stays busy after a crash | recorder left running | `termux-microphone-record -q` |
| Everything is slow after hours | model/CPU | `--doctor` reports whisper speed; consider `tiny.en` |

## Verification checklist

Run this after changing anything in the pipeline. Each line has an expected
result; if it does not match, the change is not done.

**Anywhere, no phone or microphone:**

```bash
./DTRH-Audiophile.sh --selftest        # expect: SELFTEST PASS, 2 segments
```

**On the phone:**

```bash
# 1. dependencies, permissions, mic audio, whisper speed
./DTRH-Audiophile.sh --doctor          # expect: == doctor: healthy (0 warnings) ==
                                       # mic line must NOT say digital silence

# 2. what this room sounds like
./audiophile-calibrate.sh 12           # expect: a noise floor and a suggestion

# 3. a silent minute must produce nothing
: > DTRH-Audiophile.log                # the log APPENDS across runs - truncate first
DTRH_WORK=~/tmp/verify DTRH_NOTIFY=0 DTRH_ROTATE_IDLE_S=20 \
  DTRH_ROTATE_MIN_AGE_S=15 ./DTRH-Audiophile.sh --debug &
sleep 55; ./DTRH-Audiophile.sh --stop
# expect, last line: "utterances this run: 0 (0ms of speech) - goodbye."
# expect: no "-> queue" lines and no *.md in ~/tmp/verify
# "no speech for 30s - recycling the capture file" only if the room was truly
# silent; check "speech onset" before calling rotation broken

# 4. real speech must appear verbatim
: > DTRH-Audiophile.log
DTRH_WORK=~/tmp/verify DTRH_NOTIFY=0 ./DTRH-Audiophile.sh --debug &
# say one clear sentence, wait ~10 s
# expect: one "-> queue", one ">> HH:MM:SS (Ns) <your sentence>"

# 5. offline replay, no speaking required
DTRH_WORK=~/tmp/replay ./DTRH-Audiophile.sh --replay /path/to/audio
# expect: one journal per source file under ~/tmp/replay/replay/

# 6. clean shutdown
./DTRH-Audiophile.sh --stop
# expect: pidfile gone, no audiophile-* processes, capture dir empty
```

## New phone bring-up

1. Termux + `termux-api` + `ffmpeg` + `python`; `termux-setup-storage`; grant the
   mic to Termux and Termux:API; exempt both from battery optimisation.
2. Build whisper.cpp; download `tiny.en`.
3. Clone Audiophile; `--selftest`, then `--doctor`.
4. `audiophile-calibrate.sh 20` — record the floor for that room and keep the
   suggested `DTRH_SPEECH_DB`.
5. `audiophile-model-bench.sh` — if the SoC is much faster or slower than a
   Snapdragon 845, this is what says whether a bigger model is affordable.
6. 20-minute live session with `--debug`; check utterance count, mean duration,
   and that drops are explained.

## Where things live

| Path | What |
| --- | --- |
| `~/Audiophile/DTRH-Audiophile.log` | log, append-only across runs |
| `~/Audiophile/DTRH-Audiophile.pid` | pidfile while running |
| `~/storage/shared/Obsidian/transcripts/YYYY-MM-DD.md` | the journal |
| `…/transcripts/.audiophile/index.jsonl` | audit trail |
| `$TMPDIR/audiophile/` | live capture file, queue FIFO, segment WAVs |
| `<card>/audiophile/audio/YYYY-MM-DD/` | retained utterance audio (opt-in) |
| `$TMPDIR/retranscribe/`, `$TMPDIR/model-bench/` | tool output |
