#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/godot-dead-code-scan.sh"

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

cat > "$fixture_dir/clean.gd" <<'EOF'
class_name CleanThing
extends Node

func used_function():
    return 1

func _ready():
    used_function()
    spawn()

func spawn() -> CleanThing:
    return CleanThing.new()
EOF

set +e
(cd "$fixture_dir" && bash "$script" "report.md")
status=$?
set -e
[[ $status -eq 0 ]] && echo "PASS: exits 0 when every function/class is referenced" || { echo "FAIL: expected exit 0, got $status"; fail=1; }
assert_contains "$(cat "$fixture_dir/report.md")" "No unreferenced functions or classes found" "renders a clean report"
assert_not_contains "$(cat "$fixture_dir/report.md")" "_ready" "does not flag an engine lifecycle callback as unused"
rm -f "$fixture_dir"/*.gd "$fixture_dir/report.md"

cat > "$fixture_dir/dead.gd" <<'EOF'
class_name UnusedClass
extends Node

func dead_function():
    return 2

func _ready():
    pass
EOF

set +e
(cd "$fixture_dir" && bash "$script" "report.md")
status=$?
set -e
[[ $status -eq 1 ]] && echo "PASS: exits 1 when an unreferenced function/class is found" || { echo "FAIL: expected exit 1, got $status"; fail=1; }
report_content="$(cat "$fixture_dir/report.md")"
assert_contains "$report_content" "dead_function" "flags the unreferenced function"
assert_contains "$report_content" "UnusedClass" "flags the unreferenced class"
assert_not_contains "$report_content" "_ready" "still does not flag the engine lifecycle callback"

if [[ $fail -ne 0 ]]; then
  echo "One or more tests FAILED"
  exit 1
fi
echo "All godot-dead-code-scan.sh tests passed"
