#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

export TERM=dumb

MIGRATION_OUTPUT_FILE="${MIGRATION_OUTPUT_FILE:-}"

#########################################################
# VALIDATION
#########################################################

if [[ -z "$MIGRATION_OUTPUT_FILE" ]]; then
  echo "[ERROR] MIGRATION_OUTPUT_FILE not set"
  exit 1
fi

if [[ ! -s "$MIGRATION_OUTPUT_FILE" ]]; then
  echo "[ERROR] Migration file missing/empty"
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
INPUT_FILE="$(mktemp)"
LOCK_FILE="$(mktemp)"

INTERVAL=5
MAX_PARALLEL=8

mkdir -p "$LOG_DIR" "$OUT_DIR"

exec > >(tee -a "$LOG_FILE") 2>&1

command -v gh >/dev/null || { echo "[ERROR] gh missing"; exit 1; }

#########################################################
# LOAD INPUT
#########################################################

echo "[INFO] Loading CSV..."

tail -n +2 "$MIGRATION_OUTPUT_FILE" | while IFS=',' read -r org repo mig; do
  org="${org//$'\r'/}"
  repo="${repo//$'\r'/}"
  mig="${mig//$'\r'/}"

  [[ -z "$mig" ]] && continue

  echo "$org,$repo,$mig"
done > "$INPUT_FILE"

TOTAL=$(wc -l < "$INPUT_FILE")

if [[ "$TOTAL" -eq 0 ]]; then
  echo "[ERROR] No valid migrations found"
  exit 1
fi

echo "[INFO] Total migrations: $TOTAL"

echo "org,repo,migration,status" > "$STATE_FILE"

#########################################################
# STATE UPSERT (FIX FOR YOUR ISSUE)
#########################################################

write_state() {
  local org="$1"
  local repo="$2"
  local mig="$3"
  local status="$4"

  (
    flock -x 200

    # remove old entry for migration (IMPORTANT FIX)
    grep -v ",${mig}," "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null || true

    echo "$org,$repo,$mig,$status" >> "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"

  ) 200>"$LOCK_FILE"
}

#########################################################
# WORKER
#########################################################

worker() {
  local line="$1"
  IFS=',' read -r org repo mig <<< "$line"

  write_state "$org" "$repo" "$mig" "STARTED"

  local log="$LOG_DIR/${org}_${repo}_${mig}.log"

  if gh ado2gh wait-for-migration \
      --migration-id "$mig" \
      --target-api-url "$TARGET_API_URL" >"$log" 2>&1; then
    write_state "$org" "$repo" "$mig" "COMPLETED"
  else
    write_state "$org" "$repo" "$mig" "FAILED"
  fi
}

export -f worker
export TARGET_API_URL STATE_FILE LOG_DIR LOCK_FILE

#########################################################
# RUN WORKERS (CONTROLLED PARALLELISM)
#########################################################

active=0

while IFS= read -r line; do

  while [[ "$active" -ge "$MAX_PARALLEL" ]]; do
    wait -n
    active=$((active - 1))
  done

  worker "$line" &
  active=$((active + 1))

done < "$INPUT_FILE"

wait

#########################################################
# MONITOR SNAPSHOT (FIXED ACCURATE COUNTS)
#########################################################

collect_status_snapshot() {
  SNAPSHOT_COMPLETED=0
  SNAPSHOT_FAILED=0
  SNAPSHOT_RUNNING=0
  SNAPSHOT_TOTAL=0

  while IFS=',' read -r org repo mig status; do
    [[ -z "$mig" ]] && continue

    ((SNAPSHOT_TOTAL++))

    case "$status" in
      COMPLETED) ((SNAPSHOT_COMPLETED++)) ;;
      FAILED) ((SNAPSHOT_FAILED++)) ;;
      STARTED) ((SNAPSHOT_RUNNING++)) ;;
    esac

  done < "$STATE_FILE"
}

#########################################################
# FINAL PROGRESS DISPLAY
#########################################################

collect_status_snapshot

echo "=================================================="
echo "[FINAL PROGRESS]"
echo "Total     : $SNAPSHOT_TOTAL"
echo "Completed : $SNAPSHOT_COMPLETED"
echo "Failed    : $SNAPSHOT_FAILED"
echo "Running   : $SNAPSHOT_RUNNING"
echo "=================================================="

#########################################################
# FINAL OUTPUT
#########################################################

cp "$STATE_FILE" "$OUT_DIR/final-$RUN_TS.csv"

SUCCESS=$(grep -c "COMPLETED" "$STATE_FILE" || true)
FAILED=$(grep -c "FAILED" "$STATE_FILE" || true)

echo ""
echo "FINAL SUMMARY"
echo "============="
echo "Total   : $TOTAL"
echo "Success : $SUCCESS"
echo "Failed  : $FAILED"

echo ""
echo "[INFO] Output: $OUT_DIR/final-$RUN_TS.csv"
echo "[INFO] Logs  : $LOG_DIR"

if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
