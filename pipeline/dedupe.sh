#!/usr/bin/env bash
# Merge, sort, deduplicate, and chunk the cleaned + reconciled domain/IP
# files for either the block or allow side. Trusts upstream validation
# (steps 1 and 1.5); does no validation of its own.
#
# Usage: 2.dedupe.sh --type {block|allow}
set -euo pipefail

TYPE=""
while (($# > 0)); do
  case "$1" in
    --type)
      [[ $# -ge 2 ]] || { echo "ERROR: --type needs a value" >&2; exit 2; }
      TYPE="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//; /^set -euo/d'
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

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLISHED_DIR="$BASE_DIR/public_${TYPE}_lists"
INPUT_DIR_MANUAL="$BASE_DIR/var/intake/${TYPE}/input"
INPUT_DIR_DOMAINS="$PUBLISHED_DIR/domains"
INPUT_DIR_IPS="$PUBLISHED_DIR/ips"

MANUAL_ARCHIVE_DIR="$BASE_DIR/var/logs/dedupe-${TYPE}/archive"

TEMP_DIR="$BASE_DIR/var/tmp/dedupe-${TYPE}"
LOG_DIR="$BASE_DIR/var/logs/dedupe-${TYPE}"

OUTPUT_DIR_DOMAINS="$INPUT_DIR_DOMAINS"
OUTPUT_DIR_IPS="$INPUT_DIR_IPS"

DOMAINS_MERGED="$TEMP_DIR/all-unique-${TYPE}-domains.txt"
IPS_MERGED="$TEMP_DIR/all-unique-${TYPE}-ips.txt"

DOMAIN_PREFIX="$TEMP_DIR/chunk-${TYPE}-domains-"
IP_PREFIX="$TEMP_DIR/chunk-${TYPE}-ips-"

MAX_LINES=2000000

mkdir -p "$TEMP_DIR" "$LOG_DIR" "$OUTPUT_DIR_DOMAINS" "$OUTPUT_DIR_IPS" "$MANUAL_ARCHIVE_DIR"

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_FILE="$LOG_DIR/dedupe-${TYPE}-${TIMESTAMP}.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "[*] =================================================="
echo "[*] Script started at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "[*] Log file: $LOG_FILE"
echo "[*] TYPE: $TYPE"
echo "[*] BASE_DIR: $BASE_DIR"
echo "[*] INPUT_DIR_MANUAL: $INPUT_DIR_MANUAL"
echo "[*] INPUT_DIR_DOMAINS: $INPUT_DIR_DOMAINS"
echo "[*] INPUT_DIR_IPS: $INPUT_DIR_IPS"
echo "[*] OUTPUT_DIR_DOMAINS: $OUTPUT_DIR_DOMAINS"
echo "[*] OUTPUT_DIR_IPS: $OUTPUT_DIR_IPS"
echo "[*] TEMP_DIR: $TEMP_DIR"
echo "[*] =================================================="

echo "[*] Discovering input files..."

MANUAL_FILES=("$INPUT_DIR_MANUAL"/input-"$TYPE"*.txt)
DOMAIN_FILES=("$INPUT_DIR_DOMAINS"/hosts-"$TYPE"-part*.txt)
IP_FILES=("$INPUT_DIR_IPS"/ips-"$TYPE"-part*.txt)

INPUT_FILES=()

if [ -e "${MANUAL_FILES[0]}" ]; then
    INPUT_FILES+=("${MANUAL_FILES[@]}")
fi

if [ -e "${DOMAIN_FILES[0]}" ]; then
    INPUT_FILES+=("${DOMAIN_FILES[@]}")
fi

if [ -e "${IP_FILES[0]}" ]; then
    INPUT_FILES+=("${IP_FILES[@]}")
fi

MANUAL_COUNT=0
DOMAIN_COUNT=0
IP_COUNT=0

[ -e "${MANUAL_FILES[0]}" ] && MANUAL_COUNT="${#MANUAL_FILES[@]}"
[ -e "${DOMAIN_FILES[0]}" ] && DOMAIN_COUNT="${#DOMAIN_FILES[@]}"
[ -e "${IP_FILES[0]}" ] && IP_COUNT="${#IP_FILES[@]}"

echo "[*] Manual input files found:  $MANUAL_COUNT"
echo "[*] Domain input files found:  $DOMAIN_COUNT"
echo "[*] IP input files found:      $IP_COUNT"
echo "[*] Total input files found:   ${#INPUT_FILES[@]}"

if [ "${#INPUT_FILES[@]}" -eq 0 ]; then
    echo "[!] No input files found in:"
    echo "    - $INPUT_DIR_MANUAL"
    echo "    - $INPUT_DIR_DOMAINS"
    echo "    - $INPUT_DIR_IPS"
    exit 1
fi

echo "[*] Input file list:"
printf '    - %s\n' "${INPUT_FILES[@]}"

echo "[*] Cleaning previous temp/generated files..."
rm -f "$DOMAINS_MERGED" "$IPS_MERGED"
rm -f "${DOMAIN_PREFIX}"* "${IP_PREFIX}"*
touch "$DOMAINS_MERGED" "$IPS_MERGED"

echo "[*] Processing ${#INPUT_FILES[@]} input file(s)..."

# Step 2 trusts upstream validation (steps 1 + 1.5). Pure routing here:
# digit-only lines go to ips, everything else to domains. Manual inputs
# placed in $INPUT_DIR_MANUAL must be pre-validated by step 1.
grep -hv '^[[:space:]]*$' "${INPUT_FILES[@]}" \
| awk -v domains_out="$DOMAINS_MERGED" -v ips_out="$IPS_MERGED" '
{
    line = $0
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
    if (line == "") next

    if (line ~ /^[0-9.]+$/) {
        print line >> ips_out
    } else {
        print line >> domains_out
    }
}
'

echo "[*] Sorting and deduplicating outputs..."
sort -u "$DOMAINS_MERGED" -o "$DOMAINS_MERGED"
sort -u "$IPS_MERGED" -o "$IPS_MERGED"

echo "[*] Post-processing counts:"
DOMAIN_LINE_COUNT="$(wc -l < "$DOMAINS_MERGED")"
IP_LINE_COUNT="$(wc -l < "$IPS_MERGED")"

echo "    Domains : $DOMAIN_LINE_COUNT"
echo "    IPs     : $IP_LINE_COUNT"

echo "[*] Cleaning previous output files..."
rm -f "$OUTPUT_DIR_DOMAINS"/hosts-"$TYPE"-part*.txt
rm -f "$OUTPUT_DIR_IPS"/ips-"$TYPE"-part*.txt

echo "[*] Splitting domain list into chunks of max $MAX_LINES lines..."
if [ -s "$DOMAINS_MERGED" ]; then
    split -l "$MAX_LINES" -d -a 3 "$DOMAINS_MERGED" "$DOMAIN_PREFIX"
fi

echo "[*] Renaming domain chunks dynamically..."
i=0
for file in "${DOMAIN_PREFIX}"*; do
    [ -e "$file" ] || continue
    mv "$file" "$OUTPUT_DIR_DOMAINS/hosts-${TYPE}-part${i}.txt"
    i=$((i + 1))
done
echo "[*] Generated $i domain file(s)."

echo "[*] Splitting IP list into chunks of max $MAX_LINES lines..."
if [ -s "$IPS_MERGED" ]; then
    split -l "$MAX_LINES" -d -a 3 "$IPS_MERGED" "$IP_PREFIX"
fi

echo "[*] Renaming IP chunks dynamically..."
j=0
for file in "${IP_PREFIX}"*; do
    [ -e "$file" ] || continue
    mv "$file" "$OUTPUT_DIR_IPS/ips-${TYPE}-part${j}.txt"
    j=$((j + 1))
done
echo "[*] Generated $j IP file(s)."

echo "[*] Done."
echo "[*] Domain merged file:   $DOMAINS_MERGED"
echo "[*] IP merged file:       $IPS_MERGED"

echo
echo "[*] Final domain output files:"
ls -lh "$OUTPUT_DIR_DOMAINS"/hosts-"$TYPE"-part*.txt 2>/dev/null || true

echo
echo "[*] Final IP output files:"
ls -lh "$OUTPUT_DIR_IPS"/ips-"$TYPE"-part*.txt 2>/dev/null || true

echo
echo "[*] Final line counts:"
wc -l "$DOMAINS_MERGED" "$IPS_MERGED" 2>/dev/null || true

echo "[*] Archiving manual input files..."

RUN_ARCHIVE_DIR=""

if [ "$MANUAL_COUNT" -gt 0 ]; then
    ARCHIVE_TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
    RUN_ARCHIVE_DIR="$MANUAL_ARCHIVE_DIR/$ARCHIVE_TIMESTAMP"
    mkdir -p "$RUN_ARCHIVE_DIR"

    echo "[*] Moving $MANUAL_COUNT manual input file(s) to $RUN_ARCHIVE_DIR"
    for f in "${MANUAL_FILES[@]}"; do
        [ -e "$f" ] || continue
        mv "$f" "$RUN_ARCHIVE_DIR/"
    done
else
    echo "[*] No manual input files to archive."
fi

echo "[*] Finalizing log location..."

if [ -n "$RUN_ARCHIVE_DIR" ]; then
    FINAL_LOG="$RUN_ARCHIVE_DIR/$(basename "$LOG_FILE")"
    echo "[*] Moving log to archive: $FINAL_LOG"
    mv "$LOG_FILE" "$FINAL_LOG"
else
    echo "[*] No archive directory created. Log remains in: $LOG_FILE"
fi


echo "[*] Script finished at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "[*] =================================================="