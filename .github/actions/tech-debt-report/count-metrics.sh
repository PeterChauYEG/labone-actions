#!/usr/bin/env bash
# Counts labone-actions tech-debt metrics (TypeScript/TSX call-site counts)
# over a directory tree. Prints seven space-separated integers in a fixed
# order: useEffect, Animated.*, eslint-disable(-next-line), @ts-ignore/
# @ts-expect-error, `any` usage (": any" / "as any" / "@ts-nocheck" files),
# TODO/FIXME/HACK comments, console.log. Shared by tech-debt-report/
# action.yml's "current tree" and "base-branch worktree" steps so the
# counting logic itself lives in exactly one place instead of being
# duplicated inline across two `run:` blocks.
set -uo pipefail

dir="${1:?usage: count-metrics.sh <dir>}"

# File discovery goes through `find`/a per-file `grep -oE` loop rather than
# a single `grep -rhoE --include=... --exclude-dir=...` call: --include/
# --exclude-dir are GNU-grep-only extensions, and catfood self-hosted
# runners aren't guaranteed to all be the same base image (a BusyBox
# userland grep, seen on some Alpine-based runner images, doesn't support
# either flag). `find`'s `-name`/`! -path` and `grep -oE` are both
# supported by every grep/find this needs to run on.
files="$(find "$dir" -type f \( -name '*.ts' -o -name '*.tsx' \) \
  ! -path '*/node_modules/*' ! -path '*/.next/*' ! -path '*/dist/*' \
  ! -path '*/build/*' ! -path '*/coverage/*' ! -path '*/.expo/*' \
  ! -path '*/.git/*' 2>/dev/null || true)"

count() {
  local pattern="$1" total=0 n f
  [ -z "$files" ] && { echo 0; return; }
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    # `|| true` guards against grep's exit 1 on "no matches" — under
    # `pipefail` that would otherwise make this loop look like it failed
    # just because a metric's count is zero in that one file.
    n=$(grep -oE -- "$pattern" "$f" 2>/dev/null | wc -l || true)
    total=$((total + n))
  done <<EOF
$files
EOF
  echo "$total"
}

use_effect=$(count 'useEffect\(')
# Built-in react-native Animated API only (`Animated.View`, `Animated.timing(`,
# etc.) — a bare `\bAnimated\.` match also catches third-party libs that
# happen to export their own `Animated` namespace (e.g. some
# reanimated/moti usage), which is a known, accepted imprecision for a v1
# grep-based count. See README.md.
animated=$(count '\bAnimated\.')
eslint_disable=$(count 'eslint-disable(-next-line)?')
ts_ignore=$(count '@ts-(ignore|expect-error)')
any_colon=$(count ': *any\b')
any_as=$(count '\bas any\b')
any_nocheck=$(count '@ts-nocheck')
any_usage=$((any_colon + any_as + any_nocheck))
todo=$(count '\b(TODO|FIXME|HACK)\b')
console_log=$(count 'console\.log\(')

echo "$use_effect $animated $eslint_disable $ts_ignore $any_usage $todo $console_log"
