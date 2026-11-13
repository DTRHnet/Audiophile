#!/data/data/com.termux/files/usr/bin/env bash

# ::
# :: DTRH-Audiophile.sh
# ::   A real-time audio to text logger for Termux (Android)
# ::   Version: 3.2.1
# ::
# ::   Author: KBS - DTRH.net
# :: --------------------------------------------------------------------
# ::   v3 "silence gating" rewrite
# ::
# ::   v2 recorded fixed 30-second slices and transcribed every one of them,
# ::   silence included. Whisper answers silence with invented text ("you",
# ::   "Thank you.") and burned a full whisper pass every 30s whether anyone
# ::   was talking or not.
# ::
# ::   v3 records ONE continuous Ogg/Opus stream, decodes it through a single
# ::   long-lived ffmpeg, and lets audiophile-vad.py decide where an utterance
# ::   starts and ends from the microphone's own noise floor. Whisper is only
# ::   started when someone actually spoke, on audio that starts PREROLL ms
# ::   before the first word and stops ENDSILENCE ms after the last one.
# ::
# ::   Recording is never chopped mid-sentence, so no words are lost between
# ::   slices, and a silent room costs ~1% of one core instead of a whisper
# ::   run every 30 seconds.
# :: --------------------------------------------------------------------

# --- ASCII BANNER ----------------------------------------------------------
cat <<'EOF'

  ___  _   _______ _____ ___________ _   _ _____ _      _____
 / _ \| | | |  _  \_   _|  _  | ___ \ | | |_   _| |    |  ___|
/ /_\ \ | | | | | | | | | | | | |_/ / |_| | | | | |    | |__
|  _  | | | | | | | | | | | |  __/|  _  | | | | |    |  __|
| | | | |_| | |/ / _| |_\ \_/ / |   | | | |_| |_| |____| |___
\_| |_/\___/|___/  \___/ \___/\_|   \_| |_/\___/\_____/\____/

------------------------[ DTRH.NET ]-------------------------
 admin[AT]dtrh[DOT]net                            May 05,2025
 KBS                              silence gating: v3.2.1
. . . . . . . . . . . . . . . . . . . . . . . . . . . . . . .

EOF

set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAD_PY="$DIR/audiophile-vad.py"
FOLLOW_PY="$DIR/audiophile-follow.py"

# --- CONFIGURATION ---------------------------------------------------------
PIDFILE="$DIR/DTRH-Audiophile.pid"
LOGFILE="$DIR/DTRH-Audiophile.log"
WORK="${DTRH_WORK:-$HOME/storage/shared/Obsidian/transcripts}"
MODEL="${DTRH_MODEL:-$HOME/whisper.cpp/models/ggml-tiny.en.bin}"
WHISPER="${DTRH_WHISPER:-$HOME/whisper.cpp/build/bin/whisper-cli}"

# capture: one continuous stream, readable while it is being written
CAPTURE_DIR="${DTRH_CAPTURE_DIR:-${TMPDIR:-$HOME/tmp}/audiophile}"
CAPTURE_ENC="${DTRH_ENC:-opus}"          # opus => Ogg container (streamable)
CAPTURE_BITRATE="${DTRH_BITRATE:-32}"    # kbps
CAPTURE_RATE="${DTRH_RATE:-16000}"       # Hz requested from the encoder

# voice activity detection (silence gating)
SPEECH_DB="${DTRH_SPEECH_DB:--55}"       # a block louder than this is speech
MARGIN_DB="${DTRH_MARGIN_DB:-10}"        # ...or this far above the noise floor
PREROLL_MS="${DTRH_PREROLL_MS:-2000}"    # keep this much audio before the onset
END_SILENCE_MS="${DTRH_END_SILENCE_MS:-1500}"  # silence that closes an utterance
MIN_SPEECH_MS="${DTRH_MIN_SPEECH_MS:-500}"
MIN_VOICED_DB="${DTRH_MIN_VOICED_DB:--50}"   # mean level of the voiced part
WARMUP_MS="${DTRH_WARMUP_MS:-1500}"          # ignore the recorder start transient
MAX_SEGMENT_MS="${DTRH_MAX_SEGMENT_MS:-120000}"

