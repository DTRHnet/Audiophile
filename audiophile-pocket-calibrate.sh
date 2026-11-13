#!/data/data/com.termux/files/usr/bin/bash

# ::
# :: audiophile-pocket-calibrate.sh
# ::   Two-phase calibration for a phone that lives in a pocket.
# ::
# ::   Phase A: the phone sits in the pocket and nobody talks -> pocket noise
# ::            (walking, cloth rustle, keys). This is the number that decides
# ::            whether the whole idea works in that pocket.
# ::   Phase B: the phone stays in the pocket and you talk normally.
# ::
# ::   Then it reports the separation between the two, whether whisper+Silero
# ::   can actually read the muffled speech, and a ready-to-paste setting.
# ::
# ::   The phone vibrates to cue each phase: one buzz = start, two buzzes =
# ::   talk now, three buzzes = done. Nothing is played through the speaker,
# ::   because that would end up in the recording.
# ::
# ::   usage:
# ::     ./audiophile-pocket-calibrate.sh                # 12s quiet + 14s talking
# ::     ./audiophile-pocket-calibrate.sh 15 20          # custom phase lengths
# ::     ./audiophile-pocket-calibrate.sh --analyse Q.wav T.wav   # re-analyse files
# :: --------------------------------------------------------------------

set -o pipefail

export PATH="/data/data/com.termux/files/usr/bin:$PATH"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPD="${TMPDIR:-$HOME/tmp}"
MODEL="${DTRH_MODEL:-$HOME/whisper.cpp/models/ggml-tiny.en.bin}"
WHISPER="${DTRH_WHISPER:-$HOME/whisper.cpp/build/bin/whisper-cli}"
SILERO="${DTRH_WHISPER_VAD:-auto}"
WORK="$TMPD/pocket-calib"
REPORT="$WORK/report.txt"
SENTENCE="The audiophile pipeline records audio at sixteen kilohertz and writes markdown notes."
CUE="${DTRH_CUE:-buzz}"   # buzz | beep | both - how the phase boundaries are signalled

buzz() { termux-vibrate -d "${1:-250}" >/dev/null 2>&1 || true; }

# A buzz alone is easy to miss through a pocket while walking, so cue with an
# audible beep as well. The beep lands in the recording, which is why it is
# short and why the phase boundaries are placed after it.
make_beep() {
  [[ -s "$WORK/beep.wav" ]] && return 0
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "sine=frequency=1000:duration=0.35" -af "volume=0.7" \
    -ar 22050 -ac 1 "$WORK/beep.wav" 2>/dev/null || return 1
}
beep() {
  local n="${1:-1}"
  make_beep || return 0
  while (( n-- > 0 )); do
    termux-media-player play "$WORK/beep.wav" >/dev/null 2>&1 || true
    sleep 0.55
  done
}
cue_start() {   # buzz 1
  [[ "$CUE" == beep || "$CUE" == both ]] && beep 1
  buzz 500
}
cue_talk() {    # buzz 2
  [[ "$CUE" == beep || "$CUE" == both ]] && beep 3
  buzz 500
}
cue_done() {    # buzz 3
  [[ "$CUE" == beep || "$CUE" == both ]] && beep 1
  buzz 150; sleep 0.12; buzz 150; sleep 0.12; buzz 400
}

# raise the media volume so the cue can be heard through a pocket, then restore
volume_up() {
  PREV_VOL="$(termux-volume 2>/dev/null | tr -d ' \n' | sed -n 's/.*"stream":"music","volume":\([0-9]*\).*/\1/p')"
  # only ever raise, never drop the stream this low: a silent cue is worse than none
  if [[ -z "${PREV_VOL:-}" ]] || (( PREV_VOL < 12 )); then termux-volume music 12 >/dev/null 2>&1 || true; fi
}
volume_restore() {
  [[ -n "${PREV_VOL:-}" ]] && termux-volume music "$PREV_VOL" >/dev/null 2>&1 || true
}
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# :: \?//'
  exit "${1:-0}"
}

