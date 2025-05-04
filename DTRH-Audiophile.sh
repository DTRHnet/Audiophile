#!/data/data/com.termux/files/usr/bin/env bash

# :: 
# :: DTRH-Audiophile.sh
# ::   A real-time audio to text solution for Android+Termux
# :: 
# :: - KBS < admin [at] dtrh [dot] net >
# :: - DTRH.net
# ::

set -euo pipefail

# --- DECLARATIONS -------------------------------------------------------------
WORK="$HOME/storage/shared/Obsidian/transcripts"
MODEL="$HOME/whisper.cpp/models/ggml-medium.en.bin"
INTERVAL=30            # seconds per segment
mkdir -p "$WORK"
TODAY=$(date +%F)
DAILY_MD="$WORK/$TODAY.md"

# --- CLEANUP GRACEFULLY ---------------------------------------------------
cleanup() {
  echo "[*] Finalizing any ongoing recording..."
  termux-microphone-record -q 2>/dev/null || true   # ask recorder to close file 5
  wait                                              # wait for background jobs
  echo "[*] Exiting."
}
trap cleanup SIGINT SIGTERM EXIT

# --- TRANSCRIBE -----------------------------------------------------
transcribe() {
  local base="$1"      # /path/.../segment_TIMESTAMP
  local m4a="${base}.m4a"
  local wav="${base}.wav"
  local txt="${base}.txt"

  # 1) skip empty or missing audio
  [[ -s "$m4a" ]] || { echo "[!] No audio: $m4a"; return; }

  # 2) convert to 16 kHz mono WAV
  ffmpeg -y -loglevel error -i "$m4a" -ar 16000 -ac 1 "$wav" \
    || { echo "[!] FFmpeg failed for $m4a"; return; }  # whisper.cpp only supports WAV 6

  [[ -s "$wav" ]] || { echo "[!] Empty WAV: $wav"; return; }

  # 3) run Whisper with explicit binary path & output flags
  echo "[*] Transcribing $wav → $txt"
  "$HOME/whisper.cpp/build/bin/whisper-cli" \
    -m "$MODEL" -f "$wav" -otxt -of "$base" \
    || { echo "[!] whisper-cli failed"; return; }    # use -otxt/-of to avoid truncation issues 7

  # 4) append to daily note if transcription non‑empty
  if [[ -s "$txt" ]]; then
    printf '## %s\n' "$(date '+%H:%M:%S')" >> "$DAILY_MD"
    cat "$txt" >> "$DAILY_MD"
    printf '\n---\n'   >> "$DAILY_MD"
  else
    echo "[!] Empty transcript for $wav"
  fi

  # 5) clean up slice artifacts
  rm -f "$m4a" "$wav" "$txt"
}

# --- MAIN LOOP ----------------------------------------------------------
echo "[*] Continuous ${INTERVAL}s slices — press Ctrl+C to stop."
while true; do
  ts=$(date +%Y%m%d_%H%M%S)
  base="$WORK/segment_${ts}"

  # start recording slice (non‑blocking) at high fidelity
  termux-microphone-record -f "${base}.m4a" -l 0 &  # endless, must be -q’d to stop 8
  rec_pid=$!

  sleep "$INTERVAL"

  # stop that slice, then transcribe in background
  termux-microphone-record -q                      # gracefully close .m4a 9
  wait "$rec_pid"

  transcribe "$base" &
done
