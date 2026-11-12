# Engineering journal — Audiophile v3 "silence gating"

Date: 2026-11-12
Target device: LG G7 ThinQ (`LM-G710`, `judyln`), Android 10, Termux (F-Droid),
`com.termux` uid 10344, `com.termux.api` installed, whisper.cpp built in
`~/whisper.cpp` (`ggml-tiny.en.bin` only), ffmpeg 9.0.2.
Method: USB → `adb`, `run-as com.termux` shell, all runs on the device itself.

The brief: the fixed 30-second slice is not ideal. Catch silence, stop, and
start again when something is heard. Record what was done.

---

## 1. What v2 actually did, and what it cost

`DTRH-Audiophile.sh` v2 loop:

```
termux-microphone-record -f segment.m4a -l 0 &   # start
sleep 30                                          # fixed slice
termux-microphone-record -q                       # stop
transcribe &                                      # ffmpeg m4a->wav, whisper, append
```

Measured consequences on this device:

| Observation | Evidence |
| --- | --- |
| Every 30 s of room silence still costs a full `ffmpeg` convert **plus** a whisper pass | v2 loop, `DTRH-Audiophile.log` |
| Whisper fed digital silence invents text | a 8 s silent clip transcribed as `you`; a 5 s silent clip also `you` |
| The slice boundary is invisible to the transcriber, so words straddling `:00`/`:30` are cut mid-syllable | by design, `sleep 30` |
| Nothing is transcribed until 30 s has elapsed, then whisper adds more | 30 s + transcription latency |

So the "30 second situation" is not just a latency problem: it fires whisper
on silence (which is why the journal fills with invented words), and it
truncates speech at arbitrary boundaries.

## 2. Facts established before designing anything

Everything below was measured on the device, not assumed.

**Recorder semantics** (`termux-microphone-record`):

* `-l N` does **not** block for N seconds. `termux-microphone-record -l 3 -f c.m4a`
  returns after 130–336 ms and recording continues in `com.termux.api`.
  A loop of five such calls produced exactly one real file (3.6 KB) and four
  empty ones — the later calls are silently no-ops.
* Start returns in ~256–288 ms, `-q` returns in ~109–120 ms. A 3 s sleep
  captured 3.072 s of audio, so a stop→start cycle costs ~0.3–0.4 s of lost
  audio. **Per-chunk restarting would therefore shred continuous speech**
  (~10 % loss at 3 s slices, more at 1–2 s slices).
* One continuous stream is priced correctly: `-l 0` reports
  `Max Duration: unlimited`.

**Which container can be read while it is still being written:**

| Requested file | Actual container | Readable while recording? |
| --- | --- | --- |
| `-e aac`, `x.aac` | MP4 (`ftypmp42`) | **No** — `ffmpeg` fails until `-q` finalises the file |
| `-e aac`, `x.ts` | MP4 (`ftypmp42`) | **No** |
| `-e opus`, `x.webm` | **Ogg/Opus** (`OggS`) | **Yes** |
| `-e opus`, `x.ogg` | **Ogg/Opus** (`OggS`) | **Yes** |

`ffmpeg -devices` on Termux lists only `lavfi` and `x11grab` — there is no
`opensles`/`android` audio input, so `termux-microphone-record` is the only
capture path available.

**Levels of a real room (0.1 s blocks, dBFS RMS):**

* silence / room noise: **−70 to −80 dB** mean, peaks −47 to −63 dB
* close speech (TTS playback): **−32 to −47 dB** mean, peaks −14 to −24 dB

So a single absolute threshold of about −55 dB sits ~15 dB above the noise
floor and ~10 dB below speech. An adaptive floor is still tracked, because a
phone in a pocket or a café has a different floor.

**Whisper (tiny.en, 4 threads) latency:** 4.1 s for a 10 s clip, 3.2 s for a
7 s clip, ~4 s for a 4.6 s clip — short clips are dominated by the ~1 s model
load, because `whisper-cli` is a new process per utterance.

