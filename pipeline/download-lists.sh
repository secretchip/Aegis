#!/usr/bin/env bash
# Download the public allow- or blocklists referenced by
#   sources/{type}_urls.txt
# Writes raw downloads to public_{type}_lists/input/public_lists/.
# Tracks per-URL retry state in var/state/url_health_{type}.tsv;
# URLs that fail MAX_FAILURES (default 5) consecutive runs are promoted
# to sources/obsolete/{type}_obsolete.txt.
#
# Downloads run in parallel via xargs -P (default 12 workers,
# DOWNLOAD_CONCURRENCY env var to override). Each worker writes a per-URL
# .result file; aggregation happens single-threaded so logs and the health
# TSV are written without races.
#
# Usage: 0.download_public_lists.sh --type {block|allow}
set -uo pipefail

TYPE=""
while (($# > 0)); do
  case "$1" in
    --type)
      [[ $# -ge 2 ]] || { echo "ERROR: --type needs a value" >&2; exit 2; }
      TYPE="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,/^set -uo/p' "$0" | sed 's/^# \?//; /^set -uo/d'
      exit 0
      ;;
    *)
      echo "ERROR: unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

case "$TYPE" in
  block|allow) ;;
  *) echo "ERROR: --type must be 'block' or 'allow'" >&2; exit 2 ;;
esac

SCRIPT_NAME="download-${TYPE}lists"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKER_SCRIPT="${SCRIPT_DIR}/lib/bash/download-one-url.sh"
DOWNLOAD_CONCURRENCY="${DOWNLOAD_CONCURRENCY:-12}"

URL_LIST_FILE="$BASE_DIR/sources/${TYPE}_urls.txt"
OBSOLETE_URL_LIST_FILE="$BASE_DIR/sources/obsolete/${TYPE}_obsolete.txt"
HEALTH_TSV="$BASE_DIR/var/state/url_health_${TYPE}.tsv"

OUTPUT_DIR="$BASE_DIR/var/intake/${TYPE}/input/public_lists"
LOG_DIR="$BASE_DIR/var/logs/download-${TYPE}"
TRASH_DIR="$BASE_DIR/var/tmp/download"

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
ISO_NOW="$(date -Iseconds)"

MAX_FAILURES="${MAX_FAILURES:-5}"

SUCCESS_LOG="$LOG_DIR/download-$TYPE-success-$TIMESTAMP.log"
FAILED_LOG="$LOG_DIR/download-$TYPE-failed-$TIMESTAMP.log"
RUN_LOG="$LOG_DIR/download-$TYPE-run-$TIMESTAMP.log"
TRASH_FILE="$TRASH_DIR/trash.txt"
DUPLICATES_FILE="$TRASH_DIR/duplicates-$TYPE.txt"
WORK_FILE="$TRASH_DIR/work-$TYPE.tsv"
RESULTS_DIR="$TRASH_DIR/results-$TYPE"

mkdir -p "$OUTPUT_DIR" "$LOG_DIR" "$TRASH_DIR" "$(dirname "$HEALTH_TSV")"
touch "$OBSOLETE_URL_LIST_FILE" "$HEALTH_TSV"

[[ -x "$WORKER_SCRIPT" ]] || { echo "ERROR: worker script not executable: $WORKER_SCRIPT" >&2; exit 1; }

exec > >(tee -a "$RUN_LOG") 2>&1

echo "Cleaning previous input-$TYPE-automated files..."
find "$OUTPUT_DIR" -type f \( -name "input-$TYPE-automated-*.txt" -o -name "input-$TYPE-automated-*.meta" \) -print -delete
rm -rf "$RESULTS_DIR" "$WORK_FILE"
mkdir -p "$RESULTS_DIR"

> "$TRASH_FILE"
> "$DUPLICATES_FILE"
> "$WORK_FILE"

declare -A seen_urls
declare -A consec_failures
declare -A last_attempt_iso
declare -A last_success_iso

if [[ -s "$HEALTH_TSV" ]]; then
  while IFS=$'\t' read -r url cf la ls; do
    [[ "$url" == "url" ]] && continue
    [[ -z "$url" ]] && continue
    consec_failures["$url"]="${cf:-0}"
    last_attempt_iso["$url"]="${la:-}"
    last_success_iso["$url"]="${ls:-}"
  done < "$HEALTH_TSV"
fi

echo "Starting ${TYPE}list download run"
echo "URL source file     : $URL_LIST_FILE"
echo "Health TSV          : $HEALTH_TSV"
echo "Obsolete URL file   : $OBSOLETE_URL_LIST_FILE"
echo "Output dir          : $OUTPUT_DIR"
echo "Trash file          : $TRASH_FILE"
echo "Duplicates file     : $DUPLICATES_FILE"
echo "Success log         : $SUCCESS_LOG"
echo "Failed log          : $FAILED_LOG"
echo "Max failures        : $MAX_FAILURES"
echo "Concurrency         : $DOWNLOAD_CONCURRENCY"
echo

