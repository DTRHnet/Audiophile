#!/data/data/com.termux/files/usr/bin/bash

# ::
# :: audiophile-model-bench.sh
# ::   A/B your whisper models on this phone, with this microphone path.
# ::
# ::   Builds speech clips by having the phone speak known sentences and
# ::   record them itself, then transcribes every clip with every model and
# ::   reports word error rate, latency and the realtime factor. The point is
# ::   not an abstract benchmark: it answers "can this model keep up with how
# ::   much I actually talk", which is what decides the default.
# ::
# ::   usage:
# ::     ./audiophile-model-bench.sh                 # every ggml-*.bin it finds
# ::     ./audiophile-model-bench.sh M1.bin M2.bin   # specific models
# ::     ./audiophile-model-bench.sh --server        # also time whisper-server
# ::
# ::   Clips are recorded through the microphone, so the room must be quiet
# ::   and nothing else should be talking. Roughly 1 minute per model.
# :: --------------------------------------------------------------------

set -o pipefail
export PATH="/data/data/com.termux/files/usr/bin:$PATH"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHISPER="${DTRH_WHISPER:-$HOME/whisper.cpp/build/bin/whisper-cli}"
SERVER_BIN="$(dirname "$WHISPER")/whisper-server"
TMPD="${TMPDIR:-$HOME/tmp}"
WORK="$TMPD/model-bench"
SILERO="${DTRH_WHISPER_VAD:-auto}"
USE_SERVER=0
MODELS=()

for a in "$@"; do
  case "$a" in
    --server) USE_SERVER=1;;
    -h|--help) sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# :: \?//'; exit 0;;
    *) MODELS+=("$a");;
  esac
done

# --- the sentences the phone will speak and then must read back ------------
SENTENCES=(
"The audiophile pipeline records audio at sixteen kilohertz and writes markdown notes."
"Schedule the meeting with doctor ramirez on thursday at half past nine."
"Quarterly revenue increased by twelve percent to four point three million dollars."
"Reticulated splines and ubiquitous paradigms are terrible filler words."
"Remember to buy milk, eggs, and a new usb cable."
)

have() { command -v "$1" >/dev/null 2>&1; }
have ffmpeg || { echo "ffmpeg missing"; exit 1; }
have termux-microphone-record || { echo "termux-api missing"; exit 1; }
[[ -x "$WHISPER" ]] || { echo "whisper-cli not found at $WHISPER"; exit 1; }

mkdir -p "$WORK"
rm -f "$WORK"/*.wav "$WORK"/*.txt 2>/dev/null

# --- build clips -----------------------------------------------------------
echo "== recording ${#SENTENCES[@]} clips (the phone speaks, the phone records) =="
i=0
for s in "${SENTENCES[@]}"; do
  i=$((i + 1))
  ogg="$WORK/c$i.ogg"
  termux-microphone-record -q >/dev/null 2>&1; sleep 0.3
  termux-microphone-record -e opus -b 32 -r 16000 -c 1 -f "$ogg" -l 0 >/dev/null 2>&1
  termux-tts-speak -r 1.0 "$s" >/dev/null 2>&1
  sleep 1
  termux-microphone-record -q >/dev/null 2>&1; sleep 0.5
  ffmpeg -hide_banner -loglevel error -y -f ogg -i "$ogg" -ar 16000 -ac 1 "$WORK/c$i.wav"
  printf '  clip %d: %.1fs\n' "$i" "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WORK/c$i.wav")"
  rm -f "$ogg"
done
printf '%s\n' "${SENTENCES[@]}" > "$WORK/truth.txt"

# --- pick models -----------------------------------------------------------
if (( ${#MODELS[@]} == 0 )); then
  for d in "$HOME/whisper.cpp/models" "${DTRH_MODEL_DIR:-/nonexistent}" \
           /storage/*/audiophile/models; do
    [[ -d "$d" ]] || continue
    for m in "$d"/ggml-*.bin; do
      [[ -s "$m" ]] || continue
      case "$m" in *for-tests*|*silero*) continue;; esac
      MODELS+=("$m")
    done
  done
