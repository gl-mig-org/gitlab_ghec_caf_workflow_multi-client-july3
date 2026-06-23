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
  echo "[ERROR] Invalid GITHUB_TYPE: $GITHUB_TYPE"
  exit 1
fi

RUN_TS="$(date +"%Y%m%d_%H%M%S")"
LOG_FILE="${MONITOR_MIGRATION_LOG:-$LOG_DIR/monitor-migration}-${RUN_TS}.log"
OUTPUT_FILE="$ARTIFACTS_DIR/migration-status-${RUN_TS}.csv"
PER_MIGRATION_LOG_DIR="$LOG_DIR/monitor-migration-${RUN_TS}"

INTERVAL=10

mkdir -p "$LOG_DIR" "$ARTIFACTS_DIR" "$PER_MIGRATION_LOG_DIR"

if [[ -z "$MIGRATION_OUTPUT_FILE" ]]; then
  echo "[ERROR] MIGRATION_OUTPUT_FILE not set"
  exit 1
elif [[ ! -s "$MIGRATION_OUTPUT_FILE" ]]; then
  echo "[ERROR] Missing/empty file: $MIGRATION_OUTPUT_FILE"
  exit 1
fi

exec > >(tee -a "$LOG_FILE") 2>&1

command -v gh >/dev/null 2>&1 || { echo "gh not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found"; exit 1; }
command -v nproc >/dev/null 2>&1 || { echo "nproc not found"; exit 1; }

TOTAL_MIGRATIONS=$(($(wc -l < "$MIGRATION_OUTPUT_FILE") - 1))
CPU_COUNT=$(nproc)
PARALLEL=$(( CPU_COUNT < TOTAL_MIGRATIONS ? CPU_COUNT : TOTAL_MIGRATIONS ))
PARALLEL=$(( PARALLEL > 8 ? 8 : PARALLEL ))

echo "[INFO] Starting migration monitoring..."
echo "[INFO] Total migrations: $TOTAL_MIGRATIONS"
echo "[INFO] Parallel workers: $PARALLEL"

RESULTS_TMP=$(mktemp)
INPUT_TMP=$(mktemp)

echo "github_org,github_repository,migration_id,status" > "$OUTPUT_FILE"

# -------------------------
# CSV helpers
# -------------------------
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

  for ((i=0; i<${#line}; i++)); do
    char="${line:$i:1}"

    if [[ "$char" == '"' ]]; then
      in_quotes=$([[ "$in_quotes" == true ]] && echo false || echo true)
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

append_repo_to_list() {
  local current="${1:-}"
  local value="${2:-}"

  [[ -z "$value" ]] && echo "$current" && return
  [[ -z "$current" ]] && echo "$value" && return
  echo "$current, $value"
}

collect_status_snapshot() {
  local completed_count=0 failed_count=0 running_count=0 queued_count=0
  local completed_repos="" failed_repos="" in_progress_repos="" queued_repos=""

  declare -A latest_status=()

  if [[ -s "$RESULTS_TMP" ]]; then
    while IFS=',' read -r org repo migration state; do
      latest_status["$migration"]="$state"
    done < "$RESULTS_TMP"
  fi

  while IFS= read -r line; do
    IFS=',' read -r org repo migration <<< "$line"
    repo_name="${org}/${repo}"

    case "${latest_status[$migration]:-QUEUED}" in
      COMPLETED)
        ((completed_count++))
        completed_repos="$(append_repo_to_list "$completed_repos" "$repo_name")"
        ;;
      FAILED)
        ((failed_count++))
        failed_repos="$(append_repo_to_list "$failed_repos" "$repo_name")"
        ;;
      STARTED)
        ((running_count++))
        in_progress_repos="$(append_repo_to_list "$in_progress_repos" "$repo_name")"
        ;;
      *)
        ((queued_count++))
        queued_repos="$(append_repo_to_list "$queued_repos" "$repo_name")"
        ;;
    esac
  done < "$INPUT_TMP"

  SNAPSHOT_COMPLETED=$completed_count
  SNAPSHOT_FAILED=$failed_count
  SNAPSHOT_RUNNING=$running_count
  SNAPSHOT_QUEUED=$queued_count
  SNAPSHOT_FINISHED=$((completed_count + failed_count))

  SNAPSHOT_COMPLETED_REPOS="${completed_repos:-None}"
  SNAPSHOT_FAILED_REPOS="${failed_repos:-None}"
  SNAPSHOT_IN_PROGRESS_REPOS="${in_progress_repos:-None}"
  SNAPSHOT_QUEUED_REPOS="${queued_repos:-None}"
}

# -------------------------
# Validate CSV header
# -------------------------
header="$(head -n 1 "$MIGRATION_OUTPUT_FILE" | tr -d '\r')"
readarray -t cols < <(parse_csv_line "$header")

ORG_IDX="$(find_col 'github_org')"
REPO_IDX="$(find_col 'github_repository')"
MIGRATION_ID_IDX="$(find_col 'migration_id')"

# -------------------------
# Build input
# -------------------------
while IFS= read -r raw; do
  line="$(echo "$raw" | tr -d '\r')"
  [[ -z "$line" ]] && continue

  readarray -t flds < <(parse_csv_line "$line")

  echo "$(dequote "${flds[$ORG_IDX]}"),$(dequote "${flds[$REPO_IDX]}"),$(dequote "${flds[$MIGRATION_ID_IDX]}")"
done < <(tail -n +2 "$MIGRATION_OUTPUT_FILE") > "$INPUT_TMP"

# -------------------------
# Worker
# -------------------------
run_monitor() {
  local line="$1"
  IFS=',' read -r org repo migration <<< "$line"

  local log_file="$PER_MIGRATION_LOG_DIR/${org}_${repo}_${migration}.log"

  echo "$org,$repo,$migration,STARTED" >> "$RESULTS_TMP"

  {
    gh ado2gh wait-for-migration \
      --migration-id "$migration" \
      --target-api-url "$TARGET_API_URL"
  } > "$log_file" 2>&1

  local status="FAILED"
  [[ $? -eq 0 ]] && status="COMPLETED"

  echo "$org,$repo,$migration,$status" >> "$RESULTS_TMP"
}

export -f run_monitor
export TARGET_API_URL RESULTS_TMP PER_MIGRATION_LOG_DIR

cat "$INPUT_TMP" | xargs -I {} -P "$PARALLEL" bash -c 'run_monitor "$@"' _ {}

MONITOR_PID=$!

# -------------------------
# LIVE MONITOR LOOP (FIXED)
# -------------------------

IS_TTY=false
[[ -t 1 ]] && IS_TTY=true

FIRST_DISPLAY=true

while kill -0 "$MONITOR_PID" 2>/dev/null; do
  collect_status_snapshot

  if [[ "$FIRST_DISPLAY" == true ]]; then
    FIRST_DISPLAY=false
  else
    if $IS_TTY && command -v tput >/dev/null 2>&1; then
      tput cuu 6 || true
    fi
  fi

  echo "=================================================="
  echo "[$(date '+%H:%M:%S')] Monitoring migrations..."
  echo "Progress : ${SNAPSHOT_FINISHED}/${TOTAL_MIGRATIONS}"
  echo "Completed: ${SNAPSHOT_COMPLETED} | Failed: ${SNAPSHOT_FAILED} | Running: ${SNAPSHOT_RUNNING}"
  echo "Elapsed  : $(date +%s)"
  echo "=================================================="

  sleep "$INTERVAL"
done

wait "$MONITOR_PID" || true
