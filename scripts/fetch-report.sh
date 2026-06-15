#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/fetch-report.sh <stock_code> <year> [excel_file]

Environment:
  ANNUAL_REPORT_LINKS_XLSX    Default Excel path when [excel_file] is omitted.
                              Defaults to data/annual-report-links.xlsx.
  ANNUAL_REPORT_CACHE_DIR     Local TXT cache directory. Defaults to data-cache.
  ANNUAL_REPORT_WORKFLOW      Workflow file name. Defaults to annual-report.yml.
  ANNUAL_REPORT_KEEP_PDF      Pass true to keep PDF artifacts. Defaults to false.

Output:
  Prints TXT_READY lines for cached or downloaded TXT files.
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  usage >&2
  exit 2
fi

code="$(printf '%s' "$1" | tr -cd '0-9')"
year="$2"
excel_file="${3:-${ANNUAL_REPORT_LINKS_XLSX:-data/annual-report-links.xlsx}}"
workflow="${ANNUAL_REPORT_WORKFLOW:-annual-report.yml}"
cache_dir="${ANNUAL_REPORT_CACHE_DIR:-data-cache}"
keep_pdf="${ANNUAL_REPORT_KEEP_PDF:-false}"

if [ -z "$code" ] || [ "${#code}" -gt 6 ]; then
  echo "ERROR: stock_code must be 1 to 6 digits: $1" >&2
  exit 2
fi
while [ "${#code}" -lt 6 ]; do
  code="0$code"
done

case "$year" in
  [0-9][0-9][0-9][0-9]) ;;
  *)
    echo "ERROR: year must be four digits: $year" >&2
    exit 2
    ;;
esac

case "$keep_pdf" in
  true|false) ;;
  *)
    echo "ERROR: ANNUAL_REPORT_KEEP_PDF must be true or false" >&2
    exit 2
    ;;
esac

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir/.." rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$script_dir/..")"
cd "$repo_root"

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh is required and must be authenticated for this repository" >&2
  exit 127
fi

if [ ! -f "$excel_file" ]; then
  echo "ERROR: Excel file not found: $excel_file" >&2
  exit 1
fi

target_dir="$cache_dir/$code/$year"
existing_txt="$(find "$target_dir" -maxdepth 1 -type f -iname '*.txt' -print -quit 2>/dev/null || true)"
if [ -n "$existing_txt" ]; then
  find "$target_dir" -maxdepth 1 -type f -iname '*.txt' -print | sort | while IFS= read -r path; do
    printf 'TXT_READY %s\n' "$repo_root/$path"
  done
  exit 0
fi

branch="$(git rev-parse --abbrev-ref HEAD)"
started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

gh workflow run "$workflow" \
  --ref "$branch" \
  -f "excel_file=$excel_file" \
  -f "code=$code" \
  -f "year=$year" \
  -f "keep_pdf=$keep_pdf"

run_id=""
for _ in $(seq 1 30); do
  run_id="$(
    gh run list \
      --workflow "$workflow" \
      --branch "$branch" \
      --event workflow_dispatch \
      --limit 20 \
      --json databaseId,createdAt \
      --jq "map(select(.createdAt >= \"$started_at\")) | first | .databaseId // empty"
  )"
  if [ -n "$run_id" ]; then
    break
  fi
  sleep 2
done

if [ -z "$run_id" ]; then
  echo "ERROR: could not find the workflow run started at $started_at" >&2
  exit 1
fi

gh run watch "$run_id" --exit-status

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/annual-report.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

gh run download "$run_id" -D "$tmp_dir"

mkdir -p "$target_dir"
find "$tmp_dir" -type f -iname '*.txt' -exec cp {} "$target_dir/" \;
if [ "$keep_pdf" = "true" ]; then
  find "$tmp_dir" -type f \( -iname '*.pdf' -o -iname '*.PDF' \) -exec cp {} "$target_dir/" \;
fi

if ! find "$target_dir" -maxdepth 1 -type f -iname '*.txt' -print -quit | grep -q .; then
  echo "ERROR: workflow completed but no TXT was downloaded into $target_dir" >&2
  exit 1
fi

find "$target_dir" -maxdepth 1 -type f -iname '*.txt' -print | sort | while IFS= read -r path; do
  printf 'TXT_READY %s\n' "$repo_root/$path"
done
