#!/data/data/com.termux/files/usr/bin/env bash

# ::
# :: DTRH-Audiophile.sh
# ::   A real-time audio to text logger for Termux (Android)
# ::   Version: 2.0.0
# ::
# ::   Author: KBS - DTRH.net
# :: --------------------------------------------------------------------

# --- ASCII BANNER ----------------------------------------------------------
cat <<'EOF'

  ___  _   _______ _____ ___________ _   _ _____ _      _____
 / _ \| | | |  _  \_   _|  _  | ___ \ | | |_   _| |    |  ___|
/ /_\ \ | | | | | | | | | | | | |_/ / |_| | | | | |    | |__
|  _  | | | | | | | | | | | | |  __/|  _  | | | | |    |  __|
| | | | |_| | |/ / _| |_\ \_/ / |   | | | |_| |_| |____| |___
\_| |_/\___/|___/  \___/ \___/\_|   \_| |_/\___/\_____/\____/

------------------------[ DTRH.NET ]-------------------------
 admin[AT]dtrh[DOT]net                            May 05,2025
 KBS
. . . . . . . . . . . . . . . . . . . . . . . . . . . . . . .

EOF


DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$1" == "--tail" ]]; then
  tail -F "$DIR/DTRH-Audiophile.log"
  exit 0
fi

# --- CONFIGURATION ---------------------------------------------------------
PIDFILE="$DIR/DTRH-Audiophile.pid"
LOGFILE="$DIR/DTRH-Audiophile.log"
WORK="$HOME/storage/shared/Obsidian/transcripts"
MODEL="$HOME/whisper.cpp/models/ggml-tiny.en.bin"
INTERVAL=30
NOTIF_ID=1

mkdir -p "$WORK"
TODAY=$(date +%F)
DAILY_MD="$WORK/$TODAY.md"

# --- COLOR DEFINITIONS -----------------------------------------------------
RED='\033[0;31m'
GRN='\033[0;32m'
BLU='\033[0;34m'
MAG='\033[0;35m'
YEL='\033[1;33m'
NC='\033[0m' # No Color


# --- LOGGING FUNCTIONS -----------------------------------------------------
declare -A _LEVELS=( ["ERROR"]=0 ["WARN"]=1 ["INFO"]=2 ["DEBUG"]=3 )
LOG_LEVEL="${LOG_LEVEL:-DEBUG}"

log() {
  local level="$1"; shift
  local msg="$*"
  local now="$(date '+%H:%M:%S')"
  local color

  case "$level" in
    ERROR) color="$RED";;
    WARN)  color="$YEL";;
    INFO)  color="$GRN";;
    DEBUG) color="$BLU";;
    *)     color="$NC";;
  esac

  if (( _LEVELS["$level"] <= _LEVELS["$LOG_LEVEL"] )); then
    printf "${color}[%s] [%s] %s${NC}\n" "$now" "$level" "$msg" | tee -a "$LOGFILE"
  fi
}

log_error() { log ERROR "$@"; }
log_warn()  { log WARN  "$@"; }
log_info()  { log INFO  "$@"; }
log_debug() { log DEBUG "$@"; }

shorten_path() {
  local path="$1"
  echo "${path/$HOME/\$HOME}"
}

show_settings() {
  echo -e "\n${MAG}========= DTRH-Audiophile Settings =========${NC}"

  # Apply shortening for display
  local sDIR=$(shorten_path "$DIR")
  local sPIDFILE=$(shorten_path "$PIDFILE")
  local sLOGFILE=$(shorten_path "$LOGFILE")
  local sWORK=$(shorten_path "$WORK")
  local sMODEL=$(shorten_path "$MODEL")
  local sDAILY=$(shorten_path "$DAILY_MD")

  # Two-column formatted output
  printf "${YEL}%-20s${NC}: %s\n"  "Log File" "$sLOGFILE"
  printf "${YEL}%-20s${NC}: %-40s\n" "PID File" "$sPIDFILE"
  printf "${YEL}%-20s${NC}: %s\n"  "Transcript Dir" "$sWORK"
  printf "${YEL}%-20s${NC}: %-40s\n" "Model Path" "$sMODEL"
  printf "${YEL}%-20s${NC}: %s\n"  "Interval (sec)" "$INTERVAL"
  printf "${YEL}%-20s${NC}: %-40s\n" "Today File" "$sDAILY"
  printf "${YEL}%-20s${NC}: %s\n"  "Script PID" "$$"

  echo -e "${MAG}=============================================${NC}\n"
}

