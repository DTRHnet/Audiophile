#!/data/data/com.termux/files/usr/bin/bash

# ::
# :: audiophile-retranscribe.sh
# ::   Re-run whisper over utterance audio you kept, with one or more models,
# ::   so models can be compared on YOUR voice instead of on synthetic clips.
# ::
# ::   Needs audio kept by the transcriber:
# ::     DTRH_RETAIN_AUDIO=1 ./DTRH-Audiophile.sh
# ::   which stores one WAV per utterance under <card>/audiophile/audio/YYYY-MM-DD/.
# ::
# ::   usage:
# ::     ./audiophile-retranscribe.sh                 # newest 20, all found models
# ::     ./audiophile-retranscribe.sh -n 50           # newest 50
# ::     ./audiophile-retranscribe.sh -m ~/whisper.cpp/models/ggml-base.en.bin
# ::     ./audiophile-retranscribe.sh DIR_OR_WAV ...
# ::
# ::   Output: a markdown table (one column per model, one row per utterance)
# ::   plus per-model latency and realtime factor, printed and saved.
# :: --------------------------------------------------------------------

set -o pipefail
export PATH="/data/data/com.termux/files/usr/bin:$PATH"

WHISPER="${DTRH_WHISPER:-$HOME/whisper.cpp/build/bin/whisper-cli}"
TMPD="${TMPDIR:-$HOME/tmp}"
OUTDIR="$TMPD/retranscribe"
SILERO="${DTRH_WHISPER_VAD:-auto}"
LIMIT=20
MODELS=()
SOURCES=()

usage() { sed -n '3,24p' "${BASH_SOURCE[0]}" | sed 's/^# :: \?//'; exit "${1:-0}"; }
fatal() { echo "$*" >&2; exit 1; }

while (( $# )); do
  case "$1" in
    -h|--help) usage 0;;
    -n|--limit) LIMIT="$2"; shift;;
    -m|--model) MODELS+=("$2"); shift;;
    -o|--out)   OUTDIR="$2"; shift;;
    -*)         fatal "unknown option $1";;
    *)          SOURCES+=("$1");;
  esac
  shift
done

[[ -x "$WHISPER" ]] || fatal "whisper-cli not found at $WHISPER"
command -v ffprobe >/dev/null || fatal "ffprobe missing"

