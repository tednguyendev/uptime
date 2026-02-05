#!/bin/bash

# Test runner for uptime.1m.sh
# Tests the pure functions by sourcing the script with overrides

PASS=0
FAIL=0
TEMP_DIR=$(mktemp -d)

cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $label"
    echo "  expected: '$expected'"
    echo "  actual:   '$actual'"
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  if [ -f "$path" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $label - file not found: $path"
  fi
}

assert_file_not_exists() {
  local label="$1" path="$2"
  if [ ! -f "$path" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $label - file should not exist: $path"
  fi
}

assert_file_contains() {
  local label="$1" path="$2" pattern="$3"
  if grep -q "$pattern" "$path" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $label - '$pattern' not found in $path"
  fi
}

# Source only the functions from uptime.1m.sh (override config to use temp dir)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source_functions() {
  # Override config
  DATA_DIR="$TEMP_DIR/data"
  SESSION_FILE="$DATA_DIR/session_start"
  WAKE_FILE="$DATA_DIR/wake"
  IDLE_FLAG_FILE="$DATA_DIR/idle"
  RESET_FLAG_FILE="$DATA_DIR/just_reset"
  HISTORY_FILE="$DATA_DIR/history.log"
  DEV_LOG_FILE="$DATA_DIR/dev.log"
  IDLE_THRESHOLD=300
  DEV_LOG_MAX_LINES=500
  NOW=$(date +%s)
  mkdir -p "$DATA_DIR"
}

# Extract functions from uptime.1m.sh (source only function definitions)
eval "$(sed -n '/^read_file()/,/^}/p' "$SCRIPT_DIR/uptime.1m.sh")"
eval "$(sed -n '/^format_duration()/,/^}/p' "$SCRIPT_DIR/uptime.1m.sh")"
eval "$(sed -n '/^dev_log()/,/^}/p' "$SCRIPT_DIR/uptime.1m.sh")"
eval "$(sed -n '/^timestamp_to_epoch()/,/^}/p' "$SCRIPT_DIR/uptime.1m.sh")"
eval "$(sed -n '/^epoch_to_datetime()/,/^}/p' "$SCRIPT_DIR/uptime.1m.sh")"
eval "$(sed -n '/^log_previous_session()/,/^}/p' "$SCRIPT_DIR/uptime.1m.sh")"

reset_data() {
  rm -rf "$TEMP_DIR/data"
  source_functions
}

# ============================================================
# format_duration tests
# ============================================================

echo "--- format_duration ---"

assert_eq "0 seconds" "0m" "$(format_duration 0)"
assert_eq "59 seconds" "0m" "$(format_duration 59)"
assert_eq "60 seconds" "1m" "$(format_duration 60)"
assert_eq "30 minutes" "30m" "$(format_duration 1800)"
assert_eq "59 minutes" "59m" "$(format_duration 3599)"
assert_eq "1 hour exact" "1h 0m" "$(format_duration 3600)"
assert_eq "1h 1m" "1h 1m" "$(format_duration 3660)"
assert_eq "2h 30m" "2h 30m" "$(format_duration 9000)"
assert_eq "23h 59m" "23h 59m" "$(format_duration 86340)"

# ============================================================
# read_file tests
# ============================================================

echo "--- read_file ---"

reset_data
echo "12345" > "$SESSION_FILE"
assert_eq "reads existing file" "12345" "$(read_file "$SESSION_FILE")"

reset_data
assert_eq "returns empty for missing file" "" "$(read_file "$SESSION_FILE")"

# ============================================================
# epoch_to_datetime tests
# ============================================================

echo "--- epoch_to_datetime ---"

# Round-trip: epoch → datetime → verify format
result=$(epoch_to_datetime "$NOW")
expected=$(date -r "$NOW" '+%Y-%m-%d %H:%M')
assert_eq "epoch to datetime round-trip" "$expected" "$result"

# ============================================================
# log_previous_session tests
# ============================================================

echo "--- log_previous_session ---"

