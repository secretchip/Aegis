#!/usr/bin/env bash
# Compute additions and removals per (type, kind) vs the previous snapshot,
# write them under var/changelog/, and append one row per (type, kind)
# to var/changelog/changelog.tsv.
#
# Snapshots are kept under var/state/snapshot/. The current concatenated
# sorted list is saved as <type>-<kind>.txt so the next run can diff against it.

set -Eeuo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DATE_UTC="$(date -u +%Y%m%d)"
ISO_NOW="$(date -Iseconds)"
SNAPSHOT_DIR="${ROOT_DIR}/var/state/snapshot"
CHANGELOG_DIR="${ROOT_DIR}/var/changelog"
SUMMARY_TSV="${CHANGELOG_DIR}/changelog.tsv"

mkdir -p "$SNAPSHOT_DIR" "$CHANGELOG_DIR"

if [[ ! -s "$SUMMARY_TSV" ]]; then
  printf 'run_ts\ttype\tkind\tadded\tremoved\ttotal_after\n' > "$SUMMARY_TSV"
fi

for type in block allow; do
  for kind in domains ips; do
    dir="${ROOT_DIR}/public_${type}_lists/${kind}"
    if [[ "$kind" == "domains" ]]; then
      glob="hosts-${type}-part*.txt"
    else
      glob="ips-${type}-part*.txt"
    fi

    cur="${SNAPSHOT_DIR}/${type}-${kind}.txt"
    cur_tmp="${cur}.tmp"
    prev="${SNAPSHOT_DIR}/${type}-${kind}.prev.txt"
    added="${CHANGELOG_DIR}/${DATE_UTC}-${type}-${kind}-added.txt"
    removed="${CHANGELOG_DIR}/${DATE_UTC}-${type}-${kind}-removed.txt"

    : > "$cur_tmp"
    shopt -s nullglob
    files=( "$dir"/$glob )
    shopt -u nullglob
    if (( ${#files[@]} > 0 )); then
      # Each chunk is locally sorted; ls -v concatenates them in numeric
      # order (part0, part1, …, part10). Result is globally sorted.
      # Strip ASCII '#' headers so they don't appear in the diff.
      ls -v "${files[@]}" | xargs cat | awk 'NF && !/^[[:space:]]*#/' >> "$cur_tmp"
    fi

    if [[ -f "$cur" ]]; then
      mv -f "$cur" "$prev"
    fi
    mv "$cur_tmp" "$cur"

    if [[ -f "$prev" ]]; then
      comm -13 "$prev" "$cur" > "$added"
      comm -23 "$prev" "$cur" > "$removed"
      added_count=$(wc -l < "$added")
      removed_count=$(wc -l < "$removed")
    else
      cp "$cur" "$added"
      : > "$removed"
      added_count=$(wc -l < "$added")
      removed_count=0
    fi

    total=$(wc -l < "$cur")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$ISO_NOW" "$type" "$kind" "$added_count" "$removed_count" "$total" \
      >> "$SUMMARY_TSV"
    printf '  %s/%s: +%s -%s (total %s)\n' \
      "$type" "$kind" "$added_count" "$removed_count" "$total"
  done
done

echo "Changelog written to ${CHANGELOG_DIR}/${DATE_UTC}-*.txt"
echo "Summary appended to ${SUMMARY_TSV}"
