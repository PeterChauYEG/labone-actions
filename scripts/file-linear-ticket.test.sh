#!/usr/bin/env bash
# file-linear-ticket.test.sh — smoke tests for scripts/file-linear-ticket.sh.
#
# Mocks `curl` so no real network/Linear calls are made. Exercises: the
# LINEAR_API_KEY-unset skip path, existing-open-ticket dedup (comment instead
# of duplicate create), lazy team/state resolution (never looked up on the
# dedup-only path), flat-mode ticket creation, and grouped mode (one ticket
# per {scope, description} entry in a groups-JSON file).
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

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "FAIL: $msg"
    echo "  expected NOT to contain: $needle"
    echo "  got: $haystack"
    fail=1
  else
    echo "PASS: $msg"
  fi
}

mock_bin="$(mktemp -d)"
trap 'rm -rf "$mock_bin"' EXIT

output=$(unset LINEAR_API_KEY; GITHUB_REPOSITORY="PeterChauYEG/labone-actions" PR_NUMBER=1 PR_URL="https://x" RUN_URL="https://y" \
  bash "$script" actionlint 2>&1)
status=$?
[[ $status -eq 0 ]] && echo "PASS: exits 0 when LINEAR_API_KEY unset" || { echo "FAIL: expected exit 0, got $status"; fail=1; }
assert_contains "$output" "WARN: LINEAR_API_KEY not set" "warns and skips when LINEAR_API_KEY unset"

# ── existing-open-ticket dedup: comments instead of creating a duplicate,
# and never resolves team/state (lazy lookup) since nothing gets created. ──
cat > "$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == *"commentCreate"* || "$arg" == *"issueId"* ]]; then
    echo '{"data":{"commentCreate":{"success":true}}}'
    echo "COMMENT_CALLED" >> "$MOCK_LOG"
    exit 0
  fi
  if [[ "$arg" == *"teams"* || "$arg" == *"workflowStates"* ]]; then
    echo "TEAM_OR_STATE_LOOKUP_CALLED" >> "$MOCK_LOG"
  fi
done
echo '{"data":{"issues":{"nodes":[{"id":"abc-123","identifier":"LAB-999","url":"https://linear.app/x/LAB-999","createdAt":"2024-01-01T00:00:00.000Z"}]}}}'
EOF
chmod +x "$mock_bin/curl"

log_file="$(mktemp)"
output=$(PATH="$mock_bin:$PATH" MOCK_LOG="$log_file" LINEAR_API_KEY="fake" \
  GITHUB_REPOSITORY="PeterChauYEG/labone-actions" PR_NUMBER=42 PR_URL="https://x/pr/42" RUN_URL="https://x/run/1" \
  bash "$script" actionlint 2>&1)
assert_contains "$output" "existing open ticket LAB-999" "dedups against existing open ticket"
assert_contains "$(cat "$log_file")" "COMMENT_CALLED" "posts a comment instead of creating a duplicate"
assert_not_contains "$(cat "$log_file")" "TEAM_OR_STATE_LOOKUP_CALLED" "lazy lookup: team/state are never resolved on the dedup-only path"
rm -f "$log_file"

# ── dedup search is a title-*prefix* search (so a later grouped/scoped
# ticket for the same job still gets caught by the same query) and stays
# identical across different PR numbers (PR number isn't part of the title
# or the search). ──
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
echo '{"data":{"issues":{"nodes":[{"id":"abc-123","identifier":"LAB-999","url":"https://linear.app/x/LAB-999","createdAt":"2024-01-01T00:00:00.000Z"}]}}}'
EOF
chmod +x "$mock_bin/curl"

PATH="$mock_bin:$PATH" MOCK_LOG="$log_file" LINEAR_API_KEY="fake" \
  GITHUB_REPOSITORY="PeterChauYEG/labone-actions" PR_NUMBER=1 PR_URL="https://x/pr/1" RUN_URL="https://x/run/1" \
  bash "$script" actionlint > /dev/null 2>&1
title_pr1=$(grep -o '"titlePrefix": *"[^"]*"' "$log_file" | head -1 || true)

: > "$log_file"
PATH="$mock_bin:$PATH" MOCK_LOG="$log_file" LINEAR_API_KEY="fake" \
  GITHUB_REPOSITORY="PeterChauYEG/labone-actions" PR_NUMBER=999 PR_URL="https://x/pr/999" RUN_URL="https://x/run/2" \
  bash "$script" actionlint > /dev/null 2>&1
title_pr999=$(grep -o '"titlePrefix": *"[^"]*"' "$log_file" | head -1 || true)

if [[ "$title_pr1" == "$title_pr999" && -n "$title_pr1" ]]; then
  echo "PASS: dedup search title prefix is identical across different PR numbers ($title_pr1)"
else
  echo "FAIL: dedup search title prefix differs across PR numbers"
  echo "  PR #1:   $title_pr1"
  echo "  PR #999: $title_pr999"
  fail=1