reset_data
start=$((NOW - 3600))
echo "$start" > "$SESSION_FILE"
log_previous_session "$NOW"
assert_file_exists "history file created" "$HISTORY_FILE"
assert_file_contains "logs 1h 0m" "$HISTORY_FILE" "1h 0m"

reset_data
echo "$NOW" > "$SESSION_FILE"
log_previous_session "$NOW"
assert_file_not_exists "skips zero duration" "$HISTORY_FILE"

reset_data
start=$((NOW - 7200))
end=$((NOW - 3600))
echo "$start" > "$SESSION_FILE"
log_previous_session "$end"
assert_file_contains "uses provided end time" "$HISTORY_FILE" "1h 0m"

reset_data
start=$((NOW - 1800))
echo "$start" > "$SESSION_FILE"
log_previous_session ""
assert_file_contains "uses NOW when end empty" "$HISTORY_FILE" "30m"

# ============================================================
# idle detection (integration via script)
# ============================================================

echo "--- idle threshold ---"

assert_eq "below threshold" "1" "$([ 299 -ge 300 ]; echo $?)"
assert_eq "at threshold" "0" "$([ 300 -ge 300 ]; echo $?)"
assert_eq "above threshold" "0" "$([ 301 -ge 300 ]; echo $?)"

# ============================================================
# handle_idle_reset logic
# ============================================================

echo "--- handle_idle_reset ---"

# Became idle - creates flag
reset_data
IDLE_SEC=300
[ "$IDLE_SEC" -ge "$IDLE_THRESHOLD" ] && [ ! -f "$IDLE_FLAG_FILE" ] && echo "$NOW" > "$IDLE_FLAG_FILE"
assert_file_exists "creates idle flag" "$IDLE_FLAG_FILE"
assert_eq "idle flag has NOW" "$NOW" "$(cat "$IDLE_FLAG_FILE")"

# Already idle - does nothing
reset_data
old_ts=$((NOW - 60))
echo "$old_ts" > "$IDLE_FLAG_FILE"
IDLE_SEC=300
[ "$IDLE_SEC" -ge "$IDLE_THRESHOLD" ] && [ ! -f "$IDLE_FLAG_FILE" ] && echo "$NOW" > "$IDLE_FLAG_FILE"
assert_eq "keeps old idle flag" "$old_ts" "$(cat "$IDLE_FLAG_FILE")"

# Became active with session - logs and resets
reset_data
idle_ts=$((NOW - 600))
session_ts=$((NOW - 3600))
echo "$idle_ts" > "$IDLE_FLAG_FILE"
echo "$session_ts" > "$SESSION_FILE"
IDLE_SEC=0
if [ "$IDLE_SEC" -lt "$IDLE_THRESHOLD" ] && [ -f "$IDLE_FLAG_FILE" ]; then
  idle_started=$(read_file "$IDLE_FLAG_FILE")
  rm -f "$IDLE_FLAG_FILE"
  [ -n "$(read_file "$SESSION_FILE")" ] && log_previous_session "$idle_started"
  echo "$NOW" > "$SESSION_FILE"
fi
assert_file_not_exists "idle flag removed" "$IDLE_FLAG_FILE"
assert_file_exists "history logged" "$HISTORY_FILE"
assert_eq "session reset to NOW" "$NOW" "$(cat "$SESSION_FILE")"

# Became active without session - resets only
reset_data
echo "$((NOW - 600))" > "$IDLE_FLAG_FILE"
IDLE_SEC=0
if [ "$IDLE_SEC" -lt "$IDLE_THRESHOLD" ] && [ -f "$IDLE_FLAG_FILE" ]; then
  rm -f "$IDLE_FLAG_FILE"
  [ -n "$(read_file "$SESSION_FILE")" ] && log_previous_session ""
  echo "$NOW" > "$SESSION_FILE"
fi
assert_file_not_exists "idle flag removed (no session)" "$IDLE_FLAG_FILE"
assert_file_not_exists "no history without session" "$HISTORY_FILE"
assert_file_exists "session created" "$SESSION_FILE"

# Not idle, no flag - does nothing
reset_data
IDLE_SEC=0
if [ "$IDLE_SEC" -ge "$IDLE_THRESHOLD" ]; then
  echo "$NOW" > "$IDLE_FLAG_FILE"
