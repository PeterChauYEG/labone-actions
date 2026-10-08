#!/usr/bin/env bash
# file-linear-ticket.sh — file a Linear ticket for a failing CI quality-gate
# job (actionlint), or comment on the existing open one for this PR + job
# instead of creating a duplicate.
#
# Adapted from laboratory-one-web's scripts/file-linear-ticket.sh (PR #87),
# via ops's scripts/file-linear-ticket.sh (LAB-989).
# This is deliberately a separate mechanism from
# .claude/skills/company-system/scripts/dispatch/lib-linear.sh /
# ci-failure-monitor.yml's "CI failing on main: <repo>" tickets — those file
# P0/Urgent tickets deduped per-repo for main-branch breakage. This script
# files Medium-priority tickets deduped per-PR-per-job for quality-gate
# findings on a PR, and is only ever invoked for pull_request-triggered runs.
#
# Usage: file-linear-ticket.sh <job-name> [report-path] [groups-json-path]
#
# groups-json-path (optional; default: <job-name>-groups.json, matching the
# `<job-name>-report.md`/`.json` naming convention scan scripts already
# write) — when that file exists and holds a non-empty JSON array of
# {scope, description} objects (see scripts/lib/package-cluster.mjs for the
# duplicate-code/dead-code producer), one ticket is filed/deduped per entry,
# titled "<job-name>: <repo> <scope>", instead of a single flat ticket. This
# is the deterministic, CI-side replacement for what used to be an agent's
# judgment call about how to split a large report — mirrors
# mecha-industries/mecha10 PRs #822/#824. A missing/empty/absent groups file
# is a deliberate no-op fallback to today's flat behavior — jobs that don't
# produce a groups file (design-system, react-tech-debt, max-lines,
# actionlint, ...) are unaffected.
#
# Required env vars:
#   LINEAR_API_KEY       — Linear GraphQL API key (repo secret)
#   GITHUB_REPOSITORY    — e.g. "PeterChauYEG/labone-actions"
#   PR_NUMBER            — pull request number
#   PR_URL                — pull request HTML URL
#   RUN_URL               — workflow run URL, for linking the latest failure
set -euo pipefail

job_name="$1"
report_path="${2:-}"
groups_path="${3:-${job_name}-groups.json}"
repo="${GITHUB_REPOSITORY#*/}"

DEVOPS_LABEL_ID="81380be9-86c7-4122-9263-69925d981758"
CI_LABEL_ID="01f4906f-28d8-4ff9-b95c-a1d6de39d1ca"

# Strips any "LAB-<digits>" ticket-reference substring (case-insensitive)
# out of a title component before it's used to build a Linear ticket
# title. Found live: a different split-ticket flow (not this script) once
# embedded a sibling ticket's own ID in a child ticket's title text for
# human-readable traceability — GitHub's Linear integration then
# auto-links any PR whose branch/body contains that substring to BOTH the
# real ticket and the accidentally-referenced one, so QA on the wrong
# ticket finds someone else's merged PR attached and reports a false
# mismatch. `scope` here is derived from a package/file path
# (packageOf() in lib/package-cluster.mjs) and isn't expected to ever
# collide today, but nothing stops a future package/directory name from
# looking like "lab-1234" — sanitize defensively so a title built from it
# can never reintroduce this class of bug.
strip_ticket_refs() {
  echo "$1" | sed -E 's/[-_]?\bLAB-[0-9]+\b[-_]?//Ig' | tr -s ' ' | sed -E 's/^[ -]+|[ -]+$//g'
}

job_name="$(strip_ticket_refs "$job_name")"
repo="$(strip_ticket_refs "$repo")"

if [[ -z "${LINEAR_API_KEY:-}" ]]; then
  echo "[file-linear-ticket] WARN: LINEAR_API_KEY not set — skipping" >&2
  exit 0
fi

report_body="(no report available — see run for details)"
if [[ -n "$report_path" && -f "$report_path" ]]; then
  report_body=$(cat "$report_path")
fi

description_prefix="PR: ${PR_URL}
Run: ${RUN_URL}

"

