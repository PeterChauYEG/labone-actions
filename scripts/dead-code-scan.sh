#!/usr/bin/env bash
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
