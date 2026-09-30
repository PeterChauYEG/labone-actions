#!/usr/bin/env bash
# file-ci-failure-ticket.test.sh — smoke tests for scripts/file-ci-failure-ticket.sh.
#
# Mocks `curl` so no real network/Linear calls are made. Exercises: the
# LINEAR_API_KEY-unset skip path, existing-open-ticket dedup (comment instead
# of duplicate create, matched on a stable ci-failure-key marker embedded in
# the issue description rather than the mutable title), and flat ticket
# creation with Urgent (priority 1) severity plus marker embedding.
#
# Usage: scripts/file-ci-failure-ticket.test.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/file-ci-failure-ticket.sh"

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
trap 'rm -rf "$mock_bin"' EXIT

output=$(unset LINEAR_API_KEY; GITHUB_REPOSITORY="PeterChauYEG/labone-actions" \
  bash "$script" "CI" "https://x/run/1" 2>&1)
status=$?
[[ $status -eq 0 ]] && echo "PASS: exits 0 when LINEAR_API_KEY unset" || { echo "FAIL: expected exit 0, got $status"; fail=1; }
assert_contains "$output" "WARN: LINEAR_API_KEY not set" "warns and skips when LINEAR_API_KEY unset"

# ── existing-open-ticket dedup: comments instead of creating a duplicate. ──
log_file="$(mktemp)"
cat > "$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
payload=""
for arg in "$@"; do
  if [[ "$arg" == "@-" ]]; then
    payload="$(cat)"
    break
  fi
done
haystack="$*$payload"
echo "$haystack" >> "$MOCK_LOG"
if [[ "$haystack" == *"commentCreate"* || "$haystack" == *"issueId"* ]]; then
  echo '{"data":{"commentCreate":{"success":true}}}'
  exit 0
fi
echo '{"data":{"issues":{"nodes":[{"id":"abc-123","identifier":"LAB-999","url":"https://linear.app/x/LAB-999"}]}}}'
EOF
chmod +x "$mock_bin/curl"

output=$(PATH="$mock_bin:$PATH" MOCK_LOG="$log_file" LINEAR_API_KEY="fake" \
  GITHUB_REPOSITORY="PeterChauYEG/labone-actions" \
  bash "$script" "CI" "https://x/run/1" 2>&1)
assert_contains "$output" "existing open ticket LAB-999" "dedups against existing open ticket"
if grep -q 'ci-failure-key: ci-failure:labone-actions:CI' "$log_file"; then
  echo "PASS: dedup search matches on the stable ci-failure-key marker in the description"
else
  echo "FAIL: dedup search matches on the stable ci-failure-key marker in the description"
  fail=1
fi
rm -f "$log_file"

# ── flat mode: no existing ticket -> creates one at Urgent (priority 1). ──
log_file="$(mktemp)"
cat > "$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
payload=""
for arg in "$@"; do
  if [[ "$arg" == "@-" ]]; then
    payload="$(cat)"
    break
  fi
done
haystack="$*$payload"
echo "$haystack" >> "$MOCK_LOG"
if [[ "$haystack" == *"issueCreate"* ]]; then
  echo '{"data":{"issueCreate":{"success":true,"issue":{"identifier":"LAB-1000","url":"https://linear.app/x/LAB-1000"}}}}'
  exit 0
fi
if [[ "$haystack" == *"workflowStates"* ]]; then
  echo '{"data":{"workflowStates":{"nodes":[{"id":"state-1"}]}}}'
  exit 0
fi
if [[ "$haystack" == *"teams"* ]]; then
  echo '{"data":{"teams":{"nodes":[{"id":"team-1"}]}}}'
  exit 0
fi
echo '{"data":{"issues":{"nodes":[]}}}'
EOF
chmod +x "$mock_bin/curl"

output=$(PATH="$mock_bin:$PATH" MOCK_LOG="$log_file" LINEAR_API_KEY="fake" \
  GITHUB_REPOSITORY="PeterChauYEG/labone-actions" \
  bash "$script" "CI" "https://x/run/2" 2>&1)
assert_contains "$output" "created LAB-1000" "creates a new ticket when none exists"
if grep -q '"priority": *1' "$log_file"; then
  echo "PASS: new ticket is filed at Urgent (priority 1)"
else
  echo "FAIL: new ticket is filed at Urgent (priority 1)"
  fail=1
fi
if grep -q 'ci-failure-key: ci-failure:labone-actions:CI' "$log_file"; then
  echo "PASS: new ticket description embeds the ci-failure-key marker"
else
  echo "FAIL: new ticket description embeds the ci-failure-key marker"
  fail=1
fi
rm -f "$log_file"

if [[ $fail -ne 0 ]]; then
  echo "One or more tests FAILED"
  exit 1
fi
echo "All file-ci-failure-ticket.sh tests passed"
