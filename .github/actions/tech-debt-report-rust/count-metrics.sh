#!/usr/bin/env bash
# Counts labone-actions Rust tech-debt metrics over a directory tree.
# Prints two space-separated integers in a fixed order: TODO/FIXME/HACK
# comments, `#[allow(...)]` lint-suppression attributes. Shared by
# tech-debt-report-rust/action.yml's "current tree" and "base-branch
# worktree" steps so the counting logic itself lives in exactly one place
# instead of being duplicated inline across two `run:` blocks. Mirrors
# tech-debt-report/count-metrics.sh's TS/TSX metrics, scoped to the two
# that have a direct Rust equivalent — `#[allow(...)]` is Rust's
# eslint-disable (it suppresses a specific clippy/rustc lint at a specific
# site, same as an eslint-disable(-next-line) comment does), and
# TODO/FIXME/HACK comments mean the same thing regardless of language.
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