fi
(( ${#MODELS[@]} )) || { echo "no ggml-*.bin models found"; exit 1; }
echo "== models: ${#MODELS[@]} =="
for m in "${MODELS[@]}"; do printf '  %-52s %6s MB\n' "$(basename "$m")" "$(( $(stat -c %s "$m") / 1048576 ))"; done

vad_flags=()
if [[ "$SILERO" != "off" ]]; then
  f="$SILERO"
  if [[ "$SILERO" == "auto" ]]; then
    f=""
    for c in "$HOME"/whisper.cpp/models/*silero*.bin; do [[ -s "$c" ]] && { f="$c"; break; }; done
  fi
  [[ -s "$f" ]] && vad_flags=(--vad -vm "$f" -vt 0.5)
fi

# --- run -------------------------------------------------------------------
echo
printf '%-34s %6s %7s %8s %8s %8s\n' MODEL WER MEAN_MS RT_FACTOR LOAD_MS TEXT
for m in "${MODELS[@]}"; do
  tag="$(basename "$m" .bin)"
  # cold load time, on its own
  t0=$(date +%s%N)
  "$WHISPER" -m "$m" -f "$WORK/c1.wav" -otxt -of "$WORK/load_$tag" -t 4 -np -nt -l en >/dev/null 2>&1
  t1=$(date +%s%N)
  cold=$(( (t1 - t0) / 1000000 ))

  python3 - "$WORK" "$m" "$WHISPER" "$tag" "$cold" "${#SENTENCES[@]}" "${vad_flags[@]}" <<'PY' > "$WORK/row_$tag.txt"
import os, re, subprocess, sys, time
work, model, whisper, tag, cold, n = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]), int(sys.argv[6])
vad = sys.argv[7:]
truth = [l.strip() for l in open(os.path.join(work, "truth.txt"))]
def toks(s): return re.sub(r"[^a-z0-9 ]", " ", s.lower()).split()
def edits(a, b):
    d = [[0]*(len(b)+1) for _ in range(len(a)+1)]
    for i in range(len(a)+1): d[i][0] = i
    for j in range(len(b)+1): d[0][j] = j
    for i in range(1, len(a)+1):
        for j in range(1, len(b)+1):
            d[i][j] = min(d[i-1][j]+1, d[i][j-1]+1, d[i-1][j-1] + (a[i-1] != b[j-1]))
    return d[-1][-1]
tot_e = tot_w = 0; times = []; audio = 0.0; texts = []
for i in range(1, n+1):
    wav = os.path.join(work, "c%d.wav" % i)
    audio += float(subprocess.run(["ffprobe","-v","error","-show_entries","format=duration","-of","csv=p=0",wav],
                                  capture_output=True, text=True).stdout.strip() or 0)
    out = os.path.join(work, "o_%s_%d" % (tag, i))
    t = time.time()
    subprocess.run([whisper, "-m", model, "-f", wav, "-otxt", "-of", out, "-t", "4", "-np", "-nt", "-l", "en"] + vad,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    times.append((time.time() - t) * 1000)
    txt = open(out + ".txt").read().replace("\n", " ").strip() if os.path.exists(out + ".txt") else ""
    texts.append(txt)
    a, b = toks(truth[i-1]), toks(txt)
    tot_e += edits(a, b); tot_w += len(a)
wer = 100.0 * tot_e / max(1, tot_w)
mean_ms = sum(times) / len(times)
rt = (mean_ms / 1000.0) / (audio / n) if audio else 0
print("%-34s %5.1f%% %6.0f %7.2fx %7d  %s" % (tag, wer, mean_ms, rt, cold, texts[0][:50]))
PY
  cat "$WORK/row_$tag.txt"
done

echo
echo "RT_FACTOR = transcription seconds per second of audio (lower is better;"
echo "            above 1.00 cannot keep up with continuous speech)"
echo "Note: clips are TTS through the phone's own speaker, so absolute accuracy"
echo "      is optimistic; the comparison between models is what matters."

# --- optional: resident server --------------------------------------------
if (( USE_SERVER )) && [[ -x "$SERVER_BIN" ]]; then
  echo
  echo "== whisper-server (model loaded once) =="
  port=8099
  for m in "${MODELS[@]}"; do
    tag="$(basename "$m" .bin)"
    "$SERVER_BIN" -m "$m" --host 127.0.0.1 --port "$port" -t 4 >/dev/null 2>&1 &
    spid=$!
    for i in $(seq 1 60); do curl -s --max-time 1 -o /dev/null "http://127.0.0.1:$port/" && break; sleep 4; done
    t0=$(date +%s%N)
    curl -s --max-time 300 -F "file=@$WORK/c1.wav" "http://127.0.0.1:$port/inference" >/dev/null 2>&1
    t1=$(date +%s%N)
    printf '  %-46s first request %6sms\n' "$tag" $(( (t1-t0)/1000000 ))
    kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
  done
fi

echo
echo "clips kept in $WORK (delete when done)"
