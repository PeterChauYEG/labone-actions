#!/usr/bin/env bash
set -euo pipefail

job_name="$1"
report_path="${2:-}"
groups_path="${3:-${job_name}-groups.json}"
repo="${GITHUB_REPOSITORY#*/}"

DEVOPS_LABEL_ID="81380be9-86c7-4122-9263-69925d981758"
CI_LABEL_ID="01f4906f-28d8-4ff9-b95c-a1d6de39d1ca"

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

  # shellcheck disable=SC2016
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

title="${job_name}: ${repo} failing"
title_prefix="${job_name}: ${repo}"
full_description="${description_prefix}${report_body}"
file_ticket_or_comment "$title" "$title_prefix" "$full_description"
