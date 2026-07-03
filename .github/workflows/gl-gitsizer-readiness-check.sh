#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo "GitSizer Repository Readiness Check"
echo "=========================================="

THRESHOLD_BYTES="${GIT_SIZER_LARGE_FILE_THRESHOLD_BYTES:-419430400}" # 400 MB
THRESHOLD_MB=$(( THRESHOLD_BYTES / 1024 / 1024 ))

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

mkdir -p "$OUT_DIR/gitsizer-json" "$OUT_DIR/gitsizer-text" "$LOG_DIR" "$WORK_DIR" "$TOOLS_DIR"

LOG_FILE="$LOG_DIR/git-sizer-readiness-check.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INFO] Inventory file              : $INVENTORY_FILE"
echo "[INFO] Large file threshold        : ${THRESHOLD_MB} MB"
echo "[INFO] Output directory            : $OUT_DIR"
echo "[INFO] Log file                    : $LOG_FILE"

[[ -s "$INVENTORY_FILE" ]] || {
  echo "[ERROR] Inventory file missing or empty: $INVENTORY_FILE"
  exit 1
}

[[ -n "$SOURCE_GL_SERVER_URL" ]] || {
  echo "[ERROR] SOURCE_GL_SERVER_URL is required"
  exit 1
}

[[ -n "$GITLAB_USERNAME" ]] || {
  echo "[ERROR] GITLAB_USERNAME is required"
  exit 1
}

[[ -n "$GITLAB_API_PRIVATE_TOKEN" ]] || {
  echo "[ERROR] GITLAB_API_PRIVATE_TOKEN is required"
  exit 1
}

install_git_sizer() {
  if command -v git-sizer >/dev/null 2>&1; then
    echo "[INFO] git-sizer detected: $(git-sizer --version 2>/dev/null || true)"
    return
  fi

  echo "[INFO] git-sizer not found. Installing git-sizer locally..."

  command -v curl >/dev/null 2>&1 || {
    echo "[ERROR] curl is required to install git-sizer"
    exit 1
  }

  command -v jq >/dev/null 2>&1 || {
    echo "[ERROR] jq is required to install git-sizer"
    exit 1
  }

  command -v python3 >/dev/null 2>&1 || {
    echo "[ERROR] python3 is required to extract git-sizer release archive"
    exit 1
  }

  ASSET_URL="$(
    curl -fsSL "https://api.github.com/repos/github/git-sizer/releases/latest" |
      jq -r '.assets[]
        | select(.name | test("linux-amd64.*\\.zip$"))
        | .browser_download_url' |
      head -n1
  )"

  [[ -n "$ASSET_URL" && "$ASSET_URL" != "null" ]] || {
    echo "[ERROR] Unable to find linux-amd64 git-sizer release asset"
    exit 1
  }

  curl -fsSL "$ASSET_URL" -o "$TOOLS_DIR/git-sizer.zip"

  rm -rf "$TOOLS_DIR/git-sizer-extract"
  mkdir -p "$TOOLS_DIR/git-sizer-extract"

  python3 -m zipfile -e "$TOOLS_DIR/git-sizer.zip" "$TOOLS_DIR/git-sizer-extract"

  GIT_SIZER_BIN="$(find "$TOOLS_DIR/git-sizer-extract" -type f -name git-sizer | head -n1)"

  [[ -n "$GIT_SIZER_BIN" ]] || {
    echo "[ERROR] git-sizer binary not found after extraction"
    exit 1
  }

  chmod +x "$GIT_SIZER_BIN"
  cp "$GIT_SIZER_BIN" "$TOOLS_DIR/git-sizer"

  export PATH="$PWD/$TOOLS_DIR:$PATH"

  git-sizer --version || {
    echo "[ERROR] git-sizer installation validation failed"
    exit 1
  }

  echo "[INFO] git-sizer installed locally"
}