show_settings

# --- PID CHECK & SINGLETON LOCK --------------------------------------------
if [[ -e "$PIDFILE" ]]; then
  oldpid=$(<"$PIDFILE")
  if kill -0 "$oldpid" 2>/dev/null; then
    log_warn "Script already running with PID $oldpid"
    printf "${YEL}Kill it and restart? [y/N]: ${NC}"
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      kill "$oldpid" && rm -f "$PIDFILE"
      log_info "Old process terminated."
    else
      log_info "Aborting."
      exit 0
    fi
  else
    log_info "Stale PID found. Cleaning up."
    rm -f "$PIDFILE"
  fi
fi

# --- SET PID AND TRAP EXIT -------------------------------------------------
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"; cleanup' EXIT


# --- GRACEFUL SHUTDOWN FUNCTION --------------------------------------------
cleanup() {
  log_info "Cleanup: Finalizing recording session."
  termux-microphone-record -q 2>/dev/null || true
  termux-wake-unlock
  termux-notification-remove --id $NOTIF_ID
  log_info "Wakelock released and notification cleared."
  log_info "Goodbye."
}

# --- WAKELOCK & NOTIFICATION -----------------------------------------------
termux-wake-lock
# Optional: enable notification if desired
# termux-notification --id $NOTIF_ID --title "DTRH-Audiophile" --content "Recording..." --ongoing

# --- TRANSCRIPTION FUNCTION ------------------------------------------------
transcribe() {
  local base="$1"
  local m4a="$base.m4a"
  local wav="$base.wav"
  local txt="$base.txt"

  log_debug "Verifying audio exists: $m4a"
  [[ -s "$m4a" ]] || { log_error "No audio file found: $m4a"; return; }

  log_info "Converting to WAV: $m4a → $wav"
  if ! ffmpeg -y -loglevel error -i "$m4a" -ar 16000 -ac 1 "$wav"; then
    log_error "FFmpeg failed for $m4a"
    return
  fi

  [[ -s "$wav" ]] || { log_error "Conversion produced empty WAV."; return; }

  log_info "Transcribing audio: $wav"
  if ! "$HOME/whisper.cpp/build/bin/whisper-cli" \
       -m "$MODEL" -f "$wav" -otxt -of "$base"; then
    log_error "Transcription failed for $wav"
    return
  fi

  if [[ -s "$txt" ]]; then
    log_info "Appending transcription to journal: $DAILY_MD"
    printf '\n## %s\n' "$(date '+%H:%M:%S')" >> "$DAILY_MD"
    cat "$txt" >> "$DAILY_MD"
    printf '\n---\n' >> "$DAILY_MD"
  else
    log_error "Transcript empty: $txt"
  fi

  log_debug "Cleaning up temporary files."
  rm -f "$m4a" "$wav" "$txt"
}

# --- MAIN LOOP -------------------------------------------------------------
log_info "Recording started. Slice interval: ${INTERVAL}s"

while true; do
  ts=$(date +%Y%m%d_%H%M%S)
  base="$WORK/segment_${ts}"

  log_debug "Starting new recording slice: $base.m4a"
  termux-microphone-record -f "$base.m4a" -l 0 &
  rec_pid=$!

  sleep "$INTERVAL"

  log_debug "Stopping recording process (PID: $rec_pid)"
  termux-microphone-record -q
  wait "$rec_pid"

  log_debug "Launching transcription for $base"
  transcribe "$base" &
done
