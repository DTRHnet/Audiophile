# Using the transcripts

The journal is the raw material; this is the plan for turning it into something
worth having. Nothing here is built yet except the journal itself and the audit
trail — this document fixes the design, the privacy rules and the build order so
the pieces fit when they land.

## The shape of the data

Two artefacts exist today, both append-only and both cheap to parse:

**Journal** — `transcripts/YYYY-MM-DD.md`, one block per utterance:

```markdown
## 21:04:05 (4.10s)

Did you get my other response?

---
```

**Audit** — `transcripts/.audiophile/index.jsonl`, one JSON object per utterance:
`ts`, `at` (wall clock), `dur` (seconds), `db` and `peak` (levels),
`audio` (path if the WAV was kept), `file`, `text`.

Everything below is a query over those two files. The journal is the readable
record; the JSONL is the machine record. Neither is ever rewritten in place,
which means a query is always `grep`-able and a failure never corrupts history.

## 1. Time ranges first

Every use below starts with a time range. One small binary does the selection;
everything else consumes its output.

```bash
audiophile-export --last 2h                     # from now back
audiophile-export --today
audiophile-export --from "2026-11-12 09:00" --to "2026-11-12 12:30"
audiophile-export --on 2026-11-12 --format jsonl
audiophile-export --grep "invoice"              # full-text, case-insensitive
audiophile-export --min-dur 5                   # skip one-word utterances
```

Formats, chosen by flag, all from the same internal list of typed entries:

| Format | Use |
| --- | --- |
| `md` (default) | reading, Obsidian, pasting into notes |
| `txt` | plain dump, notifications, SMS-sized digests |
| `jsonl` | piping into anything else, including your own scripts |
| `srt` / `vtt` | subtitles if the audio is ever paired with video |
| `csv` | spreadsheets: time, duration, level, words, text |

Because the audit trail carries `db`/`peak`, every export can also answer "was
this a quiet room or a loud one" without listening.

## 2. Digests — three tiers, only one of which leaves the device

### Tier 0 — statistics, no model, no network (build this first)

A digest that is pure arithmetic over the journal, so it works on any phone with
no model, no key, no permission:

- speaking time, utterance count, words, words per minute of *speech*
- the hour histogram: which hours you actually talk
- longest utterance, longest silence gap, busiest 10-minute window
- quiet-vs-loud classification from `db` (a "was I outside?" signal)
- word frequency and rare-word list (crude topic signal)
- day-over-day and week-over-week deltas

That is a genuinely useful note by itself — "Tuesday: 42 utterances, 18 minutes
of speech between 09:10 and 17:40, busiest at 11:00" — and it costs nothing.

### Tier 1 — extraction, still local, still no LLM

Deterministic patterns over the text, which are surprisingly effective on spoken
notes: bullet-like sentences, "remind me to…", numbers and times, questions
asked (lines ending in `?`), names after "call/message/email", and repeated
capitalised tokens. Output as a checklist section in the digest.

### Tier 2 — summaries and analysis, needs a language model

Summaries, topic grouping, action items and tone/shape analysis all need a real
LLM. There are two honest ways to get one, and the choice is a privacy decision,
not a technical one:

| Backend | Where the text goes | Notes |
| --- | --- | --- |
| `none` (default) | nowhere | tiers 0 and 1 only |
| `llama.cpp` local | nowhere — runs on the phone | needs a GGUF model (0.5B–2B) on the SD card; expect minutes, not seconds, for a long digest |
| `openai`-compatible HTTP | your endpoint | Ollama/LM Studio on the LAN, or a cloud API. One config string, works with many providers |

Rules for tier 2, non-negotiable:

1. **Off by default.** Nothing leaves the device because a config default said so.
2. **Explicit opt-in per backend** (`DTRH_SUMMARY_BACKEND=...`) plus a one-line
   warning printed the first time it runs.
3. **Redaction option** before any network call: strip numbers, capitalised name
   guesses, and email/phone-shaped strings.
4. **Generated text is always marked as generated** — a `## Summary (generated)`
   heading, never mixed into the verbatim transcript blocks. The transcript stays
   the source of truth; a summary is a convenience that can be deleted and
   regenerated.
