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

### 1. Move transcription off the event loop, behind a resident model

*Why:* each utterance currently pays ~1 s of `whisper-cli` model loading out of
a ~4.1 s call, and transcription is synchronous — a 120 s monologue makes the
journal lag by ~48 s while the VAD keeps queueing. `whisper-server` is already
built in `~/whisper.cpp/build/bin/` and can hold the model resident.

*Plan:* a queue worker fed by the event loop (journal order preserved), talking
either to `whisper-server` over HTTP or to a persistent `whisper-cli`-equivalent
process. Success = per-utterance latency below 2 s for a 5 s utterance, and a
measured drop in CPU per transcribed second.

*Also unlocks:* `base.en` (~2× the compute, see the A/B) becomes affordable.

### 2. SD card for models and capture files

*Why:* `/data` was at 97 % with ~1.1 GB free before `ggml-base.en.bin` (141 MB)
was added. Audio and models do not belong in app-private storage on a phone
this tight on space.

*Plan:* `DTRH_CAPTURE_DIR` already exists — point it at the SD card. Add a
model search path (`$DTRH_MODEL_DIR`) that checks removable storage first, plus
a startup check that refuses to run if free space is below a threshold instead
of silently filling the partition. Success = a full day of capture on the SD
card with `/data` untouched.

### 3. Overnight, screen-off, Doze soak

*Why:* the only promise still unproven. Screen-off capture was verified for
~30 s; nothing has run through a real night of Doze, and the device reported
28.6 °C / 40 % battery only as a snapshot.

*Plan:* 8 h with the screen off and `--debug`, then read: utterances per hour,
any `-91 dB` (microphone silenced) warnings, disk growth, battery delta,
temperature, and whether rotation fired as designed. Success = the journal has
the night in it and the battery delta is measured rather than guessed.

## Later

### 4. Relax the first gate, let Silero do the filtering

*Why:* Silero made non-speech nearly free (empty result in ~0.4 s), while the
energy gate still rejects anything whose voiced part averages below −50 dB —
which is where genuinely quiet or distant speech lives. Now that there is a
second, semantic gate, the first one can afford to be more permissive.

*Plan:* measure recall on deliberately quiet speech (TTS at low volume, phone
across the room) at `DTRH_MIN_VOICED_DB` −50 / −55 / −58, and check that junk
does not come back. Change the default only if the numbers say so.

### 5. Battery and thermal over a real hour

*Why:* 5.7–7.8 % of one core at idle is a good proxy, not a battery figure.
Success = %/hour drain on this 3000 mAh device with the screen off, and no
thermal throttling that makes transcription slower than realtime.

### 6. Autostart and the Tasker path

*Why:* the README documents a Termux:Tasker integration that nobody has ever
executed, and nothing survives a reboot today (note: `adb tcpip` does not
either, which matters for remote debugging). `termux-boot` makes the journal
survive a restart.

### 7. Privacy at rest

*Why:* transcripts and `index.jsonl` are plaintext in shared storage, readable
by any app with storage access, and the audit trail retains audio statistics for
every utterance.

*Options:* move the vault out of shared storage, optional age/GPG encryption of
the daily file, retention policy for the audit trail, and a `DTRH_RETAIN_AUDIO`
switch for anyone who wants the WAVs kept.

### 8. Optional extras, in rough order of value

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
