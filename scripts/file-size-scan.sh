#!/usr/bin/env bash
set -euo pipefail

report_md="${1:-file-size-report.md}"
threshold="${2:-300}"
scan_dir="${3:-.}"
exclude_paths="${4:-}"

find_args=(-not -path '*/target/*' -not -path '*/.git/*')
if [[ -n "$exclude_paths" ]]; then
  while IFS= read -r entry; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -z "$entry" ]] && continue
    case "$entry" in
      *'*'*) find_args+=(-not -path "$entry") ;;
      *) find_args+=(-not -path "*${entry}*") ;;
    esac
  done < <(printf '%s\n' "$exclude_paths" | tr ',' '\n')
fi

oversized=()
while IFS= read -r -d '' file; do
  lines=$(wc -l < "$file" | tr -d ' ')
  if (( lines > threshold )); then
    oversized+=("${lines}|${file}")
  fi
done < <(find "$scan_dir" -name '*.rs' "${find_args[@]}" -print0)

{
  echo "## File-Size Report (.rs files over ${threshold} lines)"
  echo
  if [[ ${#oversized[@]} -eq 0 ]]; then
    echo "No files exceed ${threshold} lines. ✅"
  else
    echo "**${#oversized[@]} file(s) exceed ${threshold} lines** — non-blocking, for awareness only:"
    echo
    printf '%s\n' "${oversized[@]}" | sort -t'|' -k1 -rn | while IFS='|' read -r lines file; do
      echo "* \`${file#./}\` — ${lines} lines"
    done
  fi
} > "$report_md"

echo "[file-size-scan] wrote $report_md (${#oversized[@]} file(s) over ${threshold} lines)"
exit 0
