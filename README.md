# Audiophile

**A voice journal that runs on your phone, offline, and writes markdown you can
actually read later.**

Audiophile listens continuously through Termux, works out for itself when an
utterance starts and ends, transcribes each one locally with Whisper, and
appends it — timestamped — to a daily markdown file in your Obsidian vault.
Nothing leaves the device. No subscription, no API key, no cloud.

> Built and measured on an LG G7 (Snapdragon 845, Android 10) running Termux
> from F-Droid. No root.

---

## Where this is at

Decisive status, split by what has actually been verified.

### Works, verified on hardware

| Capability | Evidence |
| --- | --- |
| Continuous listening with silence gating | 20-minute live session: **60 utterances, 934 words, 616 s of speech**, zero dropped, zero junk entries |
| Utterances bounded correctly | mean 10.3 s, longest 48.6 s — not chopped at pauses, not glued across them |
| Latency from last word to journal | ~6 s typical (1.5–2 s of end-silence detection + 4–5 s transcription) |
| Battery-light when idle | **5.7 % of one core** in a quiet room, 7.8 % with a video playing (ffmpeg 4.3 %, VAD 3.1 %) |
| Non-speech rejected before whisper | silence/noise/music → *no whisper call at all*; Silero rejection costs 0.4 s instead of 3.5 s of invented text |
| Screen off, phone idle | capture verified with the screen off and the app backgrounded |
| Clean lifecycle | `--status`, `--stop`, PID lock, wakelock, notification, capture-file recycling, no stray processes |
| Self-check and offline testing | `--doctor` reports healthy; `--selftest` and `--replay` need no microphone |

### Experimental or opt-in

| Thing | State |
| --- | --- |
| `whisper-server` resident model | Works, ~390 ms/utterance faster. Opt-in (`DTRH_ENGINE=server`) because it adds a process and a port to save a tenth of a call |
| Retained audio + model comparison | Works (`DTRH_RETAIN_AUDIO=1`, `audiophile-retranscribe.sh`) |
| Pocket calibration | Works, and honestly reports `UNUSABLE` — see below |
| Night-long / Doze operation | **Not verified.** A 20-minute session and a 30-second screen-off test are all the evidence there is |

### Does not work, and won't be pretended otherwise

| Thing | Why |
| --- | --- |
| Recording speech **inside a pocket** | Measured four times: the audio had energy (−32 dB) but **no words at all**, even with Silero disabled and at threshold 0.15. That is fabric masking the microphone port, not a tuning problem. `audiophile-pocket-calibrate.sh` reports it instead of guessing |
| Accurate speaker attribution | No diarisation. One voice, one journal; two people sound like one |
| Shipping as a general multi-language tool | English-only models by default; other languages work technically but are unmeasured |
| Screen-off capture overnight | Wakelock and foreground notification are in place, but a full night through Doze has not been run |

---

## How it works

```
termux-microphone-record  ──►  one continuous Ogg/Opus stream (live.ogg)
                                        │  readable while being written
                                        ▼
                              audiophile-follow.py  ──►  ffmpeg  (one decoder, all day)
                                        │  16 kHz mono PCM
                                        ▼
                              audiophile-vad.py
                                 · 100 ms RMS levels, tracks the room's noise floor
                                 · onset → utterance start, 2 s of pre-roll
                                 · 1.5 s of silence → utterance end
                                 · rejects blips and audio that is not loud enough
                                        │  one 16 kHz WAV per utterance
                                        ▼
                              whisper-cli  (+ Silero VAD as a second gate)
                                        │
                                        ▼
                     ~/storage/shared/Obsidian/transcripts/YYYY-MM-DD.md
```

Three design rules, each one earned by measurement rather than assumed:

1. **Silence is free.** No transcription, no disk, no invented text while the
   room is quiet. A fixed 30-second slice — how this started — burns a whisper
   pass every 30 s whether or not anyone is speaking, and whisper answers
   silence with invented words like *"Thank you."*
2. **Drop, never invent.** A doubtful segment is discarded and logged, not
   guessed at. Precision over recall.
3. **Never cut a word.** The recorder starts once and is never restarted
   mid-sentence; the capture file is only recycled after 90 s of silence.

---

## Quick start

```bash
# 1. Termux (from F-Droid), then:
pkg update && pkg install termux-api ffmpeg python git cmake clang wget

# 2. whisper.cpp
git clone https://github.com/ggerganov/whisper.cpp.git ~/whisper.cpp
cd ~/whisper.cpp && cmake -B build && cmake --build build --config Release
bash ./models/download-ggml-model.sh tiny.en

# 3. Audiophile
git clone https://github.com/DTRHnet/Audiophile.git ~/Audiophile
cd ~/Audiophile && chmod +x *.sh *.py

# 4. Storage link + output folder
termux-setup-storage
mkdir -p ~/storage/shared/Obsidian/transcripts

# 5. Prove it before trusting it
./DTRH-Audiophile.sh --selftest     # VAD logic, no microphone required
./DTRH-Audiophile.sh --doctor       # every dependency, permission and level
```

Then start it:

```bash
./DTRH-Audiophile.sh
```

Talk. Within a few seconds of you stopping, an entry appears in
`~/storage/shared/Obsidian/transcripts/YYYY-MM-DD.md`. `Ctrl+C` stops it cleanly;
`./DTRH-Audiophile.sh --stop` stops it from another shell.

> **One-time gotcha:** open the Termux app itself at least once. Android 10 hands
> *silent buffers* to a recorder started while the app is not running, and the
> journal stays empty with no error. `--doctor` catches exactly this.

For a session you intend to leave running, start it under tmux instead:

```bash
./DTRH-Session.sh      # transcriber on the left, live log on the right
```

---

## What it writes

Journal — append-only, one file per day:

