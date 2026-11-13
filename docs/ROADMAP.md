# Roadmap

What is next, in order, with the evidence that justifies the order — so the next
decision does not have to re-derive it. Measurements live in
[`JOURNAL.md`](JOURNAL.md); shipped changes in [`../CHANGELOG.md`](../CHANGELOG.md);
the plan for using the transcripts in [`EXPORTS.md`](EXPORTS.md).

## Direction

A voice journal that runs unattended on a phone in a pocket: **cheap when
nothing is happening**, **faithful when something is**, **never inventing words
that were not spoken**, on a stock unrooted Android device with nothing but
Termux. Then, once the recording is solid, make the record *useful* — summaries
and exports over any time range, without handing the transcript to a third party
by default.

Three rules later work must not break:

1. **Silence is free** — no transcription, no disk, no battery for a quiet room.
2. **Drop, never invent** — doubtful audio is discarded and logged, not guessed.
3. **Measure before optimising** — every default has a number behind it.

## Done

`3.0.0` silence-gated capture · `3.1.0` Silero second gate · `3.2.0` async queue
and resident model · `3.2.1` the queue bug that made it a no-op · `3.2.2`+
`--replay`, `--doctor`, retained audio on SD, model benchmark and re-transcription
tools. See the changelog for the full list and the journal for the evidence.

## Next

### 1. Export what is already recorded (the first real payoff)

`audiophile-export --last 2h --format md|txt|jsonl|csv|srt`, with `--today`,
`--from/--to`, `--on`, `--grep`, `--min-dur`. Pure plumbing over the journal and
the audit trail; no new dependencies, no model, nothing leaves the phone.

*Why first:* every other export idea is built on it, and it is immediately useful
on its own. Design and options: [`EXPORTS.md`](EXPORTS.md) §1.

### 2. A daily digest that needs no model

Speaking time, utterance count, words per minute of speech, hour histogram,
longest utterance and longest silence, plus quiet-vs-loud classification from the
audit `db` values. Written into the Obsidian daily note with front-matter, so
Dataview can query it.

*Why:* it is arithmetic, so it works on any phone, needs no key, and leaks
nothing. It is also the honest baseline a model-based summary has to beat.
Details: [`EXPORTS.md`](EXPORTS.md) §2 tier 0.

### 3. Deliver it somewhere (zero credentials)

`termux-share -a send -t text/markdown digest.md` — the Android share sheet,
where Gmail, Signal, Telegram or Slack are already waiting. No SMTP host, no app
password, no API key. Plus: optional audio embeds in Obsidian when retention is
on, and a weekly rollup note.

### 4. Overnight, screen-off, Doze soak

The one claim still unproven. Eight hours with the screen off, then read:
utterances per hour, any `-91 dB` (mic silenced) warnings, disk growth, battery
delta, temperature, whether rotation behaved. Wakelock and a foreground
notification are already in place.

### 5. Robustness pass

Recovery instead of death: termux-api dying, the SD card pulled mid-archive, the
microphone going silent mid-journal, the queue worker dying (currently handled,
but only by falling back inline). Each should log loudly and recover.

## Later

### 6. Summaries and analysis (needs a model — a privacy decision)

Map-reduce summarisation over a time range, plus extraction of action items,
questions, decisions and numbers. Backends: local `llama.cpp` on the phone
(slow but nothing leaves), or any `openai`-compatible endpoint on your LAN or in
the cloud. Off by default, explicit opt-in per backend, redaction before any
network call, and generated text always labelled as generated.
Details: [`EXPORTS.md`](EXPORTS.md) §2 tier 2.

### 7. Scheduled automation

`termux-job-scheduler` for a digest at a set hour (it can wait for the device to
be idle or charging) and `termux-boot` so the transcriber survives a reboot.
Note that `adb tcpip` does *not* survive a reboot, which matters for remote
debugging.

### 8. Battery and thermal over a real hour

Idle cost is 5.7–7.8 % of one core; the real figure is %/hour drain with the
screen off, and whether sustained transcription throttles below realtime.

### 9. Privacy at rest

Journals and the audit trail are plaintext in shared storage. Options: move the
vault out of shared storage, optional encryption of the daily file, a retention
policy for the audit trail, and the same for retained audio.

### 10. Cheap wins after that

Word-level timestamps in the journal (whisper already produces them; `-nt`
currently discards them), a per-utterance confidence, and health checks in
scheduled jobs.

## Not doing

* **Cloud transcription.** The audio never leaves the device; that is the point.
* **Root-only tricks** — loopback capture of other apps' audio, always-on mic
  services. It must run on a normal unrooted phone.
* **A learned hallucination filter.** The annotation and canned-phrase rules are
  cheap, explainable and auditable; a classifier here is a liability for a
  journal you are meant to trust.
* **Chasing `tiny.en` vs `base.en`** on synthetic audio. Three measurements
  disagree on accuracy and agree on latency; only real, retained speech can
  settle it, which is exactly why retention exists.
* **Pocket capture.** Measured four times: no words in the audio at all. The
  calibration tool reports it honestly; the code will not pretend otherwise.
* **Speaker diarisation.** Real work, real value for meetings, not this stage.

## How to change this list

Every item ends in a number or a user-visible behaviour. If a change cannot be
measured, it belongs in an issue, not here. Verification steps are in
[`OPERATIONS.md`](OPERATIONS.md) — run them before calling anything done.