create_repo_list() {
  echo "[INFO] Reading repositories from $INVENTORY_FILE"

  python3 - "$INVENTORY_FILE" "$SOURCE_GL_SERVER_URL" > "$REPO_LIST_TSV" <<'PY'
import csv
import os
import sys

inventory_file = sys.argv[1]
source_gl_server_url = sys.argv[2].rstrip("/")

def norm(value):
    return (value or "").strip()

def get_value(row, candidates):
    lowered = {k.lower().strip(): v for k, v in row.items() if k is not None}
    for candidate in candidates:
        if candidate in lowered and norm(lowered[candidate]):
            return norm(lowered[candidate])
    return ""

def first_matching_value(row, include_words):
    for key, value in row.items():
        if key is None:
            continue
        key_l = key.lower().strip()
        if all(word in key_l for word in include_words) and norm(value):
            return norm(value)
    return ""

with open(inventory_file, newline="", encoding="utf-8-sig") as f:
    reader = csv.DictReader(f)

    if not reader.fieldnames:
        print("[ERROR] CSV header not found", file=sys.stderr)
        sys.exit(1)

    writer = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n")

    count = 0

    for row in reader:
        repo_url = (
            get_value(row, [
                "http_url_to_repo",
                "https_url_to_repo",
                "clone_url",
                "repo_url",
                "repository_url",
                "url",
                "web_url",
            ])
            or first_matching_value(row, ["url"])
        )

        project_path = (
            get_value(row, [
                "path_with_namespace",
                "full_path",
                "project_path",
                "repository_path",
                "repo_path",
                "path",
            ])
        )

        repo_name = (
            get_value(row, [
                "name",
                "repo_name",
                "repository_name",
                "project_name",
            ])
        )

        if not repo_name:
            repo_name = os.path.basename(project_path.rstrip("/")) if project_path else ""

        if not repo_url and project_path:
            repo_url = f"{source_gl_server_url}/{project_path.strip('/')}.git"

        if repo_url and not repo_url.endswith(".git") and "://" in repo_url:
            repo_url = repo_url.rstrip("/") + ".git"

        if not repo_url:
            print(f"[WARN] Skipping row because repo URL/path not found: {row}", file=sys.stderr)
            continue

        if not project_path:
            cleaned = repo_url.rstrip("/")
            if cleaned.endswith(".git"):
                cleaned = cleaned[:-4]
            project_path = cleaned.split("://", 1)[-1].split("/", 1)[-1]

        if not repo_name:
            repo_name = os.path.basename(project_path.rstrip("/"))

        writer.writerow([repo_name, repo_url, project_path])
        count += 1

    if count == 0:
        print("[ERROR] No repositories found from inventory file", file=sys.stderr)
        sys.exit(1)
PY

  echo "[INFO] Repository list generated: $REPO_LIST_TSV"
  echo "[INFO] Repository count: $(wc -l < "$REPO_LIST_TSV" | tr -d ' ')"
}

write_headers() {
  python3 - "$SUMMARY_CSV" "$LARGE_FILES_CSV" <<'PY'
import csv
import sys

summary_csv = sys.argv[1]
large_files_csv = sys.argv[2]

with open(summary_csv, "w", newline="", encoding="utf-8") as f:
    writer = csv.writer(f)
    writer.writerow([
        "repo_name",
        "project_path",
        "repo_url",
        "mirror_repo_size_mb",
        "largest_blob_mb",
        "large_file_count",
        "threshold_mb",
        "status",
    ])

with open(large_files_csv, "w", newline="", encoding="utf-8") as f:
    writer = csv.writer(f)
    writer.writerow([
        "repo_name",
        "project_path",
        "repo_url",
        "blob_sha",
        "blob_size_mb",
        "file_path",
        "status",
    ])
PY
}

safe_name() {
  echo "$1" | sed 's#[^A-Za-z0-9._-]#_#g'
}

append_summary() {
  local repo_name="$1"
  local project_path="$2"
  local repo_url="$3"
  local repo_size_mb="$4"
  local largest_blob_mb="$5"
  local large_file_count="$6"
  local status="$7"

  python3 - "$SUMMARY_CSV" "$repo_name" "$project_path" "$repo_url" "$repo_size_mb" "$largest_blob_mb" "$large_file_count" "$THRESHOLD_MB" "$status" <<'PY'
import csv
import sys

csv_file = sys.argv[1]
row = sys.argv[2:]

with open(csv_file, "a", newline="", encoding="utf-8") as f:
    writer = csv.writer(f)
    writer.writerow(row)
PY
}