success_count=0
failed_count=0
trash_count=0
duplicate_count=0
obsolete_added_count=0
counter=1

if [[ ! -f "$URL_LIST_FILE" ]]; then
  echo "ERROR: URL source file not found: $URL_LIST_FILE"
  exit 1
fi

# Phase 1 (sequential): collect URLs into $WORK_FILE, applying comment-strip
# and de-duplication. One TAB-separated line per URL: counter \t url
echo "Reading source file: $URL_LIST_FILE"
while IFS= read -r line || [[ -n "$line" ]]; do
  original_line="$line"
  url="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  if [[ -z "$url" || "$url" =~ ^# ]]; then
    echo "$original_line" >> "$TRASH_FILE"
    ((trash_count++))
    continue
  fi

  if [[ -n "${seen_urls[$url]:-}" ]]; then
    echo "$url" >> "$DUPLICATES_FILE"
    ((duplicate_count++))
    continue
  fi
  seen_urls["$url"]=1

  printf '%s\t%s\n' "$counter" "$url" >> "$WORK_FILE"
  ((counter++))
done < "$URL_LIST_FILE"

total_urls=0
[[ -s "$WORK_FILE" ]] && total_urls=$(wc -l < "$WORK_FILE")
echo
echo "Dispatching $total_urls URLs to $DOWNLOAD_CONCURRENCY parallel workers..."
echo

# Phase 2 (parallel): each worker downloads one URL and writes a .result
# file into $RESULTS_DIR. No shared writes during this phase, so atomicity
# is trivial.
export OUTPUT_DIR RESULTS_DIR TYPE

if (( total_urls > 0 )); then
  < "$WORK_FILE" xargs -P "$DOWNLOAD_CONCURRENCY" -L 1 bash "$WORKER_SCRIPT"
fi

echo
echo "Aggregating per-URL results..."
# Phase 3 (sequential): walk .result files and update health state +
# success/failed logs. Single-threaded so health TSV writes are race-free.
shopt -s nullglob
for result in "$RESULTS_DIR"/*.result; do
  [[ -f "$result" ]] || continue
  IFS=$'\t' read -r r_counter r_url r_status r_outname < "$result"

  last_attempt_iso["$r_url"]="$ISO_NOW"
  if [[ "$r_status" == "success" ]]; then
    consec_failures["$r_url"]=0
    last_success_iso["$r_url"]="$ISO_NOW"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | SUCCESS | $r_url | $r_outname" >> "$SUCCESS_LOG"
    ((success_count++))
  else
    consec_failures["$r_url"]=$(( ${consec_failures["$r_url"]:-0} + 1 ))
    echo "$(date '+%Y-%m-%d %H:%M:%S') | FAILED (consec=${consec_failures[$r_url]}) | $r_url | $r_outname" >> "$FAILED_LOG"
    ((failed_count++))
  fi
done
shopt -u nullglob

# Promote chronically-failing URLs to the obsolete list.
echo "Checking for URLs at MAX_FAILURES threshold..."
for url in "${!consec_failures[@]}"; do
  if (( consec_failures["$url"] >= MAX_FAILURES )); then
    if ! grep -Fqx "$url" "$OBSOLETE_URL_LIST_FILE"; then
      echo "$url" >> "$OBSOLETE_URL_LIST_FILE"
      echo "Promoted to obsolete (>= $MAX_FAILURES consecutive failures): $url"
      ((obsolete_added_count++))
    fi
    unset 'consec_failures[$url]'
    unset 'last_attempt_iso[$url]'
    unset 'last_success_iso[$url]'
  fi
done

# Write health TSV (sorted by URL for stable diffs).
{
  printf 'url\tconsec_failures\tlast_attempt_iso\tlast_success_iso\n'
  for url in "${!consec_failures[@]}"; do
    printf '%s\t%s\t%s\t%s\n' \
      "$url" \
      "${consec_failures[$url]}" \
      "${last_attempt_iso[$url]:-}" \
      "${last_success_iso[$url]:-}"
  done | LC_ALL=C sort
} > "$HEALTH_TSV.tmp" && mv -f "$HEALTH_TSV.tmp" "$HEALTH_TSV"

echo
echo "Run completed"
echo "Successful downloads     : $success_count"
echo "Failed downloads         : $failed_count"
echo "Trash lines stored       : $trash_count"
echo "Duplicate URLs skipped   : $duplicate_count"
echo "URLs promoted to obsolete: $obsolete_added_count"
echo "Health TSV               : $HEALTH_TSV"