# housekeeping
ROTATE_IDLE_S="${DTRH_ROTATE_IDLE_S:-90}"   # rotate the capture file after this much silence
ROTATE_MIN_AGE_S="${DTRH_ROTATE_MIN_AGE_S:-120}"
ROTATE_MAX_MB="${DTRH_ROTATE_MAX_MB:-64}"
THREADS="${DTRH_THREADS:-4}"
# Keep the utterance audio instead of deleting it. Useful for re-transcribing
# real speech with a different model later. 0 = delete (default), 1 = keep.
RETAIN_AUDIO="${DTRH_RETAIN_AUDIO:-0}"
AUDIO_DIR="${DTRH_AUDIO_DIR:-}"          # empty = auto-detect the SD card
RETAIN_DAYS="${DTRH_RETAIN_DAYS:-0}"     # 0 = keep forever, otherwise prune
RETAIN_MIN_FREE_MB="${DTRH_RETAIN_MIN_FREE_MB:-500}"
# Whisper's own VAD (Silero): a second gate after the energy VAD. Measured on
# this device: pink noise and tones produce "" in ~0.4s instead of
# "(dramatic music)"/"(beeping)" in ~3.5s, while real speech is untouched.
WHISPER_VAD="${DTRH_WHISPER_VAD:-auto}"       # auto | off | path/to/silero.bin
WHISPER_VAD_THR="${DTRH_WHISPER_VAD_THRESHOLD:-0.5}"
# cli    : one whisper-cli process per utterance (loads the model every time)
# server : whisper-server resident on 127.0.0.1, model loaded once (measured
#          ~390ms less per utterance on this device; falls back to cli)
ENGINE="${DTRH_ENGINE:-cli}"
SERVER_PORT="${DTRH_SERVER_PORT:-8087}"
# 1 = transcribe in a worker fed by a queue, so the VAD event loop (levels,
# rotation, notifications) never blocks behind whisper
ASYNC="${DTRH_ASYNC:-1}"
NOTIFY="${DTRH_NOTIFY:-1}"
AUDIT="${DTRH_AUDIT:-1}"
NOTIF_ID=1

REPO_LOG_LEVEL="${LOG_LEVEL:-INFO}"
TODAY=""
DAILY_MD=""

# --- COLOR DEFINITIONS -----------------------------------------------------
RED='\033[0;31m'; GRN='\033[0;32m'; BLU='\033[0;34m'
MAG='\033[0;35m'; YEL='\033[1;33m'; CYN='\033[0;36m'; NC='\033[0m'

declare -A _LEVELS=( ["ERROR"]=0 ["WARN"]=1 ["INFO"]=2 ["DEBUG"]=3 )

# --- LOGGING ---------------------------------------------------------------
log() {
  local level="$1"; shift
  local msg="$*" color now
  now="$(date '+%H:%M:%S')"
  (( _LEVELS["$level"] <= _LEVELS["$REPO_LOG_LEVEL"] )) || return 0
  case "$level" in
    ERROR) color="$RED";; WARN) color="$YEL";; INFO) color="$GRN";; *)
           color="$BLU";;
  esac
  printf "${color}[%s] [%s] %s${NC}\n" "$now" "$level" "$msg"
  printf "[%s] [%s] %s\n" "$(date '+%F %H:%M:%S')" "$level" "$msg" >>"$LOGFILE"
}
log_error() { log ERROR "$@"; }
log_warn()  { log WARN  "$@"; }
log_info()  { log INFO  "$@"; }
log_debug() { log DEBUG "$@"; }
die() { log_error "$@"; exit 1; }

shorten_path() { echo "${1/$HOME/\$HOME}"; }

kv_get() { # kv_get key "k=v k=v ..."
  local want="$1"; shift
  local kv
  for kv in $*; do
    case "$kv" in "$want"=*) printf '%s' "${kv#*=}"; return 0;; esac
  done
  return 1
}

show_settings() {
  echo -e "\n${MAG}========= DTRH-Audiophile v3 Settings =========${NC}"
  printf "${YEL}%-22s${NC}: %s\n" "Transcript Dir"  "$(shorten_path "$WORK")"
  printf "${YEL}%-22s${NC}: %s\n" "Model"           "$(shorten_path "$MODEL")"
  printf "${YEL}%-22s${NC}: %-40s\n" "VAD thresholds" "speech>${SPEECH_DB}dB or floor+${MARGIN_DB}dB"
  printf "${YEL}%-22s${NC}: %-40s\n" "Utterance window" "preroll ${PREROLL_MS}ms / end-silence ${END_SILENCE_MS}ms"
  printf "${YEL}%-22s${NC}: %-40s\n" "Reject" "voiced<${MIN_SPEECH_MS}ms or <${MIN_VOICED_DB}dB"
  printf "${YEL}%-22s${NC}: %-40s\n" "Max segment"    "$(( MAX_SEGMENT_MS / 1000 ))s"
  printf "${YEL}%-22s${NC}: %-40s\n" "Capture"        "${CAPTURE_ENC} ${CAPTURE_BITRATE}kbps (streamed, no slicing)"
  printf "${YEL}%-22s${NC}: %-40s\n" "Rotate after"   "${ROTATE_IDLE_S}s of silence"
  printf "${YEL}%-22s${NC}: %-40s\n" "Whisper threads" "$THREADS"
  printf "${YEL}%-22s${NC}: %-40s\n" "Whisper VAD"     "$WHISPER_VAD (threshold ${WHISPER_VAD_THR})"
  printf "${YEL}%-22s${NC}: %-40s\n" "Engine / queue"  "${ENGINE} / async=$([ "$ASYNC" = 1 ] && echo on || echo off)"
  printf "${YEL}%-22s${NC}: %-40s\n" "Retain audio"    "$([ "$RETAIN_AUDIO" = 1 ] && echo "yes (${AUDIO_DIR:-auto})" || echo no)"
  printf "${YEL}%-22s${NC}: %-40s\n" "Notifications"  "$([ "$NOTIFY" = 1 ] && echo on || echo off)"
  printf "${YEL}%-22s${NC}: %s\n" "Log File"        "$(shorten_path "$LOGFILE")"
  printf "${YEL}%-22s${NC}: %s\n" "Script PID"      "$$"
  echo -e "${MAG}===============================================${NC}\n"
}

