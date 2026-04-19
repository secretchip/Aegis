#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="1.5-reconciliation.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUN_TS="$(date '+%Y%m%d-%H%M%S')"

ALLOW_DIR="${ROOT_DIR}/public_allow_lists/domains"
BLOCK_DIR="${ROOT_DIR}/public_block_lists/domains"

LOG_ARCHIVE_DIR="${ROOT_DIR}/scripts/logs/archive/${RUN_TS}"
TEMP_DIR="${ROOT_DIR}/scripts/temp"
TMP_DIR="${LOG_ARCHIVE_DIR}/tmp"
BACKUP_DIR="${LOG_ARCHIVE_DIR}/backup"

DETAIL_LOG="${LOG_ARCHIVE_DIR}/detail-${RUN_TS}.tsv"
SUMMARY_LOG="${LOG_ARCHIVE_DIR}/summary-${RUN_TS}.tsv"
CONSOLE_LOG="${LOG_ARCHIVE_DIR}/run-${RUN_TS}.log"
SUMMARY_HISTORY="${ROOT_DIR}/scripts/logs/archive/summary-history.tsv"

IANA_TLDS_URL="https://data.iana.org/TLD/tlds-alpha-by-domain.txt"
VALID_TLDS_FILE="${TEMP_DIR}/iana-tlds.txt"

ALLOW_FILE_GLOB="${ALLOW_FILE_GLOB:-*.txt}"
BLOCK_FILE_GLOB="${BLOCK_FILE_GLOB:-*.txt}"
ALLOW_RECURSIVE="${ALLOW_RECURSIVE:-false}"
BLOCK_RECURSIVE="${BLOCK_RECURSIVE:-false}"
ALLOW_EXCLUDE_REGEX="${ALLOW_EXCLUDE_REGEX:-^$}"
BLOCK_EXCLUDE_REGEX="${BLOCK_EXCLUDE_REGEX:-^$}"

ALLOW_FILES=()
BLOCK_FILES=()

mkdir -p "$LOG_ARCHIVE_DIR" "$TMP_DIR" "$BACKUP_DIR" "$TEMP_DIR"
touch "$DETAIL_LOG" "$SUMMARY_LOG" "$SUMMARY_HISTORY"
exec > >(tee -a "$CONSOLE_LOG") 2>&1

