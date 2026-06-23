#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

MIGRATION_OUTPUT_FILE="${MIGRATION_OUTPUT_FILE:-}"

GH_HOST="${GH_HOST:-}"

[[ -z "$GH_HOST" ]] && { echo "GH_HOST not set"; exit 1; }

if [[ "$GITHUB_TYPE" == "GitHub" ]]; then
  TARGET_API_URL="https://api.github.com"
elif [[ "$GITHUB_TYPE" == "GitHubDR" ]]; then
  TARGET_API_URL="https://api.${GH_HOST}"
else
  echo "Invalid GITHUB_TYPE"
  exit 1
fi

RUN_TS="$(date +"%Y%m%d_%H%M%S")"
LOG_DIR="${LOG_DIR:-./logs}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-./output_files}"

LOG_FILE="$LOG_DIR/monitor-$RUN_TS.log"
STATUS_FILE="$ARTIFACTS_DIR/status-$RUN_TS.csv"
OUTPUT_FILE="$ARTIFACTS_DIR/final-$RUN_TS.csv"
PER_MIG_DIR="$LOG_DIR/per-migration-$RUN_TS"

INTERVAL=5

mkdir -p "$LOG_DIR" "$ARTIFACTS_DIR" "$PER_MIG_DIR"

exec > >(tee -a "$LOG_FILE") 2>&1

command -v gh >/dev/null || { echo "gh missing"; exit 1; }

TOTAL_MIGRATIONS=$(($(wc -l < "$MIGRATION_OUTPUT_FILE") - 1))

CPU=$(nproc)
PARALLEL=$((CPU < TOTAL_MIGRATIONS ? CPU : TOTAL_MIGRATIONS))
[[ "$PARALLEL" -gt 8 ]] && PARALLEL=8

echo "[INFO] Total migrations: $TOTAL_MIGRATIONS"
echo "[INFO] Parallel workers: $PARALLEL"

INPUT_FILE=$(mktemp)
STATE_FILE=$(mktemp)

echo "github_org,repo,migration,status" > "$STATUS_FILE"

# ---------------- CSV parse ----------------
dequote() {
  local x="${1:-}"
  x="${x%\"}"
  x="${x#\"}"
  echo "$x"
}

parse_csv() {
  local line="$1"
  local IFS=","
  echo $line
}

# ---------------- Load input ----------------
{
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    line="${line//$'\r'/}"
    IFS=',' read -r org repo mig <<< "$line"
    echo "$org,$repo,$mig"
  done < <(tail -n +2 "$MIGRATION_OUTPUT_FILE")
} > "$INPUT_FILE"

# ---------------- Worker ----------------
run_one() {
  local line="$1"
  IFS=',' read -r org repo mig <<< "$line"

  echo "$org,$repo,$mig,STARTED" >> "$STATE_FILE"

  local log="$PER_MIG_DIR/${org}_${repo}_${mig}.log"

  if gh ado2gh wait-for-migration \
      --migration-id "$mig" \
      --target-api-url "$TARGET_API_URL" >"$log" 2>&1; then
    echo "$org,$repo,$mig,COMPLETED" >> "$STATE_FILE"
  else
    echo "$org,$repo,$mig,FAILED" >> "$STATE_FILE"
  fi
}

export -f run_one
export TARGET_API_URL STATE_FILE PER_MIG_DIR

# ---------------- RUN PARALLEL ----------------
xargs -a "$INPUT_FILE" -P "$PARALLEL" -I {} bash -c 'run_one "$@"' _ {} &
WORKER_PID=$!

# ---------------- LIVE STATE VIEW ----------------
render() {
  clear || true

  if [[ ! -s "$STATE_FILE" ]]; then
    echo "Waiting for migrations to start..."
    return
  fi

  local completed=0 failed=0 running=0

  while IFS=',' read -r o r m s; do
    case "$s" in
      COMPLETED) ((completed++)) ;;
      FAILED) ((failed++)) ;;
      STARTED) ((running++)) ;;
    esac
  done < "$STATE_FILE"

  local done=$((completed + failed))

  echo "=================================================="
  echo " Migration Monitor (CI Safe)"
  echo "=================================================="
  echo "Progress : $done / $TOTAL_MIGRATIONS"
  echo "Completed: $completed"
  echo "Failed   : $failed"
  echo "Running  : $running"
  echo "=================================================="
}

# ---------------- POLLING LOOP ----------------
while kill -0 "$WORKER_PID" 2>/dev/null; do
  render
  sleep "$INTERVAL"
done

wait "$WORKER_PID" || true

# final render
render

# ---------------- FINAL OUTPUT ----------------
awk -F',' '
{
  key=$3
  latest[key]=$0
}
END {
  for (k in latest) {
    print latest[k]
  }
}
' "$STATE_FILE" > "$OUTPUT_FILE"

echo ""
echo "FINAL SUMMARY"
echo "===================="

awk -F',' '
{
  if ($4=="COMPLETED") c++
  if ($4=="FAILED") f++
}
END {
  print "Completed:", c
  print "Failed:", f
}' "$OUTPUT_FILE"

echo ""
echo "Output file: $OUTPUT_FILE"
echo "Logs: $LOG_FILE"