# --- collect audio ---------------------------------------------------------
if (( ${#SOURCES[@]} == 0 )); then
  for cand in "${DTRH_AUDIO_DIR:-}" /storage/*/audiophile/audio "$HOME/storage/shared/Obsidian/transcripts/.audiophile/audio"; do
    [[ -n "$cand" && -d "$cand" ]] && SOURCES+=("$cand")
  done
fi
(( ${#SOURCES[@]} )) || fatal "no audio source found - run the transcriber with DTRH_RETAIN_AUDIO=1 first"

mapfile -t FILES < <(
  for s in "${SOURCES[@]}"; do
    if [[ -d "$s" ]]; then find "$s" -type f -name '*.wav' 2>/dev/null
    elif [[ -f "$s" ]]; then echo "$s"; fi
  done | sort | tail -n "$LIMIT"
)
(( ${#FILES[@]} )) || fatal "no .wav files under: ${SOURCES[*]}"
echo "== ${#FILES[@]} utterances from ${SOURCES[*]} =="

# --- models ----------------------------------------------------------------
if (( ${#MODELS[@]} == 0 )); then
  for m in "$HOME"/whisper.cpp/models/ggml-tiny.en.bin "$HOME"/whisper.cpp/models/ggml-base.en.bin; do
    [[ -s "$m" ]] && MODELS+=("$m")
  done
  for m in /storage/*/audiophile/models/ggml-*.bin; do
    [[ -s "$m" ]] && MODELS+=("$m")
  done
fi
(( ${#MODELS[@]} )) || fatal "no models found - pass -m PATH"
for m in "${MODELS[@]}"; do echo "   model: $(basename "$m")"; done

vad_flags=()
if [[ "$SILERO" != "off" ]]; then
  f="$SILERO"
  if [[ "$SILERO" == "auto" ]]; then
    f=""
    for c in "$HOME"/whisper.cpp/models/*silero*.bin; do [[ -s "$c" ]] && { f="$c"; break; }; done
  fi
  [[ -s "$f" ]] && vad_flags=(--vad -vm "$f" -vt 0.5)
fi

mkdir -p "$OUTDIR"
STAMP="$(date +%Y%m%d_%H%M%S)"
REPORT="$OUTDIR/compare_$STAMP.md"
WORK="$OUTDIR/work_$STAMP"
mkdir -p "$WORK"

# --- transcribe every file with every model --------------------------------
printf '%-40s' "utterance"
for m in "${MODELS[@]}"; do printf ' | %-10s' "$(basename "$m" .bin | sed 's/^ggml-//')"; done
printf '\n'

declare -A TOTAL_MS WORDS
for m in "${MODELS[@]}"; do TOTAL_MS[$m]=0; WORDS[$m]=0; done
total_audio=0

for f in "${FILES[@]}"; do
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null)
  total_audio=$(python3 -c "print(${total_audio:-0} + ${dur:-0})")
  head=$(basename "$(dirname "$f")")/$(basename "$f")
  printf '%-40s' "${head:0:40}"
  for m in "${MODELS[@]}"; do
    tag="$(basename "$m" .bin)"
    out="$WORK/$(basename "$f" .wav)_$tag"
    t0=$(date +%s%N)
    "$WHISPER" -m "$m" -f "$f" -otxt -of "$out" -t 4 -np -nt -l en "${vad_flags[@]}" >/dev/null 2>&1
    t1=$(date +%s%N)
    ms=$(( (t1 - t0) / 1000000 ))
    TOTAL_MS[$m]=$(( ${TOTAL_MS[$m]} + ms ))
    txt=""
    [[ -s "$out.txt" ]] && txt=$(tr '\n' ' ' <"$out.txt" | tr -s ' ' | sed 's/^ *//; s/ *$//')
    WORDS[$m]=$(( ${WORDS[$m]} + $(printf '%s' "$txt" | wc -w) ))
    printf ' | %6sms %.0fw' "$ms" "$(printf '%s' "$txt" | wc -w)"
    printf '%s\t%s\t%s\t%s\n' "$f" "$tag" "$ms" "$txt" >>"$WORK/results.tsv"
  done
  printf '\n'
done

# --- report ----------------------------------------------------------------
{
  echo "# Model comparison on real utterances"
  echo
  echo "Audio: ${#FILES[@]} utterances, $(python3 -c "print('%.1f' % ${total_audio:-0})")s total."
  echo
  echo "| model | mean latency | realtime factor | words |"
  echo "| --- | --- | --- | --- |"
  for m in "${MODELS[@]}"; do
    tag="$(basename "$m" .bin | sed 's/^ggml-//')"
    python3 -c "
ms = ${TOTAL_MS[$m]} / max(1, ${#FILES[@]})
rt = (${TOTAL_MS[$m]}/1000.0) / ${total_audio:-1}
print('| %s | %.0f ms | %.2fx | %d |' % ('$tag', ms, rt, ${WORDS[$m]}))
"
  done
  echo
  echo "## Transcripts side by side"
  echo
  # group results by file and lay them out per model
  python3 - "$WORK/results.tsv" "$REPORT.tmp" <<'PY'
import collections, sys
rows = collections.OrderedDict()
models = []
for line in open(sys.argv[1]):
    f, tag, ms, txt = line.rstrip("\n").split("\t", 3)
    rows.setdefault(f, {})[tag] = (ms, txt)
    if tag not in models: models.append(tag)
out = []
for f, per in rows.items():
    out.append("### %s" % f.split("/")[-2] + "/" + f.split("/")[-1])
    out.append("")
    for tag in models:
        ms, txt = per.get(tag, ("-", ""))
        out.append("- **%s** (%sms): %s" % (tag, ms, txt or "*(nothing)*"))
    out.append("")
open(sys.argv[2], "w").write("\n".join(out))
PY
  cat "$REPORT.tmp"; rm -f "$REPORT.tmp"
} > "$REPORT"

echo
sed -n '1,14p' "$REPORT"
echo
echo "full report: $REPORT"
echo "work files : $WORK"
