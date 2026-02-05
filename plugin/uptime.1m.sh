#!/bin/bash
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>

# === CONFIGURATION ===
DATA_DIR="$HOME/.session_tracker"
SESSION_FILE="$DATA_DIR/session_start"
WAKE_FILE="$DATA_DIR/wake"
IDLE_FLAG_FILE="$DATA_DIR/idle"
RESET_FLAG_FILE="$DATA_DIR/just_reset"
HISTORY_FILE="$DATA_DIR/history.log"
DEV_LOG_FILE="$DATA_DIR/dev.log"
IDLE_THRESHOLD=300  # 5 minutes in seconds
DEV_LOG_MAX_LINES=500
NOW=$(date +%s)
SCRIPT_PATH="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

mkdir -p "$DATA_DIR"

# === HELPERS ===

read_file() {
  [ -f "$1" ] && cat "$1" || echo ""
}

format_duration() {
  local secs=$1
  local h=$((secs / 3600))
  local m=$(( (secs % 3600) / 60 ))
  if [ "$h" -gt 0 ]; then
    echo "${h}h ${m}m"
  else
    echo "${m}m"
  fi
}

dev_log() {
  local action="$1"; shift
  local timestamp
  timestamp=$(date -r "$NOW" '+%Y-%m-%d %H:%M:%S')
  local entry="[$timestamp] $action"
  [ $# -gt 0 ] && entry="$entry | $*"
  echo "$entry" >> "$DEV_LOG_FILE"

  # Trim log if too long
  if [ -f "$DEV_LOG_FILE" ]; then
    local lines
    lines=$(wc -l < "$DEV_LOG_FILE")
    if [ "$lines" -gt "$DEV_LOG_MAX_LINES" ]; then
      tail -n "$DEV_LOG_MAX_LINES" "$DEV_LOG_FILE" > "$DEV_LOG_FILE.tmp"
      mv "$DEV_LOG_FILE.tmp" "$DEV_LOG_FILE"
    fi
  fi
}

get_idle_seconds() {
  local idle_ns
  idle_ns=$(ioreg -c IOHIDSystem | grep HIDIdleTime | head -1 | grep -o '[0-9]\+$')
  echo $(( ${idle_ns:-0} / 1000000000 ))
}

get_pmset_log() {
  pmset -g log 2>/dev/null
}

get_latest_wake() {
  local log="$1"
  local display system latest
  display=$(echo "$log" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}.*Display is turned on' | tail -1 | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}')
  system=$(echo "$log" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}.*Wake from' | grep -v DarkWake | tail -1 | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}')

  # Return the most recent
  if [ -n "$display" ] && [ -n "$system" ]; then
    if [[ "$display" > "$system" ]]; then echo "$display"; else echo "$system"; fi
  elif [ -n "$display" ]; then
    echo "$display"
  elif [ -n "$system" ]; then
    echo "$system"
  else
    echo ""
  fi
}

get_latest_sleep_before() {
  local log="$1" wake_time="$2"
  echo "$log" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}.*(Entering Sleep|Display is turned off)' \
    | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' \
    | awk -v wake="$wake_time" '$0 < wake' | tail -1
}

timestamp_to_epoch() {
  date -j -f '%Y-%m-%d %H:%M:%S' "$1" '+%s' 2>/dev/null
}

epoch_to_datetime() {
  date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null
}

log_previous_session() {
  local end_epoch="$1"
  local start_epoch
  start_epoch=$(read_file "$SESSION_FILE")
  [ -z "$start_epoch" ] && return
  [ -z "$end_epoch" ] && end_epoch=$NOW

  local duration=$((end_epoch - start_epoch))
  [ "$duration" -lt 1 ] && return

  local start_fmt end_fmt dur_fmt
  start_fmt=$(epoch_to_datetime "$start_epoch")
  end_fmt=$(epoch_to_datetime "$end_epoch")
  dur_fmt=$(format_duration "$duration")

  echo "$start_fmt | $end_fmt | $dur_fmt" >> "$HISTORY_FILE"
  dev_log "SESSION_LOGGED" "start=$start_fmt, end=$end_fmt, dur=$dur_fmt"
}

# === MAIN ===

# Fast path: manual reset
if [ -f "$RESET_FLAG_FILE" ]; then
  rm -f "$RESET_FLAG_FILE"
  echo "$NOW" > "$SESSION_FILE"
  elapsed=0
  echo "$(format_duration $elapsed) | bash=$SCRIPT_DIR/reset.sh terminal=false refresh=true"
  exit 0
fi

IDLE_SEC=$(get_idle_seconds)
PMSET_LOG=$(get_pmset_log)
LATEST_WAKE=$(get_latest_wake "$PMSET_LOG")
STORED_WAKE=$(read_file "$WAKE_FILE")

dev_log "RUN" "idle_sec=$IDLE_SEC, latest_wake=${LATEST_WAKE:11:5}, stored_wake=${STORED_WAKE:11:5}"

# === STEP 1: WAKE CYCLE DETECTION ===
if [ -n "$LATEST_WAKE" ] && [ "$LATEST_WAKE" != "$STORED_WAKE" ]; then
  dev_log "WAKE_CYCLE" "new_wake=${LATEST_WAKE:11:5}, old_wake=${STORED_WAKE:11:5}"

  if [ -n "$(read_file "$SESSION_FILE")" ] && [ -n "$STORED_WAKE" ]; then
    if [ -f "$IDLE_FLAG_FILE" ]; then
      end_epoch=$(read_file "$IDLE_FLAG_FILE")
      rm -f "$IDLE_FLAG_FILE"
      dev_log "WAKE_CYCLE:end_from_idle" "end_time=$(epoch_to_datetime "$end_epoch")"
    else
      sleep_time=$(get_latest_sleep_before "$PMSET_LOG" "$LATEST_WAKE")
      if [ -n "$sleep_time" ]; then
        end_epoch=$(timestamp_to_epoch "$sleep_time")
        dev_log "WAKE_CYCLE:end_from_sleep" "end_time=$sleep_time"
      else
        end_epoch=$NOW
      fi
    fi
    log_previous_session "$end_epoch"
  fi

  echo "$LATEST_WAKE" > "$WAKE_FILE"
  echo "$NOW" > "$SESSION_FILE"
  dev_log "WAKE_CYCLE:new_session_started"
fi

# === STEP 2: IDLE DETECTION ===
if [ "$IDLE_SEC" -ge "$IDLE_THRESHOLD" ]; then
  if [ ! -f "$IDLE_FLAG_FILE" ]; then
    echo "$NOW" > "$IDLE_FLAG_FILE"
    dev_log "IDLE:became_idle" "idle_sec=$IDLE_SEC"
  fi
elif [ -f "$IDLE_FLAG_FILE" ]; then
  idle_started=$(read_file "$IDLE_FLAG_FILE")
  rm -f "$IDLE_FLAG_FILE"
  dev_log "IDLE:became_active" "was_idle_since=$(epoch_to_datetime "$idle_started"), idle_sec=$IDLE_SEC"
  if [ -n "$(read_file "$SESSION_FILE")" ]; then
    log_previous_session "$idle_started"
  fi
  echo "$NOW" > "$SESSION_FILE"
  dev_log "IDLE:new_session_started"
fi

# === STEP 3: OUTPUT ===
session_start=$(read_file "$SESSION_FILE")
if [ -z "$session_start" ]; then
  echo "$NOW" > "$SESSION_FILE"
  session_start=$NOW
fi
elapsed=$((NOW - session_start))
echo "$(format_duration $elapsed) | bash=$SCRIPT_DIR/reset.sh terminal=false refresh=true"
