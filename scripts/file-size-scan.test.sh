#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/file-size-scan.sh"

fail=0

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "FAIL: $msg"
    echo "  expected to contain: $needle"
    echo "  got: $haystack"
    fail=1
  else
    echo "PASS: $msg"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "FAIL: $msg"
    echo "  expected NOT to contain: $needle"
    fail=1
  else
    echo "PASS: $msg"
  fi
}

fixture_dir="$(mktemp -d)"
report_md="$(mktemp)"
trap 'rm -rf "$fixture_dir" "$report_md"' EXIT

seq 1 5 > "$fixture_dir/small.rs"

set +e
output=$(bash "$script" "$report_md" 10 "$fixture_dir" 2>&1)
status=$?
set -e
[[ $status -eq 0 ]] && echo "PASS: exits 0 when nothing is oversized" || { echo "FAIL: expected exit 0, got $status"; fail=1; }
assert_contains "$(cat "$report_md")" "No files exceed 10 lines" "renders a clean report"

seq 1 5 > "$fixture_dir/small.rs"
seq 1 20 > "$fixture_dir/big.rs"
seq 1 30 > "$fixture_dir/bigger.rs"
seq 1 100 > "$fixture_dir/ignored.txt"

set +e
bash "$script" "$report_md" 10 "$fixture_dir" > /dev/null 2>&1
status=$?
set -e
[[ $status -eq 0 ]] && echo "PASS: still exits 0 when files ARE oversized (non-blocking)" || { echo "FAIL: expected exit 0, got $status"; fail=1; }
report_content="$(cat "$report_md")"
assert_contains "$report_content" "big.rs" "lists the oversized .rs file"
assert_contains "$report_content" "bigger.rs" "lists the other oversized .rs file"
assert_not_contains "$report_content" "small.rs" "omits the under-threshold file"
assert_not_contains "$report_content" "ignored.txt" "ignores non-.rs files"
bigger_pos=$(grep -n "bigger.rs" "$report_md" | head -1 | cut -d: -f1)
big_pos=$(grep -n "big.rs" "$report_md" | head -1 | cut -d: -f1)
[[ "$bigger_pos" -lt "$big_pos" ]] && echo "PASS: sorts largest file first" || { echo "FAIL: expected bigger.rs (30 lines) before big.rs (20 lines)"; fail=1; }

rm -rf "${fixture_dir:?}"/*
seq 1 20 > "$fixture_dir/big.rs"
mkdir -p "$fixture_dir/vendor-sdk"
seq 1 30 > "$fixture_dir/vendor-sdk/generated.rs"

set +e
bash "$script" "$report_md" 10 "$fixture_dir" "vendor-sdk" > /dev/null 2>&1
status=$?
set -e
[[ $status -eq 0 ]] && echo "PASS: exits 0 with one exclude" || { echo "FAIL: expected exit 0, got $status"; fail=1; }
report_content="$(cat "$report_md")"
assert_contains "$report_content" "big.rs" "still lists the non-excluded oversized file"
assert_not_contains "$report_content" "generated.rs" "excludes the given path"

rm -rf "${fixture_dir:?}"/*
seq 1 20 > "$fixture_dir/big.rs"
mkdir -p "$fixture_dir/vendor-sdk" "$fixture_dir/other-sdk"
seq 1 30 > "$fixture_dir/vendor-sdk/generated.rs"
seq 1 40 > "$fixture_dir/other-sdk/generated.rs"

set +e
bash "$script" "$report_md" 10 "$fixture_dir" "vendor-sdk,other-sdk" > /dev/null 2>&1
status=$?
set -e
[[ $status -eq 0 ]] && echo "PASS: exits 0 with multiple excludes" || { echo "FAIL: expected exit 0, got $status"; fail=1; }
report_content="$(cat "$report_md")"
assert_contains "$report_content" "big.rs" "still lists the non-excluded oversized file"
assert_not_contains "$report_content" "vendor-sdk" "excludes the first given path"
assert_not_contains "$report_content" "other-sdk" "excludes the second given path"

rm -rf "${fixture_dir:?}"/*
seq 1 20 > "$fixture_dir/big.rs"

set +e
output=$(bash "$script" "$report_md" 10 "$fixture_dir" "does-not-exist-anywhere" 2>&1)
status=$?
set -e
[[ $status -eq 0 ]] && echo "PASS: exits 0 when exclude matches nothing" || { echo "FAIL: expected exit 0, got $status"; fail=1; }
assert_contains "$(cat "$report_md")" "big.rs" "unmatched exclude is a no-op"

if [[ $fail -ne 0 ]]; then
  echo "One or more tests FAILED"
  exit 1
fi
echo "All file-size-scan.sh tests passed"