# --- analysis -------------------------------------------------------------
# Written to a file and executed, never fed through stdin: a here-document
# replaces stdin and that silently threw the samples away once already.
analyse_py() {
  cat >"$WORK/analyse.py" <<'PY'
import math, struct, sys, wave

def blocks(path, blk_ms=100):
    with wave.open(path, "rb") as w:
        sr = w.getframerate()
        raw = w.readframes(w.getnframes())
    n = int(sr * blk_ms / 1000)
    out = []
    step = n * 2
    for i in range(0, len(raw) - step + 1, step):
        s = struct.unpack("<%dh" % n, raw[i:i + step])
        tot = sum(x * x for x in s)
        out.append(20 * math.log10(math.sqrt(tot / n) / 32768) if tot else -91.0)
    return out

def stat(v, q):
    if not v:
        return -91.0
    v = sorted(v)
    return v[min(len(v) - 1, int(len(v) * q))]

quiet_path, talk_path = sys.argv[1], sys.argv[2]
q = blocks(quiet_path)
t = blocks(talk_path)
if not q or not t:
    print("could not read audio - is the microphone permission granted?")
    sys.exit(2)

# For a talking phase that is speech OVER noise, the median is the noise. The
# speech level lives in the top of the distribution, so compare high
# percentiles, and measure coverage against the threshold we would actually set.
q50, q90, q95, q99 = stat(q,.5), stat(q,.9), stat(q,.95), stat(q,.99)
t50, t90, t95 = stat(t,.5), stat(t,.9), stat(t,.95)
floor = min(q)
sep = t90 - q95                      # speech level minus the noise peaks
speech_db = q99 + 5                  # above essentially all of the pocket noise
voiced_db = t90 - 10                 # below the typical level of spoken blocks
covered = 100.0 * sum(1 for x in t if x > speech_db) / len(t)

print("pocket noise : p50 %.1f  p90 %.1f  p95 %.1f  p99 %.1f  max %.1f dB" % (q50,q90,q95,q99,max(q)))
print("pocket speech: p50 %.1f  p90 %.1f  p95 %.1f            max %.1f dB" % (t50,t90,t95,max(t)))
print("separation   : %.1f dB  (speech p90 minus noise p95)" % sep)
print("coverage     : %.0f%% of talking-phase blocks clear the %0.0f dB threshold" % (covered, speech_db))
print()
if sep >= 20:
    verdict, advice = "COMFORTABLE", "the pocket is fine; speech sits well above the noise"
elif sep >= 12:
    verdict, advice = "WORKABLE", "usable; expect occasional missed or trimmed utterances"
elif sep >= 6:
    verdict, advice = "MARGINAL", "speech barely clears the noise - expect losses, tighten the pocket or speak up"
else:
    verdict, advice = "UNUSABLE", "speech does not clear the pocket noise; the level VAD cannot work in this pocket"

print("VERDICT: %s - %s" % (verdict, advice))
print()
print("suggested settings:")
print("  DTRH_SPEECH_DB=%.0f      (noise p99 %.1f + 5)" % (speech_db, q99))
print("  DTRH_MIN_VOICED_DB=%.0f  (speech p90 %.1f - 10)" % (voiced_db, t90))
print("  DTRH_PREROLL_MS=2500   (the onset is quieter through fabric)")
print("  DTRH_END_SILENCE_MS=1200")
print()
print("effective threshold in the script will be max(DTRH_SPEECH_DB, floor+margin)")
print("  = max(%.0f, %.1f + 10) = %.0f dB   (floor %.1f dB measured in the pocket)" %
      (speech_db, floor, max(speech_db, floor + 10), floor))
print("SHELL: DTRH_SPEECH_DB=%.0f DTRH_MIN_VOICED_DB=%.0f DTRH_PREROLL_MS=2500 DTRH_END_SILENCE_MS=1200" %
      (speech_db, voiced_db))
PY
  python3 -u "$WORK/analyse.py" "$1" "$2"
}

