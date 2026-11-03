#!/usr/bin/env bash
# Regression test for the yarn-workspaces dangling-symlink bug (see
# action.yml's "Workspaces caveat" note and install.sh's relink_workspaces
# doc comment).
#
# Builds a fake content-addressed bundle the way link_bundle/
# link_node_modules_shallow actually leave one: node_modules/@scope is a
# SINGLE symlink straight into the bundle's own node_modules/@scope (which
# in turn holds per-package symlinks pointing at a since-deleted ephemeral
# checkout - same shape as a real `cache-write: true` job's output).
#
# Asserts:
#   1. relink_workspaces repoints the dangling scoped-package symlink at
#      THIS job's own checkout, not the bundle's stale one.
#   2. the shared bundle itself is left untouched - this is the actual bug:
#      before the fix, rm -rf/ln -sfn on "node_modules/@scope/pkg" walked
#      through the node_modules/@scope symlink and mutated the bundle's
#      files in place.
#   3. a yarn install failure in the non-bundle-hit path still fails the
#      whole script loudly (exit non-zero), matching `set -euo pipefail`.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=install.sh
source "$script_dir/install.sh"

fail=0

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $msg"
    echo "  expected: $expected"
    echo "  got:      $actual"
    fail=1
  else
    echo "PASS: $msg"
  fi
}

assert_success() {
  local msg="$1"
  shift
  if "$@" >/tmp/install-test-out.$$ 2>&1; then
    echo "PASS: $msg"
  else
    echo "FAIL: $msg"
    cat /tmp/install-test-out.$$
    fail=1
  fi
  rm -f /tmp/install-test-out.$$
}

assert_failure() {
  local msg="$1"
  shift
  if "$@" >/tmp/install-test-out.$$ 2>&1; then
    echo "FAIL: $msg (expected non-zero exit, got 0)"
    cat /tmp/install-test-out.$$
    fail=1
  else
    echo "PASS: $msg"
  fi
  rm -f /tmp/install-test-out.$$
}

work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT

# --- Fixture: a bundle whose scoped workspace packages point at a deleted
# ephemeral checkout, plus the two workspace packages' real current
# locations under $work_root/job (this job's "own checkout").
bundle="$work_root/bundle"
job="$work_root/job"
deleted_checkout="$work_root/deleted-ephemeral-checkout"

mkdir -p "$bundle/node_modules/@scope" "$job/packages/core" "$job/packages/app"
mkdir -p "$deleted_checkout/packages/core" "$deleted_checkout/packages/app"

cat > "$job/package.json" <<'EOF'
{"name": "root", "private": true, "workspaces": ["packages/*"]}
EOF
cat > "$job/packages/core/package.json" <<'EOF'
{"name": "@scope/core"}
EOF
cat > "$job/packages/app/package.json" <<'EOF'
{"name": "@scope/app"}
EOF

# The bundle's own node_modules/@scope/* - relative symlinks, exactly as
# yarn's node-modules linker produces for workspace packages, but captured
# at bundle-write time against the now-deleted ephemeral checkout.
ln -sfn "$deleted_checkout/packages/core" "$bundle/node_modules/@scope/core"
ln -sfn "$deleted_checkout/packages/app" "$bundle/node_modules/@scope/app"
rm -rf "$deleted_checkout" # the checkout is gone by the time another job reads the bundle

# --- Act: simulate link_node_modules_shallow (bundle -> job's node_modules)
# followed by relink_workspaces, exactly as link_bundle does.
cd "$job"
link_node_modules_shallow "$bundle/node_modules"

assert_eq "$(readlink "node_modules/@scope")" "$bundle/node_modules/@scope" \
  "shallow-link makes node_modules/@scope a single symlink straight into the bundle"

relink_workspaces

# 1. The dangling symlink is now repointed at this job's own checkout.
assert_eq "$(readlink -f "node_modules/@scope/core")" "$job/packages/core" \
  "relink_workspaces repoints node_modules/@scope/core at this job's own checkout"
assert_eq "$(readlink -f "node_modules/@scope/app")" "$job/packages/app" \
  "relink_workspaces repoints node_modules/@scope/app at this job's own checkout"

# 2. The shared bundle was NOT mutated - this is the actual regression.
# Before the fix, the lines above would have rewritten these bundle files
# to point at $job/packages/*, corrupting them for every other reader.
assert_eq "$(readlink "$bundle/node_modules/@scope/core")" "$deleted_checkout/packages/core" \
  "bundle's own node_modules/@scope/core symlink is untouched (still points at the deleted checkout)"
assert_eq "$(readlink "$bundle/node_modules/@scope/app")" "$deleted_checkout/packages/app" \
  "bundle's own node_modules/@scope/app symlink is untouched (still points at the deleted checkout)"

# --- discover_workspaces: sanity-check the package.json-only glob walk
# used instead of `yarn workspaces list --json` (which this fix removes
# the dependency on entirely).
entries="$(discover_workspaces)"
assert_eq "$entries" "$(printf '@scope/app\tpackages/app\n@scope/core\tpackages/core')" \
  "discover_workspaces finds both workspace packages via package.json globs alone"

# --- Loud-failure check: a yarn install failure must fail the whole
# script (set -euo pipefail), not get silently swallowed.
mock_bin="$(mktemp -d)"
cat > "$mock_bin/yarn" <<'EOF'
#!/usr/bin/env bash
echo "mock yarn: install always fails" >&2
exit 1
EOF
chmod +x "$mock_bin/yarn"

fail_job="$work_root/fail-job"
mkdir -p "$fail_job"
cd "$fail_job"
cat > package.json <<'EOF'
{"name": "root", "private": true}
EOF

assert_failure "install_with_retry propagates yarn's failure (not swallowed)" \
  env PATH="$mock_bin:$PATH" bash -c 'source '"$script_dir"'/install.sh; install_with_retry'

rm -rf "$mock_bin"

if [[ $fail -ne 0 ]]; then
  echo "One or more tests FAILED"
  exit 1
fi
echo "All install.sh tests passed"
