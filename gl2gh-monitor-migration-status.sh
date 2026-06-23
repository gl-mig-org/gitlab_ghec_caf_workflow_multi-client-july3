#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

MIGRATION_OUTPUT_FILE="${MIGRATION_OUTPUT_FILE:-}"

GH_HOST="${GH_HOST:-}"
if [[ -z "$GH_HOST" ]]; then
  echo "GH_HOST is not set"
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

RUN_TS="$(date +"%Y%m%d_%H%M%S")"
LOG_FILE="${MONITOR_MIGRATION_LOG:-$LOG_DIR/monitor-migration}-${RUN_TS}.log"
OUTPUT_FILE="$ARTIFACTS_DIR/migration-status-${RUN_TS}.csv"
PER_MIGRATION_LOG_DIR="$LOG_DIR/monitor-migration-${RUN_TS}"

INTERVAL=10

mkdir -p "$LOG_DIR" "$ARTIFACTS_DIR" "$PER_MIGRATION_LOG_DIR"

# IMPORTANT: CI SAFE (prevents TERM/tput issues)
export TERM=dumb

if [[ -z "$MIGRATION_OUTPUT_FILE" ]]; then
  echo "[ERROR] MIGRATION_OUTPUT_FILE not set"
  exit 1
elif [[ ! -s "$MIGRATION_OUTPUT_FILE" ]]; then
  echo "[ERROR] Migration output missing"
  exit 1
else
  echo "[INFO] Using migration output file: $MIGRATION_OUTPUT_FILE"
fi

exec > >(tee -a "$LOG_FILE") 2>&1

command -v gh >/dev/null || { echo "gh missing"; exit 1; }

TOTAL_MIGRATIONS=$(($(wc -l < "$MIGRATION_OUTPUT_FILE") - 1))

CPU_COUNT=$(nproc)
PARALLEL=$(( CPU_COUNT < TOTAL_MIGRATIONS ? CPU_COUNT : TOTAL_MIGRATIONS ))
PARALLEL=$(( PARALLEL > 8 ? 8 : PARALLEL ))

echo "[INFO] Total migrations: $TOTAL_MIGRATIONS"
echo "[INFO] Parallel workers: $PARALLEL"

RESULTS_TMP=$(mktemp)
INPUT_TMP=$(mktemp)

echo "github_org,github_repository,migration_id,status" > "$OUTPUT_FILE"

#########################################################
## Helpers (UNCHANGED CORE LOGIC)
#########################################################

dequote() {
  local field="${1:-}"
  field="${field%$'\r'}"
  field="${field%\"}"
  field="${field#\"}"
  echo "$field"
}

parse_csv_line() { ... }   # (keep your existing one unchanged)
find_col() { ... }
append_repo_to_list() { ... }

#########################################################
## STATUS COLLECTION (unchanged but safe)
#########################################################

collect_status_snapshot() {
  local completed_count=0
  local failed_count=0
  local running_count=0
  local queued_count=0

  local completed_repos=""
  local failed_repos=""
  local in_progress_repos=""
  local queued_repos=""

  declare -A latest_status=()

  if [[ -s "$RESULTS_TMP" ]]; then
    while IFS=',' read -r org repo migration state; do
      latest_status["$migration"]="$state"
    done < "$RESULTS_TMP"
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    IFS=',' read -r org repo migration <<< "$line"

    case "${latest_status[$migration]:-QUEUED}" in
      COMPLETED)
        ((completed_count++))
        ;;
      FAILED)
        ((failed_count++))
        ;;
      STARTED)
        ((running_count++))
        ;;
      *)
        ((queued_count++))
        ;;
    esac
  done < "$INPUT_TMP"

  SNAPSHOT_COMPLETED="$completed_count"
  SNAPSHOT_FAILED="$failed_count"
  SNAPSHOT_RUNNING="$running_count"
  SNAPSHOT_FINISHED=$((completed_count + failed_count))
}

#########################################################
## Build Input
#########################################################

tail -n +2 "$MIGRATION_OUTPUT_FILE" | while IFS= read -r line; do
  line="${line//$'\r'/}"
  IFS=',' read -r org repo mig <<< "$line"
  echo "$org,$repo,$mig"
done > "$INPUT_TMP"

#########################################################
## WORKER (unchanged logic)
#########################################################

run_monitor() {
  local line="$1"
  IFS=',' read -r org repo migration <<< "$line"

  echo "$org,$repo,$migration,STARTED" >> "$RESULTS_TMP"

  local log_file="$PER_MIGRATION_LOG_DIR/${org}_${repo}_${migration}.log"

  if gh ado2gh wait-for-migration \
    --migration-id "$migration" \
    --target-api-url "$TARGET_API_URL" >"$log_file" 2>&1; then
    status="COMPLETED"
  else
    status="FAILED"
  fi

  echo "$org,$repo,$migration,$status" >> "$RESULTS_TMP"
}

export -f run_monitor
export TARGET_API_URL RESULTS_TMP PER_MIGRATION_LOG_DIR

#########################################################
## FIXED PARALLEL EXECUTION (NO MONITOR PID BUG)
#########################################################

xargs -a "$INPUT_TMP" -P "$PARALLEL" -I {} bash -c 'run_monitor "$@"' _ {}

#########################################################
## CLEAN WAIT (NO tput / NO TERM / NO UI DEPENDENCY)
#########################################################

echo "[INFO] Waiting for all migrations to complete..."

while [[ $(grep -c STARTED "$RESULTS_TMP" || true) -gt \
        $(grep -c COMPLETED "$RESULTS_TMP" "$RESULTS_TMP" || true) ]]; do

  collect_status_snapshot

  echo "[PROGRESS] ${SNAPSHOT_FINISHED}/${TOTAL_MIGRATIONS} | \
Completed: ${SNAPSHOT_COMPLETED} | Failed: ${SNAPSHOT_FAILED} | Running: ${SNAPSHOT_RUNNING}"

  sleep "$INTERVAL"
done

#########################################################
## FINAL OUTPUT BUILD
#########################################################

awk -F',' '
{
  latest[$3]=$0
}
END {
  for (k in latest) {
    print latest[k]
  }
}
' "$RESULTS_TMP" | sort >> "$OUTPUT_FILE"

rm -f "$RESULTS_TMP" "$INPUT_TMP"

#########################################################
## FINAL SUMMARY (UNCHANGED)
#########################################################

echo "FINAL SUMMARY"
echo "=============="

TOTAL=$(wc -l < "$OUTPUT_FILE")
SUCCESS=$(grep -c "COMPLETED" "$OUTPUT_FILE" || true)
FAILED=$(grep -c "FAILED" "$OUTPUT_FILE" || true)

echo "Total : $TOTAL"
echo "OK    : $SUCCESS"
echo "FAIL  : $FAILED"

if [[ "$FAILED" -gt 0 ]]; then
  echo "Failed migrations exist"
  exit 1
fi