append_large_files() {
  local large_tsv="$1"
  local repo_name="$2"
  local project_path="$3"
  local repo_url="$4"

  python3 - "$large_tsv" "$LARGE_FILES_CSV" "$repo_name" "$project_path" "$repo_url" <<'PY'
import csv
import sys

large_tsv = sys.argv[1]
large_csv = sys.argv[2]
repo_name = sys.argv[3]
project_path = sys.argv[4]
repo_url = sys.argv[5]

with open(large_csv, "a", newline="", encoding="utf-8") as out_f:
    writer = csv.writer(out_f)

    with open(large_tsv, "r", encoding="utf-8") as in_f:
        for line in in_f:
            line = line.rstrip("\n")
            if not line:
                continue

            parts = line.split("\t", 2)
            blob_sha = parts[0]
            blob_size_mb = parts[1]
            file_path = parts[2] if len(parts) > 2 else ""

            writer.writerow([
                repo_name,
                project_path,
                repo_url,
                blob_sha,
                blob_size_mb,
                file_path,
                "FAILED",
            ])
PY
}

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

  export GIT_ASKPASS="$PWD/$ASKPASS_SCRIPT"
  export GIT_TERMINAL_PROMPT=0
}

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
    echo "[INFO] Checking repo       : $repo_name"
    echo "[INFO] Project path        : $project_path"
    echo "[INFO] Repo URL            : $repo_url"
    echo "--------------------------------------------------"

    rm -rf "$repo_dir"

    if ! git clone --mirror "$repo_url" "$repo_dir"; then
      echo "[ERROR] Failed to clone repository: $repo_url"

      append_summary "$repo_name" "$project_path" "$repo_url" "0" "0" "0" "FAILED_CLONE"
      overall_failure=1
      failed_repos=$((failed_repos + 1))
      continue
    fi

    repo_size_mb="$(du -sm "$repo_dir" | awk '{print $1}')"

    pushd "$repo_dir" >/dev/null

    git-sizer --json > "../../$OUT_DIR/gitsizer-json/${safe_repo_name}.json" 2>/dev/null || true
    git-sizer > "../../$OUT_DIR/gitsizer-text/${safe_repo_name}.txt" 2>/dev/null || true

    large_tsv="../../$OUT_DIR/${safe_repo_name}-large-files.tsv"

    git rev-list --objects --all |
      git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' |
      awk -v threshold="$THRESHOLD_BYTES" '
        $1 == "blob" && $3+0 > threshold {
          path=$4
          for (i=5; i<=NF; i++) {
            path=path " " $i
          }
          printf "%s\t%.2f\t%s\n", $2, $3/1024/1024, path
        }
      ' > "$large_tsv"

    largest_blob_mb="$(
      git rev-list --objects --all |
        git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' |
        awk '
          $1 == "blob" {
            if ($3 > max) max=$3
          }
          END {
            if (max == "") max=0
            printf "%.2f", max/1024/1024
          }
        '
    )"

    popd >/dev/null

    large_file_count="$(wc -l < "$OUT_DIR/${safe_repo_name}-large-files.tsv" | tr -d ' ')"

    if [[ "$large_file_count" -gt 0 ]]; then
      echo "[ERROR] Repo has $large_file_count file(s) above ${THRESHOLD_MB} MB"
      append_large_files "$OUT_DIR/${safe_repo_name}-large-files.tsv" "$repo_name" "$project_path" "$repo_url"
      append_summary "$repo_name" "$project_path" "$repo_url" "$repo_size_mb" "$largest_blob_mb" "$large_file_count" "FAILED_LARGE_FILE_ABOVE_${THRESHOLD_MB}MB"

      overall_failure=1
      failed_repos=$((failed_repos + 1))
    else
      echo "[INFO] No files above ${THRESHOLD_MB} MB found"
      append_summary "$repo_name" "$project_path" "$repo_url" "$repo_size_mb" "$largest_blob_mb" "$large_file_count" "PASSED"
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
  echo "GitSizer reports           : $OUT_DIR/gitsizer-json and $OUT_DIR/gitsizer-text"
  echo "=========================================="

  if [[ "$overall_failure" -ne 0 ]]; then
    echo "[ERROR] GitSizer readiness check failed."
    echo "[ERROR] One or more repositories have files above ${THRESHOLD_MB} MB or failed clone."
    exit 1
  fi

  echo "[INFO] GitSizer readiness check passed."
}

install_git_sizer
create_repo_list
write_headers
run_checks
