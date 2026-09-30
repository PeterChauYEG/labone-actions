#!/usr/bin/env bash
# dead-code-scan.test.sh — smoke tests for dead-code-scan.sh.
#
# Mocks `cargo` on $PATH intercepting the `machete` subcommand, so no real
# scan/cargo-machete install happens. Exercises: a fully clean scan and an
# unused-dependency finding.
#
# Usage: scripts/dead-code-scan.test.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/dead-code-scan.sh"

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

mock_bin="$(mktemp -d)"
report_md="$(mktemp)"
trap 'rm -rf "$mock_bin" "$report_md"' EXIT

# Fake `cargo machete` driven by env vars, so each test case just points
# the mock at its own fixture output/exit code.
cat > "$mock_bin/cargo" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  machete)
    cat "$MACHETE_OUTPUT"
    exit "${MACHETE_EXIT:-0}"
    ;;
  *)
    echo "unexpected invocation: cargo $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$mock_bin/cargo"

clean_machete="$mock_bin/machete-clean.txt"
: > "$clean_machete"

# ── Test 1: fully clean scan — exits 0, report says clean ──────────────────
output=$(PATH="$mock_bin:$PATH" MACHETE_OUTPUT="$clean_machete" MACHETE_EXIT=0 \
  bash "$script" "$report_md" 2>&1)
status=$?
[[ $status -eq 0 ]] && echo "PASS: exits 0 on a fully clean scan" || { echo "FAIL: expected exit 0, got $status"; fail=1; }
report_content="$(cat "$report_md")"
assert_contains "$report_content" "No unused dependencies found" "renders a clean cargo-machete section"

# ── Test 2: cargo-machete finds an unused dependency — exits 1, listed ─────
dirty_machete="$mock_bin/machete-dirty.txt"
cat > "$dirty_machete" <<'EOF'
cargo-machete found the following unused dependencies in this directory:
harness -- ./Cargo.toml:
    toml
EOF

set +e
output=$(PATH="$mock_bin:$PATH" MACHETE_OUTPUT="$dirty_machete" MACHETE_EXIT=1 \
  bash "$script" "$report_md" 2>&1)
status=$?
set -e
[[ $status -eq 1 ]] && echo "PASS: exits 1 when cargo-machete finds an unused dependency" || { echo "FAIL: expected exit 1, got $status"; fail=1; }
report_content="$(cat "$report_md")"
assert_contains "$report_content" "toml" "renders the unused dependency name"

if [[ $fail -ne 0 ]]; then
  echo "One or more tests FAILED"
  exit 1
fi
echo "All dead-code-scan.sh tests passed"
