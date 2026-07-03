#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo "GitSizer Repository Readiness Check"
echo "=========================================="

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
THRESHOLD_BYTES="${GIT_SIZER_LARGE_FILE_THRESHOLD_BYTES:-419430400}" # 400 MB
THRESHOLD_MB=$((THRESHOLD_BYTES / 1024 / 1024))

INVENTORY_FILE="${INVENTORY_FILE:-gitlab-stats.csv}"
SOURCE_GL_SERVER_URL="${SOURCE_GL_SERVER_URL:-}"
GITLAB_USERNAME="${GITLAB_USERNAME:-}"
GITLAB_API_PRIVATE_TOKEN="${GITLAB_API_PRIVATE_TOKEN:-}"

OUT_DIR="output_files/git-sizer-readiness"
LOG_DIR="logs"
WORK_DIR=".gitsizer-work"
TOOLS_DIR=".tools"

SUMMARY_CSV="$OUT_DIR/repo-size-summary.csv"
LARGE_FILES_CSV="$OUT_DIR/large-files-above-${THRESHOLD_MB}mb.csv"
REPO_LIST_TSV="$OUT_DIR/repositories.tsv"

mkdir -p "$OUT_DIR/gitsizer-json" \
         "$OUT_DIR/gitsizer-text" \
         "$LOG_DIR" \
         "$WORK_DIR" \
         "$TOOLS_DIR"

LOG_FILE="$LOG_DIR/git-sizer-readiness-check.log"

exec > >(tee -a "$LOG_FILE") 2>&1

ROOT_DIR="$(pwd)"

echo "[INFO] Inventory file       : $INVENTORY_FILE"
echo "[INFO] Large file threshold : ${THRESHOLD_MB} MB"
echo "[INFO] Output directory     : $OUT_DIR"
echo "[INFO] Log file             : $LOG_FILE"

# ------------------------------------------------------------
# Validation
# ------------------------------------------------------------
if [[ ! -s "$INVENTORY_FILE" ]]; then
  echo "[ERROR] Inventory file missing or empty: $INVENTORY_FILE"
  exit 1
fi

if [[ -z "$SOURCE_GL_SERVER_URL" ]]; then
  echo "[ERROR] SOURCE_GL_SERVER_URL is required"
  exit 1
fi

if [[ -z "$GITLAB_USERNAME" ]]; then
  echo "[ERROR] GITLAB_USERNAME is required"
  exit 1
fi

if [[ -z "$GITLAB_API_PRIVATE_TOKEN" ]]; then
  echo "[ERROR] GITLAB_API_PRIVATE_TOKEN is required"
  exit 1
fi

# ------------------------------------------------------------
# CSV helper
# ------------------------------------------------------------
csv_quote() {
  local value="${1:-}"
  value="${value//\"/\"\"}"
  printf '"%s"' "$value"
}

csv_row() {
  local first="true"
  local value

  for value in "$@"; do
    if [[ "$first" == "true" ]]; then
      first="false"
    else
      printf ','
    fi

    csv_quote "$value"
  done

  printf '\n'
}

safe_name() {
  echo "$1" | sed 's#[^A-Za-z0-9._-]#_#g'
}

# ------------------------------------------------------------
# Install git-sizer if missing
# ------------------------------------------------------------
install_git_sizer() {
  if command -v git-sizer >/dev/null 2>&1; then
    echo "[INFO] git-sizer detected: $(git-sizer --version 2>/dev/null || true)"
    return
  fi

  echo "[INFO] git-sizer not found. Installing git-sizer locally..."

  if ! command -v curl >/dev/null 2>&1; then
    echo "[ERROR] curl is required to install git-sizer"
    exit 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "[ERROR] jq is required to install git-sizer"
    exit 1
  fi

  if ! command -v unzip >/dev/null 2>&1; then
    echo "[WARN] unzip is not installed."

    if sudo -n true >/dev/null 2>&1; then
      echo "[INFO] Installing unzip..."
      sudo apt-get update -y
      sudo apt-get install -y unzip
    else
      echo "[ERROR] unzip is required to extract git-sizer."
      echo "[ACTION REQUIRED] Install unzip on the runner or add it in getting-env-ready job."
      exit 1
    fi
  fi

  ASSET_URL="$(
    curl -fsSL "https://api.github.com/repos/github/git-sizer/releases/latest" |
      jq -r '.assets[]
        | select(.name | test("linux-amd64.*\\.zip$"))
        | .browser_download_url' |
      head -n1
  )"

  if [[ -z "$ASSET_URL" || "$ASSET_URL" == "null" ]]; then
    echo "[ERROR] Unable to find linux-amd64 git-sizer release asset"
    exit 1
  fi

  echo "[INFO] Downloading git-sizer from latest GitHub release..."

  curl -fsSL "$ASSET_URL" -o "$TOOLS_DIR/git-sizer.zip"

  rm -rf "$TOOLS_DIR/git-sizer-extract"
  mkdir -p "$TOOLS_DIR/git-sizer-extract"

  unzip -q "$TOOLS_DIR/git-sizer.zip" -d "$TOOLS_DIR/git-sizer-extract"

  GIT_SIZER_BIN="$(find "$TOOLS_DIR/git-sizer-extract" -type f -name git-sizer | head -n1)"

  if [[ -z "$GIT_SIZER_BIN" ]]; then
    echo "[ERROR] git-sizer binary not found after extraction"
    exit 1
  fi

  chmod +x "$GIT_SIZER_BIN"
  cp "$GIT_SIZER_BIN" "$TOOLS_DIR/git-sizer"
  chmod +x "$TOOLS_DIR/git-sizer"

  export PATH="$ROOT_DIR/$TOOLS_DIR:$PATH"

  git-sizer --version >/dev/null 2>&1 || {
    echo "[ERROR] git-sizer installation validation failed"
    exit 1
  }

  echo "[INFO] git-sizer installed locally: $ROOT_DIR/$TOOLS_DIR/git-sizer"
}

