#!/usr/bin/env bash
# duplicate-code-scan.sh — runs cargo-dupes (AST-normalizing, Rust-native
# duplicate/near-duplicate detector; config in the caller's own
# dupes.toml) against the repo and renders its stats + report into a
# human-readable duplicate-code-report.md for the CI sticky-comment step.
#
# Bash equivalent of the Node/JS `scripts/duplicate-code-scan.mjs` scan for
# Rust callers of develop-rust-ci.yml/rust-cli-pr.yml — see those
# workflows' `duplicate_code_script_source` input (`'labone-actions'` runs
# this script directly; `'repo'`, the default, keeps running the caller's
# own vendored `duplicate_code_script` path, e.g. ai-harness-cli's
# scripts/ci/duplicate-code-scan.sh, which this mirrors).
#
# jscpd (used for TS/JS/bash/markdown) has no meaningful Rust tokenizer, so
# cargo-dupes — which parses real ASTs via syn — is the right call here.
# Exceptions/thresholds live in the caller's own dupes.toml, not here or in
# the CI job.
#
# Invoked with the caller's Cargo project already as cwd (via the
# workflow's `working-directory:` on the step that runs this) — every path
# here is deliberately cwd-relative, matching design-system-scan.mjs's
# convention for scan-with-report's `script-source: labone-actions` mode.
# The workflow is responsible for installing cargo-dupes onto PATH before
# invoking this script (see develop-rust-ci.yml's duplicate-code job).
#
# Usage: duplicate-code-scan.sh [report.md]
#
# cargo-dupes's own `check` exit code (0 = clean, 1 = over threshold, 2 =
# error) is propagated after the report is rendered, so the sticky-comment
# step always gets a report whether the scan passed or failed.
set -euo pipefail

report_md="${1:-duplicate-code-report.md}"

stats_json=$(cargo dupes stats --format json)
text_report=$(cargo dupes report 2>&1 || true)

groups=$(echo "$stats_json" | jq -r '.exact_duplicate_groups')
dup_lines=$(echo "$stats_json" | jq -r '.exact_duplicate_lines')
total_lines=$(echo "$stats_json" | jq -r '.total_lines')
percentage=$(echo "$stats_json" | jq -r '.exact_duplicate_percent')

{
  echo "## Duplicate Code Report (cargo-dupes)"
  echo
  if [[ "$groups" -eq 0 ]]; then
    echo "No duplicate code blocks found. ✅"
  else
    echo "**${groups} duplicate group(s) found — ${dup_lines}/${total_lines} lines duplicated (${percentage}%).**"
    echo
    echo "<details><summary>Clone details</summary>"
    echo
    echo '```'
    echo "$text_report"
    echo '```'
    echo
    echo "</details>"
  fi
} > "$report_md"

echo "[duplicate-code-scan] wrote $report_md (${groups} group(s), ${percentage}% duplicated)"

check_status=0
cargo dupes check || check_status=$?

exit "$check_status"
