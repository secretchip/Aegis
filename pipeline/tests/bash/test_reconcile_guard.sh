#!/usr/bin/env bash
# Unit tests for overwrite_original guard in pipeline/reconcile.sh.
# Sources the script (which is source-safe) and exercises the guard
# directly with controlled inputs in an isolated TMP_DIR.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECONCILE_SCRIPT="$SCRIPT_DIR/../../reconcile.sh"

if [[ ! -f "$RECONCILE_SCRIPT" ]]; then
  echo "FATAL: cannot find $RECONCILE_SCRIPT" >&2
  exit 2
fi

source "$RECONCILE_SCRIPT"
set +e  # Source enables errexit; we want manual assertion control.

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

TMP_DIR="$TEST_TMP"
ALLOW_FILE_LOOKUP="|"

pass_count=0
fail_count=0

assert_pass() {
  local name="$1"
  echo "PASS: $name"
  pass_count=$((pass_count + 1))
}

assert_fail() {
  local name="$1"
  echo "FAIL: $name"
  fail_count=$((fail_count + 1))
}

setup_block_case() {
  local orig_lines="$1"
  local final_lines="$2"
  local src="$TEST_TMP/case_${RANDOM}.txt"
  local safe_name
  safe_name="$(printf '%s' "$src" | sed 's|/|__|g')"
  local final_file="$TMP_DIR/block-stage1-${safe_name}"

  if (( orig_lines > 0 )); then
    seq 1 "$orig_lines" > "$src"
  else
    : > "$src"
  fi

  if (( final_lines > 0 )); then
    seq 1 "$final_lines" > "$final_file"
  fi

  printf '%s\n' "$src"
}

run_in_subshell() {
  (
    set +e
    overwrite_original "$1"
    echo "EXIT=$?"
  )
}

# --- Test 1: empty final_file → fail ---
src=$(setup_block_case 1000 0)
out=$(run_in_subshell "$src" 2>&1)
if grep -q "Refusing to overwrite" <<<"$out"; then
  assert_pass "empty final triggers fail"
else
  assert_fail "empty final triggers fail (got: $out)"
fi

# --- Test 2: empty final_file + RECONCILE_FORCE → succeed with warn, file overwritten empty ---
src=$(setup_block_case 1000 0)
RECONCILE_FORCE=true overwrite_original "$src" 2>/tmp/test_reconcile_warn.$$
if [[ ! -s "$src" ]] && grep -q "RECONCILE_FORCE" /tmp/test_reconcile_warn.$$; then
  assert_pass "empty final + FORCE bypasses + file emptied"
else
  assert_fail "empty final + FORCE bypass (src size: $(wc -l < "$src"), warn: $(cat /tmp/test_reconcile_warn.$$))"
fi
rm -f /tmp/test_reconcile_warn.$$
unset RECONCILE_FORCE

# --- Test 3: >10% drop → fail ---
src=$(setup_block_case 1000 500)
out=$(run_in_subshell "$src" 2>&1)
if grep -q "10% loss" <<<"$out"; then
  assert_pass ">10% drop triggers fail"
else
  assert_fail ">10% drop triggers fail (got: $out)"
fi

# --- Test 4: <10% drop → succeed ---
src=$(setup_block_case 1000 950)
out=$(run_in_subshell "$src" 2>&1)
if grep -q "EXIT=0" <<<"$out"; then
  assert_pass "<10% drop allowed"
else
  assert_fail "<10% drop allowed (got: $out)"
fi

# --- Test 5: <100 line original → threshold check skipped ---
src=$(setup_block_case 50 5)
out=$(run_in_subshell "$src" 2>&1)
if grep -q "EXIT=0" <<<"$out"; then
  assert_pass "<100 line original skips threshold"
else
  assert_fail "<100 line original skips threshold (got: $out)"
fi

# --- Test 6: >10% drop + RECONCILE_FORCE → succeed with warn ---
src=$(setup_block_case 1000 100)
RECONCILE_FORCE=true overwrite_original "$src" 2>/tmp/test_reconcile_warn.$$
final_lines=$(wc -l < "$src")
if (( final_lines == 100 )) && grep -q "RECONCILE_FORCE" /tmp/test_reconcile_warn.$$; then
  assert_pass ">10% drop + FORCE bypasses"
else
  assert_fail ">10% drop + FORCE bypasses (final: $final_lines)"
fi
rm -f /tmp/test_reconcile_warn.$$
unset RECONCILE_FORCE

# --- Summary ---
echo
echo "Results: $pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]] || exit 1