fi
assert_contains "$title_pr1" "actionlint: labone-actions" "dedup search title prefix omits PR number"
if grep -q 'nin.*completed.*cancelled.*duplicate' "$log_file"; then
  echo "PASS: dedup search excludes duplicate/cancelled/completed states"
else
  echo "FAIL: dedup search excludes duplicate/cancelled/completed states"
  fail=1
fi
rm -f "$log_file"

# ── flat mode: no existing ticket -> creates one, lazily resolving team and
# state only once actually needed. ──
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

output=$(PATH="$mock_bin:$PATH" LINEAR_API_KEY="fake" \
  GITHUB_REPOSITORY="PeterChauYEG/labone-actions" PR_NUMBER=7 PR_URL="https://x/pr/7" RUN_URL="https://x/run/2" \
  bash "$script" actionlint 2>&1)
assert_contains "$output" "created LAB-1000" "creates a new ticket when none exists"

# ── grouped mode: a non-empty groups-JSON array files one ticket per entry,
# titled "<job-name>: <repo> <scope>", instead of the flat single ticket. ──
groups_file="$(mktemp)"
cat > "$groups_file" <<'EOF'
[
  {"scope": "core", "description": "core findings"},
  {"scope": "misc", "description": "misc findings"}
]
EOF

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
  echo '{"data":{"issueCreate":{"success":true,"issue":{"identifier":"LAB-2000","url":"https://linear.app/x/LAB-2000"}}}}'
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
  GITHUB_REPOSITORY="PeterChauYEG/labone-actions" PR_NUMBER=9 PR_URL="https://x/pr/9" RUN_URL="https://x/run/3" \
  bash "$script" duplicate-code /dev/null "$groups_file" 2>&1)
assert_contains "$output" "has 2 group(s)" "grouped mode: reports the group count"
assert_contains "$(cat "$log_file")" 'duplicate-code: labone-actions core' "grouped mode: files a ticket titled with the core scope"
assert_contains "$(cat "$log_file")" 'duplicate-code: labone-actions misc' "grouped mode: files a ticket titled with the misc scope"
rm -f "$log_file" "$groups_file"

# ── an empty groups array is a no-op fallback to flat mode. ──
empty_groups_file="$(mktemp)"
echo '[]' > "$empty_groups_file"
cat > "$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"data":{"issues":{"nodes":[{"id":"abc-123","identifier":"LAB-999","url":"https://linear.app/x/LAB-999","createdAt":"2024-01-01T00:00:00.000Z"}]}}}'
EOF
chmod +x "$mock_bin/curl"
output=$(PATH="$mock_bin:$PATH" LINEAR_API_KEY="fake" \
  GITHUB_REPOSITORY="PeterChauYEG/labone-actions" PR_NUMBER=10 PR_URL="https://x/pr/10" RUN_URL="https://x/run/4" \
  bash "$script" duplicate-code /dev/null "$empty_groups_file" 2>&1)
assert_contains "$output" "existing open ticket LAB-999" "empty groups array falls back to flat mode"
rm -f "$empty_groups_file"

# ── a scope that looks like a ticket reference (e.g. a package/dir name
# coincidentally matching LAB-<digits>) must not leak into the created
# title — guards against the GitHub/Linear PR auto-link collision this
# caused live when a different (non-labone-actions) split-ticket flow put
# a sibling ticket's ID in a child ticket's title. ──
ticket_ref_groups_file="$(mktemp)"
cat > "$ticket_ref_groups_file" <<'EOF'
[
  {"scope": "lab-4217-legacy", "description": "findings in the lab-4217-legacy package"}
]
EOF
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
  echo '{"data":{"issueCreate":{"success":true,"issue":{"identifier":"LAB-2001","url":"https://linear.app/x/LAB-2001"}}}}'
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
  GITHUB_REPOSITORY="PeterChauYEG/labone-actions" PR_NUMBER=11 PR_URL="https://x/pr/11" RUN_URL="https://x/run/5" \
  bash "$script" duplicate-code /dev/null "$ticket_ref_groups_file" 2>&1)
created_title=$(grep -o '"title": *"[^"]*"' "$log_file" | head -1)
assert_not_contains "$created_title" "lab-4217" "a scope resembling a ticket ID is stripped from the created title"
assert_contains "$created_title" 'duplicate-code: labone-actions legacy' "the rest of the sanitized scope still makes it into the title"
# the (untouched) description is allowed to still mention it — only the title must be sanitized
assert_contains "$(cat "$log_file")" "lab-4217-legacy package" "description text is left alone, only the title is sanitized"
rm -f "$log_file" "$ticket_ref_groups_file"

if [[ $fail -ne 0 ]]; then
  echo "One or more tests FAILED"
  exit 1
fi
echo "All file-linear-ticket.sh tests passed"
