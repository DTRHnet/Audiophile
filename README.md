# Audiophile

![](audiophile.png)

---

![](audiophile2.png)

---

## A Continuous Audio Transcription Pipeline


## 1. Summary

This project turns an Android phone into a continuous, hands-free voice
journal. It listens through Termux, decides for itself when an utterance
starts and ends, transcribes each utterance with OpenAI's Whisper model via
whisper.cpp, and appends the text to a daily markdown file that Obsidian can
open.

Since v3 the pipeline is **silence gated**: nothing is sent to whisper while
the room is quiet. One continuous audio stream is decoded all the time, so an
utterance is captured whole — it is never cut at a fixed 30-second boundary —
and it is handed to whisper the moment the speaker stops.

## 2. How It Works

```
termux-microphone-record  ──►  one continuous Ogg/Opus stream (live.ogg)
                                        │  grows in place, readable while written
                                        ▼
                              audiophile-follow.py + ffmpeg (one long-lived decoder)
                                        │  16 kHz mono PCM
                                        ▼
                              audiophile-vad.py
                                 · per-100 ms RMS levels
                                 · tracks the room noise floor
                                 · onset → utterance start (with 2 s pre-roll)
                                 · 1.5 s of silence → utterance end
                                        │  one 16 kHz WAV per utterance
                                        ▼
                              whisper-cli (tiny.en) + Silero VAD
                                        │
                                        ▼
                          ~/storage/shared/Obsidian/transcripts/YYYY-MM-DD.md
```

Why it is built this way:

* **No fixed slices.** `termux-microphone-record` with a duration limit returns
  immediately and a stop/start cycle loses ~0.3–0.4 s of audio, which cuts
  words in half. v3 starts the recorder once and never restarts it
  mid-sentence.
* **Silence is free.** Whisper fed silence invents text ("you",
  "Thank you.") — v2 did exactly that every 30 seconds. In v3 whisper is
  started only for utterances that contain speech, on audio that begins
  `PREROLL_MS` before the first word and ends 250 ms after the last one.
* **Cheap when idle.** A silent room costs a decode of 32 kB/s of Opus and a
  VAD that does arithmetic on it — measured at 7.8 % of one core on the LG G7
  (ffmpeg ~4.3 %, VAD ~3.1 %), against ~40 % for v2's whisper-every-30 s.
* **Streamable container.** `.m4a`/`.aac`/`.ts` recordings are MP4 files that
  cannot be read until they are finalised. `-e opus` with a `.ogg`/`.webm`
  name produces Ogg/Opus, which can be decoded while it is being written.

The capture file is recycled after 90 s of continuous silence (the gap lands
in silence, so it cannot cut a word), which keeps disk use flat.

## 3. Prerequisites

### Termux Setup

