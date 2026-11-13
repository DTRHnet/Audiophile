# Roadmap

Where Audiophile is going, what is queued, and why — with the evidence that
justifies the order, so the next decision does not need to re-derive it. The
microphone-side findings live in [`JOURNAL.md`](JOURNAL.md); shipped changes in
[`../CHANGELOG.md`](../CHANGELOG.md).

## Direction

A voice journal that runs unattended on a phone that stays in a pocket: it
should be **cheap when nothing is happening**, **faithful when something is**,
**never invent words that were not spoken**, and it must survive a stock,
unrooted Android device with nothing but Termux. Everything below is ranked by
"how much does this improve that promise per hour of work", and nothing ships
without a measurement that can be re-run.

Three rules the code follows, which later work must not break:

1. **Silence is free** — no transcription, no disk, no battery for a quiet room.
2. **Drop, never invent** — a doubtful segment is discarded and logged, not
   guessed at. Precision over recall.
3. **Measure before optimising** — every default in `DTRH-Audiophile.sh` has a
   number behind it in the journal.

## Next

### 1. ~~Move transcription off the event loop, behind a resident model~~ — done in 3.2.0

Shipped: a queue worker transcribes serially (order preserved) so the event
loop never blocks, plus an opt-in resident `whisper-server` that saves ~390 ms
per utterance. Still open: whether `DTRH_ENGINE=server` should become the
default once it has survived a long run, and whether the saved time makes
`base.en` viable (it is ~2× the compute; see the A/B in the journal).

### 2. SD card: captures and archives (models stay internal)

*Status:* the card is mounted and writable (`/storage/7BFE-5787`, 30 GB), and
the model question is now settled by measurement — see the benchmark in
`JOURNAL.md`. Loading a model from exFAT cost ~12.4 s against ~6.8 s from
internal storage, so **the active model stays on internal storage**; the card is
for capture files, archives, and models that are not currently loaded.
`DTRH_CAPTURE_DIR` already points anywhere, so moving captures to the card is a
one-line configuration change; what remains is a free-space guard and a
documented layout.

### 2b. SD card for models and capture files

*Why:* `/data` was at 97 % with ~1.1 GB free before `ggml-base.en.bin` (141 MB)
was added. Audio and models do not belong in app-private storage on a phone
this tight on space.

*Plan:* `DTRH_CAPTURE_DIR` already exists — point it at the SD card. Add a
model search path (`$DTRH_MODEL_DIR`) that checks removable storage first, plus
a startup check that refuses to run if free space is below a threshold instead
of silently filling the partition. Success = a full day of capture on the SD
card with `/data` untouched.

### 3. Pocket mode: measure it, then decide

*Why:* a pocket muffles the microphone (high frequencies gone), adds body rumble
and cloth-rustle bursts, and puts the phone further from the mouth. A synthetic
pocket (fabric filtering + rumble + rustle) already shows the failure mode:
with the bed loud enough, the wideband level of pocket noise and of muffled
speech is *identical* (−30.8 dB for both), Silero still accepts the speech, and
whisper degrades to `file pipeline.`.

*Done:* `audiophile-pocket-calibrate.sh` measures the real pocket in two phases
and reports separation, coverage, verdict and a ready-to-paste setting.

*Next:* run it in the actual pocket, then act on the verdict:
* **COMFORTABLE / WORKABLE** — just ship the suggested settings, and note that
  `DTRH_PREROLL_MS` matters more here (the onset is quieter through fabric).
* **MARGINAL / UNUSABLE** — the candidates are (a) measure level on a
  speech-band signal (`highpass=200,lowpass=3500`) instead of wideband, which
  suppresses rumble and rustle; (b) let Silero be the primary gate and keep the
  energy VAD only as a cheap pre-filter; (c) accept that this pocket is not a
  recording environment and say so. Pick with measurements, not intuition.

### 4. Overnight, screen-off, Doze soak

*Why:* the only promise still unproven. Screen-off capture was verified for
~30 s; nothing has run through a real night of Doze, and the device reported
28.6 °C / 40 % battery only as a snapshot.

*Plan:* 8 h with the screen off and `--debug`, then read: utterances per hour,
any `-91 dB` (microphone silenced) warnings, disk growth, battery delta,
temperature, and whether rotation fired as designed. Success = the journal has
the night in it and the battery delta is measured rather than guessed.

## Later

### 5. Relax the first gate, let Silero do the filtering

*Why:* Silero made non-speech nearly free (empty result in ~0.4 s), while the
energy gate still rejects anything whose voiced part averages below −50 dB —
which is where genuinely quiet or distant speech lives. Now that there is a
second, semantic gate, the first one can afford to be more permissive.

*Plan:* measure recall on deliberately quiet speech (TTS at low volume, phone
across the room) at `DTRH_MIN_VOICED_DB` −50 / −55 / −58, and check that junk
does not come back. Change the default only if the numbers say so.

### 6. Battery and thermal over a real hour

*Why:* 5.7–7.8 % of one core at idle is a good proxy, not a battery figure.
Success = %/hour drain on this 3000 mAh device with the screen off, and no
thermal throttling that makes transcription slower than realtime.

### 7. Autostart and the Tasker path

*Why:* the README documents a Termux:Tasker integration that nobody has ever
executed, and nothing survives a reboot today (note: `adb tcpip` does not
either, which matters for remote debugging). `termux-boot` makes the journal
survive a restart.

### 8. Privacy at rest

*Why:* transcripts and `index.jsonl` are plaintext in shared storage, readable
by any app with storage access, and the audit trail retains audio statistics for
every utterance.

*Options:* move the vault out of shared storage, optional age/GPG encryption of
the daily file, retention policy for the audit trail, and a `DTRH_RETAIN_AUDIO`
switch for anyone who wants the WAVs kept.

### 9. Optional extras, in rough order of value

* Word-level timestamps in the journal (whisper already produces them; the
  `-nt` flag currently discards them).
* A wake-word or "record only this app" mode, for people who do not want the
  room transcribed.
* Speaker separation (diarisation) — real work, real value for meetings.
* A `--replay FILE` mode to re-run the pipeline over recorded audio, so tuning
  can be done without re-performing the audio.

## Not doing

* **Cloud transcription.** The point of this project is that the audio never
  leaves the device.
* **Root-only tricks** (loopback capture of other apps' audio, always-on mic
  services). It has to run on a normal, unrooted phone.
* **A learned hallucination filter.** The annotation and canned-phrase rules are
  cheap, explainable and auditable; a classifier here would be a liability for
  a journal you are meant to trust.
* **Chasing `tiny.en` vs `base.en`.** The A/B is decided: 9.5 % vs 6.3 % word
  error for 2× the time. Revisit only if the hardware changes.

## How to change this list

Every item ends with a number or a user-visible behaviour. If a proposed change
cannot be measured, it belongs in an issue, not here. The verification steps are
in [`JOURNAL.md` §9](JOURNAL.md) — run them before calling anything done.