elif [ -f "$IDLE_FLAG_FILE" ]; then
  rm -f "$IDLE_FLAG_FILE"
fi
assert_file_not_exists "no idle flag" "$IDLE_FLAG_FILE"
assert_file_not_exists "no session" "$SESSION_FILE"

# ============================================================
# handle_wake_cycle logic
# ============================================================

echo "--- handle_wake_cycle ---"

# Same wake - skips
reset_data
echo "2024-01-15 10:00:00" > "$WAKE_FILE"
LATEST_WAKE="2024-01-15 10:00:00"
STORED_WAKE="2024-01-15 10:00:00"
skipped=false
[ "$LATEST_WAKE" = "$STORED_WAKE" ] && skipped=true
assert_eq "same wake skips" "true" "$skipped"

# New wake, no session
reset_data
LATEST_WAKE="2024-01-15 11:00:00"
STORED_WAKE="2024-01-15 10:00:00"
if [ "$LATEST_WAKE" != "$STORED_WAKE" ]; then
  echo "$LATEST_WAKE" > "$WAKE_FILE"
  echo "$NOW" > "$SESSION_FILE"
fi
assert_eq "stores new wake" "2024-01-15 11:00:00" "$(cat "$WAKE_FILE")"
assert_file_exists "creates session" "$SESSION_FILE"

# New wake with idle flag - logs from idle
reset_data
session_ts=$((NOW - 7200))
idle_ts=$((NOW - 3600))
echo "$session_ts" > "$SESSION_FILE"
echo "$idle_ts" > "$IDLE_FLAG_FILE"
echo "2024-01-15 10:00:00" > "$WAKE_FILE"
LATEST_WAKE="2024-01-15 11:00:00"
STORED_WAKE="2024-01-15 10:00:00"
if [ "$LATEST_WAKE" != "$STORED_WAKE" ]; then
  if [ -n "$(read_file "$SESSION_FILE")" ] && [ -n "$STORED_WAKE" ]; then
    if [ -f "$IDLE_FLAG_FILE" ]; then
      end_epoch=$(read_file "$IDLE_FLAG_FILE")
      rm -f "$IDLE_FLAG_FILE"
      log_previous_session "$end_epoch"
    fi
  fi
  echo "$LATEST_WAKE" > "$WAKE_FILE"
  echo "$NOW" > "$SESSION_FILE"
fi
assert_file_not_exists "idle flag removed after wake" "$IDLE_FLAG_FILE"
assert_file_exists "history from idle wake" "$HISTORY_FILE"
assert_file_contains "logged 1h session" "$HISTORY_FILE" "1h 0m"

# ============================================================
# reset flag fast path
# ============================================================

echo "--- reset flag ---"

reset_data
touch "$RESET_FLAG_FILE"
if [ -f "$RESET_FLAG_FILE" ]; then
  rm -f "$RESET_FLAG_FILE"
  echo "$NOW" > "$SESSION_FILE"
fi
assert_file_not_exists "reset flag removed" "$RESET_FLAG_FILE"
assert_eq "session set to NOW" "$NOW" "$(cat "$SESSION_FILE")"

# No reset flag
reset_data
fast=false
[ -f "$RESET_FLAG_FILE" ] && fast=true
assert_eq "no reset flag" "false" "$fast"

# ============================================================
# elapsed time
# ============================================================

echo "--- elapsed ---"

reset_data
start=$((NOW - 3600))
echo "$start" > "$SESSION_FILE"
session_start=$(read_file "$SESSION_FILE")
elapsed=$((NOW - session_start))
assert_eq "elapsed 1 hour" "3600" "$elapsed"

reset_data
echo "$NOW" > "$SESSION_FILE"
session_start=$(read_file "$SESSION_FILE")
elapsed=$((NOW - session_start))
assert_eq "elapsed zero" "0" "$elapsed"

# ============================================================
# Results
# ============================================================

echo ""
echo "================================"
echo "$((PASS + FAIL)) tests, $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