**Microphone silence trap (worth knowing):** with **no Termux process alive**,
recordings made through `run-as` were *exact digital zeros* (−91.0 dB) even
while TTS was audibly speaking. `dumpsys audio` still showed
`rec start … src:MIC` and appops `RECORD_AUDIO: allow`, and the input thread
was running at 8 kHz — only the samples were silent. After
`am start -n com.termux/.HomeActivity` the same recordings captured real audio
(−63.6 dB mean foreground, −62.6 dB background). This is the Android 10
"background app gets silence" behaviour, and it is why the script now warns
loudly when it sees `-91.0` dB from the microphone.

## 3. Approaches that were tested and rejected

1. **Short fixed chunks + restart** (the literal reading of "stop recording in
   silence"): rejected on measurement — 0.3–0.4 s of audio lost per restart,
   plus `-l N` not blocking makes the loop fragile.
2. **Polling the live file** every 0.5–1.0 s with
   `ffmpeg -sseof -0.7 -i live.ogg -af volumedetect` + `ffprobe`: works
   (this is how the initial VAD calibration was done) but costs **200–260 ms
   per poll** — 20–50 % of one core, forever. Too expensive for an
   all-day logger.
3. **`tail -f live.ogg | ffmpeg -f ogg -i -`**: **fails** —
   `Error opening input: End of file`, 0 bytes decoded, on a pipe fed by
   `tail -f`. `cat file | ffmpeg -i -` on the same bytes decodes fine, and
   `( cat file; sleep 6 ) | ffmpeg …` decodes fine (2.5 MB of PCM), so the
   demuxer is happy with a held-open pipe and unhappy with `tail -f`
   specifically.

## 4. What v3 does

One continuous Ogg/Opus capture, one long-lived decoder, a real VAD between
them, and whisper only for utterances.

```
termux-microphone-record -e opus -r 16000 -c 1 -f live.ogg -l 0
        │  (grows in place, readable while written)
        ▼
feed_stream(): `tail -c +N | head -c M` in a loop — reads exactly the bytes
               appended since last pass and holds stdout open, so ffmpeg sees
               a continuous, never-closing Ogg stream
        ▼
ffmpeg -f ogg -i - -ac 1 -ar 16000 -f s16le -            (one process, all day)
        ▼
audiophile-vad.py: per-100 ms RMS, noise-floor tracking, hysteresis
        │
        ├── ev=level  (1/s, for logs/notification)
        ├── ev=begin / ev=segment / ev=drop
        ▼
DTRH-Audiophile.sh: reads events from a FIFO, sends each utterance WAV to
                    whisper, appends to the daily markdown, audits to JSONL
```

VAD state machine, per 100 ms block, `db = 20·log10(rms/32768)`:

* noise floor falls instantly, rises 0.05 dB/block while idle, clamped to
  [−90, −40] dB
* `threshold = max(DTRH_SPEECH_DB, floor + DTRH_MARGIN_DB)`
* onset needs 2 consecutive loud blocks; utterance **start** is moved back
  `PREROLL_MS` (2 s) so the first consonant is never clipped
* utterance **end** needs `END_SILENCE_MS` (1.5 s) of continuous silence, and
  the file is cut at the last loud block + 250 ms tail
* `MAX_SEGMENT_MS` (120 s) caps a monologue and continues in a new file
* utterances with < `MIN_SPEECH_MS` (400 ms) of voiced audio are dropped
  before whisper is called at all
* the whole segment buffer is written as a 16 kHz mono WAV by python, so the
  old `m4a → wav` ffmpeg conversion is gone

Because the decoder is fed by a byte follower rather than `-ss` seeks, segment
boundaries are sample-accurate and no audio is ever re-decoded or duplicated.

Housekeeping: when the VAD reports ≥ `DTRH_ROTATE_IDLE_S` (90 s) of continuous
silence, the capture file is recycled (stop recorder, delete file, start a new
one) — the gap lands in silence, so it cannot cut a word. A size cap
(`DTRH_ROTATE_MAX_MB`, 64 MB) forces the same on absurdly long monologues.
The capture file is also recycled after any pipeline restart, so a crashed
decoder can never make the same audio transcribed twice.

Hallucination guard: even with gating, whisper occasionally emits `you`,
`Thank you.`, `[BLANK_AUDIO]`, `Subscribe!` on a very short quiet segment;
those exact strings are dropped instead of written into the journal.

Also added: `--status`, `--stop`, `--tail`, `--selftest`, `--debug`,
`--no-notify`, `--work`, `--model`, env overrides for every threshold, a JSONL
audit trail (`.audiophile/index.jsonl` next to the transcripts), live
notification, wakelock, PID lock, and a warning if the microphone returns
digital silence.

## 5. Evidence

`--selftest` (synthetic track: 2 s silence, 3 s tone, 2.5 s silence, 1 s tone,
2 s silence) — no microphone needed, works on any box:

```
ev=ready sr=16000 block_ms=100 thr=-55.0 floor=-70.0
ev=begin t=2.10
ev=segment … t0=0.00 t1=5.20 dur=5.20 voiced=3.00 vdb=-30.1 reason=silence
ev=begin t=7.60
ev=segment … t0=5.50 t1=8.70 dur=3.20 voiced=1.00 vdb=-30.1 reason=silence
ev=end segments=2
SELFTEST PASS   (segments written: 2, expected 2)
```

End-to-end on the device with real speech (TTS through the speaker, silence
between utterances):

```
[INFO] vad ready (speech>-55.0dB, floor -78.0dB)
[DEBUG] speech onset at 18.40s
[INFO] utterance 4.60s (voiced 2.30s, -32.0dB, silence) -> whisper
[INFO] >> 16:48:17 (4.60s) The quick brown fox jumps over the lazy dog.
[INFO] utterance 4.10s (voiced 1.90s, -35.2dB, silence) -> whisper
[INFO] >> 16:48:28 (4.10s) Silence gating is working as intended.
```

Verbatim transcripts, whisper invoked exactly twice in ~40 s of recording that
contained ~5 s of speech; the silent stretches produced no segments, no
whisper calls and no invented text. End-of-speech → segment emission was
1.5–2 s (the end-silence window plus decoder lag).

**Screen off (the pocket use case).** With the screen powered off via
`KEYCODE_POWER` and the app in the background, the next utterance was still
captured and transcribed:

```
[INFO] utterance 6.10s (voiced 3.40s, -31.7dB, silence) -> whisper
[INFO] >> 17:13:34 (6.10s) Second utterance recorded with the screen off and the app in the background.
```

**Rotation.** Both paths were exercised:

* idle path: `[INFO] no speech for 30s - recycling the capture file`, followed
  by `capture started: live-…ogg` and `vad ready`, and the next utterance was
  transcribed normally;
* size-cap path (forced with `DTRH_ROTATE_MAX_MB=0`): rotations every ~15 s
  regardless of VAD state, each followed by a fresh capture file and a healthy
  `vad ready`, with a clean stop afterwards (no strays, capture dir empty).

**Graceful stop.** `--stop` → `cleanup: stopping capture and transcriber`,
pidfile removed, recorder released, capture file deleted, zero surviving
processes (`audiophile-vad.py`, `audiophile-follow.py`, ffmpeg).

**Idle cost, measured three times:**

| Configuration | Idle CPU (one core) |
| --- | --- |
| v3 first cut: bash feeder forking `stat`+`tail`+`head`+`sleep` ~7×/s | **21.5 %** |
| after switching the feeder to a single `dd` per pass | 18.3 % |
| after moving the follow loop into `audiophile-follow.py` | **7.8 %** |

Attribution of the final 7.8 %: ffmpeg ~4.3 %, VAD python ~3.1 %, follower and
orchestrator ≈ 0. For comparison, v2 ran a full whisper pass every 30 s; at
0.4× realtime that alone is ~40 % of a core, plus an ffmpeg conversion per
slice.

## 6. What the testing broke, and what was fixed

Each of these was found by running it, not by reading it.

1. **Junk in the journal.** First soak run wrote `[BLANK_AUDIO]`,
   `(birds chirping)`, `(keyboard clicking)` and `(mumbling)` into the daily
   markdown — 4 of 8 entries. Whisper describes non-speech with a bracketed
   annotation, so any transcription that is *entirely* `(...)` or `[...]` is
   now dropped, along with a small canned-phrase list.
   *Extra bug found while unit-testing the filter:* the first version of the
   regex was `^[[:space:]]*[\(\[](.*)[\)\]][[:space:]]*$`, whose
   backslash-escaped bracket expression never matched anything — it failed
   silently. The working form is
   `^[[:space:]]*(\(.*\)|\[.*\])[[:space:]]*$`, verified against 12 strings.
2. **Transients transcribed as speech.** Doors, keyboards and the phone being
   picked up crossed the onset threshold and produced 0.4–0.8 s "utterances"
   at −50…−54 dB. Added a second gate: the mean level of the *voiced* blocks
   must be ≥ `DTRH_MIN_VOICED_DB` (−50 dB); `DTRH_MIN_SPEECH_MS` went 400 →
   500 ms; and the first `DTRH_WARMUP_MS` (1.5 s) after the recorder starts is
   ignored, because MediaRecorder itself emits a transient when it opens.
   Voice at −32…−47 dB still passes, distant speech at −47 dB still passes.
3. **21.5 % of a core while idle.** The bash feeder was forking `stat`,
   `tail`, `head` and `sleep` on every pass, ~7 forks/s forever. Replaced by
   `audiophile-follow.py`; 7.8 % left, which is the actual decode+VAD work.
4. **Rotation depended on silence happening.** The size cap was only evaluated
   inside the `ev=idle` handler. A noisy room never idles — measured directly:
   a video playing at ~−50 dB kept the VAD in `speech` for 20+ s, correctly
   refusing to transcribe it (`drop … vdb=-50.1 reason=quiet`) but blocking
   every rotation. The size cap now also runs from the `ev=level` handler
   every 15 s, so the capture file cannot grow unbounded in any room.
5. **Silence-deaf microphone.** Documented in §2: Android 10 hands all-zero
   samples to capture started while the Termux app is not running. The script
   now warns instead of quietly recording nothing.

## 7. Limits, and what is still untested

* Multi-hour stability, thermal behaviour and true battery drain are not
  measured — only a 45–60 s idle window and a ~2 minute soak.
* `tiny.en` accuracy vs `base.en` on this microphone is not compared. tiny.en
  already mis-hears one word in ten ("audiophile" → "audio file") and drops
  final clauses of quiet sentences.
* Transcription is synchronous, so the journal stays in order but a long
  monologue delays its own transcript by ~0.4× its length.
* **A room is not a speaker.** A video playing nearby is indistinguishable from
  a person talking; it gets transcribed with equal confidence (observed:
  "I'll see you guys later." from a nearby video). This is inherent to
  energy-based gating — the threshold decides what counts as "someone spoke",
  not who.
* Screen-off capture was verified in one ~30 s test, not overnight with Doze.
* No tests with a headset, Bluetooth or speakerphone routing.
* The canned-phrase list and the annotation rule are hand-written, not learned.
* `DTRH_END_SILENCE_MS=1500` will split a slow speaker with long pauses into
  several utterances; that is a tuning knob, not a bug.

## 8. Files

* `DTRH-Audiophile.sh` — rewritten (v2 → v3), orchestrator
* `audiophile-vad.py` — new, VAD/segmenter (stdin PCM → segment WAVs)
* `audiophile-follow.py` — new, byte-exact file follower (replaces `tail -f`)
* `audiophile-calibrate.sh` — new, prints the room's noise floor and a
  suggested `DTRH_SPEECH_DB`
* `README.md` — updated for v3
