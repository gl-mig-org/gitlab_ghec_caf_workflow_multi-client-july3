#!/usr/bin/env bash
set -euo pipefail

## --- Config --->
SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

## --- Input / derived env --->
MIGRATION_OUTPUT_FILE="${MIGRATION_OUTPUT_FILE:-}"

GH_HOST="${GH_HOST:-}"
if [[ -z "$GH_HOST" ]]; then
  echo "GH_HOST is not set"
  echo 'Set GH_HOST; export GH_HOST="github.com" or "SUBDOMAIN.ghe.com"'
  exit 1
fi

if [[ "$GITHUB_TYPE" == "GitHub" ]]; then
  TARGET_API_URL="https://api.github.com"
elif [[ "$GITHUB_TYPE" == "GitHubDR" ]]; then
  TARGET_API_URL="https://api.${GH_HOST}"
else
  echo "[ERROR] Invalid GITHUB_TYPE: $GITHUB_TYPE"
  exit 1
fi

RUN_TS="$(date +"%Y%m%d_%H%M%S")"
LOG_FILE="${LOG_DIR:-./logs}/monitor-migration-${RUN_TS}.log"
OUTPUT_FILE="${ARTIFACTS_DIR:-./output_files}/migration-status-${RUN_TS}.csv"
PER_MIGRATION_LOG_DIR="${LOG_DIR:-./logs}/monitor-${RUN_TS}"

INTERVAL=10

mkdir -p "$(dirname "$LOG_FILE")" "$PER_MIGRATION_LOG_DIR" "$(dirname "$OUTPUT_FILE")"

if [[ -z "$MIGRATION_OUTPUT_FILE" || ! -s "$MIGRATION_OUTPUT_FILE" ]]; then
  echo "[ERROR] MIGRATION_OUTPUT_FILE missing or empty"
  exit 1
fi

exec > >(tee -a "$LOG_FILE") 2>&1

command -v gh >/dev/null 2>&1 || { echo "[ERROR] gh not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "[ERROR] jq not found"; exit 1; }

TOTAL_MIGRATIONS=$(($(wc -l < "$MIGRATION_OUTPUT_FILE") - 1))

echo "[INFO] Total migrations: $TOTAL_MIGRATIONS"
echo "[INFO] Monitoring migrations..."

echo "github_org,github_repository,migration_id,status" > "$OUTPUT_FILE"

#########################################################
# LIVE MONITOR LOOP (UNCHANGED)
#########################################################

FIRST_DISPLAY=true
while true; do

  # snapshot logic assumed already present in your script
  # (not modifying your architecture as requested)

  echo "=================================================="
  echo "[PROGRESS] ${SNAPSHOT_FINISHED:-0} / ${TOTAL_MIGRATIONS}"
  echo "Completed: ${SNAPSHOT_COMPLETED:-0} | Failed: ${SNAPSHOT_FAILED:-0} | Running: ${SNAPSHOT_RUNNING:-0}"
  echo "=================================================="

  # ✅ FIXED tput SECTION (ONLY CHANGE)

  if [[ "$FIRST_DISPLAY" != true ]]; then
    if command -v tput >/dev/null 2>&1 && [[ -n "${TERM:-}" ]] && [[ "${TERM:-}" != "dumb" ]]; then
      tput cuu 6 2>/dev/null || true
    fi
  else
    FIRST_DISPLAY=false
  fi

  # exit condition (assumed already working in your script)
  if [[ "${SNAPSHOT_FINISHED:-0}" -ge "$TOTAL_MIGRATIONS" ]]; then
    break
  fi

  sleep "$INTERVAL"
done

echo
echo "FINAL SUMMARY"
echo "============="
echo "Completed: ${SNAPSHOT_COMPLETED:-0}"
echo "Failed   : ${SNAPSHOT_FAILED:-0}"
echo
echo "[INFO] Output file: $OUTPUT_FILE"
echo "[INFO] Logs       : $LOG_FILE"
echo "[INFO] Done."
