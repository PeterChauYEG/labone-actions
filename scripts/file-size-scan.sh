#!/usr/bin/env bash
# file-size-scan.sh — flags .rs files over a line-count threshold.
#
# Bash equivalent of the Node/JS `scripts/max-lines-scan.mjs` scan for
# Rust callers of develop-rust-ci.yml/rust-cli-pr.yml — see those
# workflows' `file_size_script_source` input (`'labone-actions'` runs this
# script directly; `'repo'`, the default, keeps running the caller's own
# vendored `file_size_script` path, e.g. ai-harness-cli's
# scripts/ci/file-size-scan.sh, which this mirrors).
#
# clippy::too_many_lines only gates function length, not file length, and
# no Rust-native tool fills that gap. Deliberately non-blocking (unlike
# duplicate-code-scan.sh): the CI job posts this report as a sticky comment
# but never fails the build on it.
#
# Invoked with the caller's Cargo project already as cwd (via the
# workflow's `working-directory:` on the step that runs this) — every path
# here is deliberately cwd-relative, matching design-system-scan.mjs's
# convention for scan-with-report's `script-source: labone-actions` mode.
#
# Usage: file-size-scan.sh [report.md] [threshold] [scan-dir] [exclude-paths]
#
# exclude-paths is a comma- or newline-separated list of path prefixes/globs
# to skip, e.g. 'ai-harness-api-sdk,auth-sdk' or a glob like '*/generated/*'.
# Each entry that has no '*' of its own is wrapped as '*<entry>*' so a bare
# directory name (or path fragment) excludes anywhere it appears; an entry
# already containing '*' is used as-is. An entry matching nothing is a no-op.
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