usage() {
  cat <<EOF
usage: $(basename "$0") [options]

  (no argument)     run the transcriber
  --tail            follow the log file
  --stop            stop a running instance
  --status          show whether an instance is running
  --selftest        run the VAD state machine against a synthetic track
  --debug           verbose (DEBUG) logging
  --no-notify       do not touch the notification shade
  --work DIR        transcript output directory
  --model FILE      whisper ggml model
  -h, --help        this text

environment overrides: DTRH_SPEECH_DB DTRH_END_SILENCE_MS DTRH_PREROLL_MS
  DTRH_MIN_SPEECH_MS DTRH_MAX_SEGMENT_MS DTRH_THREADS DTRH_WORK DTRH_MODEL
  DTRH_ENC DTRH_BITRATE DTRH_RATE DTRH_ROTATE_IDLE_S DTRH_NOTIFY LOG_LEVEL
EOF
}

# --- ARGUMENTS -------------------------------------------------------------
SELFTEST=0
while (( $# )); do
  case "$1" in
    --tail)      tail -F "$LOGFILE"; exit 0;;
    --debug)     REPO_LOG_LEVEL=DEBUG;;
    --no-notify) NOTIFY=0;;
    --work)      WORK="$2"; shift;;
    --model)     MODEL="$2"; shift;;
    --selftest)  SELFTEST=1;;
    --stop)
      if [[ -s "$PIDFILE" ]]; then
        pid=$(<"$PIDFILE")
        if kill -0 "$pid" 2>/dev/null; then kill "$pid"; echo "signalled PID $pid"; exit 0; fi
        rm -f "$PIDFILE"; echo "stale pidfile removed"; exit 0
      fi
      echo "not running"; exit 0;;
    --status)
      if [[ -s "$PIDFILE" ]] && kill -0 "$(<"$PIDFILE")" 2>/dev/null; then
        echo "running (PID $(<"$PIDFILE"))"
      else
        echo "not running"
      fi; exit 0;;
    -h|--help)   usage; exit 0;;
    *)           die "unknown option: $1 (try --help)";;
  esac
  shift
done

mkdir -p "$WORK" "$CAPTURE_DIR"
for f in "$LOGFILE"; do : >>"$f"; done
TODAY=$(date +%F)
DAILY_MD="$WORK/$TODAY.md"
AUDIT_JSONL="$WORK/.audiophile/index.jsonl"

have() { command -v "$1" >/dev/null 2>&1; }

