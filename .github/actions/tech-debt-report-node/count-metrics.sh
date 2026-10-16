#!/usr/bin/env bash
set -uo pipefail

dir="${1:?usage: count-metrics.sh <dir>}"

if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  files="$(git -C "$dir" ls-files --cached --others --exclude-standard -- '*.ts' '*.tsx' 2>/dev/null \
    | sed "s|^|${dir%/}/|" || true)"
else
  files="$(find "$dir" -type f \( -name '*.ts' -o -name '*.tsx' \) \
    ! -path '*/node_modules/*' ! -path '*/dist/*' ! -path '*/build/*' \
    ! -path '*/coverage/*' ! -path '*/.git/*' 2>/dev/null || true)"
fi

count() {
  local pattern="$1" total=0 n f
  [ -z "$files" ] && { echo 0; return; }
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    n=$(grep -oE -- "$pattern" "$f" 2>/dev/null | wc -l || true)
    total=$((total + n))
  done <<EOF
$files
EOF
  echo "$total"
}

eslint_disable=$(count '(eslint-disable(-next-line)?|prettier-ignore|biome-ignore)')
ts_ignore=$(count '@ts-(ignore|expect-error)')
any_colon=$(count ': *any\b')
any_as=$(count '\bas any\b')
any_nocheck=$(count '@ts-nocheck')
any_usage=$((any_colon + any_as + any_nocheck))
todo=$(count '\b(TODO|FIXME|HACK)\b')
console_log=$(count 'console\.log\(')

echo "$eslint_disable $ts_ignore $any_usage $todo $console_log"
