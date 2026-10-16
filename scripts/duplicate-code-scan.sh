#!/usr/bin/env bash
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
