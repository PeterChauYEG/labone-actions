#!/usr/bin/env bash
set -euo pipefail

workflow_name="${1:-CI}"
run_url="${2:-}"
run_id="${3:-}"

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "[classify-ci-failure] WARN: ANTHROPIC_API_KEY not set — filing without classification" >&2
  echo "file"
  exit 0
fi

jobs_json="{}"
if [[ -n "$run_id" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  jobs_json=$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${run_id}/jobs" 2>/dev/null || echo "{}")
fi

failed_summary=$(echo "$jobs_json" | jq -r '
  [.jobs[]? | select(.conclusion == "failure") |
    "- " + .name + ": " + ([.steps[]? | select(.conclusion == "failure") | .name] | join(", "))
  ] | join("\n")
' 2>/dev/null || echo "")

if [[ -z "$failed_summary" ]]; then
  failed_summary="(no per-job detail available)"
fi

prompt="A GitHub Actions workflow run failed. Decide whether this looks like a transient flake (infra hiccup, network blip, runner disconnect, known-flaky test retry) or a genuine code/CI breakage worth a ticket.

Workflow: ${workflow_name}
Run: ${run_url}
Failed jobs/steps:
${failed_summary}

Respond with ONLY one word: FILE (genuine failure, file a ticket) or SKIP (transient flake, don't file)."

request=$(jq -n --arg prompt "$prompt" '{
  model: "claude-haiku-4-5-20251001",
  max_tokens: 16,
  messages: [{role: "user", content: $prompt}]
}')

response=$(curl -s -X POST https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "$request")

verdict_text=$(echo "$response" | jq -r '.content[0].text // empty')

if [[ -z "$verdict_text" ]]; then
  echo "[classify-ci-failure] WARN: classification call failed — filing without classification" >&2
  echo "file"
  exit 0
fi

if [[ "$verdict_text" == *SKIP* ]]; then
  echo "skip"
else
  echo "file"
fi
