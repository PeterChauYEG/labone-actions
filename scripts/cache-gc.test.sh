#!/usr/bin/env bash
# cache-gc.test.sh — smoke tests for scripts/cache-gc.sh.
#
# Mocks `gh` so no real GitHub API calls are made. Exercises: deleting a
# stale PR-branch cache under the short threshold, keeping a fresh
# main-branch cache under the long threshold, deleting a stale main-branch
# cache once it exceeds the (longer) main threshold, and skipping a repo
# with no caches entirely.
#
# Usage: scripts/cache-gc.test.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/cache-gc.sh"

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

# A cache "very old" (10 days ago) and one "fresh" (a few minutes ago),
# expressed as ISO-8601 so the script's own `date -u -d` parses them
# exactly like a real gh cache list response.
very_old="$(date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ)"
fresh="$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"

cat >"$mock_bin/gh" <<EOF
#!/usr/bin/env bash
log_file="\${MOCK_LOG:-/dev/null}"
echo "gh \$*" >>"\$log_file"

if [[ "\$1 \$2" == "repo list" ]]; then
  echo '["repo-a","repo-empty"]' | jq -r '.[]'
  exit 0
fi

if [[ "\$1 \$2" == "cache list" ]]; then
  repo_arg=""
  for a in "\$@"; do
    case "\$prev" in
      -R) repo_arg="\$a" ;;
    esac
    prev="\$a"
  done
  if [[ "\$repo_arg" == *"repo-empty" ]]; then
    echo '[]'
    exit 0
  fi
  cat <<JSON
[
  {"id": "1", "ref": "refs/heads/feature-x", "lastAccessedAt": "$very_old", "sizeInBytes": 1000},
  {"id": "2", "ref": "refs/heads/main", "lastAccessedAt": "$fresh", "sizeInBytes": 2000},
  {"id": "3", "ref": "refs/heads/main", "lastAccessedAt": "$very_old", "sizeInBytes": 3000}
]
JSON
  exit 0
fi

if [[ "\$1 \$2" == "cache delete" ]]; then
  echo "DELETE \$3" >>"\$log_file"
  exit 0
fi

echo "unexpected gh invocation: \$*" >&2
exit 1
EOF
chmod +x "$mock_bin/gh"

log_file="$(mktemp)"
output=$(PATH="$mock_bin:$PATH" MOCK_LOG="$log_file" GH_TOKEN="fake" \
  GITHUB_STEP_SUMMARY="$(mktemp)" \
  bash "$script" --owner test-owner --main-max-idle-days 2 --other-max-idle-days 1 2>&1)
log_contents="$(cat "$log_file")"

assert_contains "$log_contents" "DELETE 1" "deletes the stale PR-branch cache (id 1, past the 1-day threshold)"
assert_not_contains "$log_contents" "DELETE 2" "keeps the fresh main-branch cache (id 2, well inside the 2-day threshold)"
assert_contains "$log_contents" "DELETE 3" "deletes the stale main-branch cache (id 3, past the 2-day threshold)"
assert_contains "$output" "deleted 2 cache(s), reclaimed 4000 byte(s)" "summary totals only the two deleted caches (1000 + 3000 bytes)"

rm -f "$log_file"

if [[ $fail -ne 0 ]]; then
  echo "One or more tests FAILED"
  exit 1
fi
echo "All cache-gc.sh tests passed"