5. **Map-reduce, not one giant prompt.** Long days get chunked by time, each
   chunk summarised, then the summaries merged. It keeps prompts small, cost
   predictable, and failures local to one chunk.

Analysis worth having beyond a summary: open questions, decisions made, numbers
and commitments spoken, and a "things I said I'd do" list. All of these are
prompt variants over the same map-reduce plumbing.

## 3. Where it goes

### Obsidian (primary — this is where the journal already lives)

- Keep the daily note as the source of truth.
- Add YAML front-matter so Dataview can query it:
  `date, utterances, seconds, words, source, retained_audio`.
- Add an optional `## Summary` block at the top (tier 0 always; tier 2 when enabled).
- Link a weekly rollup note that lists the daily notes and totals.
- **If audio is retained**, embed it so the note is playable in Obsidian:
  `![[audio/2026-11-12/seg_20261112_210405_001.wav]]`. This is the cheapest way
  to make "I want to check what I actually said" possible, and it costs one line
  per utterance.
- Tags: `#audiophile`, plus a per-digest `#daily` / `#weekly`.

### Email and messaging (Android share sheet — zero credentials)

`termux-share -a send -t text/markdown digest.md` opens the Android share sheet;
Gmail, Signal, Telegram, Slack — whatever is installed — appears as a target.
No SMTP host, no app password, no API key, and the user picks the destination
each time. This is the right default for "send me the day's digest".

Automated mail, when the share sheet is not enough: `msmtp` (a Termux package)
plus an app password, invoked by the exporter. Documented as tier 3 because it
stores a credential on the phone.

### Local files

Plain files next to the journal, plus `jsonl` for anything else: `rsync`/`scp`
to a server, or Syncthing (already documented) for continuous sync to a laptop.

### Raw audio

Only exists if `DTRH_RETAIN_AUDIO=1`. Then, for a chosen range:

- zip the WAVs for a range and share/export them the same way as a digest;
- or sync them with Syncthing alongside the journals;
- or `termux-share -a send -t audio/wav file.wav` for one utterance.

Two cautions, both real: a 16 kHz mono WAV is ~32 KB per second (~1.2 MB per
minute), and audio is the most sensitive artefact the project produces. Raw
audio export is therefore **opt-in twice** — you must have enabled retention
*and* ask for the export.

## 4. Scheduling

Digests are only useful if they arrive without being asked for:

- `termux-job-scheduler` for a daily digest at a set hour (it can wait for the
  device to be idle or charging), the natural home for "21:30, summarise today".
- `termux-boot` so the transcriber itself comes back after a reboot.
- Tasker, for people already living there: fire the script on a context change.

## 5. Privacy tiers, stated plainly

| Tier | What it means | What leaves the phone |
| --- | --- | --- |
| 0 | local statistics and extraction | nothing |
| 1 | local LLM (llama.cpp on the phone) | nothing |
| 2 | LLM on your own LAN (Ollama/LM Studio) | transcript text, to your network |
| 3 | cloud LLM or SMTP | transcript text, or the digest, to a third party |

The project default is tier 0. Every step up is a deliberate flag, and the
README will keep stating which tier the default configuration is.

## 6. Build order

Smallest useful thing first, each step independently shippable:

1. **`audiophile-export`** — time ranges, `md`/`txt`/`jsonl`/`csv` output, `--grep`.
   No new dependencies, immediately useful, and it is the plumbing everything
   else needs.
2. **Tier 0 digest** — the statistics note, into Obsidian with front-matter.
3. **Obsidian polish** — front-matter, weekly rollup, optional audio embeds.
4. **`termux-share` delivery** — one command to send any digest anywhere.
5. **Tier 1 extraction** — the deterministic checklists.
6. **Tier 2 plumbing** — `openai`-compatible backend behind an explicit flag,
   with redaction and map-reduce; local `llama.cpp` after that if it proves
   tolerable on the phone.
7. **Scheduled digests** — `termux-job-scheduler` + boot autostart.

Not planned: real-time streaming of transcripts to a cloud service, speaker
diarisation, and anything that uploads audio without being asked twice.
