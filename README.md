# labone-actions

[![CI](https://github.com/PeterChauYEG/labone-actions/actions/workflows/ci.yml/badge.svg)](https://github.com/PeterChauYEG/labone-actions/actions/workflows/ci.yml)
[![Security scan](https://github.com/PeterChauYEG/labone-actions/actions/workflows/security.yml/badge.svg)](https://github.com/PeterChauYEG/labone-actions/actions/workflows/security.yml)
[![Actionlint](https://github.com/PeterChauYEG/labone-actions/actions/workflows/actionlint.yml/badge.svg)](https://github.com/PeterChauYEG/labone-actions/actions/workflows/actionlint.yml)

Shared GitHub Actions workflows/actions for LAB repos, so CI stops being
copy-pasted (and slowly drifting) across every web repo.

All jobs here assume **self-hosted `catfood` runners** — GitHub-hosted
runners (`ubuntu-latest` etc.) are blocked account-wide by billing. Every
consumer repo must have a `catfood` runner registered before calling any of
these workflows.

Design rationale, incident history, and per-workflow internals have moved
out of this README into [`docs/`](docs/) — see the links at the bottom.

## Reusable workflows

| Workflow | Trigger it's meant for | Purpose |
|---|---|---|
| `.github/workflows/develop-ci.yml` | `pull_request` | Full PR-time quality gate set (lint, typecheck, tests, scans) with ONE aggregated sticky PR comment + deduped Linear ticket filing on failure, via the `danger-comment` job — see [`docs/reporting.md`](docs/reporting.md). For yarn/Next.js-ish **web** repos. |
| `.github/workflows/main-ci.yml` | `push` to `main` | Same gate set as plain pass/fail checks (`a11y`/`design-system`/`dead-code`/`duplicate-code`/`react-tech-debt`/`max-lines` are all advisory-only, nextjs-ci v1.0.3 — see [`docs/workflows.md`](docs/workflows.md)), plus `deploy` (Dokku) and `slack-notification`. For yarn/Next.js-ish **web** repos. |
| `.github/workflows/develop-node-ci.yml` | `pull_request` | PR-time quality gate set (lint, typecheck, test, build, security-scan, dependency-audit) as plain pass/fail checks, optional ls-lint (`enable_ls_lint`), dead-code (`enable_dead_code`, LAB-1866) and duplicate-code (`enable_duplicate_code`), yarn-only, opt-in and advisory-only. `peer-deps`/`security-scan`/`secret-scan`/`dependency-audit`/`dead-code`/`duplicate-code` all feed ONE aggregated sticky PR comment + deduped Linear ticket filing on failure, via the `danger-comment` job. For yarn- or pnpm-based (`package_manager` input, LAB-1268) Node/NestJS **backend service** repos. |
| `.github/workflows/main-node-ci.yml` | `push` to `main` | Same gate set as `develop-node-ci.yml`, plus `deploy` (Dokku) and `slack-notification`. Optional dead-code (`enable_dead_code`, LAB-1866, plain pass/fail, yarn-only) opt-in. For yarn/Node/NestJS **backend service** repos. |
| `.github/workflows/godot-develop-ci.yml` | `pull_request` | format/lint/duplicate-code/test quality gate (gdformat, gdlint, jscpd, GUT) with Linear ticket filing on failure. For Godot 4/GDScript **game** repos. |
| `.github/workflows/main-godot-ci.yml` | `push` to `main` | Same gate set as `godot-develop-ci.yml` (no separate deploy/slack-notification - Godot repos here have no server-side deploy target). For Godot 4/GDScript **game** repos. |
| `.github/workflows/develop-python-ci.yml` | `pull_request` | lint (ruff), test, security-scan, secret-scan, optional dependency-audit (pip-audit) as plain pass/fail checks. `security-scan`/`secret-scan`/`dependency-audit` feed one aggregated sticky PR comment + deduped Linear ticket filing via `danger-comment`. For **Python** repos (data pipelines, MCP servers, ML/robotics scripts). |
| `.github/workflows/main-python-ci.yml` | `push` to `main` | Same gate set as `develop-python-ci.yml`, no path filtering (main-push CI only skips via `is_dependabot`). No deploy job - no single common deploy target for Python repos in this org. For **Python** repos. |
| `.github/workflows/develop-rust-ci.yml` | `pull_request` | fmt/clippy/test/dead-code/duplicate-code/file-size/security-scan/secret-scan/dependency-audit all feed ONE aggregated sticky PR comment + deduped Linear ticket filing via `danger-comment`, optional build. For **Rust CLI/tool** repos. |
| `.github/workflows/main-rust-ci.yml` | `push` to `main` | Same gate set as `develop-rust-ci.yml` as plain pass/fail checks (no path filtering, no sticky-comment/Linear-ticket-filing - no PR to attach those to). No deploy job - no single common deploy target for Rust CLI/tool repos in this org. For **Rust CLI/tool** repos. |
| `.github/workflows/develop-mobile-ci.yml` | `pull_request` | lint/typecheck as plain pass/fail checks, optional ls-lint/test/a11y/design-system/dead-code (knip)/duplicate-code (jscpd)/security-scan/dependency-audit, all feeding ONE aggregated sticky PR comment + deduped Linear ticket filing via `danger-comment`. For **Expo/React Native mobile** repos. |
| `.github/workflows/ci-failure-monitor.yml` | `workflow_run` (completed, on `main`) | Files (or comments on) one Urgent (P0) Linear ticket per repo, titled `🔴 CI failing on main: <repo>`, whenever the caller's own main-branch CI workflow(s) finish with `conclusion == 'failure'`. Deduped per-repo, NOT per-job — see [`docs/workflows.md`](docs/workflows.md) and `scripts/file-ci-failure-ticket.sh`'s header comment for how this differs from the PR-time `file-linear-tickets` job. |
| `.github/workflows/security-scan.yml` | either | Trivy filesystem vuln/secret scan. |
| `.github/workflows/actionlint.yml` | `pull_request` | Lints the caller's own `.github/workflows/*.yml` with actionlint. Stack-agnostic — any repo with a `.github/workflows/` directory can call it. |
| `.github/workflows/dependabot-automerge.yml` | `pull_request` | Auto-merges dependabot minor/patch PRs. |
| `.github/workflows/version-bump.yml` | `push` to `main` (mobile repos: `schedule` instead) + `workflow_dispatch` | CalVer version bump: pushes a bump commit and tags a release when there are new commits since the last tag. Requires the caller repo to provide `./scripts/bump-version.sh` (see below). |

Full `workflow_call` inputs and job lists for every workflow above: [`docs/workflows.md`](docs/workflows.md).

## Orchestrator workflows — prefer these over calling `develop-*-ci.yml`/`main-*-ci.yml` directly

For each `develop-*-ci.yml`/`main-*-ci.yml` pair that has a PR-time and/or push-to-main
counterpart, this repo also ships a thin, type-specific **orchestrator** `workflow_call`
workflow one level up: `mobile-pr.yml`, `node-pr.yml`, `web-pr.yml`, `python-pr.yml`,
`rust-pr.yml`, `godot-pr.yml`, `node-main.yml`, `web-main.yml`. Prefer these over calling
`develop-*-ci.yml`/`main-*-ci.yml` directly — they bake in the `permissions:`/`concurrency:`
wiring every caller needs, so a caller repo's own workflow file becomes a near-empty `uses:`
block. See [`docs/orchestrators.md`](docs/orchestrators.md) for the full design rationale.

### `templates/` — canonical caller files, one per repo type

Every reusable workflow above has a matching canonical caller file under `templates/` in this
repo (`templates/node-pr.yml`, `templates/godot-pr.yml`, `templates/mobile-pr.yml`, etc.) — the
exact `.github/workflows/<name>.yml` content a consumer repo of that type should have, not just
a code block in this README. **Copy the template file verbatim** into the consumer repo (as
`develop.yml`/`pr.yml`, matching whatever the repo already calls its PR-CI file) rather than
hand-authoring a new wrapper from scratch — hand-authored wrappers drift (different job names
across repos of the same type, different file names, missing the `actionlint` sibling job,
etc.), which is exactly what this whole repo exists to prevent. As of LAB-2096, every `*-pr.yml`/
`*-main.yml` template `uses:` its type's orchestrator workflow (see "Orchestrator workflows"
above) rather than `develop-*-ci.yml`/`main-*-ci.yml` directly, so a fresh caller repo gets the
correct `permissions:`/`concurrency:` wiring with zero hand-authoring.

| Template | Type | Job name it uses |
|---|---|---|
| `templates/node-pr.yml` / `templates/node-main.yml` | Node/NestJS backend service | `ci` |
| `templates/web-pr.yml` / `templates/web-main.yml` | Next.js/React web | `ci` |
| `templates/python-pr.yml` | Python | `ci` |
| `templates/godot-pr.yml` | Godot 4/GDScript | `godot-ci` |
| `templates/rust-pr.yml` | Rust CLI/tool | `rust-ci` |
| `templates/mobile-pr.yml` | Expo/React Native mobile | `ci` |
| `templates/security.yml` | any (stack-agnostic) | `trivy` |

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
      # enable_design_system: false
```

For a monorepo where the Next.js/yarn app doesn't live at the repo root, set
`working-directory`. For example, `chuunibyou` keeps its app under
`prototype/`:

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
      working-directory: prototype
      pr_number: ${{ github.event.pull_request.number }}
      pr_url: ${{ github.event.pull_request.html_url }}
      is_dependabot: ${{ github.event.pull_request.user.login == 'dependabot[bot]' }}
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

And `dependabot-automerge.yml`:

```yaml
name: Dependabot Auto-merge
on:
  pull_request:
    types: [opened, synchronize, reopened]

jobs:
  automerge:
    uses: PeterChauYEG/labone-actions/.github/workflows/dependabot-automerge.yml@main
    secrets: inherit
```

For a Node/NestJS **backend service** repo, use `develop-node-ci.yml` and
`main-node-ci.yml` instead — same thin-wrapper pattern, no `pr_url`/
`pr_number` (there are no sticky PR comments on this job set):

```yaml
name: Develop CI
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  ci:
    permissions:
      contents: read
      pull-requests: write
    uses: PeterChauYEG/labone-actions/.github/workflows/develop-node-ci.yml@main
    secrets: inherit
    with:
      is_dependabot: ${{ github.event.pull_request.user.login == 'dependabot[bot]' }}
      # Turn off any job your repo doesn't have a yarn script for, e.g.:
      # enable_security_scan: false
```

**The `ci` job's `permissions: {contents: read, pull-requests: write}` block
above is REQUIRED, not optional** — `develop-node-ci.yml`'s `dead-code` job
(and, on the mobile sibling below, `dead-code`/`duplicate-code`/`a11y`/
`design-system`) declares its own job-level `permissions:
pull-requests: write` for its sticky-PR-comment feature, and GitHub
validates a reusable workflow's *entire* permission graph up front, before
dispatching a single job — it can never grant the callee more scope than
the caller's own job holds. A caller `ci` job with no `permissions:`
override (or one that omits `pull-requests: write`) makes the **whole PR
CI run** fail with `startup_failure` and 0 jobs recorded, even if
`enable_dead_code`/`enable_duplicate_code`/`enable_a11y`/
`enable_design_system` are all left off — the permission-graph check
happens before any job's `if:` is evaluated, so the `enable_*` flag never
gets a chance to skip it. See gateway-service PR #164 for the incident
this pattern was found from (7 caller repos hit it independently before
each added this block); if you suspect a caller repo is missing it, check
`gh run list --event pull_request` for `startup_failure` conclusions.

And `main.yml`:

```yaml
name: Main CI
on:
  push:
    branches: [main]
jobs:
  ci:
    uses: PeterChauYEG/labone-actions/.github/workflows/main-node-ci.yml@main
    with:
      is_dependabot: ${{ github.event.head_commit.author.name == 'dependabot[bot]' }}
      dokku_remote_url: ssh://dokku@192.168.1.31:22/<app-name>
    secrets: inherit
```

**Before wiring either of these up, your service's `package.json` MUST**:

- have its `lint` script invoke eslint with `--max-warnings=0` (e.g.
  `"lint": "eslint . --max-warnings=0"`) — the `lint` job here just runs
  `yarn lint` and fails on any non-zero exit, so a `lint` script without
  that flag lets warnings through as a green check. This shared workflow
  cannot enforce the flag on your script's behalf.
- have its own coverage-threshold enforcement configured in whatever
  runs `yarn test:coverage` (jest `coverageThreshold` / vitest
  `coverage.thresholds`) — recommended default: 90% lines/branches. The
  `test` job here is a hard pass/fail gate on the test runner's exit code
  only; it has no visibility into per-service coverage numbers, so a repo
  with no threshold configured gets a green check regardless of coverage.

And `version-bump.yml` (requires the caller repo to have its own
`./scripts/bump-version.sh <new-version>` — that script is repo-specific
(which files carry a version string varies per repo) and is deliberately
not centralized here). Version strings are CalVer: `YY.MMDD-HHMM`, UTC,
zero-padded (e.g. `26.1009-1430`).

**Every repo bumps on every merge to main, except mobile repos, which bump
on a schedule instead** (mobile's build pipeline is expensive enough that
bumping on every merge isn't worth it).

Non-mobile callers (web/API/service/CLI — everything that isn't mobile):

```yaml
name: Version Bump
on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  version-bump:
    uses: PeterChauYEG/labone-actions/.github/workflows/version-bump.yml@main
    secrets: inherit
```

Mobile callers only:

```yaml
name: Version Bump
on:
  schedule:
    - cron: '0 9 * * 1,3,5'
  workflow_dispatch:

jobs:
  version-bump:
    uses: PeterChauYEG/labone-actions/.github/workflows/version-bump.yml@main
    secrets: inherit
```

Pin to a tag/SHA instead of `@main` once this repo starts cutting releases;
`@main` is fine for now while the interface is still settling.

## More documentation

Per-workflow design rationale, caching/concurrency internals, and history
that don't belong in a quick-start README live under `docs/`:

- [`docs/workflows.md`](docs/workflows.md) — full `workflow_call` inputs and
  job lists for every reusable workflow (`develop-ci.yml`, `main-ci.yml`,
  `develop-node-ci.yml`, `main-node-ci.yml`, `ci-failure-monitor.yml`,
  `security-scan.yml`, `actionlint.yml`, `godot-develop-ci.yml`,
  `develop-python-ci.yml`, `develop-rust-ci.yml`, `develop-mobile-ci.yml`,
  `dependabot-automerge.yml`, `version-bump.yml`).
- [`docs/orchestrators.md`](docs/orchestrators.md) — why the orchestrator
  layer (LAB-2096) exists and what it collapses for callers.
- [`docs/caching.md`](docs/caching.md) — the three generations of the
  dependency-install caching strategy, plus the ESLint/TypeScript/Jest/Trivy/
  cargo script caches and the cache-to-main read/write split.
- [`docs/concurrency.md`](docs/concurrency.md) — the three separate
  concurrency mechanisms in play (workflow-level `concurrency:` groups, the
  runner-host job-concurrency semaphore, and `develop-ci.yml`'s `setup` job
  group) and the deadlock they can cause if confused.
- [`docs/reporting.md`](docs/reporting.md) — how the `danger-comment`
  aggregator, `scan-with-report`, `post-danger-comment`, and the tech-debt
  metrics reports work internally.