# --- SELFTEST: prove the VAD state machine without touching the microphone --
selftest() {
  have ffmpeg || die "ffmpeg missing"
  have python3 || die "python3 missing"
  local t; t="$(mktemp -d)"
  echo "== synthesising 2s silence / 3s tone / 2.5s silence / 1s tone / 2s silence =="
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "sine=frequency=220:sample_rate=16000:duration=3,volume=0.35" \
    -f lavfi -i "sine=frequency=330:sample_rate=16000:duration=1,volume=0.35" \
    -f lavfi -i "anullsrc=r=16000:cl=mono" \
    -filter_complex "[2:a]atrim=0:2[s1];[2:a]atrim=0:2.5[s2];[2:a]atrim=0:2[s3]; \
                     [s1][0:a][s2][1:a][s3]concat=n=5:v=0:a=1,aresample=16000[a]" \
    -map "[a]" -ac 1 -ar 16000 -f s16le "$t/track.raw" 2>/dev/null \
    || { echo "  (fallback: simpler track)"; \
         { head -c 64000 /dev/zero; ffmpeg -hide_banner -loglevel error -f lavfi -i "sine=frequency=220:duration=3" -ac 1 -ar 16000 -f s16le -; \
           head -c 80000 /dev/zero; ffmpeg -hide_banner -loglevel error -f lavfi -i "sine=frequency=330:duration=1" -ac 1 -ar 16000 -f s16le -; \
           head -c 64000 /dev/zero; } > "$t/track.raw"; }
  echo "  track: $(stat -c %s "$t/track.raw") bytes"
  echo "== running the VAD over it =="
  VAD_OUTDIR="$t/out" VAD_TAG=selftest VAD_LEVEL_EVERY_S=99 \
    python3 -u "$VAD_PY" < "$t/track.raw" | sed 's/^/  /'
  local n; n=$(ls "$t/out"/*.wav 2>/dev/null | wc -l)
  echo "== segments written: $n (expected 2) =="
  for f in "$t"/out/*.wav; do
    [[ -e "$f" ]] || continue
    printf '  %-28s %ss audio\n' "$(basename "$f")" \
      "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f")"
  done
  (( n == 2 )) && { echo "SELFTEST PASS"; rm -rf "$t"; return 0; } \
               || { echo "SELFTEST FAIL"; return 1; }
}

if (( SELFTEST )); then selftest; exit $?; fi

# --- PRE-FLIGHT ------------------------------------------------------------
show_settings
have termux-microphone-record || die "termux-api missing: pkg install termux-api"
have ffmpeg                   || die "ffmpeg missing: pkg install ffmpeg"
have python3                  || die "python3 missing: pkg install python"
[[ -f "$VAD_PY" ]]            || die "audiophile-vad.py not found next to this script"
[[ -f "$FOLLOW_PY" ]]         || die "audiophile-follow.py not found next to this script"
[[ -x "$WHISPER" ]]           || die "whisper-cli not found at $(shorten_path "$WHISPER")"
[[ -s "$MODEL" ]]             || die "model not found at $(shorten_path "$MODEL")"

# --- WHISPER VAD (silero) --------------------------------------------------
WHISPER_VAD_FILE=""
if [[ "$WHISPER_VAD" != "off" ]]; then
  if [[ "$WHISPER_VAD" != "auto" ]]; then
    WHISPER_VAD_FILE="$WHISPER_VAD"
  else
    for cand in "$HOME"/whisper.cpp/models/*silero*.bin                 "$(dirname "$WHISPER")"/../models/*silero*.bin; do
      [[ -s "$cand" ]] && { WHISPER_VAD_FILE="$cand"; break; }
    done
  fi
  if [[ -s "$WHISPER_VAD_FILE" ]]; then
    log_info "whisper vad: silero ($(basename "$WHISPER_VAD_FILE"), threshold ${WHISPER_VAD_THR})"
  else
    WHISPER_VAD_FILE=""
    log_warn "no silero model found - non-speech audio will reach whisper and may be invented as text"
    log_warn "point DTRH_WHISPER_VAD at a Silero ggml model (see whisper.cpp models/README.md)"
  fi
fi

# --- RETAINED AUDIO (optional, SD card friendly) ---------------------------
ARCHIVE_OK=0
AUDIO_ROOT=""
if (( RETAIN_AUDIO )); then
  probe_writable() { [[ -d "$1" ]] || return 1; ( : >"$1/.wtest" ) 2>/dev/null && rm -f "$1/.wtest"; }
  if [[ -n "$AUDIO_DIR" ]]; then
    mkdir -p "$AUDIO_DIR" 2>/dev/null
    probe_writable "$AUDIO_DIR" && AUDIO_ROOT="$AUDIO_DIR"
  else
    # first removable volume that accepts writes: /storage/<UUID>/audiophile/audio
    for vol in /storage/*-*; do
      [[ -d "$vol" ]] || continue
      mkdir -p "$vol/audiophile/audio" 2>/dev/null
      probe_writable "$vol/audiophile/audio" && { AUDIO_ROOT="$vol/audiophile/audio"; break; }
    done
  fi
  if [[ -n "$AUDIO_ROOT" ]]; then
    ARCHIVE_OK=1
    log_info "retaining utterance audio in $(shorten_path "$AUDIO_ROOT")"
  else
    log_warn "DTRH_RETAIN_AUDIO=1 but no writable location found - audio will be deleted"
    RETAIN_AUDIO=0
  fi
fi

archive_space_kb() { df -k "$AUDIO_ROOT" 2>/dev/null | awk 'NR==2{print $4}'; }

archive_segment() {  # $1 = wav path; returns 0 if it was archived
  (( ARCHIVE_OK )) || return 1
  local wav="$1"
  local free; free=$(archive_space_kb)
  if [[ -n "$free" ]] && (( free < RETAIN_MIN_FREE_MB * 1024 )); then
    ARCHIVE_OK=0
    log_warn "retained-audio volume below ${RETAIN_MIN_FREE_MB}MB free - archiving off"
    return 1
  fi
  local dest="$AUDIO_ROOT/$(date +%F)"
  mkdir -p "$dest" || return 1
  mv -f "$wav" "$dest/" 2>/dev/null || return 1
  ARCHIVED_PATH="$dest/$(basename "$wav")"
  log_debug "archived $(basename "$wav")"
  return 0
}

prune_archive() {
  (( ARCHIVE_OK && RETAIN_DAYS > 0 )) || return 0
  local cutoff; cutoff=$(date -d "-${RETAIN_DAYS} days" +%F 2>/dev/null) || return 0
  local d
  for d in "$AUDIO_ROOT"/*/; do
    [[ -d "$d" ]] || continue
    local day; day=$(basename "$d")
    [[ "$day" < "$cutoff" ]] && { rm -rf "$d"; log_info "pruned archived audio ${day}"; }
  done
}

# --- PID LOCK --------------------------------------------------------------
if [[ -e "$PIDFILE" ]]; then
  oldpid=$(<"$PIDFILE")
  if kill -0 "$oldpid" 2>/dev/null; then
    log_warn "Script already running with PID $oldpid"
    printf "${YEL}Kill it and restart? [y/N]: ${NC}"
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      kill "$oldpid"; rm -f "$PIDFILE"; sleep 1
      log_info "Old process terminated."
    else
      log_info "Aborting."; exit 0
    fi
  else
    log_info "Stale PID found. Cleaning up."
    rm -f "$PIDFILE"
  fi
fi
echo $$ >"$PIDFILE"

# --- RUNTIME STATE ---------------------------------------------------------
PIPE_PG=""
EVFIFO="$CAPTURE_DIR/events.fifo"
LIVE=""
LIVE_STARTED=0
LIVE_EPOCH=0
RECORDING=0
TOTAL_SEGMENTS=0
TOTAL_MS=0
LAST_NOTIFY=0
MIC_SILENT_WARNED=0
QUEUE_FIFO=""
WORKER_PID=""
SERVER_PID=""
JOBS_QUEUED=0
ARCHIVE_COUNT=0
ARCHIVED_PATH=""
LEVEL_TICKS=0
QUIET_DROPS=0
QUIET_ADVISED=0
SHUTTING_DOWN=0

# --- RECORDER --------------------------------------------------------------
rec_start() {
  local file="$1"
  termux-microphone-record -q >/dev/null 2>&1
  sleep 0.25
  rm -f "$file"
  local out
  out=$(termux-microphone-record -e "$CAPTURE_ENC" -b "$CAPTURE_BITRATE" \
            -r "$CAPTURE_RATE" -c 1 -f "$file" -l 0 2>&1)
  if [[ "$out" != *"Recording started"* ]]; then
    log_error "could not start the microphone: $out"
    return 1
  fi
  RECORDING=1
  LIVE="$file"
  LIVE_STARTED=$(date +%s)
  LIVE_EPOCH=$(date +%s)
  log_info "capture started: $(basename "$file")"
  # the encoder needs a moment before the container has audio pages in it
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [[ -s "$file" ]] && (( $(stat -c %s "$file") > 2000 )) && return 0
    sleep 0.2
  done
  log_warn "capture file is empty after 2s - check the microphone permission"
  return 1
}

rec_stop() {
  (( RECORDING )) || return 0
  termux-microphone-record -q >/dev/null 2>&1
  sleep 0.3
  RECORDING=0
}

# --- STREAM FEEDER ---------------------------------------------------------
# tail -f cannot be used here: ffmpeg refuses an ogg pipe that arrives through
# it ("End of file" on open).  Reading the file ourselves and holding the pipe
# open works and lets us follow the live container byte-exactly.

# --- PIPELINE --------------------------------------------------------------
pipeline_stop() {
  if [[ -n "$PIPE_PG" ]]; then
    kill -TERM -- "-$PIPE_PG" 2>/dev/null
    sleep 0.15
    kill -KILL -- "-$PIPE_PG" 2>/dev/null
    PIPE_PG=""
  fi
  exec 7<&- 2>/dev/null || true
  rm -f "$EVFIFO"
}

pipeline_start() {
  local live="$1"
  pipeline_stop
  rm -f "$EVFIFO"
  mkfifo -m 600 "$EVFIFO" || { log_error "cannot create $EVFIFO"; return 1; }
  export VAD_OUTDIR="$CAPTURE_DIR/segments" VAD_TAG="seg" \
         VAD_SPEECH_DB="$SPEECH_DB" VAD_MARGIN_DB="$MARGIN_DB" \
         VAD_PREROLL_MS="$PREROLL_MS" VAD_ENDSIL_MS="$END_SILENCE_MS" \
         VAD_MINSPEECH_MS="$MIN_SPEECH_MS" VAD_MAXSEG_MS="$MAX_SEGMENT_MS" \
         VAD_MIN_VOICED_DB="$MIN_VOICED_DB" VAD_WARMUP_MS="$WARMUP_MS"
  mkdir -p "$VAD_OUTDIR"
  set -m   # own process group, so the whole chain can be signalled at once
  (
    python3 -u "$FOLLOW_PY" "$live" 0.15 2>>"$LOGFILE" \
      | ffmpeg -hide_banner -nostdin -loglevel error -f ogg -i - \
               -vn -ac 1 -ar 16000 -f s16le - 2>>"$LOGFILE" \
      | python3 -u "$VAD_PY" 2>>"$LOGFILE"
  ) >"$EVFIFO" 2>>"$LOGFILE" &
  PIPE_PG=$!
  set +m
  exec 7<"$EVFIFO"
  return 0
}

capture_size_kb() { echo $(( $(stat -c %s "$LIVE" 2>/dev/null || echo 0) / 1024 )); }

# The size cap must not depend on the room ever being quiet: in a noisy room
# the VAD never reports idle, which used to mean the capture file grew without
# bound. Called from the level event, so it always gets evaluated.
size_cap_check() {
  local size_kb; size_kb=$(capture_size_kb)
  if (( size_kb > ROTATE_MAX_MB * 1024 )); then
    log_warn "capture file reached ${size_kb}kB (cap ${ROTATE_MAX_MB}MB) - recycling"
    rotate_capture || log_error "rotation failed"
    return 0
  fi
  return 1
}

rotate_capture() {
  local old="$LIVE"
  log_debug "rotating capture (silence housekeeping)"
  pipeline_stop
  rec_stop
  [[ -n "$old" ]] && rm -f "$old"
  rec_start "$CAPTURE_DIR/live-$(date +%H%M%S).ogg" || return 1
  pipeline_start "$LIVE" || return 1
}

# --- TRANSCRIBE QUEUE (keeps the VAD loop responsive) ----------------------
trap '' PIPE    # a dead worker must not kill the orchestrator mid-write

queue_start() {
  (( ASYNC )) || return 0
  QUEUE_FIFO="$CAPTURE_DIR/queue.fifo"
  rm -f "$QUEUE_FIFO"
  mkfifo -m 600 "$QUEUE_FIFO" || { ASYNC=0; log_warn "cannot create queue; transcribing inline"; return 0; }
  ( transcribe_worker ) &
  WORKER_PID=$!
  exec 6>"$QUEUE_FIFO"     # unblocks once the worker opens the read end
  log_debug "transcription worker pid $WORKER_PID (async)"
  return 0
}

transcribe_worker() {
  log_debug "worker[$BASHPID]: opening $QUEUE_FIFO"
  exec 8<"$QUEUE_FIFO" || { log_warn "worker[$BASHPID]: cannot open queue"; return 1; }
  log_debug "worker[$BASHPID]: queue open, waiting"
  while IFS=$'\t' read -r -u 8 file hhmmss dur db peak; do   # -u 8! without it read takes stdin
    [[ -n "$file" ]] || continue
    log_debug "worker[$BASHPID]: got $(basename "$file")"
    transcribe "$file" "$hhmmss" "$dur" "$db" "$peak"
  done
  log_debug "worker[$BASHPID]: queue closed, exiting"
  exec 8<&-
}

queue_stop() {
  (( ASYNC )) || return 0
  exec 6>&- 2>/dev/null || true
  if [[ -n "$WORKER_PID" ]]; then
    local i
    for i in $(seq 1 60); do
      kill -0 "$WORKER_PID" 2>/dev/null || break
      sleep 0.25
    done
    kill "$WORKER_PID" 2>/dev/null
    WORKER_PID=""
  fi
  rm -f "$QUEUE_FIFO"
  return 0
}

enqueue_segment() {  # file hhmmss dur db peak
  (( JOBS_QUEUED++ ))
  if (( ASYNC )) && [[ -n "$WORKER_PID" ]] && kill -0 "$WORKER_PID" 2>/dev/null; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$@" >&6 2>/dev/null && return 0
    log_warn "queue write failed - transcribing inline"
  elif (( ASYNC )); then
    log_warn "worker gone - transcribing inline"
  fi
  transcribe "$@"
}

# --- OPTIONAL RESIDENT MODEL ----------------------------------------------
server_start() {
  [[ "$ENGINE" == "server" ]] || return 0
  local srv; srv="$(dirname "$WHISPER")/whisper-server"
  if [[ ! -x "$srv" ]]; then
    log_warn "whisper-server not found next to whisper-cli - using cli"; ENGINE=cli; return 0
  fi
  "$srv" -m "$MODEL" --host 127.0.0.1 --port "$SERVER_PORT" -t "$THREADS" \
      >/dev/null 2>&1 &
  SERVER_PID=$!
  local i
  for i in $(seq 1 40); do
    curl -s --max-time 1 -o /dev/null "http://127.0.0.1:$SERVER_PORT/" 2>/dev/null && {
      log_info "whisper-server resident on 127.0.0.1:$SERVER_PORT (pid $SERVER_PID)"
      return 0
    }
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      log_warn "whisper-server failed to start - using cli"; ENGINE=cli; SERVER_PID=""; return 0
    fi
    sleep 0.5
  done
  log_warn "whisper-server did not answer - using cli"; ENGINE=cli
  kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""
  return 0
}

server_stop() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
  SERVER_PID=""
  return 0
}