# ------------------------------------------------------------
# Create repository list from gitlab-stats.csv
# No Python is used here.
# This AWK parser handles normal CSV and quoted CSV fields.
# ------------------------------------------------------------
create_repo_list() {

  awk -F',' '
  NR==1 {

      for(i=1;i<=NF;i++) {

          gsub(/"/,"",$i)

          if(tolower($i)=="namespace")
              ns=i

          if(tolower($i)=="project")
              proj=i

          if(tolower($i)=="full_url")
              url=i
      }

      next
  }

  {

      namespace=$ns
      project=$proj
      repo_url=$url

      gsub(/"/,"",namespace)
      gsub(/"/,"",project)
      gsub(/"/,"",repo_url)

      print project "\t" repo_url "\t" namespace "/" project
  }
  ' "$INVENTORY_FILE" > "$REPO_LIST_TSV"

  echo "[INFO] Repository list generated: $REPO_LIST_TSV"
  echo "[INFO] Repository count: $(wc -l < "$REPO_LIST_TSV" | tr -d ' ')"
}

# ------------------------------------------------------------
# Create CSV headers
# ------------------------------------------------------------
write_headers() {
  csv_row \
    "repo_name" \
    "project_path" \
    "repo_url" \
    "mirror_repo_size_mb" \
    "largest_blob_mb" \
    "large_file_count" \
    "threshold_mb" \
    "status" \
    > "$SUMMARY_CSV"

  csv_row \
    "repo_name" \
    "project_path" \
    "repo_url" \
    "blob_sha" \
    "blob_size_mb" \
    "file_path" \
    "status" \
    > "$LARGE_FILES_CSV"
}

append_summary() {
  local repo_name="$1"
  local project_path="$2"
  local repo_url="$3"
  local repo_size_mb="$4"
  local largest_blob_mb="$5"
  local large_file_count="$6"
  local status="$7"

  csv_row \
    "$repo_name" \
    "$project_path" \
    "$repo_url" \
    "$repo_size_mb" \
    "$largest_blob_mb" \
    "$large_file_count" \
    "$THRESHOLD_MB" \
    "$status" \
    >> "$SUMMARY_CSV"
}

append_large_files() {
  local large_tsv="$1"
  local repo_name="$2"
  local project_path="$3"
  local repo_url="$4"

  while IFS=$'\t' read -r blob_sha blob_size_mb file_path; do
    [[ -z "${blob_sha:-}" ]] && continue

    csv_row \
      "$repo_name" \
      "$project_path" \
      "$repo_url" \
      "$blob_sha" \
      "$blob_size_mb" \
      "$file_path" \
      "FAILED" \
      >> "$LARGE_FILES_CSV"
  done < "$large_tsv"
}

# ------------------------------------------------------------
# Git authentication for GitLab clone
# ------------------------------------------------------------
create_askpass() {
  ASKPASS_SCRIPT="$WORK_DIR/git-askpass.sh"

  cat > "$ASKPASS_SCRIPT" <<EOF
#!/usr/bin/env bash
case "\$1" in
  *Username*) echo "$GITLAB_USERNAME" ;;
  *Password*) echo "$GITLAB_API_PRIVATE_TOKEN" ;;
  *) echo "$GITLAB_API_PRIVATE_TOKEN" ;;
esac
EOF

  chmod +x "$ASKPASS_SCRIPT"

  export GIT_ASKPASS="$ROOT_DIR/$ASKPASS_SCRIPT"
  export GIT_TERMINAL_PROMPT=0
}

# ------------------------------------------------------------
# Run GitSizer and 400 MB blob/file validation
# ------------------------------------------------------------
run_checks() {
  local overall_failure=0
  local total_repos=0
  local failed_repos=0
  local passed_repos=0

  create_askpass

  while IFS=$'\t' read -r repo_name repo_url project_path; do
    total_repos=$((total_repos + 1))

    safe_repo_name="$(safe_name "$project_path")"
    repo_dir="$WORK_DIR/${safe_repo_name}.git"

    echo
    echo "--------------------------------------------------"
    echo "[INFO] Checking repo : $repo_name"
    echo "[INFO] Project path  : $project_path"
    echo "[INFO] Repo URL      : $repo_url"
    echo "--------------------------------------------------"

    rm -rf "$repo_dir"

    if ! git clone --mirror "$repo_url" "$repo_dir"; then
      echo "[ERROR] Failed to clone repository: $repo_url"

      append_summary \
        "$repo_name" \
        "$project_path" \
        "$repo_url" \
        "0" \
        "0" \
        "0" \
        "FAILED_CLONE"

      overall_failure=1
      failed_repos=$((failed_repos + 1))
      continue
    fi

    repo_size_mb="$(du -sm "$repo_dir" | awk '{print $1}')"

    large_tsv="$OUT_DIR/${safe_repo_name}-large-files.tsv"
    large_tsv_abs="$ROOT_DIR/$large_tsv"

    pushd "$repo_dir" >/dev/null

    echo "[INFO] Running git-sizer for $repo_name"

    git-sizer --json > "$ROOT_DIR/$OUT_DIR/gitsizer-json/${safe_repo_name}.json" 2>/dev/null || true
    git-sizer > "$ROOT_DIR/$OUT_DIR/gitsizer-text/${safe_repo_name}.txt" 2>/dev/null || true

    echo "[INFO] Checking for blobs/files above ${THRESHOLD_MB} MB"

    git rev-list --objects --all |
      git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' |
      awk -v threshold="$THRESHOLD_BYTES" '
        $1 == "blob" && $3 + 0 > threshold {
          path = $4

          for (i = 5; i <= NF; i++) {
            path = path " " $i
          }

          if (path == "") {
            path = "<path unavailable>"
          }

          printf "%s\t%.2f\t%s\n", $2, $3 / 1024 / 1024, path
        }
      ' > "$large_tsv_abs"

    largest_blob_mb="$(
      git rev-list --objects --all |
        git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' |
        awk '
          $1 == "blob" {
            if ($3 > max) {
              max = $3
            }
          }

          END {
            if (max == "") {
              max = 0
            }

            printf "%.2f", max / 1024 / 1024
          }
        '
    )"

    popd >/dev/null

    large_file_count="$(wc -l < "$large_tsv" | tr -d ' ')"

    if [[ "$large_file_count" -gt 0 ]]; then
      echo "[ERROR] Repo has $large_file_count blob/file(s) above ${THRESHOLD_MB} MB"

      append_large_files \
        "$large_tsv" \
        "$repo_name" \
        "$project_path" \
        "$repo_url"

      append_summary \
        "$repo_name" \
        "$project_path" \
        "$repo_url" \
        "$repo_size_mb" \
        "$largest_blob_mb" \
        "$large_file_count" \
        "FAILED_LARGE_FILE_ABOVE_${THRESHOLD_MB}MB"

      overall_failure=1
      failed_repos=$((failed_repos + 1))
    else
      echo "[INFO] No blobs/files above ${THRESHOLD_MB} MB found"

      append_summary \
        "$repo_name" \
        "$project_path" \
        "$repo_url" \
        "$repo_size_mb" \
        "$largest_blob_mb" \
        "$large_file_count" \
        "PASSED"

      passed_repos=$((passed_repos + 1))
    fi

    rm -rf "$repo_dir"

  done < "$REPO_LIST_TSV"

  echo
  echo "=========================================="
  echo "GitSizer Readiness Summary"
  echo "=========================================="
  echo "Total repositories checked : $total_repos"
  echo "Passed repositories        : $passed_repos"
  echo "Failed repositories        : $failed_repos"
  echo "Summary CSV                : $SUMMARY_CSV"
  echo "Large files CSV            : $LARGE_FILES_CSV"
  echo "GitSizer JSON reports      : $OUT_DIR/gitsizer-json"
  echo "GitSizer text reports      : $OUT_DIR/gitsizer-text"
  echo "=========================================="

  if [[ "$overall_failure" -ne 0 ]]; then
    echo "[ERROR] GitSizer readiness check failed."
    echo "[ERROR] One or more repositories have files above ${THRESHOLD_MB} MB or failed clone."
    exit 1
  fi

  echo "[INFO] GitSizer readiness check passed."
}

# ------------------------------------------------------------
# Main execution
# ------------------------------------------------------------
install_git_sizer
create_repo_list
write_headers
run_checks
