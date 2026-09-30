#!/usr/bin/env bash
# dead-code-scan.sh — detects unused Cargo dependencies via cargo-machete
# and renders the findings into a human-readable dead-code-report.md for
# the CI sticky-comment step.
#
# Bash equivalent of the Node/JS `scripts/dead-code-scan.mjs` scan for
# Rust callers of develop-rust-ci.yml/rust-cli-pr.yml — see those
# workflows' `dead_code_script_source` input (`'labone-actions'` runs this
# script directly; `'repo'`, the default, keeps running the caller's own
# vendored `dead_code_script` path, e.g. ai-harness-cli's
# scripts/ci/dead-code-scan.sh, which this mirrors).
#
# Tooling note: knip (used for the TS/JS `dead-code` job) has no Rust
# equivalent — there's no cross-crate unused-export detector for Rust.
# `cargo-machete` covers unused *dependencies*; unused private items are
# already caught by the `cargo clippy -- -D warnings` job, so no separate
# dead-code lint step is needed here. Unused `pub` exports across
# workspace crates have no good Rust tool available yet and are
# intentionally out of scope (same scope as ai-harness-cli's script).
#
# Invoked with the caller's Cargo project already as cwd (via the
# workflow's `working-directory:` on the step that runs this) — every path
# here is deliberately cwd-relative, matching design-system-scan.mjs's
# convention for scan-with-report's `script-source: labone-actions` mode.
#
# Usage: dead-code-scan.sh [report.md]
set -euo pipefail

report_md="${1:-dead-code-report.md}"

machete_status=0
machete_output=$(cargo machete 2>&1) || machete_status=$?

{
  echo "## Dead Code Report"
  echo
  echo "> \`cargo-machete\` for unused dependencies. Unused private items are already caught by the \`clippy\` CI job; unused pub exports across crates have no Rust tool available and are out of scope."
  echo
  echo "### Unused dependencies (cargo-machete)"
  echo
  if [[ "$machete_status" -eq 0 ]]; then
    echo "No unused dependencies found. ✅"
  else
    echo '```'
    echo "$machete_output"
    echo '```'
  fi
} > "$report_md"

echo "[dead-code-scan] wrote $report_md (cargo-machete exit ${machete_status})"

if [[ "$machete_status" -ne 0 ]]; then
  exit 1
fi
exit 0
