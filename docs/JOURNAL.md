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

**Quiet room (the case that was previously untestable).** Re-run with the
room silent, `DTRH_ROTATE_IDLE_S=20`, `DTRH_ROTATE_MIN_AGE_S=15`, 55 s window:

```
QUIET-ROOM IDLE CPU: 5.7% of one core over 55s
idle events reached bash : 3
rotations (idle path)    : 1
capture-starts           : 2
utterances detected      : 0      <- correct
whisper invocations      : 0      <- correct
transcripts written      : 0

[DEBUG] idle 15s (capture age 23s, 83kB; rotate at 20s idle / 15s age)   <- correctly below threshold
[DEBUG] idle 30s (capture age 38s, 131kB; rotate at 20s idle / 15s age)  <- trips it
[INFO]  no speech for 30s - recycling the capture file
[INFO]  vad ready
```

That closes the one path that had only been forced rather than observed. A
silent minute now costs 5.7 % of one core and produces no whisper call at all.

**Threshold reading for this room** (60 level events during that silent
minute): min −85.0, median −82.7, p90 −72.2, **max −54.4 dB**, floor settled
between −85.5 and −70.0. Two of 60 blocks crossed the default −55 dB
threshold but never two in a row, so no utterance was created — that is the
hysteresis doing its job, but it has little margin. For this phone in this
room `DTRH_SPEECH_DB=-60` is the safer setting (the fixed
`audiophile-calibrate.sh` independently suggests −61): it keeps ~12 dB of headroom
over the 90th-percentile noise and still sits far below real speech
(−32…−47 dB measured).

**Gates under an active room** (the 55 s run above was not silent: three
onsets at 6.9 s, 29.6 s and 47.9 s). Nothing reached whisper and nothing was
written, and the reason is visible per onset:

```
[DEBUG] dropped 3.60s of audio: too_short (voiced 300ms, -48.1dB)
[DEBUG] dropped 2.60s of audio: too_short (voiced 300ms, -54.0dB)
[DEBUG] dropped 2.40s of audio: too_short (voiced 200ms, -48.1dB)
```

The idle timer restarted on each of them, so the 30 s rotation did not fire —
correct behaviour, and the reason the checklist below tells you to grep for
`speech onset` before concluding that rotation is broken.

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

**Silero VAD as a second gate** (6 s clips, `whisper-cli --vad -vm <silero>
-vt 0.5`, `ggml-tiny.en.bin`):

| clip | without `--vad` | with Silero |
| --- | --- | --- |
| pink noise | `(dramatic music)` — 3307 ms | **empty** — 419 ms |
| 440 + 660 Hz tones | `(beeping)` — 3570 ms | **empty** — 463 ms |
| real speech | `Please transcribe this spoken sentence into the journal.` — 3839 ms | same text — 4008 ms |

So the semantic gate removes non-speech at the source *and* makes it ~8× cheaper
(whisper skips the encoder work), for ~170 ms of extra overhead on real speech.
Wired in as `--vad -vm … -vt 0.5`, auto-detected, and verified end to end on the
device: `[INFO] whisper vad: silero (for-tests-silero-v6.2.0-ggml.bin,
threshold 0.5)` followed by a correct transcript, and with a deliberately wrong
`DTRH_WHISPER_VAD` the pipeline warns
(`no silero model found - non-speech audio will reach whisper`) and keeps
transcribing rather than failing. The model present in this checkout is the
whisper.cpp test build; a released Silero ggml is the right thing to ship.

**`tiny.en` vs `base.en`**, six spoken sentences captured through the
microphone, numbered/currency formatting normalised before scoring:

| model | WER over 63 words | per utterance | worst case |
| --- | --- | --- | --- |
| `tiny.en` | **9.5 %** | **4.1 s** | "with" → "a" in one sentence |
| `base.en` | 6.3 % | **8.3 s** | same two mishearings, one sentence fixed |

`base.en` costs 2× the time — slower than realtime on this SoC — to fix one
sentence out of six. Both models render "audiophile" as "audio file" and
"Silero" as "cellular", which points at the microphone/TTS chain rather than
model capacity. Caveat: six TTS sentences through a speaker into a phone mic is
a small, slightly artificial sample; it decides the *default*, not the ceiling.

