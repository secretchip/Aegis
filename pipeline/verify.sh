#!/usr/bin/env bash
# Compare current pipeline-output line counts against a stored baseline.
# Fail-closed if any (type, kind) total dropped more than DROP_THRESHOLD%
# or grew more than GROW_THRESHOLD%.
#
# Behavior:
#   - First run (baseline missing or empty): save current values, exit 0.
#   - Subsequent runs: compare deltas; on threshold breach → fail.
#   - On success: update baseline.
#   - VERIFY_FORCE=true: threshold breaches downgrade to warn() and the
#     baseline is updated anyway. Use sparingly.
#
# Env vars:
#   DROP_THRESHOLD  Percent drop allowed before failing (default 20).
#   GROW_THRESHOLD  Percent growth allowed before failing (default 500).
#   VERIFY_FORCE    "true" to bypass threshold failures (default "false").

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BASELINE_FILE="${ROOT_DIR}/var/state/last-run-counts.tsv"
VERIFY_FORCE="${VERIFY_FORCE:-false}"

# Per-type thresholds. Resolution order:
#   1. DROP_THRESHOLD_{BLOCK,ALLOW} / GROW_THRESHOLD_{BLOCK,ALLOW}  (per-type)
#   2. DROP_THRESHOLD / GROW_THRESHOLD                              (global)
#   3. Defaults: drop 20 (block) / 30 (allow); grow 500 each
resolve_threshold() {
  local kind="$1" type="$2" default="$3" name val global_name
  name="${kind}_THRESHOLD_${type^^}"
  val="${!name:-}"
  if [[ -n "$val" ]]; then echo "$val"; return; fi
  global_name="${kind}_THRESHOLD"
  val="${!global_name:-}"
  if [[ -n "$val" ]]; then echo "$val"; return; fi
  echo "$default"
}

drop_threshold_for() {
  case "$1" in
    block) resolve_threshold DROP block 20 ;;
    allow) resolve_threshold DROP allow 30 ;;
    *)     resolve_threshold DROP "$1" 20 ;;
  esac
}

grow_threshold_for() {
  case "$1" in
    block) resolve_threshold GROW block 500 ;;
    allow) resolve_threshold GROW allow 500 ;;
    *)     resolve_threshold GROW "$1" 500 ;;
  esac
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

warn() {
  printf '[%s] WARNING: %s\n' "$(date '+%F %T')" "$*" >&2
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

count_glob() {
  # Sum line counts across files matching <dir>/<glob>; missing files = 0.
  # Two-arg form so $dir can contain whitespace without word-splitting the
  # glob pattern.
  local dir="$1" glob="$2"
  local total=0 f
  shopt -s nullglob
  for f in "$dir"/$glob; do
    [[ -f "$f" ]] || continue
    total=$((total + $(wc -l < "$f")))
  done
  shopt -u nullglob
  echo "$total"
}

mkdir -p "$(dirname "$BASELINE_FILE")"
touch "$BASELINE_FILE"

# Compute current totals.
declare -A CURRENT
for type in block allow; do
  CURRENT[${type}_domains]="$(count_glob "${ROOT_DIR}/public_${type}_lists/domains" "hosts-${type}-part*.txt")"
  CURRENT[${type}_ips]="$(count_glob "${ROOT_DIR}/public_${type}_lists/ips" "ips-${type}-part*.txt")"
done

write_baseline() {
  local tmp
  tmp="$(mktemp)"
  {
    printf 'type\tkind\tlines\n'
    for type in block allow; do
      for kind in domains ips; do
        printf '%s\t%s\t%d\n' "$type" "$kind" "${CURRENT[${type}_${kind}]}"
      done
    done
  } > "$tmp"
  mv -f "$tmp" "$BASELINE_FILE"
}

# Bootstrap path: empty or header-only baseline → save and exit.
nontrivial_lines="$(awk 'NR>1 && NF>0' "$BASELINE_FILE" | wc -l)"
if [[ "$nontrivial_lines" -eq 0 ]]; then
  log "No baseline found at $BASELINE_FILE — recording current totals as baseline."
  write_baseline
  for type in block allow; do
    for kind in domains ips; do
      log "  ${type}/${kind}: ${CURRENT[${type}_${kind}]} lines"
    done
  done
  exit 0
fi

# Load baseline into PREV.
declare -A PREV
while IFS=$'\t' read -r type kind lines; do
  [[ "$type" == "type" ]] && continue
  [[ -z "$type" ]] && continue
  PREV[${type}_${kind}]="$lines"
done < "$BASELINE_FILE"

# Compare and report.
breaches=0
for type in block allow; do
  drop_limit="$(drop_threshold_for "$type")"
  grow_limit="$(grow_threshold_for "$type")"
  for kind in domains ips; do
    local_key="${type}_${kind}"
    cur="${CURRENT[$local_key]}"
    prev="${PREV[$local_key]:-0}"
    delta=$((cur - prev))

    # Compute percent change vs prev. If prev is 0, any growth is treated
    # as 0% (no baseline to compare against meaningfully). Drops from 0
    # cannot happen.
    if [[ "$prev" -eq 0 ]]; then
      pct=0
      direction="="
    elif [[ "$cur" -lt "$prev" ]]; then
      pct=$(( (prev - cur) * 100 / prev ))
      direction="-"
    elif [[ "$cur" -gt "$prev" ]]; then
      pct=$(( (cur - prev) * 100 / prev ))
      direction="+"
    else
      pct=0
      direction="="
    fi

    log "  ${type}/${kind}: ${prev} -> ${cur} (delta ${direction}${pct}%)"

    if [[ "$direction" == "-" ]] && (( pct > drop_limit )); then
      breaches=$((breaches + 1))
      if [[ "$VERIFY_FORCE" == "true" ]]; then
        warn "VERIFY_FORCE=true: ${type}/${kind} dropped ${pct}% (limit ${drop_limit}%)"
      else
        warn "${type}/${kind} dropped ${pct}% (limit ${drop_limit}%)"
      fi
    elif [[ "$direction" == "+" ]] && (( pct > grow_limit )); then
      breaches=$((breaches + 1))
      if [[ "$VERIFY_FORCE" == "true" ]]; then
        warn "VERIFY_FORCE=true: ${type}/${kind} grew ${pct}% (limit ${grow_limit}%)"
      else
        warn "${type}/${kind} grew ${pct}% (limit ${grow_limit}%)"
      fi
    fi
  done
done

if [[ "$breaches" -gt 0 ]] && [[ "$VERIFY_FORCE" != "true" ]]; then
  fail "${breaches} threshold breach(es). Set VERIFY_FORCE=true (or DROP_THRESHOLD_<TYPE> / GROW_THRESHOLD_<TYPE>) to override."
fi

# Update baseline on success (or forced).
write_baseline
log "Baseline updated at $BASELINE_FILE"
