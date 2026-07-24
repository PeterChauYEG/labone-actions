#!/usr/bin/env bash
# file-linear-ticket.test.sh — smoke tests for scripts/file-linear-ticket.sh.
#
# Mocks `curl` so no real network/Linear calls are made. Exercises the three
# code paths: LINEAR_API_KEY unset (skip), existing open ticket found
# (comment instead of duplicate create), no existing ticket (create).
#
# Usage: scripts/file-linear-ticket.test.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/file-linear-ticket.sh"

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

# ── Test 1: LINEAR_API_KEY unset — should skip cleanly (exit 0, no curl calls) ──
output=$(unset LINEAR_API_KEY; GITHUB_REPOSITORY="PeterChauYEG/labone-actions" PR_NUMBER=1 PR_URL="https://x" RUN_URL="https://y" \
  bash "$script" actionlint 2>&1)
status=$?
[[ $status -eq 0 ]] && echo "PASS: exits 0 when LINEAR_API_KEY unset" || { echo "FAIL: expected exit 0, got $status"; fail=1; }
assert_contains "$output" "WARN: LINEAR_API_KEY not set" "warns and skips when LINEAR_API_KEY unset"

# ── Test 2: existing open ticket found — comments instead of creating ──────
cat > "$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
# Fake curl: first call (search) returns an existing ticket; if a second
# call happens with a commentCreate mutation, log it so the test can assert.
for arg in "$@"; do
  if [[ "$arg" == *"commentCreate"* || "$arg" == *"issueId"* ]]; then
    echo '{"data":{"commentCreate":{"success":true}}}'
    echo "COMMENT_CALLED" >> "$MOCK_LOG"
    exit 0
  fi
done
echo '{"data":{"issues":{"nodes":[{"id":"abc-123","identifier":"LAB-999","url":"https://linear.app/x/LAB-999"}]}}}'
EOF
chmod +x "$mock_bin/curl"

log_file="$(mktemp)"
output=$(PATH="$mock_bin:$PATH" MOCK_LOG="$log_file" LINEAR_API_KEY="fake" \
  GITHUB_REPOSITORY="PeterChauYEG/labone-actions" PR_NUMBER=42 PR_URL="https://x/pr/42" RUN_URL="https://x/run/1" \
  bash "$script" actionlint 2>&1)
assert_contains "$output" "existing open ticket LAB-999" "dedups against existing open ticket"
assert_contains "$(cat "$log_file")" "COMMENT_CALLED" "posts a comment instead of creating a duplicate"
rm -f "$log_file"

# ── Test 2b: two different PR numbers for the same job+repo produce the ────
# same dedup search title (no PR number baked in) — this is the core fix:
# cross-PR dedup must match regardless of which PR is currently failing.
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

PATH="$mock_bin:$PATH" MOCK_LOG="$log_file" LINEAR_API_KEY="fake" \
  GITHUB_REPOSITORY="PeterChauYEG/labone-actions" PR_NUMBER=1 PR_URL="https://x/pr/1" RUN_URL="https://x/run/1" \
  bash "$script" actionlint > /dev/null 2>&1
title_pr1=$(grep -o '"title": *"[^"]*"' "$log_file" | head -1 || true)

: > "$log_file"
PATH="$mock_bin:$PATH" MOCK_LOG="$log_file" LINEAR_API_KEY="fake" \
  GITHUB_REPOSITORY="PeterChauYEG/labone-actions" PR_NUMBER=999 PR_URL="https://x/pr/999" RUN_URL="https://x/run/2" \
  bash "$script" actionlint > /dev/null 2>&1
title_pr999=$(grep -o '"title": *"[^"]*"' "$log_file" | head -1 || true)

if [[ "$title_pr1" == "$title_pr999" && -n "$title_pr1" ]]; then
  echo "PASS: dedup search title is identical across different PR numbers ($title_pr1)"
else
  echo "FAIL: dedup search title differs across PR numbers"
  echo "  PR #1:   $title_pr1"
  echo "  PR #999: $title_pr999"
  fail=1
fi
assert_contains "$title_pr1" "actionlint: labone-actions failing" "dedup search title omits PR number"
rm -f "$log_file"

# ── Test 3: no existing ticket — creates one ────────────────────────────────
cat > "$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
# When invoked as `curl ... -d @-` (piped from jq), the query lives on
# stdin, not in argv — read it so we can branch on its content and avoid
# SIGPIPE'ing the jq producer.
payload=""
for arg in "$@"; do
  if [[ "$arg" == "@-" ]]; then
    payload="$(cat)"
    break
  fi
done
haystack="$*$payload"
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
# search query — no existing ticket
echo '{"data":{"issues":{"nodes":[]}}}'
EOF
chmod +x "$mock_bin/curl"

output=$(PATH="$mock_bin:$PATH" LINEAR_API_KEY="fake" \
  GITHUB_REPOSITORY="PeterChauYEG/labone-actions" PR_NUMBER=7 PR_URL="https://x/pr/7" RUN_URL="https://x/run/2" \
  bash "$script" actionlint 2>&1)
assert_contains "$output" "created LAB-1000" "creates a new ticket when none exists"

if [[ $fail -ne 0 ]]; then
  echo "One or more tests FAILED"
  exit 1
fi
echo "All file-linear-ticket.sh tests passed"
