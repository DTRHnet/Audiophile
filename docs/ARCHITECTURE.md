# Architecture

How the pipeline works, why each piece is shaped the way it is, and what was
measured and rejected along the way. Raw evidence — every number and every defect
— is in [`JOURNAL.md`](JOURNAL.md).

## The problem being solved

Record speech continuously on a phone, transcribe it locally, and leave behind
markdown that is worth reading later — without draining the battery, without
filling the disk, and without inventing text that nobody said.

A fixed recording slice (30 seconds is the obvious choice, and was v2) fails all
three. It fires whisper whether or not anyone is speaking, whisper answers
silence with invented words, and it cuts sentences at the boundary. Every design
decision below follows from measuring those failures.

## Components

| File | Role |
| --- | --- |
| `DTRH-Audiophile.sh` | orchestrator: recorder lifecycle, pipeline, queue, journal, housekeeping, CLI |
| `audiophile-follow.py` | follows the growing capture file and streams its bytes to stdout |
| `audiophile-vad.py` | voice activity detection and utterance segmentation |
| `whisper-cli` / `whisper-server` | transcription (external, built from whisper.cpp) |
| `audiophile-calibrate.sh` | measures a room and suggests a threshold |
| `audiophile-pocket-calibrate.sh` | two-phase pocket measurement with a verdict |
| `audiophile-model-bench.sh` | model comparison on synthetic clips |
| `audiophile-retranscribe.sh` | model comparison on kept real audio |
| `DTRH-Session.sh` | tmux: transcriber plus live log |

## The capture path, and why it looks like this

```
termux-microphone-record -e opus -r 16000 -c 1 -f live.ogg -l 0
        │
        ▼
audiophile-follow.py "$live" 0.15      (read file, hold stdout open)
        │
        ▼
ffmpeg -f ogg -i - -vn -ac 1 -ar 16000 -f s16le -      (one process, all day)
        │
        ▼
audiophile-vad.py                       (100 ms blocks, state machine)
```

**One continuous recording, never restarted mid-sentence.** `termux-microphone-record`
returns in ~200 ms and stops in ~110 ms, so a stop/start cycle costs 0.3–0.4 s of
audio — enough to swallow a syllable every few seconds. The recorder is started
once and runs until shutdown.

**Ogg/Opus specifically.** `.m4a`, `.aac` and `.ts` all come back as MP4 on this
device and cannot be decoded until the file is finalised; `-e opus` with a
`.ogg`/`.webm` name produces Ogg/Opus, which is decodable while it is being
written. That single fact is what makes continuous capture possible at all.

**A byte follower instead of `tail -f`.** `tail -f live.ogg | ffmpeg -f ogg -i -`
fails with `Error opening input: End of file` and decodes nothing. Reading the
file in a loop, writing the new bytes to a held-open pipe, works. Doing that loop
in bash cost 21.5 % of a core in `stat`/`dd`/`sleep` forks; the same loop in a
resident python process costs nothing measurable.

**One decoder for the whole day.** Because the pipeline is a stream, there are no
seeks, no re-decodes, and segment boundaries are exact. Rotation of the capture
file (after 90 s of silence, or at the size cap) is the only time the chain is
restarted, and it happens in silence so it cannot cut a word.

## Voice activity detection

`audiophile-vad.py` reads 16 kHz mono PCM and decides where utterances begin and
end. Per 100 ms block:

```
db   = 20·log10(rms/32768)                    RMS of the block, in dBFS
floor: falls instantly, climbs 0.05 dB/block while idle, clamped [-90, -40]
thr   = max(DTRH_SPEECH_DB, floor + DTRH_MARGIN_DB)
loud  = db > thr
```

State machine:

- **idle → speech** on 2 consecutive loud blocks (200 ms). Segment start is moved
  back `DTRH_PREROLL_MS` (2 s) so the first consonant is never lost, and back far
  enough to cover decoder latency.
- **speech → idle** after `DTRH_ENDSIL_MS` (1.5 s) of continuous silence. The
  segment is cut at the last loud block plus 250 ms of tail.
- **caps**: `DTRH_MAX_SEGMENT_MS` (120 s) closes a monologue and continues in a
  new file, so nothing is unbounded.
- **rejection, before whisper is ever invoked**: fewer than
  `DTRH_MIN_SPEECH_MS` (500 ms) of voiced audio, or a voiced part whose mean level
  is below `DTRH_MIN_VOICED_DB` (−50 dB). This is what stops doors, keyboards and
  pocket handling from becoming journal entries.
- **warm-up**: the first `DTRH_WARMUP_MS` (1.5 s) after the recorder starts is
  ignored, because MediaRecorder emits a transient when it opens.

Segments are written as 16 kHz mono WAV by the VAD itself, so there is no
`.m4a → .wav` conversion step and no second decode.

