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

export TERM=dumb

if [[ -z "$MIGRATION_OUTPUT_FILE" ]]; then
  echo "[ERROR] MIGRATION_OUTPUT_FILE not set"
  exit 1
elif [[ ! -s "$MIGRATION_OUTPUT_FILE" ]]; then
  echo "[ERROR] Migration output file missing/empty"
  exit 1
else
  echo "[INFO] Using migration output file: $MIGRATION_OUTPUT_FILE"
fi

exec > >(tee -a "$LOG_FILE") 2>&1

command -v gh >/dev/null 2>&1 || { echo "gh not found"; exit 1; }

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
# CSV helpers
#########################################################

dequote() {
  local field="${1:-}"
  field="${field%$'\r'}"
  field="${field%\"}"
  field="${field#\"}"
  echo "$field"
}

parse_csv_line() {
  local line="$1"
  local -a fields=()
  local field=""
  local in_quotes=false
  local char
  local i

  for ((i=0; i<${#line}; i++)); do
    char="${line:$i:1}"

    if [[ "$char" == '"' ]]; then
      if [[ "$in_quotes" == true ]]; then
        if [[ $((i + 1)) -lt ${#line} && "${line:$((i+1)):1}" == '"' ]]; then
          field+='"'
          ((i++))
        else
          in_quotes=false
        fi
      else
        in_quotes=true
      fi
    elif [[ "$char" == ',' && "$in_quotes" == false ]]; then
      fields+=("$field")
      field=""
    else
      field+="$char"
    fi
  done

  fields+=("$field")
  printf '%s\n' "${fields[@]}"
}

find_col() {
  local name="$1"
  for i in "${!cols[@]}"; do
    [[ "$(dequote "${cols[$i]}")" == "$name" ]] && { echo "$i"; return 0; }
  done
  return 1
}

#########################################################
# Status collector
#########################################################

collect_status_snapshot() {
  local completed=0 failed=0 running=0 queued=0

  if [[ -s "$RESULTS_TMP" ]]; then
    while IFS=',' read -r org repo migration state; do
      case "$state" in
        COMPLETED) ((completed++)) ;;
        FAILED) ((failed++)) ;;
        STARTED) ((running++)) ;;
        *) ((queued++)) ;;
      esac
    done < "$RESULTS_TMP"
  fi

  SNAPSHOT_COMPLETED=$completed
  SNAPSHOT_FAILED=$failed
  SNAPSHOT_RUNNING=$running
  SNAPSHOT_FINISHED=$((completed + failed))
}

#########################################################
# Build input
#########################################################

header="$(head -n 1 "$MIGRATION_OUTPUT_FILE" | tr -d '\r')"
readarray -t cols < <(parse_csv_line "$header")

ORG_IDX="$(find_col 'github_org')"
REPO_IDX="$(find_col 'github_repository')"
MIGRATION_ID_IDX="$(find_col 'migration_id')"

tail -n +2 "$MIGRATION_OUTPUT_FILE" | while IFS= read -r line; do
  line="${line//$'\r'/}"
  readarray -t flds < <(parse_csv_line "$line")

  org="$(dequote "${flds[$ORG_IDX]:-}")"
  repo="$(dequote "${flds[$REPO_IDX]:-}")"
  mig="$(dequote "${flds[$MIGRATION_ID_IDX]:-}")"

  [[ -z "$mig" ]] && continue

  echo "$org,$repo,$mig"
done > "$INPUT_TMP"

#########################################################
# Worker
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
# Run parallel (FIXED)
#########################################################

xargs -a "$INPUT_TMP" -P "$PARALLEL" -I {} bash -c 'run_monitor "$@"' _ {} &
WORKER_PID=$!

#########################################################
# Polling loop (CI SAFE)
#########################################################

FIRST=true

while kill -0 "$WORKER_PID" 2>/dev/null; do
  collect_status_snapshot

  if [[ "$FIRST" == true ]]; then
    FIRST=false
  fi

  echo "=================================================="
  echo "[INFO] Monitoring migrations"
  echo "Progress : ${SNAPSHOT_FINISHED}/${TOTAL_MIGRATIONS}"
  echo "Completed: ${SNAPSHOT_COMPLETED}"
  echo "Failed   : ${SNAPSHOT_FAILED}"
  echo "Running  : ${SNAPSHOT_RUNNING}"
  echo "=================================================="

  sleep "$INTERVAL"
done

wait "$WORKER_PID" || true

#########################################################
# Final output
#########################################################

awk -F',' '
{
  latest[$3]=$0
}
END {
  for (k in latest) print latest[k]
}
' "$RESULTS_TMP" >> "$OUTPUT_FILE"

rm -f "$RESULTS_TMP" "$INPUT_TMP"

#########################################################
# Summary
#########################################################

echo "FINAL SUMMARY"
echo "============="

TOTAL=$(wc -l < "$OUTPUT_FILE")
SUCCESS=$(grep -c "COMPLETED" "$OUTPUT_FILE" || true)
FAILED=$(grep -c "FAILED" "$OUTPUT_FILE" || true)

echo "Total : $TOTAL"
echo "Success: $SUCCESS"
echo "Failed : $FAILED"

if [[ "$FAILED" -gt 0 ]]; then
  echo "[ERROR] Some migrations failed"
  exit 1
fi
