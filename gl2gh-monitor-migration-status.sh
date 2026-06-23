#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

MIGRATION_OUTPUT_FILE="${MIGRATION_OUTPUT_FILE:-}"

export TERM=dumb

#########################################################
# VALIDATION
#########################################################

if [[ -z "$MIGRATION_OUTPUT_FILE" ]]; then
  echo "[ERROR] MIGRATION_OUTPUT_FILE not set"
  exit 1
fi

if [[ ! -s "$MIGRATION_OUTPUT_FILE" ]]; then
  echo "[ERROR] Migration CSV missing/empty"
  exit 1
fi

GH_HOST="${GH_HOST:-}"
if [[ -z "$GH_HOST" ]]; then
  echo "[ERROR] GH_HOST not set"
  exit 1
fi

if [[ "$GITHUB_TYPE" == "GitHub" ]]; then
  TARGET_API_URL="https://api.github.com"
elif [[ "$GITHUB_TYPE" == "GitHubDR" ]]; then
  TARGET_API_URL="https://api.${GH_HOST}"
else
  echo "[ERROR] Invalid GITHUB_TYPE"
  exit 1
fi

#########################################################
# SETUP
#########################################################

RUN_TS="$(date +"%Y%m%d_%H%M%S")"

LOG_DIR="${LOG_DIR:-./logs}"
OUT_DIR="${ARTIFACTS_DIR:-./output_files}"

LOG_FILE="$LOG_DIR/monitor-$RUN_TS.log"
STATE_FILE="$OUT_DIR/state-$RUN_TS.csv"
OUTPUT_FILE="$OUT_DIR/final-$RUN_TS.csv"
QUEUE_FILE="$(mktemp)"
LOCK_FILE="$(mktemp)"

INTERVAL=5
MAX_PARALLEL=8

mkdir -p "$LOG_DIR" "$OUT_DIR"

exec > >(tee -a "$LOG_FILE") 2>&1

command -v gh >/dev/null || { echo "[ERROR] gh missing"; exit 1; }

#########################################################
# LOAD INPUT (STRICT)
#########################################################

echo "[INFO] Loading CSV..."

tail -n +2 "$MIGRATION_OUTPUT_FILE" | while IFS=',' read -r org repo mig; do
  org="${org//$'\r'/}"
  repo="${repo//$'\r'/}"
  mig="${mig//$'\r'/}"

  if [[ -n "$mig" ]]; then
    echo "$org,$repo,$mig,PENDING"
  fi
done > "$QUEUE_FILE"

TOTAL=$(wc -l < "$QUEUE_FILE")

if [[ "$TOTAL" -eq 0 ]]; then
  echo "[ERROR] No valid migrations found"
  exit 1
fi

echo "[INFO] Total migrations: $TOTAL"

echo "org,repo,migration,status" > "$STATE_FILE"

#########################################################
# THREAD SAFE STATE WRITER
#########################################################

write_state() {
  local line="$1"
  (
    flock -x 200
    echo "$line" >> "$STATE_FILE"
  ) 200>"$LOCK_FILE"
}

#########################################################
# WORKER
#########################################################

worker() {
  local line="$1"

  IFS=',' read -r org repo mig status <<< "$line"

  write_state "$org,$repo,$mig,STARTED"

  local log="$LOG_DIR/${org}_${repo}_${mig}.log"

  if gh ado2gh wait-for-migration \
      --migration-id "$mig" \
      --target-api-url "$TARGET_API_URL" >"$log" 2>&1; then
    write_state "$org,$repo,$mig,COMPLETED"
  else
    write_state "$org,$repo,$mig,FAILED"
  fi
}

export -f worker
export TARGET_API_URL STATE_FILE LOG_DIR LOCK_FILE

#########################################################
# RUNNERS (NO xargs, NO PID DEPENDENCY)
#########################################################

run_workers() {
  local active=0

  while IFS= read -r line; do

    while [[ "$active" -ge "$MAX_PARALLEL" ]]; do
      wait -n
      active=$((active - 1))
    done

    worker "$line" &
    active=$((active + 1))

  done < "$QUEUE_FILE"

  wait
}

#########################################################
# MONITOR (EVENT DRIVEN)
#########################################################

monitor() {
  while true; do

    local completed failed running

    completed=$(grep -c "COMPLETED" "$STATE_FILE" || true)
    failed=$(grep -c "FAILED" "$STATE_FILE" || true)
    running=$(grep -c "STARTED" "$STATE_FILE" || true)

    local done=$((completed + failed))

    echo "=================================================="
    echo "[PROGRESS] $done / $TOTAL"
    echo "Completed: $completed | Failed: $failed | Running: $running"
    echo "=================================================="

    if [[ "$done" -ge "$TOTAL" ]]; then
      break
    fi

    sleep "$INTERVAL"
  done
}

#########################################################
# EXECUTION
#########################################################

echo "[INFO] Starting workers + monitor..."

run_workers &
WORKER_PID=$!

monitor

wait "$WORKER_PID"

#########################################################
# FINAL OUTPUT
#########################################################

sort -u "$STATE_FILE" > "$OUTPUT_FILE"

echo ""
echo "FINAL SUMMARY"
echo "============="

TOTAL_DONE=$(wc -l < "$OUTPUT_FILE")

SUCCESS=$(grep -c "COMPLETED" "$OUTPUT_FILE" || true)
FAILED=$(grep -c "FAILED" "$OUTPUT_FILE" || true)

echo "Total processed: $TOTAL_DONE"
echo "Success        : $SUCCESS"
echo "Failed         : $FAILED"

echo ""
echo "[INFO] Output file: $OUTPUT_FILE"
echo "[INFO] Logs       : $LOG_DIR"