The VAD emits one event per decision on stdout, as `key=value` lines:
`ready`, `level`, `begin`, `segment`, `drop`, `idle`, `end`, `error`. Bash parses
them without a JSON dependency.

## The second gate: Silero inside whisper

The energy VAD answers "is this loud?", which is not the same as "is this
speech". Music, video soundtracks and fabric rustle are loud and are not speech,
and whisper handed a non-speech clip will describe it — `(dramatic music)`,
`(beeping)` — rather than stay quiet.

`whisper-cli --vad -vm <silero> -vt 0.5` puts a semantic gate in front of the
encoder. Measured on 6 s clips:

| clip | without `--vad` | with Silero |
| --- | --- | --- |
| pink noise | `(dramatic music)` — 3307 ms | *empty* — 419 ms |
| tones | `(beeping)` — 3570 ms | *empty* — 463 ms |
| real speech | correct sentence — 3839 ms | same sentence — 4008 ms |

It removes junk at the source *and* makes non-speech ~8× cheaper. If no Silero
model is present the pipeline warns once and continues without the gate rather
than failing.

## Transcription queue and engines

Transcription runs behind a queue so the listener never blocks:

```
event loop (main shell)  ── writes one line per utterance ──►  FIFO
                                                                 │
                                        worker (single, serial) ◄┘
                                                                 │
                                                    whisper → journal → audit
```

A single worker preserves journal order with no locking, and level handling,
rotation and notifications stay responsive while whisper works. Replay mode
forces this off, because there each source file needs a complete journal before
the next one starts.

Two engines: `cli` (a fresh `whisper-cli` per utterance, model loaded each time)
and `server` (`whisper-server` resident on loopback, model loaded once). The
resident model saves ~390 ms per utterance and stays opt-in: it buys a tenth of a
call for a process, a port and a lifecycle.

## Housekeeping

- **Rotation**: the capture file is recycled after 90 s of silence (never during
  speech) or when the size cap is hit. The size cap is also checked from the level
  event, because a noisy room never reports idle and would otherwise grow the file
  without bound.
- **Retained audio**: off by default. When on, each utterance WAV is moved to
  `<card>/audiophile/audio/YYYY-MM-DD/` instead of deleted, with a free-space
  guard that switches archiving off rather than fill the volume.
- **Batching**: utterances are transcribed individually; a long monologue becomes
  several segments rather than one enormous prompt.

## Failure behaviour

The design preference is *degrade visibly, never silently*:

| Failure | Behaviour |
| --- | --- |
| Microphone returns digital silence | loud warning naming the cause (open Termux once, grant permission) |
| Decoder/pipeline dies | capture file is recycled and the chain restarted, so audio cannot be transcribed twice |
| Queue worker dies | witnesses write a warning and transcribe inline — nothing is lost |
| Silero model missing | warning once, pipeline continues without the second gate |
| Retained-audio volume full | archiving disables itself, transcription continues |
| No speech for a long time | capture file recycled; nothing accumulates |
| `--stop` or Ctrl+C | recorder released, worker drained, temp audio removed, pidfile removed |

## Rejected designs, and the measurement that rejected them

| Design | Why not |
| --- | --- |
| Fixed 30 s slices (v2) | whisper on silence 120×/hour, invented text, words cut at boundaries |
| Restart the recorder per chunk | 0.3–0.4 s of audio lost per restart |
| Poll the live file with `ffmpeg -sseof` per second | 200–260 ms per poll, ~20 % of a core, forever |
| `tail -f` into ffmpeg | ffmpeg dies with `End of file`, decodes nothing |
| `.m4a`/`.aac`/`.ts` capture | MP4 containers, unreadable until finalised |
| Bash feeder with `stat`/`dd` | 21.5 % of one core in fork overhead |
| `base.en` as default | 2× the compute, no accuracy difference the benchmarks can resolve on this audio path |
| `base.en-q5_1` | no accuracy gain and 1.06× realtime — cannot keep up with continuous speech |
| Models on the SD card | ~12.4 s load from exFAT vs ~6.8 s from internal |
| Throwing away audio by default | *kept as an option* — retention exists precisely so model choices can be re-tested on real speech |

## Data formats

Journal block:

```markdown
## HH:MM:SS (N.NNs)

text

---
```

Audit line (`transcripts/.audiophile/index.jsonl`):

```json
{"ts":"ISO8601","file":"seg_YYYYMMDD_HHMMSS_NNN.wav","at":"HH:MM:SS","dur":4.10,
 "db":-38.4,"peak":-21.0,"audio":null,"text":"…"}
```

`db` is the mean level of the voiced blocks, `peak` the loudest sample seen;
`audio` is the retained WAV path when retention is on. Together these are what
`docs/EXPORTS.md` builds every export and digest on.
