# labone-actions

Shared GitHub Actions workflows/actions for LAB repos, so CI stops being
copy-pasted (and slowly drifting) across every web repo.

All jobs here assume **self-hosted `catfood` runners** — GitHub-hosted
runners (`ubuntu-latest` etc.) are blocked account-wide by billing. Every
consumer repo must have a `catfood` runner registered before calling any of
these workflows.

## Reusable workflows

| Workflow | Trigger it's meant for | Purpose |
|---|---|---|
| `.github/workflows/develop-ci.yml` | `pull_request` | Full PR-time quality gate set (lint, typecheck, tests, scans) with sticky PR comments + Linear ticket filing on failure. |
| `.github/workflows/main-ci.yml` | `push` to `main` | Same gate set as plain pass/fail checks, plus `deploy` (Dokku) and `slack-notification`. |
| `.github/workflows/security-scan.yml` | either | Trivy filesystem vuln/secret scan. |
| `.github/workflows/dependabot-automerge.yml` | not reusable — copy the job or call it directly (see below) | Auto-merges dependabot minor/patch PRs. |

### Caller pattern

Callers are thin wrappers: a workflow file in the consumer repo that
computes anything the reusable workflow can't see from its own context
(PR number/URL, whether the actor is dependabot), then `uses:` the
reusable workflow with `secrets: inherit`. Example `develop.yml`:

```yaml
name: Develop CI
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  ci:
    uses: PeterChauYEG/labone-actions/.github/workflows/develop-ci.yml@main
    secrets: inherit
    with:
      pr_number: ${{ github.event.pull_request.number }}
      pr_url: ${{ github.event.pull_request.html_url }}
      is_dependabot: ${{ github.event.pull_request.user.login == 'dependabot[bot]' }}
      # Turn off any job your repo doesn't have a yarn script for, e.g.:
      # enable_e2e: false
```

And `main.yml`:

```yaml
name: Main CI
on:
  push:
    branches: [main]

jobs:
  ci:
    uses: PeterChauYEG/labone-actions/.github/workflows/main-ci.yml@main
    secrets: inherit
    with:
      is_dependabot: ${{ github.event.head_commit.author.name == 'dependabot[bot]' }}
      dokku_remote_url: 'ssh://dokku@192.168.1.31:22/<app-name>'
```

Pin to a tag/SHA instead of `@main` once this repo starts cutting releases;
`@main` is fine for now while the interface is still settling.

### `develop-ci.yml` — inputs and jobs

Inputs (all `workflow_call` inputs, `enable_*` default `true`):

- `pr_number` (number) — for concurrency grouping + Linear ticket linking.
- `pr_url` (string) — for Linear ticket linking.
- `is_dependabot` (boolean) — caller-computed; skips every job below
  `lint`/`typecheck`/`build`.
- `enable_ls_lint`, `enable_build`, `enable_test`, `enable_a11y`,
  `enable_design_system`, `enable_dead_code`, `enable_duplicate_code`,
  `enable_e2e`, `enable_react_tech_debt`, `enable_max_lines` (boolean) —
  turn a job off if your repo has no matching yarn script.

Jobs: `setup`, `lint`, `ls-lint`, `typecheck`, `build`, `test`, `a11y`,
`design-system`, `dead-code`, `duplicate-code`, `run-e2e-tests`,
`react-tech-debt`, `max-lines`. Scan jobs (`a11y`, `design-system`,
`dead-code`, `duplicate-code`, `run-e2e-tests`) post a sticky PR comment on
every run and file/comment-on a Linear ticket (via
`scripts/file-linear-ticket.sh`) when they fail; `react-tech-debt` and
`max-lines` only post the sticky comment (no ticket), matching prior
per-repo behavior.

### `main-ci.yml` — inputs and jobs

Same `enable_*`/`is_dependabot` inputs as `develop-ci.yml` (no `pr_number`/
`pr_url` — there's no PR at push-to-main time), plus:

- `enable_deploy` (boolean, default `true`)
- `dokku_remote_url` (string) — required if `enable_deploy` is true.
- `enable_slack_notification` (boolean, default `true`)

Jobs: the same `setup`/`lint`/.../`max-lines` set as plain pass/fail
gates (no sticky comments, no ticket filing), plus `deploy` (pushes to
`dokku_remote_url` using secret `DOKKU_DEPLOY_SSH_KEY`) and
`slack-notification` (posts the deploy result using secret
`SLACK_WEBHOOK_URL`). `deploy` runs only if every enabled gate job actually
passed — jobs skipped via `enable_*: false` don't block it (skipped isn't a
failure), but any real failure or cancellation does.

**These names are load-bearing**: a follow-on task migrates
`laboratory-one-web` to call these exact workflows, so treat the
`workflow_call` input names and job names above as a stable interface —
don't rename them without also updating every caller.

## Caching strategy

Every job used to do its own checkout + `setup-node` + cache-restore +
full `yarn install --frozen-lockfile` — up to ~12 redundant installs per PR
across the full job set, on top of two repos using incompatible cache key
conventions (flat `.yarn-cache` vs. Yarn Berry's `.yarn/cache` +
`.yarn/install-state.gz`, meaning the cache wasn't even shared across those
two repos' historical CI).

This repo's workflows fix that with a **shared `setup` job + artifact**,
not just a cache-key fix:

1. `setup` runs once: checkout, enable Corepack, `actions/setup-node`,
   restore the Yarn cache (standardized on the Yarn Berry paths), run
   `yarn install --frozen-lockfile`, then upload `node_modules` (+
   `.next/cache` if present) as a build artifact named
   `deps-${{ github.run_id }}` — see `.github/actions/setup-node-yarn/action.yml`.
2. Every other job `needs: setup` and downloads that artifact instead of
   installing — see `.github/actions/restore-deps/action.yml`.

Why artifact-over-fixing-just-the-cache-key: `actions/cache` restore still
pays per-job tar-extraction + Yarn's link/resolve step for every job that
restores it (Yarn's own local package cache avoids re-fetching over the
network, but not that per-job unpack/link cost) — on a run with ~12 jobs
that's still ~12x the extraction/link work even with a correct, shared
cache key. Uploading the fully-installed `node_modules` once and
downloading the ready-to-use tree in every other job replaces that
per-job "resolve + link" cost with a single artifact transfer over the
self-hosted fleet's local network, which is fast and doesn't grow with the
job count. The Yarn cache (`actions/cache`) is *also* kept in `setup`, so
even a `setup` cache-miss (new lockfile) only pays the network-fetch cost
once, not per job.

If a repo ever needs a job that's genuinely independent of `setup` (rare —
none of the current jobs are), it's fine for that job to opt out of
`needs: setup` and install directly; the composite actions don't assume
they're the only way to get dependencies in place.

## `security-scan.yml`

Unchanged. Reusable, `workflow_call` input `scan-ref` (string, default
`.`), single `trivy` job. Call it directly with `secrets: inherit`.

## `dependabot-automerge.yml`

Left as a standalone (non-reusable) workflow rather than converting it to
`workflow_call`. It's already tiny (one job, no yarn/build dependency) and
every consumer wants the same behavior with no meaningful variation to
parameterize — turning it into a reusable workflow would add an extra
indirection layer for no real flexibility gain. Copy the file as-is into a
consumer repo's `.github/workflows/` if it needs auto-merge.
