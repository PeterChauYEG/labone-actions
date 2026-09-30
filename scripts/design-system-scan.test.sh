#!/usr/bin/env bash
# design-system-scan.test.sh — smoke tests for design-system-scan.mjs.
#
# Mocks `npx eslint --format json .` on $PATH so no real ESLint run
# happens, and runs the script against small fixture trees under a temp
# cwd. Exercises: the base ESLint-rule report (always on, unchanged
# behavior), the opt-in shadcn-usage check
# (DESIGN_SYSTEM_SHADCN_VENDOR_PATH), and the opt-in React Native
# typography/theme-color check (DESIGN_SYSTEM_RN_MODE +
# DESIGN_SYSTEM_RN_EXEMPT_PATHS).
#
# Usage: scripts/design-system-scan.test.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/design-system-scan.mjs"

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

mock_bin="$(mktemp -d)"
trap 'rm -rf "$mock_bin" "$work_a" "$work_b" "$work_c"' EXIT

# Fake `npx eslint --format json .` driven by an env var pointing at a
# fixture JSON payload, so each test case controls the eslint findings
# independently of the real linter.
cat > "$mock_bin/npx" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" != "eslint" ]]; then
  echo "unexpected invocation: npx $*" >&2
  exit 2
fi
cat "$ESLINT_JSON"
EOF
chmod +x "$mock_bin/npx"

empty_eslint="$mock_bin/eslint-empty.json"
echo '[]' > "$empty_eslint"

# ── Test 1: base ESLint check only (both new modes unset) ──────────────────
work_a="$(mktemp -d)"
eslint_hit="$mock_bin/eslint-hit.json"
cat > "$eslint_hit" <<JSON
[{"filePath":"$work_a/src/App.tsx","messages":[{"ruleId":"lab-react-standards/no-raw-text-element","line":3,"message":"raw text"}]}]
JSON

set +e
output=$(cd "$work_a" && PATH="$mock_bin:$PATH" ESLINT_JSON="$eslint_hit" node "$script" 2>&1)
status=$?
set -e
[[ $status -eq 1 ]] && echo "PASS: exits 1 on an eslint violation" || { echo "FAIL: expected exit 1, got $status"; fail=1; }
assert_contains "$output" "1 design-system violation" "logs the violation count"
report_a="$(cat "$work_a/design-system-report.md")"
assert_contains "$report_a" "no-raw-text-element" "base report includes the eslint violation"
assert_not_contains "$report_a" "shadcn usage" "shadcn section absent when mode not enabled"
assert_not_contains "$report_a" "react-native typography" "RN section absent when mode not enabled"

# ── Test 2: shadcn-usage mode ───────────────────────────────────────────────
work_b="$(mktemp -d)"
mkdir -p "$work_b/src/components" "$work_b/src/design-system/vendor"
cat > "$work_b/src/components/Form.tsx" <<'EOF'
export const Form = () => <button type="button">Go</button>;
EOF
cat > "$work_b/src/design-system/vendor/button.tsx" <<'EOF'
export const Button = () => <button type="button">Go</button>;
EOF

set +e
output=$(cd "$work_b" && PATH="$mock_bin:$PATH" ESLINT_JSON="$empty_eslint" \
  DESIGN_SYSTEM_SHADCN_VENDOR_PATH="src/design-system/vendor/" node "$script" 2>&1)
status=$?
set -e
[[ $status -eq 1 ]] && echo "PASS: exits 1 on a shadcn-usage violation" || { echo "FAIL: expected exit 1, got $status"; fail=1; }
assert_contains "$output" "1 design-system violation" "logs the violation count"
report_b="$(cat "$work_b/design-system-report.md")"
assert_contains "$report_b" "shadcn usage" "shadcn section present when mode enabled"
assert_contains "$report_b" "src/components/Form.tsx" "flags the raw <button> outside the vendor path"
assert_not_contains "$report_b" "src/design-system/vendor/button.tsx" "does not flag the vendor path itself"

# ── Test 3: React Native typography + theme-color mode ─────────────────────
work_c="$(mktemp -d)"
mkdir -p "$work_c/src/screens" "$work_c/src/widgets"
cat > "$work_c/src/screens/Home.tsx" <<'EOF'
import { Text } from 'react-native';
export const Home = () => <Text style={{ color: '#fff' }}>Hi</Text>;
EOF
cat > "$work_c/src/widgets/WorkoutWidget.tsx" <<'EOF'
export const backgroundColor = '#fff';
EOF

set +e
output=$(cd "$work_c" && PATH="$mock_bin:$PATH" ESLINT_JSON="$empty_eslint" \
  DESIGN_SYSTEM_RN_MODE=true DESIGN_SYSTEM_RN_EXEMPT_PATHS="src/widgets/WorkoutWidget.tsx" \
  node "$script" 2>&1)
status=$?
set -e
[[ $status -eq 1 ]] && echo "PASS: exits 1 on RN typography/theme-color violations" || { echo "FAIL: expected exit 1, got $status"; fail=1; }
assert_contains "$output" "design-system violation" "logs the violation count"
report_c="$(cat "$work_c/design-system-report.md")"
assert_contains "$report_c" "react-native typography" "RN section present when mode enabled"
assert_contains "$report_c" "raw <Text> from 'react-native'" "flags the raw RN <Text> usage"
assert_contains "$report_c" "hex color literal" "flags the raw hex color literal"
assert_not_contains "$report_c" "WorkoutWidget" "does not flag the caller-supplied exempt path"

if [[ $fail -ne 0 ]]; then
  echo "One or more tests FAILED"
  exit 1
fi
echo "All design-system-scan.mjs tests passed"
