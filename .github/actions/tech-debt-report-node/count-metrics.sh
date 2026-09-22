#!/usr/bin/env bash
# Counts labone-actions Node/backend tech-debt metrics (TypeScript
# call-site counts) over a directory tree. Prints five space-separated
# integers in a fixed order: disable-comments (eslint-disable(-next-line)/
# prettier-ignore/biome-ignore), @ts-ignore/@ts-expect-error, `any` usage
# (": any" / "as any" / "@ts-nocheck" files), TODO/FIXME/HACK comments,
# console.log. Shared by tech-debt-report-node/action.yml's "current tree"
# and "base-branch worktree" steps so the counting logic itself lives in
# exactly one place instead of being duplicated inline across two `run:`
# blocks.
#
# Mirrors tech-debt-report/count-metrics.sh's TS/TSX metrics, scoped to the
# five that have a direct Node/NestJS-backend equivalent - `useEffect(`
# call sites and RN `Animated.*` usage are dropped, since neither has any
# meaning outside React/React Native (a backend service has no component
# lifecycle, no Animated API). Everything else here (lint suppressions,
# @ts-ignore, any usage, TODO/FIXME/HACK, console.log) is generic
# TypeScript tech debt, equally meaningful in a NestJS service as in a
# React app.
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