# --- TRANSCRIPTION ---------------------------------------------------------
append_md() { # $1=wall HH:MM:SS  $2=duration  $3=text
  local hhmmss="$1" dur="$2" text="$3"
  local today; today=$(date +%F)
  if [[ "$today" != "$TODAY" ]]; then
    TODAY="$today"; DAILY_MD="$WORK/$TODAY.md"
    log_info "rolling over to $DAILY_MD"
  fi
  printf '\n## %s (%ss)\n\n%s\n\n---\n' "$hhmmss" "$dur" "$text" >>"$DAILY_MD"
  log_info ">> $hhmmss (${dur}s) $text"
}

audit_line() { # $1=wav $2=hhmmss $3=dur $4=db $5=peak $6=text $7=archived_path
  (( AUDIT )) || return 0
  mkdir -p "$(dirname "$AUDIT_JSONL")"
  local audio_json="null"
  [[ -n "${7:-}" ]] && audio_json="\"$(printf '%s' "$7" | sed 's/\\/\\\\/g; s/"/\\"/g')\""
  printf '{"ts":"%s","file":"%s","at":"%s","dur":%s,"db":%s,"peak":%s,"audio":%s,"text":"%s"}\n' \
    "$(date -Iseconds)" "$(basename "$1")" "$2" "$3" "$4" "$5" "$audio_json" \
    "$(printf '%s' "$6" | sed 's/\\/\\\\/g; s/"/\\"/g')" >>"$AUDIT_JSONL"
}

