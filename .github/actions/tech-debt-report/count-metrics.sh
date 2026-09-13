#!/usr/bin/env bash
# Counts labone-actions tech-debt metrics (TypeScript/TSX call-site counts)
# over a directory tree. Prints seven space-separated integers in a fixed
# order: useEffect, Animated.*, disable-comments (eslint-disable(-next-line)/
# prettier-ignore/biome-ignore), @ts-ignore/@ts-expect-error, `any` usage
# (": any" / "as any" / "@ts-nocheck" files), TODO/FIXME/HACK comments,
# console.log. Shared by tech-debt-report/action.yml's "current tree" and
# "base-branch worktree" steps so the counting logic itself lives in
# exactly one place instead of being duplicated inline across two `run:`
# blocks.
set -uo pipefail

dir="${1:?usage: count-metrics.sh <dir>}"

# File discovery: `git ls-files` (tracked + untracked-but-not-ignored)
# instead of a raw `find` over the tree, so this automatically respects
# whatever a repo's own .gitignore excludes (build output, vendored
# dirs, anything else a repo chooses to ignore) rather than a hardcoded
# guess-list that silently misses whatever this list's authors didn't
# think of. Falls back to the old hardcoded-exclude `find` only if `dir`
# isn't inside a git working tree at all (e.g. a detached worktree setup
# gone wrong) - confirmed live 2026-09-13 that a plain `find` was scanning
# committed *and* gitignored files alike (node_modules/.next/dist/build/
# coverage/.expo were hardcoded, but anything a caller repo additionally
# ignores - e.g. a generated/ or .turbo/ dir - was silently still scanned).
# `--include=`/`--exclude-dir=` grep flags aren't used here either way:
# they're GNU-grep-only extensions, and catfood self-hosted runners aren't
# guaranteed to all be the same base image (a BusyBox userland grep, seen
# on some Alpine-based runner images, doesn't support either flag).
if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  files="$(git -C "$dir" ls-files --cached --others --exclude-standard -- '*.ts' '*.tsx' 2>/dev/null \
    | sed "s|^|${dir%/}/|" || true)"
else
  files="$(find "$dir" -type f \( -name '*.ts' -o -name '*.tsx' \) \
    ! -path '*/node_modules/*' ! -path '*/.next/*' ! -path '*/dist/*' \
    ! -path '*/build/*' ! -path '*/coverage/*' ! -path '*/.expo/*' \
    ! -path '*/.git/*' 2>/dev/null || true)"
fi

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
# Broadened beyond eslint-disable to any lint/formatter suppression
# comment this fleet's tooling recognizes: prettier-ignore and
# biome-ignore are the same "disable this rule right here" pattern for
# the other two tools some repos use alongside (or instead of) eslint.
eslint_disable=$(count '(eslint-disable(-next-line)?|prettier-ignore|biome-ignore)')
ts_ignore=$(count '@ts-(ignore|expect-error)')
any_colon=$(count ': *any\b')
any_as=$(count '\bas any\b')
any_nocheck=$(count '@ts-nocheck')
any_usage=$((any_colon + any_as + any_nocheck))
todo=$(count '\b(TODO|FIXME|HACK)\b')
console_log=$(count 'console\.log\(')

echo "$use_effect $animated $eslint_disable $ts_ignore $any_usage $todo $console_log"