usage() {
  cat <<USAGE
Usage:
  $0 [options]

Options:
  --allow-dir PATH           Directory containing allow list files
  --block-dir PATH           Directory containing block list files
  --allow-glob PATTERN       File glob for allow files, default: *.txt
  --block-glob PATTERN       File glob for block files, default: *.txt
  --allow-recursive BOOL     true|false, default: false
  --block-recursive BOOL     true|false, default: false
  --allow-exclude-regex REG  Basename regex to exclude allow files
  --block-exclude-regex REG  Basename regex to exclude block files
  -h, --help                 Show help

Default paths:
  Allow dir: ${ALLOW_DIR}
  Block dir: ${BLOCK_DIR}
  Logs dir : ${LOG_ARCHIVE_DIR}
  Temp dir : ${TEMP_DIR}
USAGE
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

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

validate_bool() {
  local v="${1,,}"
  [[ "$v" == "true" || "$v" == "false" ]] || fail "Boolean must be true or false, got: $1"
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --allow-dir)
        (($# >= 2)) || fail "Missing value after --allow-dir"
        ALLOW_DIR="$2"
        shift 2
        ;;
      --block-dir)
        (($# >= 2)) || fail "Missing value after --block-dir"
        BLOCK_DIR="$2"
        shift 2
        ;;
      --allow-glob)
        (($# >= 2)) || fail "Missing value after --allow-glob"
        ALLOW_FILE_GLOB="$2"
        shift 2
        ;;
      --block-glob)
        (($# >= 2)) || fail "Missing value after --block-glob"
        BLOCK_FILE_GLOB="$2"
        shift 2
        ;;
      --allow-recursive)
        (($# >= 2)) || fail "Missing value after --allow-recursive"
        ALLOW_RECURSIVE="$2"
        shift 2
        ;;
      --block-recursive)
        (($# >= 2)) || fail "Missing value after --block-recursive"
        BLOCK_RECURSIVE="$2"
        shift 2
        ;;
      --allow-exclude-regex)
        (($# >= 2)) || fail "Missing value after --allow-exclude-regex"
        ALLOW_EXCLUDE_REGEX="$2"
        shift 2
        ;;
      --block-exclude-regex)
        (($# >= 2)) || fail "Missing value after --block-exclude-regex"
        BLOCK_EXCLUDE_REGEX="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done
}

discover_files_in_dir() {
  local dir="$1"
  local glob="$2"
  local recursive="$3"
  local exclude_regex="$4"
  local result_var="$5"

  [[ -d "$dir" ]] || fail "Directory not found: $dir"

  local -a depth_args=()
  if [[ "${recursive,,}" == "false" ]]; then
    depth_args=(-maxdepth 1)
  fi

  local -a found=()
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    local base
    base="$(basename "$path")"
    if [[ "$base" =~ $exclude_regex ]]; then
      continue
    fi
    found+=("$path")
  done < <(find "$dir" "${depth_args[@]}" -type f -name "$glob" | LC_ALL=C sort)

  ((${#found[@]} > 0)) || fail "No files found in directory '$dir' matching glob '$glob'"

  case "$result_var" in
    ALLOW_FILES)
      ALLOW_FILES=("${found[@]}")
      ;;
    BLOCK_FILES)
      BLOCK_FILES=("${found[@]}")
      ;;
    *)
      fail "Unsupported result variable: $result_var"
      ;;
  esac
}

parse_iana_header_epoch() {
  local header="$1"
  local stamp
  stamp="$(sed -n 's/^# Version [0-9]\+, Last Updated \(.* UTC\)$/\1/p' <<< "$header")"
  [[ -n "$stamp" ]] || return 1
  date -u -d "$stamp" '+%s'
}

refresh_tld_file() {
  require_cmd curl
  require_cmd stat
  require_cmd date
  require_cmd sed
  require_cmd awk

  local remote_tmp="${TMP_DIR}/iana-tlds.remote"
  local remote_header remote_epoch local_epoch=0 should_update="false"

  log "Checking IANA TLD file freshness"
  if ! curl -fsSL "$IANA_TLDS_URL" -o "$remote_tmp"; then
    if [[ -f "$VALID_TLDS_FILE" ]]; then
      warn "Could not download remote IANA TLD file. Using cached local copy: $VALID_TLDS_FILE"
      return 0
    fi
    fail "Could not download remote IANA TLD file and no local cached copy exists"
  fi

  remote_header="$(head -n 1 "$remote_tmp" || true)"
  [[ -n "$remote_header" ]] || fail "Downloaded IANA TLD file is empty"

  if ! remote_epoch="$(parse_iana_header_epoch "$remote_header")"; then
    fail "Could not parse IANA TLD header timestamp from: $remote_header"
  fi

  if [[ ! -f "$VALID_TLDS_FILE" ]]; then
    should_update="true"
    log "Local cached IANA TLD file not found. Will create it."
  else
    local_epoch="$(stat -c '%Y' "$VALID_TLDS_FILE")"
    if (( remote_epoch > local_epoch )); then
      should_update="true"
      log "Remote IANA TLD file is newer than cached local copy."
    else
      log "Cached local IANA TLD file is current enough. No refresh needed."
    fi
  fi

  if [[ "$should_update" == "true" ]]; then
    mv -f "$remote_tmp" "$VALID_TLDS_FILE"
    touch "$VALID_TLDS_FILE"
    log "Updated cached IANA TLD file: $VALID_TLDS_FILE"
  else
    rm -f "$remote_tmp"
  fi

  [[ -f "$VALID_TLDS_FILE" ]] || fail "IANA TLD cache file missing after refresh logic"
}

validate_inputs() {
  require_cmd awk
  require_cmd sort
  require_cmd cp
  require_cmd mv
  require_cmd mktemp
  require_cmd sed
  require_cmd find
  require_cmd grep
  require_cmd head

  validate_bool "$ALLOW_RECURSIVE"
  validate_bool "$BLOCK_RECURSIVE"

  refresh_tld_file

  discover_files_in_dir "$ALLOW_DIR" "$ALLOW_FILE_GLOB" "$ALLOW_RECURSIVE" "$ALLOW_EXCLUDE_REGEX" "ALLOW_FILES"
  discover_files_in_dir "$BLOCK_DIR" "$BLOCK_FILE_GLOB" "$BLOCK_RECURSIVE" "$BLOCK_EXCLUDE_REGEX" "BLOCK_FILES"

  local f
  for f in "${ALLOW_FILES[@]}" "${BLOCK_FILES[@]}"; do
    [[ -f "$f" ]] || fail "Input file not found: $f"
    [[ -r "$f" ]] || fail "Input file not readable: $f"
    [[ -w "$f" ]] || fail "Input file not writable: $f"
  done
}

backup_file() {
  local src="$1"
  local rel
  rel="${src#${ROOT_DIR}/}"
  local dst="${BACKUP_DIR}/${rel}"
  mkdir -p "$(dirname "$dst")"
  cp -p -- "$src" "$dst"
}

prepare_master_files() {
  ALLOW_EXACT_KEYS_RAW="${TMP_DIR}/allow-exact-keys.raw"
  ALLOW_WILDCARD_BASES_RAW="${TMP_DIR}/allow-wildcard-bases.raw"
  ALLOW_EXACT_KEYS="${TMP_DIR}/allow-exact-keys.txt"
  ALLOW_WILDCARD_BASES="${TMP_DIR}/allow-wildcard-bases.txt"
  MATCHED_EXACT_BOTH_RAW="${TMP_DIR}/matched-exact-both.raw"
  MATCHED_WILDCARD_BASES_BOTH_RAW="${TMP_DIR}/matched-wildcard-bases-both.raw"
  MATCHED_EXACT_BOTH="${TMP_DIR}/matched-exact-both.txt"
  MATCHED_WILDCARD_BASES_BOTH="${TMP_DIR}/matched-wildcard-bases-both.txt"
  : > "$ALLOW_EXACT_KEYS_RAW"
  : > "$ALLOW_WILDCARD_BASES_RAW"
  : > "$MATCHED_EXACT_BOTH_RAW"
  : > "$MATCHED_WILDCARD_BASES_BOTH_RAW"
}

preprocess_allow_file() {
  local src="$1"
  local safe_name
  safe_name="$(printf '%s' "$src" | sed 's|/|__|g')"
  local out_stage1="${TMP_DIR}/allow-stage1-${safe_name}"
  local summary_tmp="${TMP_DIR}/summary-allow-stage1-${safe_name}.tsv"

  awk \
    -v role="allow_stage1" \
    -v src="$src" \
    -v out="$out_stage1" \
    -v detail_log="$DETAIL_LOG" \
    -v summary_tmp="$summary_tmp" \
    -v allow_exact_raw="$ALLOW_EXACT_KEYS_RAW" \
    -v allow_wc_raw="$ALLOW_WILDCARD_BASES_RAW" \
    -v run_ts="$RUN_TS" \
    -v tld_file="$VALID_TLDS_FILE" '
    BEGIN {
      FS="\n"
      while ((getline t < tld_file) > 0) {
        gsub(/\r/, "", t)
        if (t ~ /^#/ || t ~ /^[[:space:]]*$/) continue
        t = toupper(t)
        VALID_TLDS[t] = 1
      }
      close(tld_file)
    }

    function ltrim(s) { sub(/^[[:space:]]+/, "", s); return s }
    function rtrim(s) { sub(/[[:space:]]+$/, "", s); return s }
    function trim(s)  { return rtrim(ltrim(s)) }

    function wildcard_base(s, tmp) {
      tmp = s
      while (tmp ~ /^\*\./) sub(/^\*\./, "", tmp)
      return tmp
    }

    function is_valid_hostname_core(s,    tmp, n, a, i, tld) {
      tmp = wildcard_base(s)
      if (tmp == "") return 0
      if (tmp ~ /\*/) return 0
      n = split(tmp, a, ".")
      if (n < 2) return 0
      for (i = 1; i <= n; i++) {
        if (a[i] == "") return 0
        if (length(a[i]) > 63) return 0
        if (a[i] !~ /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/) return 0
      }
      tld = toupper(a[n])
      return (tld in VALID_TLDS)
    }

    function normalize_entry(raw,    s) {
      norm_reason = ""
      had_trailing_dot = 0
      s = trim(raw)
      if (s == "") {
        norm_reason = "blank_or_whitespace"
        return ""
      }
      if (s ~ /[[:space:]]/) {
        norm_reason = "internal_whitespace"
        return ""
      }
      s = tolower(s)
      while (s ~ /\.$/) {
        sub(/\.$/, "", s)
        had_trailing_dot = 1
      }
      if (!is_valid_hostname_core(s)) {
        norm_reason = had_trailing_dot ? "invalid_after_trailing_dot_removal_or_invalid_tld" : "invalid_entry_or_invalid_tld"
        return ""
      }
      return s
    }

    function entry_type(s) {
      return (s ~ /^\*\./ ? "wildcard" : "exact")
    }

    function log_detail(side, action, reason, original, normalized) {
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", run_ts, side, src, action, reason, original, normalized >> detail_log
    }

    {
      input_lines++
      original = $0
      normalized = normalize_entry(original)

      if (normalized == "") {
        removed_invalid++
        log_detail("allow", "remove", norm_reason, original, "")
        next
      }

      print normalized >> out
      if (entry_type(normalized) == "exact") {
        print normalized >> allow_exact_raw
        allow_exact_kept++
      } else {
        print wildcard_base(normalized) >> allow_wc_raw
        allow_wc_kept++
      }
      kept++
    }

    END {
      printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", role, src, input_lines+0, kept+0, removed_invalid+0, 0, 0, 0, allow_exact_kept+0, allow_wc_kept+0 > summary_tmp
    }
  ' "$src"
}

process_block_file() {
  local src="$1"
  local safe_name
  safe_name="$(printf '%s' "$src" | sed 's|/|__|g')"
  local out_stage1="${TMP_DIR}/block-stage1-${safe_name}"
  local summary_tmp="${TMP_DIR}/summary-block-stage1-${safe_name}.tsv"

  awk \
    -v role="block_stage1" \
    -v src="$src" \
    -v out="$out_stage1" \
    -v detail_log="$DETAIL_LOG" \
    -v summary_tmp="$summary_tmp" \
    -v allow_exact_file="$ALLOW_EXACT_KEYS" \
    -v allow_wc_file="$ALLOW_WILDCARD_BASES" \
    -v matched_exact_raw="$MATCHED_EXACT_BOTH_RAW" \
    -v matched_wc_raw="$MATCHED_WILDCARD_BASES_BOTH_RAW" \
    -v run_ts="$RUN_TS" \
    -v tld_file="$VALID_TLDS_FILE" '
    BEGIN {
      FS="\n"
      while ((getline t < tld_file) > 0) {
        gsub(/\r/, "", t)
        if (t ~ /^#/ || t ~ /^[[:space:]]*$/) continue
        t = toupper(t)
        VALID_TLDS[t] = 1
      }
      close(tld_file)

      while ((getline e < allow_exact_file) > 0) {
        if (e != "") ALLOW_EXACT[e] = 1
      }
      close(allow_exact_file)

      while ((getline w < allow_wc_file) > 0) {
        if (w != "") ALLOW_WC_BASE[w] = 1
      }
      close(allow_wc_file)
    }

    function ltrim(s) { sub(/^[[:space:]]+/, "", s); return s }
    function rtrim(s) { sub(/[[:space:]]+$/, "", s); return s }
    function trim(s)  { return rtrim(ltrim(s)) }

    function wildcard_base(s, tmp) {
      tmp = s
      while (tmp ~ /^\*\./) sub(/^\*\./, "", tmp)
      return tmp
    }

    function is_valid_hostname_core(s,    tmp, n, a, i, tld) {
      tmp = wildcard_base(s)
      if (tmp == "") return 0
      if (tmp ~ /\*/) return 0
      n = split(tmp, a, ".")
      if (n < 2) return 0
      for (i = 1; i <= n; i++) {
        if (a[i] == "") return 0
        if (length(a[i]) > 63) return 0
        if (a[i] !~ /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/) return 0
      }
      tld = toupper(a[n])
      return (tld in VALID_TLDS)
    }

    function normalize_entry(raw,    s) {
      norm_reason = ""
      had_trailing_dot = 0
      s = trim(raw)
      if (s == "") {
        norm_reason = "blank_or_whitespace"
        return ""
      }
      if (s ~ /[[:space:]]/) {
        norm_reason = "internal_whitespace"
        return ""
      }
      s = tolower(s)
      while (s ~ /\.$/) {
        sub(/\.$/, "", s)
        had_trailing_dot = 1
      }
      if (!is_valid_hostname_core(s)) {
        norm_reason = had_trailing_dot ? "invalid_after_trailing_dot_removal_or_invalid_tld" : "invalid_entry_or_invalid_tld"
        return ""
      }
      return s
    }

    function entry_type(s) {
      return (s ~ /^\*\./ ? "wildcard" : "exact")
    }

    function is_covered_by_allow_wc(host,    tmp, pos) {
      tmp = host
      if (tmp in ALLOW_WC_BASE) return 1
      while ((pos = index(tmp, ".")) > 0) {
        tmp = substr(tmp, pos + 1)
        if (tmp in ALLOW_WC_BASE) return 1
      }
      return 0
    }

    function log_detail(side, action, reason, original, normalized) {
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", run_ts, side, src, action, reason, original, normalized >> detail_log
    }

    {
      input_lines++
      original = $0
      normalized = normalize_entry(original)

      if (normalized == "") {
        removed_invalid++
        log_detail("block", "remove", norm_reason, original, "")
        next
      }

      type = entry_type(normalized)
      if (type == "exact") {
        if (normalized in ALLOW_EXACT) {
          removed_exact_both++
          print normalized >> matched_exact_raw
          log_detail("block", "remove", "exact_present_in_allow_and_block_remove_from_both", original, normalized)
          next
        }
        if (is_covered_by_allow_wc(normalized)) {
          removed_covered_by_allow_wc++
          log_detail("block", "remove", "block_exact_covered_by_allow_wildcard", original, normalized)
          next
        }
      } else {
        base = wildcard_base(normalized)
        if (base in ALLOW_WC_BASE) {
          removed_wc_both++
          print base >> matched_wc_raw
          log_detail("block", "remove", "wildcard_present_in_allow_and_block_remove_from_both", original, normalized)
          next
        }
      }

      print normalized >> out
      kept++
    }

    END {
      printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", role, src, input_lines+0, kept+0, removed_invalid+0, removed_exact_both+0, removed_covered_by_allow_wc+0, removed_wc_both+0, 0, 0 > summary_tmp
    }
  ' "$src"
}

finalize_allow_file() {
  local src="$1"
  local safe_name
  safe_name="$(printf '%s' "$src" | sed 's|/|__|g')"
  local in_stage1="${TMP_DIR}/allow-stage1-${safe_name}"
  local out_final="${TMP_DIR}/final-${safe_name}"
  local summary_tmp="${TMP_DIR}/summary-allow-final-${safe_name}.tsv"

  awk \
    -v role="allow_final" \
    -v src="$src" \
    -v out="$out_final" \
    -v detail_log="$DETAIL_LOG" \
    -v summary_tmp="$summary_tmp" \
    -v matched_exact_file="$MATCHED_EXACT_BOTH" \
    -v matched_wc_file="$MATCHED_WILDCARD_BASES_BOTH" \
    -v run_ts="$RUN_TS" '
    BEGIN {
      FS="\n"
      while ((getline e < matched_exact_file) > 0) {
        if (e != "") MATCHED_EXACT[e] = 1
      }
      close(matched_exact_file)

      while ((getline w < matched_wc_file) > 0) {
        if (w != "") MATCHED_WC_BASE[w] = 1
      }
      close(matched_wc_file)
    }

    function wildcard_base(s, tmp) {
      tmp = s
      while (tmp ~ /^\*\./) sub(/^\*\./, "", tmp)
      return tmp
    }

    function entry_type(s) {
      return (s ~ /^\*\./ ? "wildcard" : "exact")
    }

    function log_detail(side, action, reason, original, normalized) {
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", run_ts, side, src, action, reason, original, normalized >> detail_log
    }

    {
      input_lines++
      normalized = $0
      type = entry_type(normalized)
      if (type == "exact") {
        if (normalized in MATCHED_EXACT) {
          removed_exact_both++
          log_detail("allow", "remove", "exact_present_in_allow_and_block_remove_from_both", normalized, normalized)
          next
        }
      } else {
        base = wildcard_base(normalized)
        if (base in MATCHED_WC_BASE) {
          removed_wc_both++
          log_detail("allow", "remove", "wildcard_present_in_allow_and_block_remove_from_both", normalized, normalized)
          next
        }
      }

      print normalized >> out
      kept++
    }

    END {
      printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", role, src, input_lines+0, kept+0, 0, removed_exact_both+0, 0, removed_wc_both+0, 0, 0 > summary_tmp
    }
  ' "$in_stage1"
}

dedupe_master_files() {
  LC_ALL=C sort -u "$ALLOW_EXACT_KEYS_RAW" > "$ALLOW_EXACT_KEYS"
  LC_ALL=C sort -u "$ALLOW_WILDCARD_BASES_RAW" > "$ALLOW_WILDCARD_BASES"
  LC_ALL=C sort -u "$MATCHED_EXACT_BOTH_RAW" > "$MATCHED_EXACT_BOTH"
  LC_ALL=C sort -u "$MATCHED_WILDCARD_BASES_BOTH_RAW" > "$MATCHED_WILDCARD_BASES_BOTH"
}

overwrite_original() {
  local src="$1"
  local safe_name base_name dir_name samefs_tmp final_file
  safe_name="$(printf '%s' "$src" | sed 's|/|__|g')"
  base_name="$(basename "$src")"
  dir_name="$(dirname "$src")"

  if [[ " $ALLOW_FILE_LOOKUP " == *"|$src|"* ]]; then
    final_file="${TMP_DIR}/final-${safe_name}"
  else
    final_file="${TMP_DIR}/block-stage1-${safe_name}"
  fi

  [[ -f "$final_file" ]] || : > "$final_file"
  samefs_tmp="$(mktemp "${dir_name}/.${base_name}.reconcile.XXXXXX")"
  cp -- "$final_file" "$samefs_tmp"
  mv -- "$samefs_tmp" "$src"
}

append_summaries_to_history() {
  local f
  {
    printf 'role\tfile\tinput_lines\tkept\tremoved_invalid\tremoved_exact_both\tremoved_covered_by_allow_wc\tremoved_wc_both\tallow_exact_kept\tallow_wc_kept\n'
    for f in "${TMP_DIR}"/summary-*.tsv; do
      [[ -f "$f" ]] || continue
      cat "$f"
    done
  } > "$SUMMARY_LOG"

  if [[ ! -s "$SUMMARY_HISTORY" ]]; then
    printf 'run_ts\trole\tfile\tinput_lines\tkept\tremoved_invalid\tremoved_exact_both\tremoved_covered_by_allow_wc\tremoved_wc_both\tallow_exact_kept\tallow_wc_kept\n' > "$SUMMARY_HISTORY"
  fi

  for f in "${TMP_DIR}"/summary-*.tsv; do
    [[ -f "$f" ]] || continue
    awk -v run_ts="$RUN_TS" 'BEGIN{FS=OFS="\t"} {print run_ts, $0}' "$f" >> "$SUMMARY_HISTORY"
  done
}

print_discovery_summary() {
  echo
  log "Discovered allow files: ${#ALLOW_FILES[@]}"
  printf '  %s\n' "${ALLOW_FILES[@]}"
  echo
  log "Discovered block files: ${#BLOCK_FILES[@]}"
  printf '  %s\n' "${BLOCK_FILES[@]}"
  echo
}

print_console_summary() {
  log "Run complete. Summary files:"
  log "  Detailed removals : $DETAIL_LOG"
  log "  Per-file summaries: $SUMMARY_LOG"
  log "  Historical summary: $SUMMARY_HISTORY"
  log "  Backups           : $BACKUP_DIR"
  log "  Cached TLD file   : $VALID_TLDS_FILE"

  echo
  echo "Per-file summary:"
  cat "$SUMMARY_LOG"
}

main() {
  parse_args "$@"
  validate_inputs
  print_discovery_summary
  prepare_master_files

  ALLOW_FILE_LOOKUP="|"
  local f
  for f in "${ALLOW_FILES[@]}"; do
    ALLOW_FILE_LOOKUP+="$f|"
  done

  log "Backing up original files"
  for f in "${ALLOW_FILES[@]}" "${BLOCK_FILES[@]}"; do
    backup_file "$f"
  done

  log "Normalizing allow files and building lookup sets"
  for f in "${ALLOW_FILES[@]}"; do
    log "  Allow: $f"
    preprocess_allow_file "$f"
  done

  log "Deduplicating allow lookup sets"
  dedupe_master_files

  log "Processing block files"
  for f in "${BLOCK_FILES[@]}"; do
    log "  Block: $f"
    process_block_file "$f"
  done

  log "Deduplicating matched allow/block conflicts"
  dedupe_master_files

  log "Finalizing allow files"
  for f in "${ALLOW_FILES[@]}"; do
    log "  Allow final: $f"
    finalize_allow_file "$f"
  done

  log "Overwriting original files"
  for f in "${ALLOW_FILES[@]}" "${BLOCK_FILES[@]}"; do
    overwrite_original "$f"
  done

  append_summaries_to_history
  print_console_summary
}

main "$@"