# Whisper answers non-speech with annotations - "(birds chirping)",
# "[BLANK_AUDIO]", "(keyboard clicking)" - and, fed silence, with canned
# phrases. Neither belongs in a journal.
HALLU_REASON=""
is_hallucination() {
  local text="$1" t
  HALLU_REASON=""
  if [[ "$text" =~ ^[[:space:]]*(\(.*\)|\[.*\])[[:space:]]*$ ]]; then
    HALLU_REASON="non-speech annotation"
    return 0
  fi
  t="${text,,}"
  t="${t//[^[:alnum:]]/}"
  case "$t" in
    ""|you|thankyou|thanks|thanksforwatching|thankyouforwatching|\
    thanksforwatchingandsubscribing|pleasesubscribe|subscribe|\
    subscribetomychannel|bye|blankaudio|silence|noise|mm|\
    transcriptionby|amaraorg|subtitlesby)
      HALLU_REASON="canned whisper phrase"
      return 0;;
  esac
  return 1
}

transcribe() { # $1=wav $2=wall HH:MM:SS $3=dur $4=db $5=peak
  local wav="$1" hhmmss="$2" dur="$3" db="$4" peak="$5"
  local base="${wav%.wav}"
  local txt="$base.txt"

  local vad_args=()
  [[ -n "$WHISPER_VAD_FILE" ]] && vad_args=(--vad -vm "$WHISPER_VAD_FILE" -vt "$WHISPER_VAD_THR")

  if [[ "$ENGINE" == "server" && -n "$SERVER_PID" ]]; then
    # resident model, one HTTP call; whisper's chatter never reaches our log
    local resp
    resp=$(curl -s --max-time 300 \
      -F "file=@$wav" -F "response_format=json" \
      "http://127.0.0.1:$SERVER_PORT/inference" 2>/dev/null)
    if [[ -z "$resp" ]]; then
      log_warn "whisper-server gave no answer - falling back to cli for this one"
      ENGINE=cli
    else
      printf '%s' "$resp" \
        | sed -n 's/.*"text"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | sed 's/\\n/ /g; s/\\"/"/g' >"$txt"
    fi
  fi
  if [[ ! -s "$txt" ]]; then
    if ! "$WHISPER" -m "$MODEL" -f "$wav" -otxt -of "$base" -l en \
          -t "$THREADS" -np -nt "${vad_args[@]}" >/dev/null 2>&1; then
      log_error "whisper failed on $(basename "$wav")"
      rm -f "$wav" "$txt"
      return 1
    fi
  fi

  local text=""
  [[ -s "$txt" ]] && text=$(tr '\n' ' ' <"$txt" | tr -s ' ' | sed 's/^ *//; s/ *$//')
  # whisper prefixes real speech with its own description of the background,
  # e.g. "[typing] First few words". Drop those annotations, keep the words.
  if [[ -n "$text" ]]; then
    text=$(printf '%s' "$text" | sed -E 's/^[[:space:]]*(\[[^]]*\]|\([^)]*\))[[:space:]]*//')
    text=$(printf '%s' "$text" | sed -E 's/[[:space:]]*(\[[^]]*\]|\([^)]*\))[[:space:]]*$//')
    text=$(printf '%s' "$text" | sed 's/^ *//; s/ *$//')
  fi

  if [[ -z "$text" ]]; then
    log_debug "no words in $(basename "$wav") - dropped"
  elif is_hallucination "$text"; then
    log_debug "dropped whisper artefact ($HALLU_REASON): \"$text\""
  else
    append_md "$hhmmss" "$dur" "$text"
    AUDIO_KEPT=""
    ARCHIVED_PATH=""
    archive_segment "$wav" && AUDIO_KEPT="$ARCHIVED_PATH"
    audit_line "$wav" "$hhmmss" "$dur" "$db" "$peak" "$text" "$AUDIO_KEPT"
    TOTAL_SEGMENTS=$(( TOTAL_SEGMENTS + 1 ))
    TOTAL_MS=$(( TOTAL_MS + ${dur%.*} * 1000 ))
    (( ARCHIVE_COUNT++ ))
    (( ARCHIVE_COUNT % 200 == 0 )) && prune_archive
  fi
  rm -f "$wav" "$txt"
}

