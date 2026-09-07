#!/usr/bin/env bash
# cache-gc.sh — delete idle GitHub Actions caches across every repo an
# account owns, per LAB cache policy (README.md "Scheduled cache GC").
#
# main-branch (refs/heads/main) cache entries are the canonical ones every
# job's `restore-keys` fallback depends on (see README.md "Per-job cache
# scoping"), so they get a longer idle threshold than every other
# (PR-branch) ref. `last_accessed_at`, not `created_at`, drives eviction —
# a cache that's still being restored regularly shouldn't be deleted just
# because it's old.
#
# Assumes GNU `date`'s `-d` flag (parses `lastAccessedAt`'s ISO-8601
# timestamp into epoch seconds) — true for every catfood self-hosted
# runner this repo targets, unlike count-metrics.sh's GNU-grep avoidance
# (that one runs on a wider, less certain set of runner images). Not
# portable to macOS/BSD `date`.
#
# Usage: cache-gc.sh --owner <org-or-user> [--main-max-idle-days N]
#                     [--other-max-idle-days N]
#
# Required env var:
#   GH_TOKEN — GitHub PAT with repo-wide cache read/delete scope (gh CLI
#              reads this automatically; see cache-gc.yml's own comment
#              for which secret this is).
set -euo pipefail

trap 'echo "error: cache-gc.sh failed at line $LINENO" >&2' ERR

usage() {
  echo "Usage: $0 --owner <org-or-user> [--main-max-idle-days N] [--other-max-idle-days N]" >&2
  exit 1
}

owner=""
main_max_idle_days=2
other_max_idle_days=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)
      owner="$2"
      shift 2
      ;;
    --main-max-idle-days)
      main_max_idle_days="$2"
      shift 2
      ;;
    --other-max-idle-days)
      other_max_idle_days="$2"
      shift 2
      ;;
    -h | --help)
      usage
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

if [[ -z "$owner" ]]; then
  usage
fi

summary_file="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

now_epoch="$(date -u +%s)"
main_cutoff_epoch=$((now_epoch - main_max_idle_days * 86400))
other_cutoff_epoch=$((now_epoch - other_max_idle_days * 86400))

{
  echo "## Cache GC"
  echo
  echo "| repo | caches deleted | bytes reclaimed |"
  echo "| --- | --- | --- |"
} >>"$summary_file"

total_deleted=0
total_bytes=0

repos="$(gh repo list "$owner" --json name --limit 200 --jq '.[].name')"

while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue

  caches_json="$(gh cache list -R "$owner/$repo" --json id,ref,lastAccessedAt,sizeInBytes --limit 100 2>/dev/null || echo '[]')"

  if [[ "$caches_json" == "[]" || -z "$caches_json" ]]; then
    continue
  fi

  repo_deleted=0
  repo_bytes=0

  while IFS=$'\t' read -r cache_id cache_ref last_accessed size_bytes; do
    [[ -z "$cache_id" ]] && continue

    if [[ "$cache_ref" == "refs/heads/main" ]]; then
      cutoff_epoch=$main_cutoff_epoch
    else
      cutoff_epoch=$other_cutoff_epoch
    fi

    last_accessed_epoch="$(date -u -d "$last_accessed" +%s)"

    if ((last_accessed_epoch < cutoff_epoch)); then
      if gh cache delete "$cache_id" -R "$owner/$repo" >/dev/null 2>&1; then
        repo_deleted=$((repo_deleted + 1))
        repo_bytes=$((repo_bytes + size_bytes))
      fi
    fi
  done < <(echo "$caches_json" | jq -r '.[] | [.id, .ref, .lastAccessedAt, .sizeInBytes] | @tsv')

  if ((repo_deleted > 0)); then
    echo "| $repo | $repo_deleted | $repo_bytes |" >>"$summary_file"
  fi

  total_deleted=$((total_deleted + repo_deleted))
  total_bytes=$((total_bytes + repo_bytes))
done <<<"$repos"

{
  echo
  echo "**Total**: $total_deleted cache(s) deleted, $total_bytes byte(s) reclaimed."
} >>"$summary_file"

echo "cache-gc: deleted $total_deleted cache(s), reclaimed $total_bytes byte(s) across $owner"
