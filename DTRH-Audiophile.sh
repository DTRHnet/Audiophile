#!/data/data/com.termux/files/usr/bin/env bash

# :: 
# :: DTRH-Audiophile.sh
# ::   A real-time audio to text solution for Android+Termux
# :: 
# :: - KBS < admin [at] dtrh [dot] net >
# :: - DTRH.net
# ::

# --- CONFIGURATION ---------------------------------------------------------
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE="$DIR/DTRH-Audiophile.pid"
LOGFILE="$DIR/DTRH-Audiophile.log"
WORK="$HOME/storage/shared/Obsidian/transcripts"
MODEL="$HOME/whisper.cpp/models/ggml-tiny.en.bin"
INTERVAL=30   # seconds per slice
NOTIF_ID=1    # Termux notification ID

mkdir -p "$WORK"
TODAY=$(date +%F)
DAILY_MD="$WORK/$TODAY.md"

# --- LOGGING FUNCTIONS -----------------------------------------------------
declare -A _LEVELS=( ["ERROR"]=0 ["INFO"]=1 ["DEBUG"]=2 )
LOG_LEVEL="${LOG_LEVEL:-INFO}"

printf "\n=== %s ===\n" "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOGFILE"
log() {
  local level="$1"; shift
  local msg="$*"
  local now="$(date '+%H:%M:%S')"
  if (( _LEVELS["$level"] <= _LEVELS["$LOG_LEVEL"] )); then
    printf "[%s] [%s] %s\n" "$now" "$level" "$msg" | tee -a "$LOGFILE"
  fi
}
log_error() { log ERROR "$*"; }
log_info()  { log INFO  "$*"; }
log_debug() { log DEBUG "$*"; }

# --- SINGLETON LOCK --------------------------------------------------------
if [[ -e "$PIDFILE" ]]; then
  oldpid=$(<"$PIDFILE")
  if kill -0 "$oldpid" 2>/dev/null; then
    log_error "Already running (PID $oldpid). Exiting."
    exit 1
  else
    log_info "Removing stale PID file."
    rm -f "$PIDFILE"
  fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

# --- PREAMBLE: FOREGROUND SIGNALS & WAKELOCK --------------------------------
# Show persistent notification
#termux-notification --id $NOTIF_ID \
#  --title "DTRH-Audiophile" \
#  --content "Recording every $INTERVAL seconds" \
#  --ongoing
# Acquire wakelock to keep CPU running
termux-wake-lock

# --- GRACEFUL SHUTDOWN -----------------------------------------------------
cleanup() {
  log_info "Cleanup: finalizing recording..."
  termux-microphone-record -q 2>/dev/null || true
  wait
  # Release wakelock and remove notification
  termux-wake-unlock
  termux-notification-remove --id $NOTIF_ID
  log_info "Exit."
}
trap cleanup SIGINT SIGTERM

# --- TRANSCRIPTION ---------------------------------------------------------
transcribe() {
  local base="$1"
  local m4a="$base.m4a"
  local wav="$base.wav"
  local txt="$base.txt"

  log_debug "Checking audio file $m4a"
  [[ -s "$m4a" ]] || { log_error "No audio: $m4a"; return; }

  log_info "Converting $m4a -> $wav"
  if ! ffmpeg -y -loglevel error -i "$m4a" -ar 16000 -ac 1 "$wav"; then
    log_error "FFmpeg failed for $m4a"
    return
  fi
  [[ -s "$wav" ]] || { log_error "Empty WAV: $wav"; return; }

  log_info "Transcribing $wav -> $txt"
  if ! "$HOME/whisper.cpp/build/bin/whisper-cli" \
       -m "$MODEL" -f "$wav" -otxt -of "$base"; then
    log_error "whisper-cli failed for $wav"
    return
  fi

  if [[ -s "$txt" ]]; then
    log_info "Appending transcript to $DAILY_MD"
    printf '## %s\n' "$(date '+%H:%M:%S')" >> "$DAILY_MD"
    cat "$txt" >> "$DAILY_MD"
    printf '\n---\n' >> "$DAILY_MD"
  else
    log_error "Empty transcript: $txt"
  fi

  log_debug "Cleaning up $m4a, $wav, $txt"
  rm -f "$m4a" "$wav" "$txt"
}

# --- MAIN LOOP -------------------------------------------------------------
log_info "Starting continuous ${INTERVAL}s recording"
while true; do
  ts=$(date +%Y%m%d_%H%M%S)
  base="$WORK/segment_${ts}"

  log_debug "Launching recorder for $base.m4a"
  termux-microphone-record -f "$base.m4a" -l 0 &
  rec_pid=$!

  log_debug "Sleeping $INTERVAL seconds"
  sleep "$INTERVAL"

  log_debug "Stopping recorder (PID $rec_pid)"
  termux-microphone-record -q
  wait "$rec_pid"

  log_debug "Spawning transcription job"
  transcribe "$base" &
done