maybe_notify() {
  (( NOTIFY )) || return 0
  local now; now=$(date +%s)
  (( now - LAST_NOTIFY < 60 )) && return 0
  LAST_NOTIFY=$now
  local content
  if [[ "$(kv_state)" == "speech" ]]; then
    content="listening... ${TOTAL_SEGMENTS} utterances today"
  else
    content="idle - ${TOTAL_SEGMENTS} utterances today"
  fi
  termux-notification --id "$NOTIF_ID" --title "DTRH-Audiophile" \
    --content "$content" --ongoing --priority low >/dev/null 2>&1
}

kv_state() { echo "${CUR_STATE:-idle}"; }

# --- EVENT HANDLING --------------------------------------------------------
handle_event() {
  local line="$1" ev
  ev=$(kv_get ev "$line") || return 0
  case "$ev" in
    ready)
      log_info "vad ready (speech>$(kv_get thr "$line")dB, floor $(kv_get floor "$line")dB)"
      CUR_STATE=idle;;
    level)
      CUR_STATE=$(kv_get state "$line")
      local db; db=$(kv_get db "$line")
      log_debug "level db=$db floor=$(kv_get floor "$line") thr=$(kv_get thr "$line") state=$CUR_STATE buffered=$(kv_get buf "$line")s"
      if [[ "$db" == "-91.0" ]] && (( MIC_SILENT_WARNED == 0 )); then
        MIC_SILENT_WARNED=1
        log_warn "microphone is returning digital silence - open Termux once and grant the microphone permission"
      elif [[ "$db" != "-91.0" ]]; then
        MIC_SILENT_WARNED=1
      fi
      (( ++LEVEL_TICKS % 15 == 0 )) && size_cap_check
      maybe_notify;;
    begin)
      log_debug "speech onset at $(kv_get t "$line")s";;
    segment)
      local file t0 dur db peak reason
      file=$(kv_get file "$line"); t0=$(kv_get t0 "$line")
      dur=$(kv_get dur "$line");  db=$(kv_get db "$line")
      peak=$(kv_get peak "$line"); reason=$(kv_get reason "$line")
      log_info "utterance ${dur}s (voiced $(kv_get voiced "$line")s, ${db}dB, ${reason}) -> queue"
      local hhmmss
      hhmmss=$(date -d "@$(( LIVE_EPOCH + ${t0%.*} ))" +%H:%M:%S 2>/dev/null || date +%H:%M:%S)
      enqueue_segment "$file" "$hhmmss" "$dur" "$db" "$peak";;
    drop)
      local reason; reason=$(kv_get reason "$line")
      log_debug "dropped $(kv_get dur "$line")s of audio: ${reason} (voiced $(kv_get voiced_ms "$line")ms, $(kv_get vdb "$line")dB)"
      if [[ "$reason" == "quiet" ]]; then
        QUIET_DROPS=$(( QUIET_DROPS + 1 ))
        if (( QUIET_DROPS == 20 && QUIET_ADVISED == 0 )); then
          QUIET_ADVISED=1
          log_warn "20 utterances rejected as too quiet - this room is noisy at your current threshold"
          log_warn "run ./audiophile-calibrate.sh or raise DTRH_SPEECH_DB (now ${SPEECH_DB}dB)"
        fi
      fi;;
    idle)
      local secs; secs=$(kv_get seconds "$line")
      local age=$(( $(date +%s) - LIVE_STARTED ))
      local size_kb; size_kb=$(capture_size_kb)
      log_debug "idle ${secs}s (capture age ${age}s, ${size_kb}kB; rotate at ${ROTATE_IDLE_S}s idle / ${ROTATE_MIN_AGE_S}s age)"
      if (( secs >= ROTATE_IDLE_S && age >= ROTATE_MIN_AGE_S )); then
        log_info "no speech for ${secs}s - recycling the capture file"
        rotate_capture || log_error "rotation failed"
      else
        size_cap_check
      fi;;
    error)
      log_error "vad error: $(kv_get msg "$line")";;
    end)
      log_warn "vad pipeline finished (segments=$(kv_get segments "$line"))";;
    *) :;;
  esac
}

