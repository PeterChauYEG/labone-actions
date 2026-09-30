#!/usr/bin/env bash
# file-ci-failure-ticket.sh — file a Linear ticket when a main-branch CI
# workflow fails, or comment on the existing open one for this repo instead
# of creating a duplicate.
#
# Deliberately a separate mechanism from scripts/file-linear-ticket.sh: that
# script files Medium-priority tickets deduped per-PR-per-job for quality-gate
# findings on a PR, and is only ever invoked for pull_request-triggered runs.
# This script files a single Urgent (P0) ticket deduped per-repo for
# main-branch breakage — a broken main blocks every subsequent deploy, so it
# gets one loud ticket per repo rather than one per failing job. Mirrors
# company-system's scripts/create-ci-failure-ticket.sh (agent-monitor-driven,
# not GHA-driven) — same title shape and dedup intent, reimplemented here as
# a plain GHA-invokable script with no ops-harness/company-system dependency.
#
# Usage: file-ci-failure-ticket.sh <workflow-name> <run-url>
#
# Required env vars:
#   LINEAR_API_KEY       — Linear GraphQL API key (repo secret)
#   GITHUB_REPOSITORY    — e.g. "PeterChauYEG/labone-actions"
# Optional env vars:
#   REPORT                — extra failure detail (e.g. job name list) appended to the ticket description
set -euo pipefail

workflow_name="${1:-CI}"
run_url="${2:-}"
report="${REPORT:-}"

CI_LABEL_ID="01f4906f-28d8-4ff9-b95c-a1d6de39d1ca"

if [[ -z "${LINEAR_API_KEY:-}" ]]; then
  echo "[file-ci-failure-ticket] WARN: LINEAR_API_KEY not set — skipping" >&2
  exit 0
fi

repo_name="${GITHUB_REPOSITORY#*/}"
title="🔴 CI failing on main: ${repo_name}"
ci_failure_key="ci-failure:${repo_name}:${workflow_name}"
ci_failure_marker="<!-- ci-failure-key: ${ci_failure_key} -->"

# ── Dedup: one open ticket per repo+workflow, matched on a stable marker in
# the description rather than the (mutable) title — triage agents retitle
# tickets, which breaks an exact-title match and lets duplicates through.
search_query=$(jq -n --arg descriptionContains "$ci_failure_marker" '{
  query: "query($descriptionContains: String!) { issues(filter: { team: { key: { eq: \"LAB\" } }, state: { type: { nin: [\"completed\", \"cancelled\", \"duplicate\"] } }, description: { contains: $descriptionContains } }, first: 1) { nodes { id identifier url } } }",
  variables: { descriptionContains: $descriptionContains }
}')

search_response=$(curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$search_query")

existing_id=$(echo "$search_response" | jq -r '.data.issues.nodes[0].id // empty')
existing_identifier=$(echo "$search_response" | jq -r '.data.issues.nodes[0].identifier // empty')

if [[ -n "$existing_id" ]]; then
  echo "[file-ci-failure-ticket] existing open ticket $existing_identifier — commenting instead of creating a duplicate"
  comment_body="Still failing: \`${workflow_name}\` on main as of ${run_url}."
  comment_json=$(jq -n --arg issueId "$existing_id" --arg body "$comment_body" \
    '{query:"mutation($issueId:String!,$body:String!){commentCreate(input:{issueId:$issueId,body:$body}){success}}", variables:{issueId:$issueId, body:$body}}')
  curl -s -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$comment_json" > /dev/null
  exit 0
fi

# ── No existing ticket — resolve team + Backlog state, then create one ─────
team_response=$(curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ teams(filter: { key: { eq: \"LAB\" } }) { nodes { id } } }"}')
team_id=$(echo "$team_response" | jq -r '.data.teams.nodes[0].id // empty')

if [[ -z "$team_id" ]]; then
  echo "[file-ci-failure-ticket] ERROR: could not find LAB team" >&2
  exit 1
fi

states_response=$(curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ workflowStates(filter: { team: { key: { eq: \"LAB\" } }, name: { eq: \"Backlog\" } }) { nodes { id } } }"}')
state_id=$(echo "$states_response" | jq -r '.data.workflowStates.nodes[0].id // empty')

if [[ -z "$state_id" ]]; then
  echo "[file-ci-failure-ticket] ERROR: could not find Backlog state" >&2
  exit 1
fi

description="**Repository:** \`${repo_name}\`
**Workflow:** \`${workflow_name}\`
**Run:** ${run_url}
"

if [[ -n "$report" ]]; then
  description="${description}
### Details
${report}
"
fi

description="${description}
${ci_failure_marker}
"

# shellcheck disable=SC2016 # single-quoted on purpose: GraphQL variable refs.
mutation='mutation($teamId: String!, $title: String!, $description: String!, $stateId: String!, $priority: Int, $labelIds: [String!]) {
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

create_response=$(jq -n \
  --arg mutation "$mutation" \
  --arg teamId "$team_id" \
  --arg title "$title" \
  --arg description "$description" \
  --arg stateId "$state_id" \
  --arg ciLabelId "$CI_LABEL_ID" \
  '{
    query: $mutation,
    variables: {
      teamId: $teamId,
      title: $title,
      description: $description,
      stateId: $stateId,
      priority: 1,
      labelIds: [$ciLabelId]
    }
  }' | \
  curl -s -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d @-)

success=$(echo "$create_response" | jq -r '.data.issueCreate.success // false')

if [[ "$success" != "true" ]]; then
  echo "[file-ci-failure-ticket] ERROR: issueCreate failed: $(echo "$create_response" | jq -r '.errors[0].message // "unknown"')" >&2
  exit 1
fi

identifier=$(echo "$create_response" | jq -r '.data.issueCreate.issue.identifier')
url=$(echo "$create_response" | jq -r '.data.issueCreate.issue.url')
echo "[file-ci-failure-ticket] created $identifier: $url"
