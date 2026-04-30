#!/usr/bin/env bash
# Download a single URL. Designed to be invoked in parallel via xargs -P.
#
# Stdin args (passed by xargs -L 1): COUNTER URL
# Env vars (passed by parent):
#   OUTPUT_DIR   destination dir for input-${TYPE}-automated-*.txt
#   RESULTS_DIR  per-URL .result files for the parent to aggregate
#   TYPE         "block" or "allow"
#
# Output files written by this worker:
#   $OUTPUT_DIR/input-${TYPE}-automated-${counter}.txt   (success only)
#   $OUTPUT_DIR/input-${TYPE}-automated-${counter}.meta
#   $RESULTS_DIR/${counter}.result   TSV: counter \t url \t status \t output-basename
#
# Exit code is always 0 — failures are reported via the .result file so that
# xargs does not stop the rest of the batch.

set -uo pipefail

counter="${1:?counter required}"
url="${2:?url required}"

: "${OUTPUT_DIR:?OUTPUT_DIR not set}"
: "${RESULTS_DIR:?RESULTS_DIR not set}"
: "${TYPE:?TYPE not set}"

output_file="$OUTPUT_DIR/input-${TYPE}-automated-${counter}.txt"
metadata_file="$OUTPUT_DIR/input-${TYPE}-automated-${counter}.meta"
result_file="$RESULTS_DIR/${counter}.result"

if curl -fL --connect-timeout 20 --max-time 300 --retry 2 --retry-delay 2 \
   -A "cb/0.1" "$url" -o "$output_file" 2>/dev/null; then
  status="success"
else
  status="failed"
  rm -f "$output_file"
fi

{
  echo "source_url=$url"
  echo "downloaded_at=$(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "output_file=$(basename "$output_file")"
  echo "status=$status"
} > "$metadata_file"

printf '%s\t%s\t%s\t%s\n' "$counter" "$url" "$status" "$(basename "$output_file")" \
  > "$result_file"

# Single-line stdout per URL — xargs aggregates these in order of completion.
printf '[%s] %s: %s\n' "$counter" "$status" "$url"