server_start
queue_start

# --- CLEANUP ---------------------------------------------------------------
cleanup() {
  (( SHUTTING_DOWN )) && return 0
  SHUTTING_DOWN=1
  trap - EXIT INT TERM HUP
  log_info "cleanup: stopping capture and transcriber"
  pipeline_stop
  rec_stop
  queue_stop
  server_stop
  [[ -n "$LIVE" ]] && rm -f "$LIVE"
  rm -rf "${CAPTURE_DIR:?}/segments" 2>/dev/null || true
  termux-notification-remove --id "$NOTIF_ID" >/dev/null 2>&1 || true
  termux-wake-unlock >/dev/null 2>&1 || true
  prune_archive
  rm -f "$PIDFILE"
  log_info "utterances this run: $TOTAL_SEGMENTS (${TOTAL_MS}ms of speech) - goodbye."
}
trap cleanup EXIT INT TERM HUP

# --- RUN -------------------------------------------------------------------
termux-wake-lock >/dev/null 2>&1 || true
log_info "starting: silence-gated transcription (preroll ${PREROLL_MS}ms, end-silence ${END_SILENCE_MS}ms)"

while (( SHUTTING_DOWN == 0 )); do
  if ! rec_start "$CAPTURE_DIR/live-$(date +%H%M%S).ogg"; then
    log_error "capture could not be started - retrying in 5s"
    sleep 5; continue
  fi
  if ! pipeline_start "$LIVE"; then
    log_error "pipeline could not be started - retrying in 5s"
    rec_stop; sleep 5; continue
  fi

  while IFS= read -r line <&7; do
    handle_event "$line"
  done

  # outer loop restart: either the chain died or someone rotated the capture
  if (( SHUTTING_DOWN == 0 )); then
    log_warn "pipeline stream ended - restarting with a fresh capture file"
    pipeline_stop
    rec_stop
    rm -f "$LIVE"
    sleep 0.5
  fi
done
