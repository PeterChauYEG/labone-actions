#!/usr/bin/env bash
set -uo pipefail

dir="${1:?usage: count-metrics.sh <dir>}"

if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  files="$(git -C "$dir" ls-files --cached --others --exclude-standard -- '*.rs' 2>/dev/null \
    | sed "s|^|${dir%/}/|" || true)"
else
  files="$(find "$dir" -type f -name '*.rs' \
    ! -path '*/target/*' ! -path '*/.git/*' 2>/dev/null || true)"
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

todo=$(count '\b(TODO|FIXME|HACK)\b')
allow_attrs=$(count '#!?\[allow\(')

echo "$todo $allow_attrs"