# ── Shared: file a ticket for $1=title, or comment on the oldest already-
# open one whose title starts with $2=title_prefix. $3=description_body.
# Dedup rationale: search on a title *prefix* rather than an exact match so
# a scoped/split ticket's title ("<job-name>: <repo> <scope>") still shares
# a common prefix with a flat single-ticket ("<job-name>: <repo> failing")
# filed before this job's report grew large enough to need splitting.
#
# A prefix match can return more than one open ticket. We don't try to
# merge those here — out of scope — we just need to comment on one of them
# instead of creating yet another. Fetch a batch and pick the oldest (by
# createdAt) as the canonical target, since Linear's default ordering for
# `issues` isn't documented/guaranteed here.
#
# state.type must also exclude "duplicate": tickets we've manually deduped
# still match this title-prefix search, so without the exclusion this query
# finds them again, comments on them, and Linear's activity-triggered
# automation flips them back out of the Duplicate state — silently undoing
# the dedup on every subsequent CI failure.
file_ticket_or_comment() {
  local title="$1" title_prefix="$2" description_body="$3"

  local search_query search_response oldest_match existing_id existing_identifier
  search_query=$(jq -n --arg titlePrefix "$title_prefix" '{
    query: "query($titlePrefix: String!) { issues(filter: { team: { key: { eq: \"LAB\" } }, state: { type: { nin: [\"completed\", \"cancelled\", \"duplicate\"] } }, title: { startsWith: $titlePrefix } }, first: 25) { nodes { id identifier url createdAt } } }",
    variables: { titlePrefix: $titlePrefix }
  }')

  search_response=$(curl -s -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$search_query")

  oldest_match=$(echo "$search_response" | jq -c '[.data.issues.nodes[]?] | sort_by(.createdAt) | .[0] // empty')
  existing_id=$(echo "$oldest_match" | jq -r '.id // empty')
  existing_identifier=$(echo "$oldest_match" | jq -r '.identifier // empty')

  if [[ -n "$existing_id" ]]; then
    echo "[file-linear-ticket] existing open ticket $existing_identifier for \"$title_prefix*\" — commenting instead of creating a duplicate"
    local comment_body comment_json
    comment_body="Still failing on PR #${PR_NUMBER} as of ${RUN_URL}."
    comment_json=$(jq -n --arg issueId "$existing_id" --arg body "$comment_body" \
      '{query:"mutation($issueId:String!,$body:String!){commentCreate(input:{issueId:$issueId,body:$body}){success}}", variables:{issueId:$issueId, body:$body}}')
    curl -s -X POST https://api.linear.app/graphql \
      -H "Authorization: $LINEAR_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$comment_json" > /dev/null
    return 0
  fi

  ensure_team_and_state

  # shellcheck disable=SC2016 # single-quoted on purpose: these are GraphQL
  # variable references ($teamId etc.), not shell variables - they must
  # stay literal here and are supplied later via the `variables` payload.
  local mutation='mutation($teamId: String!, $title: String!, $description: String!, $stateId: String!, $priority: Int, $labelIds: [String!]) {
    issueCreate(input: {
      teamId: $teamId,
      title: $title,
      description: $description,
      stateId: $stateId,
      priority: $priority,
      labelIds: $labelIds
    }) {
      success
      issue { identifier url }
    }
  }'

  local create_response success identifier url
  create_response=$(jq -n \
    --arg mutation "$mutation" \
    --arg teamId "$team_id" \
    --arg title "$title" \
    --arg description "$description_body" \
    --arg stateId "$state_id" \
    --arg devopsLabelId "$DEVOPS_LABEL_ID" \
    --arg ciLabelId "$CI_LABEL_ID" \
    '{
      query: $mutation,
      variables: {
        teamId: $teamId,
        title: $title,
        description: $description,
        stateId: $stateId,
        priority: 3,
        labelIds: [$devopsLabelId, $ciLabelId]
      }
    }' | \
    curl -s -X POST https://api.linear.app/graphql \
      -H "Authorization: $LINEAR_API_KEY" \
      -H "Content-Type: application/json" \
      -d @-)

  success=$(echo "$create_response" | jq -r '.data.issueCreate.success // false')

  if [[ "$success" != "true" ]]; then
    echo "[file-linear-ticket] ERROR: issueCreate failed for \"$title\": $(echo "$create_response" | jq -r '.errors[0].message // "unknown"')" >&2
    return 1
  fi

  identifier=$(echo "$create_response" | jq -r '.data.issueCreate.issue.identifier')
  url=$(echo "$create_response" | jq -r '.data.issueCreate.issue.url')
  echo "[file-linear-ticket] created $identifier: $url"
}

# ── Resolve team + Backlog state lazily, once, on first actual need (i.e.
# the first ticket in this run that has no existing match to comment on
# instead) — not eagerly at startup. A run where every group/the flat
# ticket already has an open match never creates anything, so it should
# never pay for these two extra lookups either.
team_id=""
state_id=""
ensure_team_and_state() {
  if [[ -n "$team_id" ]]; then
    return 0
  fi

  local team_response states_response
  team_response=$(curl -s -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"query":"{ teams(filter: { key: { eq: \"LAB\" } }) { nodes { id } } }"}')
  team_id=$(echo "$team_response" | jq -r '.data.teams.nodes[0].id // empty')

  if [[ -z "$team_id" ]]; then
    echo "[file-linear-ticket] ERROR: could not find LAB team" >&2
    exit 1
  fi

  states_response=$(curl -s -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"query":"{ workflowStates(filter: { team: { key: { eq: \"LAB\" } }, name: { eq: \"Backlog\" } }) { nodes { id } } }"}')
  state_id=$(echo "$states_response" | jq -r '.data.workflowStates.nodes[0].id // empty')

  if [[ -z "$state_id" ]]; then
    echo "[file-linear-ticket] ERROR: could not find Backlog state" >&2
    exit 1
  fi
}

# ── Grouped mode: a groups file with a non-empty array splits filing into
# one ticket per {scope, description} entry. Anything else (missing file,
# empty array, invalid JSON) falls through to the flat single-ticket path.
group_count=0
if [[ -f "$groups_path" ]] && jq -e 'type == "array" and length > 0' "$groups_path" > /dev/null 2>&1; then
  group_count=$(jq 'length' "$groups_path")
fi

if [[ "$group_count" -gt 0 ]]; then
  echo "[file-linear-ticket] $groups_path has $group_count group(s) — filing one ticket per group"
  for i in $(seq 0 $((group_count - 1))); do
    scope=$(strip_ticket_refs "$(jq -r ".[$i].scope" "$groups_path")")
    group_description=$(jq -r ".[$i].description" "$groups_path")
    title="${job_name}: ${repo} ${scope}"
    title_prefix="$title"
    full_description="${description_prefix}${group_description}"
    file_ticket_or_comment "$title" "$title_prefix" "$full_description"
  done
  exit 0
fi

# ── Flat mode (today's behavior): one ticket for the whole job/report ──────
title="${job_name}: ${repo} failing"
title_prefix="${job_name}: ${repo}"
full_description="${description_prefix}${report_body}"
file_ticket_or_comment "$title" "$title_prefix" "$full_description"