# --- record ---------------------------------------------------------------
record_phases() {
  local quiet_s="${1:-12}" talk_s="${2:-14}" raw="$WORK/pocket.ogg"
  mkdir -p "$WORK"
  have termux-microphone-record || { echo "termux-api missing"; exit 1; }
  termux-microphone-record -q >/dev/null 2>&1; sleep 0.3
  rm -f "$raw"
  termux-microphone-record -e opus -b 32 -r 16000 -c 1 -f "$raw" -l 0 >/dev/null 2>&1
  make_beep; volume_up
  echo "recording... PHASE A: keep quiet in your pocket (${quiet_s}s) - do not talk"
  echo "   cue: buzz 1 = start"
  cue_start
  sleep "$quiet_s"
  echo "PHASE B: talk now, normally, for ${talk_s}s - say this:"
  echo "   \"$SENTENCE\""
  echo "   cue: buzz 2 = talk now"
  cue_talk
  sleep "$talk_s"
  termux-microphone-record -q >/dev/null 2>&1
  sleep 0.6
  cue_done; volume_restore
  local total; total=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$raw" 2>/dev/null)
  echo "done (${total}s recorded)"
  ffmpeg -hide_banner -loglevel error -y -f ogg -i "$raw" -ar 16000 -ac 1 "$WORK/quiet.wav"
  ffmpeg -hide_banner -loglevel error -y -f ogg -i "$raw" -ss "$quiet_s" -ar 16000 -ac 1 "$WORK/talk.wav"
  echo
}

# --- whisper sanity check -------------------------------------------------
speech_check() {
  local wav="$1" flags=()
  have "$WHISPER" || { echo "whisper-cli not found - skipping speech check"; return; }
  [[ -s "$MODEL" ]] || { echo "model not found - skipping speech check"; return; }
  if [[ "$SILERO" != "off" ]]; then
    local f="$SILERO"
    if [[ "$SILERO" == "auto" ]]; then
      f=""
      for c in "$HOME"/whisper.cpp/models/*silero*.bin; do [[ -s "$c" ]] && { f="$c"; break; }; done
    fi
    [[ -s "$f" ]] && flags=(--vad -vm "$f" -vt 0.5)
  fi
  echo "whisper (with silero if available) on the talking phase:"
  "$WHISPER" -m "$MODEL" -f "$wav" -otxt -of "$WORK/talk" -l en -t 4 -np -nt "${flags[@]}" >/dev/null 2>&1
  local text; text=$(tr '\n' ' ' <"$WORK/talk.txt" 2>/dev/null | sed 's/^ *//; s/ *$//')
  # Words, or only whisper's description of a noise? "(whooshing)" and
  # "[BLANK_AUDIO]" are not speech, and must not count as a successful capture.
  if [[ "$text" =~ ^[[:space:]]*(\(.*\)|\[.*\])[[:space:]]*$ ]]; then
    SPEECH_TEXT=""
    echo "   -> only a non-speech annotation ($text) - no words in the talking phase."
  else
    SPEECH_TEXT="$text"
  fi
  if [[ -z "$SPEECH_TEXT" || "$SPEECH_TEXT" == *BLANK_AUDIO* ]]; then
    echo "   -> NO SPEECH FOUND in the talking phase."
  else
    echo "   -> \"$text\""
    echo "   ground truth: \"$SENTENCE\""
  fi
  echo
}

# --- main -----------------------------------------------------------------
if [[ "$1" == "-h" || "$1" == "--help" ]]; then usage 0; fi
mkdir -p "$WORK"

if [[ "$1" == "--analyse" ]]; then
  [[ -s "$2" && -s "$3" ]] || { echo "need two readable WAVs: quiet, then talking"; exit 1; }
  { analyse_py "$2" "$3"; } | tee "$REPORT"
  echo
  speech_check "$3" | tee -a "$REPORT"
  echo "report: $REPORT"
  exit 0
fi

record_phases "$1" "$2"
echo "== pocket calibration $(date '+%F %T') =="
{ analyse_py "$WORK/quiet.wav" "$WORK/talk.wav"; } | tee "$REPORT"
echo
speech_check "$WORK/talk.wav" | tee -a "$REPORT"
echo
if [[ -z "${SPEECH_TEXT:-}" || "${SPEECH_TEXT}" == *BLANK_AUDIO* ]]; then
  cat <<'MSG'
RUN INVALID - this is not a verdict about the pocket.
No speech was found in the talking phase, so the comparison above is
meaningless. It usually means the "talk now" cue was missed (three beeps plus
three buzzes) or the phase A recording was not actually quiet.
Redo it with the phone already in the pocket before the run starts, stay still
during phase A, and talk as soon as the three beeps land.
MSG
  echo "report: $REPORT"
  exit 3
fi
echo "report: $REPORT"
echo "raw audio kept at: $WORK/pocket.ogg (delete when done)"