**Pocket acoustics, simulated.** Clean speech was filtered like fabric
(`highpass=200,lowpass=2500`, −12 dB) and mixed over a synthetic pocket bed
(brown-noise rumble lowpassed at 350 Hz plus tremolo'd pink-noise rustle). With
a loud bed the wideband level is useless as a discriminator — pocket noise and
muffled speech both measured −30.8 dB mean — Silero still accepted the speech,
and whisper produced `file pipeline.` from a sentence it otherwise transcribes
word for word. With a realistic bed (mean −54.5 dB) the separation is +12.4 dB
at the 90th percentile, which the tool calls WORKABLE. Caveat: these beds are
synthetic and one of them was unrealistically loud, so they show the *failure
mode*, not your pocket. Hence `audiophile-pocket-calibrate.sh`.

**The pocket tool had to be corrected too.** Its first version compared the
*median* of the talking phase against the noise — but in a speech-over-noise
recording the median **is** the noise (measured −63.2 dB while the speech peaked
at −32.9 dB), so a perfectly workable pocket was reported as UNUSABLE. It now
compares high percentiles (speech p90 vs noise p95), reports threshold coverage,
and states the effective threshold the script will actually use
(`max(DTRH_SPEECH_DB, floor + margin)`).

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
5. **The calibration tool threw its own audio away.** `audiophile-calibrate.sh`
   piped PCM into `python3 - <<PY`; a here-document redirects stdin, so python
   read its *program* from stdin and the samples were discarded —
   `no audio decoded - is the microphone permission granted?`, while the
   recording was fine (93 kB). It now decodes to a temp file and passes the
   path as an argument. Its suggestion was also rebuilt: it used the p10 of a
   single-cluster recording, which for this room landed at −68 dB — *below*
   the −53.8 dB transient peaks it was supposed to sit above. It now estimates
   the noise floor from the quietest third of the blocks and suggests
   `floor + 20 dB`, which yields **−61 dB** here.
6. **Silence-deaf microphone.** Documented in §2: Android 10 hands all-zero
   samples to capture started while the Termux app is not running. The script
   now warns instead of quietly recording nothing.

## 7. Limits, and what is still untested

* Multi-hour stability, thermal behaviour and true battery drain are not
  measured — only 45–60 s idle windows and ~2 minute soaks (device reported
  40 % battery, 28.6 °C throughout, which says nothing about an overnight run).
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
* The Silero model in this checkout is whisper.cpp's `for-tests-silero-v6.2.0`
  build, not a released Silero; it demonstrably works here, but shipping should
  use a proper release. `--vad-threshold 0.5` was not swept — only spot-checked.
* The `base.en` A/B is six TTS sentences (63 words) — enough to choose a default,
  not enough to claim a general accuracy figure.
* Disk is the binding constraint on this phone: `/data` was at 97 % (1.3 GB
  free), and `ggml-base.en.bin` is 141 MB. Models belong on removable storage;
  that is queued in `docs/ROADMAP.md`.
* `DTRH_END_SILENCE_MS=1500` will split a slow speaker with long pauses into
  several utterances; that is a tuning knob, not a bug.

## 8. Files

* `DTRH-Audiophile.sh` — rewritten (v2 → v3), orchestrator
* `audiophile-vad.py` — new, VAD/segmenter (stdin PCM → segment WAVs)
* `audiophile-follow.py` — new, byte-exact file follower (replaces `tail -f`)
* `audiophile-calibrate.sh` — new, prints the room's noise floor and a
  suggested `DTRH_SPEECH_DB`
* `audiophile-pocket-calibrate.sh` — new, two-phase calibration for a phone kept
  in a pocket: separation, coverage, verdict, suggested settings
* `.gitignore` — keeps the runtime log and pidfile out of `git status`
* `CHANGELOG.md` — version history
* `docs/ROADMAP.md` — direction, queued work, and what is deliberately not planned
* `README.md` — updated for v3 / v3.1

## 9. Verification checklist

Run this after any change to the pipeline. Each step has an expected result; if
it does not match, the change is not done.

**On any machine, no phone and no microphone needed:**

```bash
./DTRH-Audiophile.sh --selftest
# expect: "segments written: 2 (expected 2)"  and  "SELFTEST PASS"
```

**On the phone, in `~/Audiophile`:**

```bash
# 1. what this room actually sounds like
./audiophile-calibrate.sh 12
# expect: "blocks: N (100 ms each ...)", "noise floor (quietest third) = .. dB",
#         "suggested: DTRH_SPEECH_DB=.."   (this phone/room measured -61)

# 2. a silent minute must produce nothing at all
: > DTRH-Audiophile.log      # the log APPENDS across runs - truncate it first,
                            # otherwise every grep below reports old runs too
DTRH_WORK=~/tmp/verify DTRH_NOTIFY=0 DTRH_ROTATE_IDLE_S=20 \
  DTRH_ROTATE_MIN_AGE_S=15 ./DTRH-Audiophile.sh --debug &
sleep 55; ./DTRH-Audiophile.sh --stop
# ALWAYS expect:
#   last line "utterances this run: 0 (0ms of speech) - goodbye."
#   no "-> whisper" line, no *.md in DTRH_WORK, pidfile gone, no strays
#
# expect "no speech for 30s - recycling the capture file" ONLY if the room was
# genuinely quiet for the whole window. Grep "speech onset" before concluding:
# any sound above DTRH_SPEECH_DB restarts the idle timer and rotation is then
# correctly skipped. In that case what you should see instead is the gates:
#   "dropped 3.60s of audio: too_short (voiced 300ms, -48.1dB)"
#   "dropped 2.60s of audio: too_short (voiced 300ms, -54.0dB)"
# i.e. a sound was noticed and deliberately not sent to whisper. A non-silent
# room is not a failed test - a whisper call or a written segment is.

# 3. real speech must come out verbatim
: > DTRH-Audiophile.log      # again: one run per log check
DTRH_WORK=~/tmp/verify DTRH_NOTIFY=0 ./DTRH-Audiophile.sh --debug &
# say one clear sentence, wait ~10 s
# expect: a "## HH:MM:SS (Ns)" block containing that sentence, and
#         exactly one "-> whisper" line per utterance

# 4. cost when nobody is talking (needs an idle window, >= 45 s)
# expect: ~6-8 % of one core total (ffmpeg ~4 %, VAD ~3 %)
# measured on the LG G7: 5.7 % in a quiet room, 7.8 % with a video playing

# 5. clean shutdown
./DTRH-Audiophile.sh --stop
# expect: pidfile removed, "ps -A | grep audiophile" empty, capture dir empty,
#         "utterances this run: N ... goodbye." in the log
```

**On the phone with the screen off** (the pocket case):

```bash
adb shell input keyevent KEYCODE_POWER          # screen off
# speak, then check the journal: the utterance must still appear
```

The last line of every run is the per-run summary
(`utterances this run: N (...) - goodbye.`) — that number is the one to trust
when the log has not been truncated.

Two things to remember when reading results: `-91.0 dB` from the microphone
means Android handed over silence (open the Termux app once), and a `drop
reason=quiet` line means the sound crossed the onset threshold but was not
loud enough to be a voice — that is the second gate working, not a failure.
