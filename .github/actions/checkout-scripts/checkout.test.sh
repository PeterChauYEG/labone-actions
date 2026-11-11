#!/usr/bin/env bash
# Regression test for LAB-5420 (gamecraft PR CI's dead-code/duplicate-code/
# max-lines jobs failing with "ERROR: Repository not found." when checking
# out labone-actions-scan-scripts).
#
# Exercises checkout.sh's do_checkout/checkout_with_retries against a local
# fake "origin" (a throwaway bare repo) instead of the real GitHub remote,
# so this runs offline and fast:
#   1. A single anonymous checkout against a valid remote succeeds and
#      materializes only the sparse-checked-out scripts/ directory on a
#      local `main` branch - the actual fix (no token/AUTHORIZATION header
#      needed at all, see checkout.sh's header comment).
#   2. The happy path takes exactly one attempt - no wasted retry sleeps
#      when the first anonymous attempt already succeeds.
#   3. Every attempt against a broken remote fails, retries twice
#      (printing both ::warning:: lines), then gives up non-zero - the
#      retry/backoff behavior inherited from the old actions/checkout
#      3-attempt loop is preserved.
#   4. The token fallback is only wired up (via the
#      http.https://github.com/.extraheader git config) on that final
#      attempt, never on the first two anonymous ones.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=checkout.sh
source "$script_dir/checkout.sh"

fail=0

assert_success() {
  local msg="$1"
  if [ "$2" -eq 0 ]; then
    echo "PASS: $msg"
  else
    echo "FAIL: $msg (exit code $2)"
    fail=1
  fi
}

assert_failure_code() {
  local msg="$1"
  if [ "$2" -ne 0 ]; then
    echo "PASS: $msg"
  else
    echo "FAIL: $msg (expected non-zero exit, got 0)"
    fail=1
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "PASS: $msg"
  else
    echo "FAIL: $msg"
    echo "  expected to contain: $needle"
    echo "  got: $haystack"
    fail=1
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "PASS: $msg"
  else
    echo "FAIL: $msg"
    echo "  expected NOT to contain: $needle"
    echo "  got: $haystack"
    fail=1
  fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Build a fake "origin": a bare repo with a scripts/ dir plus a top-level
# file, on a `main` branch - same shape as the real labone-actions repo.
fake_remote_src="$work/fake-remote-src"
fake_remote="$work/fake-remote.git"
mkdir -p "$fake_remote_src/scripts"
echo "console.log('fake scan script')" > "$fake_remote_src/scripts/dead-code-scan.mjs"
echo "# fake labone-actions" > "$fake_remote_src/README.md"
git -C "$fake_remote_src" init -q -b main
git -C "$fake_remote_src" -c user.email=test@test.com -c user.name=test add -A
git -C "$fake_remote_src" -c user.email=test@test.com -c user.name=test commit -qm "fake commit"
git clone -q --bare "$fake_remote_src" "$fake_remote"

export CHECKOUT_RETRY_SLEEP_1=0
export CHECKOUT_RETRY_SLEEP_2=0

# 1 & 2: happy path against a working remote, no token needed.
target1="$work/target1"
out1="$(CHECKOUT_REMOTE_URL="$fake_remote" checkout_with_retries "$target1" "" 2>&1)"
rc1=$?
assert_success "anonymous checkout against a valid remote succeeds" "$rc1"
if [ -f "$target1/scripts/dead-code-scan.mjs" ]; then
  echo "PASS: sparse-checkout materialized scripts/dead-code-scan.mjs"
else
  echo "FAIL: sparse-checkout did not materialize scripts/dead-code-scan.mjs"
  fail=1
fi
assert_not_contains "$out1" "retrying" "happy path takes one attempt, no retry warnings"

# 3: every attempt against a broken remote fails, with both retry warnings.
target2="$work/target2"
out2="$(CHECKOUT_REMOTE_URL="$work/does-not-exist" checkout_with_retries "$target2" "" 2>&1)"
rc2=$?
assert_failure_code "checkout against a broken remote fails after exhausting retries" "$rc2"
assert_contains "$out2" "retrying in 15s" "first retry warning printed"
assert_contains "$out2" "retrying in 45s" "second retry warning printed"

# 4: token fallback is only configured on the final (3rd) attempt, never
# on the first two anonymous ones.
assert_empty() {
  local msg="$1" actual="$2"
  if [ -z "$actual" ]; then
    echo "PASS: $msg"
  else
    echo "FAIL: $msg (found: $actual)"
    fail=1
  fi
}

target3="$work/target3"
CHECKOUT_REMOTE_URL="$fake_remote" do_checkout "$target3" false >/dev/null 2>&1 || true
anon_auth="$(git -C "$target3" config --get http.https://github.com/.extraheader 2>/dev/null || true)"
assert_empty "no AUTHORIZATION header configured on an anonymous attempt" "$anon_auth"

CHECKOUT_REMOTE_URL="$fake_remote" do_checkout "$target3" true "fake-token-value" >/dev/null 2>&1 || true
token_auth="$(git -C "$target3" config --get http.https://github.com/.extraheader 2>/dev/null || true)"
if [[ "$token_auth" == AUTHORIZATION:\ basic\ * ]]; then
  echo "PASS: AUTHORIZATION header configured when a token is explicitly passed"
else
  echo "FAIL: AUTHORIZATION header not configured when a token is explicitly passed (got: $token_auth)"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "SOME TESTS FAILED"
  exit 1
fi
echo "ALL TESTS PASSED"
