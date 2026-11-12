#!/data/data/com.termux/files/usr/bin/bash

# ::
# :: audiophile-calibrate.sh
# ::   Measures this room + this microphone and suggests a DTRH_SPEECH_DB.
# ::
# ::   Records SECONDS of audio, cuts it into 100 ms blocks and reports the
# ::   dBFS distribution. Run it twice: once in silence, once while talking,
# ::   and put the suggested value between the two clusters.
# ::
# ::   usage: ./audiophile-calibrate.sh [seconds]   (default 20)
# :: --------------------------------------------------------------------

set -o pipefail

SECONDS_TO_RUN="${1:-20}"
TMPD="${TMPDIR:-$HOME/tmp}"
OUT="$TMPD/audiophile-calib-$$.ogg"

command -v termux-microphone-record >/dev/null || { echo "termux-api missing"; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg missing"; exit 1; }
command -v python3 >/dev/null || { echo "python3 missing"; exit 1; }

cleanup() {
  termux-microphone-record -q >/dev/null 2>&1
  rm -f "$OUT"
}
trap cleanup EXIT INT TERM

echo "recording ${SECONDS_TO_RUN}s - stay quiet for half of it, then talk, or run it twice"
termux-microphone-record -q >/dev/null 2>&1
sleep 0.3
termux-microphone-record -e opus -b 32 -r 16000 -c 1 -f "$OUT" -l 0 >/dev/null 2>&1
sleep "$SECONDS_TO_RUN"
termux-microphone-record -q >/dev/null 2>&1
sleep 0.6

echo "analysing $(stat -c %s "$OUT" 2>/dev/null) bytes"
ffmpeg -hide_banner -nostdin -loglevel error -f ogg -i "$OUT" \
       -vn -ac 1 -ar 16000 -f s16le - 2>/dev/null \
| python3 -u - <<'PY'
import math, struct, sys

SR, BLOCK = 16000, 1600
data = sys.stdin.buffer.read()
blocks = []
for start in range(0, len(data) - BLOCK * 2 + 1, BLOCK * 2):
    samples = struct.unpack("<%dh" % BLOCK, data[start:start + BLOCK * 2])
    total = sum(s * s for s in samples)
    blocks.append(20 * math.log10(math.sqrt(total / BLOCK) / 32768) if total else -91.0)

if not blocks:
    print("no audio decoded - is the microphone permission granted?")
    sys.exit(1)

blocks.sort()
def q(p):
    return blocks[min(len(blocks) - 1, int(len(blocks) * p))]

print("blocks: %d (100 ms each, %.1fs of audio)" % (len(blocks), len(blocks) / 10))
for name, p in (("min", 0.0), ("p10", 0.10), ("p50", 0.50), ("p90", 0.90), ("max", 1.0)):
    print("  %-4s %7.1f dB" % (name, q(p) if p < 1.0 else blocks[-1]))

quiet, loud = q(0.10), q(0.95)
if blocks[0] <= -90.0 and blocks[-1] <= -90.0:
    print("\nALL BLOCKS ARE DIGITAL SILENCE (-91 dB).")
    print("Open the Termux app once, grant the microphone permission and retry -")
    print("Android hands silent buffers to capture that it does not allow.")
    sys.exit(2)

suggest = max(-70.0, min(-40.0, quiet + 15.0))
print("\nquiet cluster p10 = %.1f dB | loud cluster p95 = %.1f dB" % (quiet, loud))
if loud - quiet < 10:
    print("the two clusters are only %.1f dB apart - record silence and speech" % (loud - quiet))
    print("in separate runs for a cleaner reading")
print("suggested:  DTRH_SPEECH_DB=%.0f" % suggest)
print("i.e.        DTRH_SPEECH_DB=%.0f ./DTRH-Audiophile.sh" % suggest)
PY
