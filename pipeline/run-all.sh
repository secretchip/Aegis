#!/usr/bin/env bash
# Run the full AEGIS-DNS pipeline end to end. The execution order lives here
# (no longer encoded in numeric script-name prefixes). Each stage exits
# non-zero on failure; this script bails immediately under set -e.
#
# Env vars honored by the stages:
#   DOWNLOAD_CONCURRENCY  workers for stage 1 (default 12)
#   MAX_FAILURES          consecutive-failure threshold (default 5)
#   DROP_THRESHOLD_{BLOCK,ALLOW}  per-type drop % limits (defaults: see CLAUDE.md)
#   GROW_THRESHOLD_{BLOCK,ALLOW}  per-type grow % limits (default 500 each)
#   DROP_THRESHOLD / GROW_THRESHOLD  global fallbacks if per-type not set
#   RECONCILE_FORCE       bypass overwrite_original guard (default false)
#   VERIFY_FORCE          bypass verify-output thresholds (default false)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Capture the run start time so finalize-build can compute total duration.
mkdir -p "$ROOT_DIR/var/state"
date -u +%Y-%m-%dT%H:%M:%S+00:00 > "$ROOT_DIR/var/state/build-start.iso"

bash "$SCRIPT_DIR/download-lists.sh" --type block
bash "$SCRIPT_DIR/download-lists.sh" --type allow

python3 "$SCRIPT_DIR/cleanup.py" --type block
python3 "$SCRIPT_DIR/cleanup.py" --type allow

# Validate human-curated pins (sources/pins/{block,allow}.txt) and emit
# them as another manual-input file for dedupe to merge.
python3 "$SCRIPT_DIR/extract-pins.py"

bash "$SCRIPT_DIR/reconcile.sh"

bash "$SCRIPT_DIR/dedupe.sh" --type block
bash "$SCRIPT_DIR/dedupe.sh" --type allow

bash "$SCRIPT_DIR/verify.sh"

# Compute final stats, prepend ASCII headers to each public chunk,
# and refresh the README stats block. Runs before manifest so the
# manifest's sha256 sums reflect the headered files.
python3 "$SCRIPT_DIR/finalize-build.py"

python3 "$SCRIPT_DIR/manifest.py"
python3 "$SCRIPT_DIR/consumer-config.py"

bash "$SCRIPT_DIR/changelog.sh"