```markdown
## 21:04:05 (4.10s)

Did you get my other response?

---
```

Audit trail, one JSON object per utterance (`.audiophile/index.jsonl`), for when
you want to know *why* something did or did not appear:

```json
{"ts":"2026-11-12T21:04:09-05:00","file":"seg_20261112_210405_001.wav","at":"21:04:05",
 "dur":4.10,"db":-38.4,"peak":-21.0,"audio":null,"text":"Did you get my other response?"}
```

Utterance audio is deleted once transcribed, unless you turn on retention
(`DTRH_RETAIN_AUDIO=1`), which keeps one WAV per utterance on the SD card.

---

## Tools that ship with it

| Command | What it is for |
| --- | --- |
| `./DTRH-Audiophile.sh` | the transcriber |
| `--doctor` | binaries, model, permissions, disk, **whether the mic actually delivers audio**, whisper speed |
| `--replay PATH` | runs the real pipeline over a file or folder — tune and test with nobody talking |
| `--selftest` | asserts the VAD state machine on a synthetic track |
| `--status` / `--stop` / `--tail` | instance control and live log |
| `--debug` | every VAD decision, for tuning |
| `audiophile-calibrate.sh` | measures the room and suggests a threshold |
| `audiophile-model-bench.sh` | WER, latency and realtime factor for every model you have |
| `audiophile-retranscribe.sh` | re-runs models over audio you kept, side by side |
| `audiophile-pocket-calibrate.sh` | two-phase pocket measurement with an honest verdict |
| `DTRH-Session.sh` | transcriber + live log side by side in tmux |

---

## Configuration

Everything is environment-overridable; nothing needs editing.

| Variable | Default | Meaning |
| --- | --- | --- |
| `DTRH_WORK` | `~/storage/shared/Obsidian/transcripts` | where journals are written |
| `DTRH_MODEL` | `.../ggml-tiny.en.bin` | whisper model |
| `DTRH_SPEECH_DB` | `-55` | a 100 ms block louder than this is speech |
| `DTRH_MARGIN_DB` | `10` | …or this far above the measured noise floor |
| `DTRH_PREROLL_MS` | `2000` | audio kept before the first word |
| `DTRH_END_SILENCE_MS` | `1500` | silence that closes an utterance |
| `DTRH_MIN_SPEECH_MS` | `500` | blips shorter than this are discarded |
| `DTRH_MIN_VOICED_DB` | `-50` | mean level the voiced part must reach |
| `DTRH_MAX_SEGMENT_MS` | `120000` | split a long monologue |
| `DTRH_RETAIN_AUDIO` | `0` | `1` keeps each utterance's WAV (SD card friendly) |
| `DTRH_AUDIO_DIR` | *(auto)* | where kept audio goes |
| `DTRH_RETAIN_DAYS` | `0` | prune kept audio after N days (0 = keep) |
| `DTRH_ASYNC` | `1` | transcribe in a worker so listening never blocks |
| `DTRH_ENGINE` | `cli` | `server` keeps the model resident on loopback |
| `DTRH_WHISPER_VAD` | `auto` | Silero second gate: `auto`, `off`, or a model path |
| `DTRH_NOTIFY` / `LOG_LEVEL` | `1` / `INFO` | notification, and `DEBUG` for tracing |

Symptom-driven tuning lives in [`docs/OPERATIONS.md`](docs/OPERATIONS.md).

---

## Measured facts

Numbers, not claims. The method and the raw runs are in
[`docs/JOURNAL.md`](docs/JOURNAL.md).

| Measurement | Result |
| --- | --- |
| Idle CPU, quiet room | 5.7 % of one core |
| Idle CPU, video playing | 7.8 % of one core |
| `tiny.en` speed | 0.37–0.39× realtime |
| `base.en` speed | 0.74–0.79× realtime |
| Model accuracy on identical audio | `tiny.en` 18.2 % WER vs `base.en` 18.2 % WER in the second run (14.5 % in the first) — the TTS audio path dominates the error, so **`tiny.en` stays default** |
| Capture size | Opus 32 kbps ≈ 4 KB/s ≈ 14 MB/hour |
| Silero value | non-speech: empty result in 0.42–0.46 s vs 3.3–3.6 s of invented text |

---

## What this is for next

The journal is the raw material. Time-ranged summaries, analyses, and delivery
to Obsidian / email / local files / raw audio are designed in
[`docs/EXPORTS.md`](docs/EXPORTS.md) — the plan, the privacy tiers, and the build
order. Near-term engineering work is in [`docs/ROADMAP.md`](docs/ROADMAP.md).

---

## Documentation

| Document | Contents |
| --- | --- |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | how the pipeline works, why each part exists, what was rejected and why |
| [`docs/OPERATIONS.md`](docs/OPERATIONS.md) | install, daily workflow, tuning by symptom, verification checklist, new-device bring-up |
| [`docs/EXPORTS.md`](docs/EXPORTS.md) | using the transcripts: time ranges, digests, summaries, delivery targets |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | what is next, and what is deliberately not planned |
| [`docs/JOURNAL.md`](docs/JOURNAL.md) | the engineering log: every measurement and every defect found |
| [`CHANGELOG.md`](CHANGELOG.md) | version history |

---

## Limits worth knowing before you rely on it

- **A room is not a speaker.** A video playing nearby is transcribed with the
  same confidence as a person talking.
- **No speaker labels.** Two people in the room produce one continuous voice.
- **English, small model.** `tiny.en` mis-hears rare words ("audiophile" →
  "audio file"); a bigger model fixes some of it for twice the latency.
- **The journal is plaintext** in shared storage. Anything with storage access
  can read it.

## License

MIT — see [LICENSE](LICENSE). Original concept and v2 by KBS / DTRH.net.