1. **Install Termux**: Download from [F-Droid](https://f-droid.org/en/packages/com.termux/).
2. **Update Packages**:
   ```bash
   pkg update && pkg upgrade
   ```
3. **Install Dependencies**:
   ```bash
   pkg install termux-api ffmpeg git cmake clang wget python
   ```
4. **Grant Microphone Permission**:
   ```bash
   termux-microphone-record -d -f /dev/null
   ```
   Accept the permission prompt when it appears. Open the Termux app itself at
   least once: Android 10 hands **silent audio** (all-zero samples) to capture
   that is started while the app is not running.

### Whisper.cpp Installation

1. **Clone Repository**:
   ```bash
   git clone https://github.com/ggerganov/whisper.cpp.git
   cd whisper.cpp
   ```

2. **Build**:
   ```bash
   cmake -B build
   cmake --build build --config Release
   ```

3. **Download a Model**:
   ```bash
   make -j tiny.en.bin     # default: fastest, 4.1s per utterance (measured)
   # or
   wget -c https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin \
        -P models/
   ```

## 4. Usage

```bash
termux-setup-storage                        # once, links Termux to Android storage
mkdir -p ~/storage/shared/Obsidian/transcripts
cd ~/Audiophile
chmod +x DTRH-Audiophile.sh audiophile-vad.py audiophile-follow.py audiophile-calibrate.sh
./DTRH-Audiophile.sh
```

Press `Ctrl+C` to stop. The daily journal is
`~/storage/shared/Obsidian/transcripts/YYYY-MM-DD.md`; each utterance is
appended with the wall-clock time it started and its duration:

```markdown
## 16:48:17 (4.60s)

The quick brown fox jumps over the lazy dog.

---
```

### Options

| Flag | Meaning |
| --- | --- |
| *(none)* | run the transcriber |
| `--tail` | follow the log file |
| `--status` | is an instance running? |
| `--stop` | stop the running instance |
| `--selftest` | run the VAD over a synthetic track (2 utterances expected) — works without a microphone |
| `--replay PATH` | run the real pipeline over a file or directory of audio — no microphone, no waiting for someone to talk |
| `--doctor` | check every dependency, permission, level and speed, then exit |
| `--debug` | verbose logging, including every VAD level decision |
| `--no-notify` | do not touch the notification shade |
| `--work DIR` | write transcripts somewhere else |
| `--model FILE` | use a different ggml model |

`audiophile-pocket-calibrate.sh --analyse QUIET.wav TALKING.wav` re-analyses two
existing recordings instead of recording again.

### Tuning it to your room

```bash
./audiophile-calibrate.sh 20      # stay quiet for half of it, then talk
```

It prints the dBFS distribution of 100 ms blocks and a suggested threshold. A
typical quiet room sits at −70…−80 dB and close speech at −30…−45 dB, so the
default `DTRH_SPEECH_DB=-55` has ~15 dB of headroom on each side. If the phone
is in a pocket or a noisy café, raise it (e.g. `-45`).

Everything is overridable from the environment, no editing required:

| Variable | Default | Meaning |
| --- | --- | --- |
| `DTRH_SPEECH_DB` | `-55` | a block louder than this is speech |
| `DTRH_MARGIN_DB` | `10` | or this far above the measured noise floor |
| `DTRH_PREROLL_MS` | `2000` | audio kept before the first word |
| `DTRH_END_SILENCE_MS` | `1500` | silence that closes an utterance |
| `DTRH_MIN_SPEECH_MS` | `500` | shorter blips are discarded |
| `DTRH_MIN_VOICED_DB` | `-50` | mean level of the voiced part must beat this |
| `DTRH_WARMUP_MS` | `1500` | ignore the recorder's own start transient |
| `DTRH_MAX_SEGMENT_MS` | `120000` | split a long monologue |
| `DTRH_ROTATE_IDLE_S` | `90` | recycle the capture file after this much silence |
| `DTRH_ROTATE_MAX_MB` | `64` | hard size cap; enforced even in a noisy room |
| `DTRH_THREADS` | `4` | whisper threads |
| `DTRH_WHISPER_VAD` | `auto` | whisper's Silero VAD: `auto`, `off`, or a model path |
| `DTRH_WHISPER_VAD_THRESHOLD` | `0.5` | Silero speech probability threshold |
| `DTRH_ASYNC` | `1` | transcribe in a worker so the listener never blocks |
| `DTRH_RETAIN_AUDIO` | `0` | `1` keeps each utterance's WAV instead of deleting it |
| `DTRH_AUDIO_DIR` | *(auto)* | where kept audio goes; empty = first writable SD card |
| `DTRH_RETAIN_DAYS` | `0` | prune kept audio older than N days (0 = keep forever) |
| `DTRH_RETAIN_MIN_FREE_MB` | `500` | stop keeping audio if the volume gets this full |
| `DTRH_ENGINE` | `cli` | `cli`, or `server` to keep the model resident |
| `DTRH_SERVER_PORT` | `8087` | loopback port for `DTRH_ENGINE=server` |
| `DTRH_WORK` | `~/storage/shared/Obsidian/transcripts` | output directory |
| `DTRH_MODEL` | `~/whisper.cpp/models/ggml-tiny.en.bin` | model |
| `DTRH_NOTIFY` | `1` | live notification |
| `LOG_LEVEL` | `INFO` | `DEBUG` for level-by-level tracing |

Example: a snappier configuration for a meeting room.

```bash
DTRH_SPEECH_DB=-50 DTRH_END_SILENCE_MS=900 ./DTRH-Audiophile.sh --debug
```

### Calibrating for a pocket

A phone in a pocket is a different room: fabric removes the high frequencies,
your body adds low-frequency rumble, and cloth rustle adds bursts. Measure it
instead of guessing:

```bash
cd ~/Audiophile
./audiophile-pocket-calibrate.sh          # 12s quiet + 14s talking
```

Put the phone in the pocket you actually use, leave it there, and follow the
buzzes: **one buzz = keep quiet**, **two buzzes = talk normally** (say the
sentence printed on screen), **three buzzes = done**. Nothing is played through
the speaker, because that would land in the recording.

It reports the pocket's noise distribution, the level of your muffled speech,
the separation between them, how much of your speech would clear the threshold,
a verdict, and a ready-to-paste line:

```
pocket noise : p50 -54.6  p90 -53.1  p95 -52.4  p99 -52.2  max -52.2 dB
pocket speech: p50 -63.2  p90 -40.0  p95 -36.4            max -32.9 dB
separation   : 12.4 dB  (speech p90 minus noise p95)
VERDICT: WORKABLE - usable; expect occasional missed or trimmed utterances
SHELL: DTRH_SPEECH_DB=-47 DTRH_MIN_VOICED_DB=-50 DTRH_PREROLL_MS=2500 DTRH_END_SILENCE_MS=1200
```

Verdicts: **COMFORTABLE** (≥20 dB), **WORKABLE** (≥12), **MARGINAL** (≥6),
**UNUSABLE** (<6 — the level detector cannot separate speech from that pocket,
and the report says so instead of pretending). The last step also runs whisper
on your talking phase, so you find out whether the muffled audio is *readable*
as well as *detectable*.

```bash
DTRH_SPEECH_DB=-47 DTRH_MIN_VOICED_DB=-50 ./DTRH-Audiophile.sh
```

### Replaying recorded audio (no microphone)

The same detector, the same whisper, the same journal — driven from a file
instead of the microphone. This is how to tune thresholds or compare models
without performing for the phone:

```bash
./DTRH-Audiophile.sh --replay ~/storage/shared/Obsidian/transcripts/.audiophile/audio/2026-11-12
./DTRH-Audiophile.sh --replay recording.wav
DTRH_MODEL=~/whisper.cpp/models/ggml-base.en.bin ./DTRH-Audiophile.sh --replay clip.wav
```

Each source file gets its own journal under `<work>/replay/<name>.md`, so a
replay never touches your real daily notes. Replay transcribes inline (async is
switched off) so each file's journal is complete when it is written.

### Checking the install

```bash
./DTRH-Audiophile.sh --doctor
```

```
  [ OK ] ffmpeg present            [ OK ] model: ggml-tiny.en.bin (74MB)
  [ OK ] silero vad: ...           [ OK ] transcript dir writable
  [ OK ] microphone delivers audio (peak -41.4)
  [ OK ] whisper ran a 3s tone in 2877ms (0.96x realtime)
== doctor: healthy (0 warning(s)) ==
```

It records three seconds and reports the peak level, so a silenced microphone
(Android handing over zeros) is caught here rather than mid-journal.

### Keeping the audio (SD card)

By default each utterance's WAV is deleted once it is transcribed. Keep them
instead, and you can re-transcribe real speech with a better model later:

```bash
DTRH_RETAIN_AUDIO=1 ./DTRH-Audiophile.sh
```

Audio lands under `<SD card>/audiophile/audio/YYYY-MM-DD/`, one WAV per
utterance, and the audit trail records the path. The card is auto-detected;
override with `DTRH_AUDIO_DIR`. Keeping stops automatically below
`DTRH_RETAIN_MIN_FREE_MB`, and `DTRH_RETAIN_DAYS=14` prunes old days.

Then compare models on **your** voice rather than on synthetic clips:

```bash
./audiophile-retranscribe.sh -n 20        # newest 20 utterances, all models found
./audiophile-retranscribe.sh -n 50 -m ~/whisper.cpp/models/ggml-base.en.bin
```

It prints one row per utterance with each model's latency and word count, then
a per-model summary (mean latency, realtime factor) and a side-by-side report
written to `$TMPDIR/retranscribe/compare_*.md`.

Storage guidance: keep the **active model on internal storage** (loading from
exFAT measured ~12.4 s against ~6.8 s internal), and use the card for kept audio
and archives. The live capture file does not belong on the card - it is written
to continuously and deleted seconds later.

### Checking that it works

```bash
./DTRH-Audiophile.sh --selftest
```

This synthesises a track with two tones separated by silence and asserts that
exactly two utterances come out of the VAD. It exercises the whole state
machine without needing speech or a microphone.

### Installing and updating on the phone

The phone copy is a normal git clone, so updating is a pull:

```bash
cd ~/Audiophile
git pull
chmod +x *.sh *.py
./DTRH-Audiophile.sh --selftest
```

`DTRH-Session.sh` starts the transcriber with a live log pane beside it in tmux
(detach with `Ctrl+b d`, kill the whole thing with `Ctrl+C` in the left pane):

```bash
./DTRH-Session.sh
```

A failed change is worth catching before it costs you a day of audio; the
commands that prove the pipeline still works are listed in
`docs/JOURNAL.md` §9 "Verification checklist".

## 5. Advanced

### 5a. Termux-API + Termux-Tasker + Tasker Integration

1. **Install Termux:Tasker**: Available on [F-Droid](https://f-droid.org/en/packages/com.termux.tasker/).
2. **Create Tasker Profile**:
   - **Trigger**: Define your desired trigger (e.g., specific time, event).
   - **Action**: Add a Termux action to execute `DTRH-Audiophile.sh`.
3. **Configure Termux:Tasker**:
   - Place `DTRH-Audiophile.sh`, `audiophile-vad.py`, `audiophile-follow.py`
     and `audiophile-calibrate.sh` in `~/.termux/tasker/`.
   - Ensure they are executable:
     ```bash
     chmod +x ~/.termux/tasker/DTRH-Audiophile.sh \
              ~/.termux/tasker/audiophile-vad.py \
              ~/.termux/tasker/audiophile-follow.py
     ```

### 5b. Obsidian Integration

1. **Set Vault Location**: Point your Obsidian vault to `~/storage/shared/Obsidian/`.
2. **Access Transcripts**: Transcriptions are saved in the `transcripts`
   folder as daily markdown files (`YYYY-MM-DD.md`).
3. **Organize Notes**: Utilize Obsidian's features to link, tag, and organize
   your notes. A per-utterance audit trail is kept in
   `transcripts/.audiophile/index.jsonl` (time, duration, level, peak, text) —
   Obsidian ignores dot-directories.

### 5c. Syncthing for Cross-Device Sync

1. **Install Syncthing**:
   - **Android**: Available on [F-Droid](https://f-droid.org/en/packages/com.nutomic.syncthingandroid/).
   - **Desktop**: Available from [Syncthing.net](https://syncthing.net/).
2. **Configure Syncthing**:
   - **Add Folder**: Set the Obsidian vault (`~/storage/shared/Obsidian/`) as a shared folder.
   - **Connect Devices**: Use Syncthing's device ID system to link your device to your desktop.
3. **Sync**: Syncthing will automatically synchronize the folder, ensuring transcriptions are available everywhere.

**Note**: Ensure Syncthing is running on all devices for seamless synchronization.

## 6. Troubleshooting

* **Nothing is transcribed.** Run `./DTRH-Audiophile.sh --debug` and watch the
  `level` lines. If every line reads `db=-91.0`, the microphone is handing the
  process digital silence: open the Termux app once and make sure the
  microphone permission is granted for Termux *and* Termux:API. The script
  warns about this explicitly at startup.
* **Speech is cut at the start.** Increase `DTRH_PREROLL_MS` (default 2000).
* **One utterance is split into two.** Increase `DTRH_END_SILENCE_MS`
  (default 1500) — a slow speaker with long pauses needs more.
* **Two sentences are glued together.** Decrease `DTRH_END_SILENCE_MS`.
* **Nothing is ever detected in a noisy room.** Raise `DTRH_SPEECH_DB`
  (e.g. `-45`) or run `./audiophile-calibrate.sh`.
* **Some utterances leave no entry in the journal.** Run with `--debug` and
  look for `dropped whisper artefact (non-speech annotation): "(music)"` or
  `dropped 3.2s of audio: quiet`. Whisper describes non-speech with bracketed
  annotations and they are dropped on purpose; `quiet` means the segment never
  got above `DTRH_MIN_VOICED_DB`.
* **Whisper ran but nothing was written.** Same thing — the audio was music,
  a video or a door, not a voice. Raise or lower `DTRH_MIN_VOICED_DB` to taste.
* **`no silero model found` at startup.** whisper then runs without its second
  gate, so noise can still be described as `(music)`. Point `DTRH_WHISPER_VAD`
  at a Silero ggml model, or set `DTRH_WHISPER_VAD=off` to silence the warning.
* **The capture file keeps growing.** It is recycled after 90 s of silence, and
  hard-capped by `DTRH_ROTATE_MAX_MB` even when the room is never quiet (a
  noisy room never reports idle). Lower the cap if disk is tight. Larger
  models make fewer mistakes: `DTRH_MODEL=~/whisper.cpp/models/ggml-base.en.bin`.
* **It stops overnight.** Make sure the Termux wake lock is held
  (`termux-wake-lock`, done by the script) and disable battery optimisation for
  Termux and Termux:API in Android settings.
* **`--stop` says "not running" but the mic is still busy.**
  `termux-microphone-record -q` clears a stuck recorder.

### Which model?

`tiny.en` is the default and the measured winner for this use: over six spoken
sentences it scored 9.5 % word error at 4.1 s per utterance, while `base.en`
scored 6.3 % at 8.3 s — twice the time, slower than realtime on this phone, for
one sentence corrected out of six. Use `base.en` only if accuracy matters more
than latency:

```bash
wget -c https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin \
     -P ~/whisper.cpp/models/
DTRH_MODEL=~/whisper.cpp/models/ggml-base.en.bin ./DTRH-Audiophile.sh
```

Models are large (141 MB for `base.en`, 74 MB for `tiny.en`); watch free space
on `/data`, and see `docs/ROADMAP.md` for moving them to an SD card.

## 7. Design notes

* [`CHANGELOG.md`](CHANGELOG.md) — what changed in each version, and why.
* [`docs/ROADMAP.md`](docs/ROADMAP.md) — direction, what is queued next, and
  what is deliberately not being done.
* [`docs/JOURNAL.md`](docs/JOURNAL.md) — the measurements behind every decision (recorder
timing, container streamability, dB levels, whisper latency, idle CPU), the
approaches that were measured and rejected, the defects found during bring-up,
the honest limits of the current design, and a §9 verification checklist to
re-run after any change.

## 8. License

This project is licensed under the MIT License.
