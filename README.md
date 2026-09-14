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
| `.github/workflows/develop-ci.yml` | `pull_request` | Full PR-time quality gate set (lint, typecheck, tests, scans) with ONE aggregated sticky PR comment + deduped Linear ticket filing on failure, via the `danger-comment` job — see "Aggregated reporting" below. For yarn/Next.js-ish **web** repos. |
| `.github/workflows/main-ci.yml` | `push` to `main` | Same gate set as plain pass/fail checks (`a11y`/`design-system`/`dead-code`/`duplicate-code`/`react-tech-debt`/`max-lines` are all advisory-only, nextjs-ci v1.0.3 — see below), plus `deploy` (Dokku) and `slack-notification`. For yarn/Next.js-ish **web** repos. |
| `.github/workflows/develop-node-ci.yml` | `pull_request` | PR-time quality gate set (lint, typecheck, test, build, security-scan, dependency-audit) as plain pass/fail checks, optional ls-lint (`enable_ls_lint`), dead-code (`enable_dead_code`, LAB-1866) and duplicate-code (`enable_duplicate_code`), yarn-only, opt-in and advisory-only. `peer-deps`/`security-scan`/`secret-scan`/`dependency-audit`/`dead-code`/`duplicate-code` all feed ONE aggregated sticky PR comment + deduped Linear ticket filing on failure, via the `danger-comment` job. For yarn- or pnpm-based (`package_manager` input, LAB-1268) Node/NestJS **backend service** repos. |
| `.github/workflows/main-node-ci.yml` | `push` to `main` | Same gate set as `develop-node-ci.yml`, plus `deploy` (Dokku) and `slack-notification`. Optional dead-code (`enable_dead_code`, LAB-1866, plain pass/fail, yarn-only) opt-in. For yarn/Node/NestJS **backend service** repos. |
| `.github/workflows/godot-develop-ci.yml` | `pull_request` | format/lint/duplicate-code/test quality gate (gdformat, gdlint, jscpd, GUT) with Linear ticket filing on failure. For Godot 4/GDScript **game** repos. |
| `.github/workflows/main-godot-ci.yml` | `push` to `main` | Same gate set as `godot-develop-ci.yml` (no separate deploy/slack-notification - Godot repos here have no server-side deploy target). For Godot 4/GDScript **game** repos. |
| `.github/workflows/develop-python-ci.yml` | `pull_request` | lint (ruff), test, security-scan, secret-scan, optional dependency-audit (pip-audit) as plain pass/fail checks. `security-scan`/`secret-scan`/`dependency-audit` feed one aggregated sticky PR comment + deduped Linear ticket filing via `danger-comment`. For **Python** repos (data pipelines, MCP servers, ML/robotics scripts). |
| `.github/workflows/main-python-ci.yml` | `push` to `main` | Same gate set as `develop-python-ci.yml`, no path filtering (main-push CI only skips via `is_dependabot`). No deploy job - no single common deploy target for Python repos in this org. For **Python** repos. |
| `.github/workflows/develop-rust-ci.yml` | `pull_request` | fmt/clippy/test/dead-code/duplicate-code/file-size/security-scan/secret-scan/dependency-audit all feed ONE aggregated sticky PR comment + deduped Linear ticket filing via `danger-comment`, optional build. For **Rust CLI/tool** repos. |
| `.github/workflows/main-rust-ci.yml` | `push` to `main` | Same gate set as `develop-rust-ci.yml` as plain pass/fail checks (no path filtering, no sticky-comment/Linear-ticket-filing - no PR to attach those to). No deploy job - no single common deploy target for Rust CLI/tool repos in this org. For **Rust CLI/tool** repos. |
| `.github/workflows/develop-mobile-ci.yml` | `pull_request` | lint/typecheck as plain pass/fail checks, optional ls-lint/test/a11y/design-system/dead-code (knip)/duplicate-code (jscpd)/security-scan/dependency-audit, all feeding ONE aggregated sticky PR comment + deduped Linear ticket filing via `danger-comment`. For **Expo/React Native mobile** repos. |
| `.github/workflows/security-scan.yml` | either | Trivy filesystem vuln/secret scan. |
| `.github/workflows/actionlint.yml` | `pull_request` | Lints the caller's own `.github/workflows/*.yml` with actionlint. Stack-agnostic — any repo with a `.github/workflows/` directory can call it. |
| `.github/workflows/dependabot-automerge.yml` | `pull_request` | Auto-merges dependabot minor/patch PRs. |
| `.github/workflows/version-bump.yml` | `schedule` + `workflow_dispatch` | CalVer version bump: opens+auto-merges a PR and tags a release when there are new commits since the last tag. Requires the caller repo to provide `./scripts/bump-version.sh` (see below). |

## Orchestrator workflows (LAB-2096) — prefer these over calling `develop-*-ci.yml`/`main-*-ci.yml` directly

For each `develop-*-ci.yml`/`main-*-ci.yml` pair that has a PR-time and/or push-to-main
counterpart, this repo also ships a thin, type-specific **orchestrator** `workflow_call`
workflow one level up: `mobile-pr.yml`, `node-pr.yml`, `web-pr.yml`, `python-pr.yml`,
`rust-pr.yml`, `godot-pr.yml`, `node-main.yml`, `web-main.yml`. A consumer repo's own
`develop.yml`/`main.yml` calls the orchestrator, the orchestrator calls the underlying
`develop-*-ci.yml`/`main-*-ci.yml` (GitHub supports up to 4 levels of nested `workflow_call`, so
this 3-level chain — caller repo → orchestrator → develop-/main-*-ci.yml — is safely within
budget).

The orchestrator bakes in every piece of boilerplate every caller of a given type repeats today:
computing `pr_number`/`pr_url`/`is_dependabot` from `github.event` (still available transitively
through the whole call chain, since the outermost trigger — the calling repo's own
`develop.yml`/`main.yml` — is still `pull_request`/`push`), the `if: github.event.action !=
'closed'` guard, the per-PR `concurrency:` group, the `actionlint` sibling job, and — most
importantly — the exact `permissions:` block the underlying workflow's own jobs need for their
sticky-PR-comment/Linear-ticket-filing features (`pull-requests: write`, sometimes `id-token:
write`). Getting that grant wrong or omitting it entirely doesn't just disable the affected
job — it fails the caller's **entire** CI run with `startup_failure` and 0 jobs recorded, because
GitHub validates a reusable workflow's whole callee permission graph before dispatching a single
job, regardless of which `enable_*` flags are set. That's exactly the failure mode that hit 7
caller repos independently before `develop-node-ci.yml`'s caller contract got documented (see
gateway-service PR #164) — and `templates/web-pr.yml` shipped with no `permissions:` block at
all for years before this orchestrator layer existed. Baking the grant into one file that every
caller of that type shares means it can't drift or get silently dropped per-repo again.

**Prefer the type-specific orchestrator** (`templates/mobile-pr.yml`, `templates/node-pr.yml`,
etc. now point at it) over calling `develop-*-ci.yml`/`main-*-ci.yml` directly — a caller repo's
own workflow file becomes a near-empty `uses:` block, most repos need zero `with:` keys, and it
stays in sync automatically as the orchestrator's own definition evolves. Call the underlying
`develop-*-ci.yml`/`main-*-ci.yml` directly only if a repo's needs are too unusual to fit the
orchestrator's input surface (e.g. a bespoke input the orchestrator doesn't pass through) —
in that case, copy that repo's own `permissions:`/`concurrency:`/`pr_number`/`pr_url`/
`is_dependabot` wiring from the orchestrator's source as a reference rather than
hand-rolling it from scratch.

One genuinely repo-specific case the orchestrator can't fully collapse: a caller whose own
`main.yml` pre-creates check-runs for its own CalVer version-bump PR (opened by
`github-actions[bot]`, see `version-bump.yml` below) wants those version-bump PRs treated like a
dependabot PR too. Rather than baking that org-wide (most repos don't have this), every
orchestrator exposes it as an opt-in boolean input, `also_treat_actions_bot_as_dependabot`
(default `false`), that ORs into the computed `is_dependabot` expression.

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

Each `*-pr.yml` template already includes the `actionlint` sibling job — a fresh repo (or a
repo migrating for the first time) gets workflow-YAML linting for free, no separate follow-up
needed. Uncomment/adjust the `enable_*`/other inputs shown as comments in the template to match
what the specific repo actually has (test suite, dependency-audit compatibility, a
`postinstall` codegen step that needs `extra_deps_paths`, etc.) — read the relevant reusable
workflow's own section further down this README for the full input reference before changing
defaults blindly.

Repo-specific bespoke jobs (`ls-lint`, `dead-code`, `duplicate-code`, a project-specific smoke
test, etc.) have no shared-workflow equivalent and are NOT part of any template — add them as
additional sibling jobs in the same file, same as every already-migrated repo does today.

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
not centralized here):

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

### `develop-ci.yml` — inputs and jobs

Inputs (all `workflow_call` inputs, `enable_*` default `true`):

- `working-directory` (string, default `.`) — directory (relative to the
  repo root) the Next.js/yarn app lives in. Defaults to the repo root so
  every existing caller keeps working with zero changes; set it for a
  monorepo caller, e.g. `working-directory: prototype`. Threaded through to
  `setup-node-yarn` (install, Node version detection, yarn cache path,
  lockfile hash key, `node_modules` cache location), every
  `yarn <script>` step (via the step's `working-directory:` property), and
  `scan-with-report` (script working directory + report-file path prefix).
- `pr_number` (number) — for concurrency grouping + Linear ticket linking.
- `pr_url` (string) — for Linear ticket linking.
- `pr_base_sha` (string, default `''`) — `github.event.pull_request.base.sha`.
  Only used by `tech-debt` (when `enable_tech_debt` is true) to compute a
  delta vs. the PR's base branch; harmless to leave unset otherwise.
- `is_dependabot` (boolean) — caller-computed; skips every job below
  `lint`/`typecheck`/`build`.
- `enable_ls_lint`, `enable_build`, `enable_test`,
  `enable_design_system`, `enable_dead_code`, `enable_duplicate_code`,
  `enable_react_tech_debt`, `enable_max_lines` (boolean,
  default `true`) — turn a job off if your repo has no matching yarn
  script.
- `enable_tech_debt` (boolean, default **`false`**) — run the grep-based
  tech-debt metrics report and post it as a sticky PR comment. Opt-in,
  unlike every other `enable_*` above — see "Tech debt metrics report"
  below.
- `extra_deps_paths` (string, default `''`) — space-separated list of
  additional paths (relative to `working-directory`) folded into the
  `node_modules` cache entry every job restores, beyond
  `node_modules`/`.next/cache`. Needed if your repo has a `postinstall`
  script that writes gitignored generated code outside `node_modules` (e.g.
  an SDK codegen step writing to `src/generated/`) — without this, that
  directory isn't part of what gets cached/restored and every job fails
  with "Cannot find module". E.g. `extra_deps_paths: 'src/generated'`.

No `secrets:` are declared on these `workflow_call` inputs — every caller
uses `secrets: inherit`, so the reusable workflow reads whatever secrets
the caller has directly. One such secret with special meaning: if a repo
has a `LAB_GIT_DEPS_SSH_KEY` secret set (an SSH deploy key with read access
to a private git-dependency package, e.g.
`"eslint-plugin-lab-react-standards": "github:PeterChauYEG/eslint-plugin-lab-react-standards#main"`
in `package.json`), `setup-node-yarn` loads it into an `ssh-agent` before
`yarn install`. Repos without that secret get empty string, which skips
this step entirely — zero-diff for every repo with no private git
dependencies.

Jobs: `setup`, `lint`, `ls-lint`, `typecheck`, `build`, `test`,
`peer-deps`, `security-scan`, `secret-scan`,
`design-system`, `dead-code`, `duplicate-code`,
`react-tech-debt`, `max-lines`, `tech-debt` (opt-in,
see "Tech debt metrics report" below), and `danger-comment`. All nine
reporting jobs (`peer-deps`, `security-scan`, `secret-scan`,
`design-system`, `dead-code`, `duplicate-code`, `react-tech-debt`,
`max-lines`, `tech-debt`) feed `danger-comment`, which posts ONE combined
sticky PR comment and files/comments-on a Linear ticket (via
`scripts/file-linear-ticket.sh`) for whichever of them failed — see
"Aggregated reporting" below. Internally, each of the five scan jobs
(`design-system`, `dead-code`, `duplicate-code`, `react-tech-debt`,
`max-lines`) is just a `setup-node-yarn` call followed by one call to the
`.github/actions/scan-with-report` composite action — see "Scan job
dedup" below.

**`a11y`/`run-e2e-tests` removed (fleet-wide Playwright/Chromium/a11y/e2e
removal):** both jobs, their `enable_a11y`/`enable_e2e` inputs, and the
Chromium install step + `playwright` input in
`.github/actions/scan-with-report` were removed - a repo-owner decision to
drop Playwright/Chromium-based CI fleet-wide, companion to per-repo test
removal and the shared runner image dropping the Chromium apt packages.

**Blocking vs advisory (nextjs-ci v1.0.3, 2026-08-20):** `design-system`,
`dead-code`, `duplicate-code`, `react-tech-debt`,
and `max-lines` are all advisory (`scan-with-report`'s `blocking: 'false'`
input) — they still run and still expose their `outcome`/`report` to
`danger-comment`, but a finding never fails the job itself (nextjs-ci
v1.0.2, 2026-08-20, PR #68 covered `duplicate-code`/`max-lines` in
`main-ci.yml`'s equivalent pass/fail-to-advisory move — same rationale
applies here: all of these are repo-wide scans that can trip on a
pre-existing finding unrelated to the PR's own diff, which is too brittle
to gate a merge/deploy on). `peer-deps` is advisory the same way (its
checks are `continue-on-error: true`, unrelated to `scan-with-report`).
See `main-ci.yml`'s equivalent note below for the push-to-main side of this
same change.

**`required-checks` (LAB-2103):** a final aggregator job that `needs:` every
REAL (blocking) gate job above - `lint`, `ls-lint`, `typecheck`, `build`,
`test`, `security-scan`, `secret-scan` - and fails if any of them resolves
to `failure` or `cancelled` (`if: always()`, so it still runs and reports
even when an upstream gate didn't). The explicitly-advisory scan jobs
(`peer-deps`, `design-system`, `dead-code`, `duplicate-code`,
`react-tech-debt`, `max-lines`), the opt-in `tech-debt` metrics report, and
`danger-comment` itself are deliberately **not** dependencies - see the
job's own comment in the workflow file.
**Caller repos' branch protection should require ONLY this one context
(`required-checks`) going forward, not the individual per-job contexts** -
that's what prevents required-check drift when a job inside this shared
workflow is renamed/added/removed, which previously desynced every caller's
branch protection silently (no visible error - just permanently blocked
merges). This PR does **not** change branch protection on any caller repo
itself - that's a separate follow-up once this merges (the
`required-checks` context doesn't exist until then, so requiring it now
would immediately and permanently block every caller).

### `main-ci.yml` — inputs and jobs

Same `working-directory`/`enable_*`/`is_dependabot` inputs as
`develop-ci.yml` (no `pr_number`/`pr_url` — there's no PR at push-to-main
time), plus:

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

**`a11y`/`design-system`/`dead-code`/`duplicate-code`/`react-tech-debt`/
`max-lines` are advisory, not pass/fail (nextjs-ci v1.0.3, 2026-08-20):**
unlike the other gate jobs here, their `run: yarn <script>` steps all set
`continue-on-error: true`, so a finding never fails the job (and therefore
never blocks `deploy` via the `needs.*.result` check) — the step still
runs and still exits non-zero internally on a finding, only the workflow's
treatment of that exit code changed. This is push-to-main, so there's no
PR to post a sticky comment on; check the job's own log for output.
`duplicate-code`/`max-lines` got this treatment first (nextjs-ci v1.0.2,
2026-08-20, PR #68) — confirmed root cause of a stalled ai-harness-web
deploy on 2026-08-20, where an unrelated PR merged fine but push-to-main
deploy silently never ran because `duplicate-code` failed on a
pre-existing repo-wide jscpd finding unrelated to that PR's diff. `a11y`,
`design-system`, `dead-code`, and `react-tech-debt` followed the same
pattern in this v1.0.3 pass, for the same reason. `typecheck`, `build`,
`lint`, `test`, `run-e2e-tests`, and `ls-lint` are unchanged and still
block `deploy` on failure.

**`required-checks` (LAB-2103):** same aggregator pattern as
`develop-ci.yml`'s job (see that section for the full rationale), scoped to
this file's actual job list - `needs: [lint, typecheck, build, test,
run-e2e-tests]` (no `ls-lint` job exists here). `a11y`/`design-system`/
`duplicate-code`/`react-tech-debt`/`max-lines` are excluded (their
`continue-on-error: true` steps already keep them out of the failure path -
see above), as are `deploy`/`slack-notification` (redundant with `deploy`'s
own `needs.*.result` check). Since this workflow only runs on `push` to
`main`, not `pull_request`, branch protection's required-status-checks
mechanism never actually gates it - this job exists here for parity with
`develop-ci.yml` and as a single visible pass/fail signal on the run
summary, not because any caller repo's branch protection currently (or
will) point at it.

**These names are load-bearing**: a follow-on task migrates
`laboratory-one-web` to call these exact workflows, so treat the
`workflow_call` input names and job names above as a stable interface —
don't rename them without also updating every caller.

### `develop-node-ci.yml` — inputs and jobs

Backend-service (Node/NestJS) sibling of `develop-ci.yml`. Inputs (all
`workflow_call` inputs, `enable_*` default `true`):

- `working-directory` (string, default `.`) — same role as in
  `develop-ci.yml`, threaded through to `setup-node-yarn`/`setup-node-pnpm`
  and every `<package manager> <script>` step.
- `package_manager` (string, default `'yarn'`) — `'yarn'` or `'pnpm'`
  (LAB-1268). Selects `setup-node-yarn` vs. `setup-node-pnpm` in the
  `setup` job and every downstream job (via `cached-script`'s own
  `package-manager` input), and is substituted directly as the CLI command
  in every `lint`/`typecheck`/`build`/`test` step (e.g. `${{
  inputs.package_manager }} lint`) since both CLIs accept the same
  script-invocation syntax. `dependency-audit` is the one exception —
  yarn's vuln-audit subcommand is `yarn npm audit` (not `yarn audit`, per
  the Yarn Berry note below), so that job branches on two separate `if:`
  steps instead. A pnpm caller's `package.json` needs `pnpm-lock.yaml`
  present (used as the cache/tsbuildinfo/eslintcache key input) the same
  way a yarn caller needs `yarn.lock`.
- `is_dependabot` (boolean) — caller-computed from
  `github.event.pull_request.user.login`. Skips `test`, `security-scan`
  and `dependency-audit` (`lint`/`typecheck`/`build` stay on).
- `enable_build`, `enable_test`, `enable_security_scan`,
  `enable_dependency_audit` (boolean) — turn a job off if your repo has no
  matching yarn script.
- `enable_ls_lint` (boolean, default **`false`** — opt-in, unlike
  `develop-ci.yml`'s identical input, which defaults `true`) — runs the
  `ls-lint` job (`yarn lint:ls`), gated on the `changes` job's `ls_lint`
  output. Brand-new capability for backend repos with no existing caller
  migrated to it yet, so each repo opts in explicitly as it migrates —
  same rationale as `enable_dead_code` below.
- `enable_dead_code` (boolean, default **`false`** — opt-in, unlike the
  `enable_*` inputs above, LAB-1866) — runs `yarn dead-code` via the shared
  `scan-with-report` composite action (same one `develop-ci.yml`'s
  `dead-code` job uses), exposing its `outcome`/`report` to the
  `danger-comment` aggregator job (see "Aggregated reporting" above), but
  `blocking: 'false'` so it never fails the job itself. `scan-with-report`
  always runs `yarn <script>` regardless of `package_manager`, so this only
  works for `package_manager: yarn` callers — a `pnpm` caller enabling it
  would fail. `pr_number`/`pr_url` (below) feed `danger-comment`'s Linear
  ticket link.
- `enable_duplicate_code` (boolean, default **`false`**, same opt-in
  rationale as `enable_dead_code`) — runs `yarn duplicate-code` via the
  same `scan-with-report` composite action, same `danger-comment`/
  `blocking: 'false'`/yarn-only behavior as `enable_dead_code`.
  Mirrors `develop-ci.yml`'s `duplicate-code` job.
- `pr_number` (number, default `0`) / `pr_url` (string, default `''`) —
  same role as `develop-ci.yml`'s identical inputs; consumed by the
  `danger-comment` job for its Linear ticket links.
- `security_scan_trivyignores` (string, default `''`) — passed straight
  through to the `security-scan` job's `trivy-action` call. Empty by
  default: this shared workflow ships **no default `.trivyignore`
  baseline** — any suppression must be a deliberate, visible ignore file
  living in the consumer repo, referenced here explicitly.
- `extra_deps_paths` (string, default `''`) — same role as in
  `develop-ci.yml`.

No `secrets:` are declared here either — every caller uses
`secrets: inherit`, same `LAB_GIT_DEPS_SSH_KEY` convention as
`develop-ci.yml` above (a sibling ticket adds a `lab-nest-standards` rule
set to the same `labone-eslint-plugin` package for backend services,
consumed the same way via a private git dependency).

Jobs: `changes`, `setup`, `lint`, `typecheck`, `build`, `test`,
`peer-deps`, `security-scan`, `secret-scan`, `dependency-audit`,
`danger-comment`, plus optional `ls-lint` (`enable_ls_lint`, off by
default), `dead-code` (`enable_dead_code`, off by default) and
`duplicate-code` (`enable_duplicate_code`, off by default). `peer-deps`,
`security-scan`, `secret-scan`, `dependency-audit`, `dead-code`, and
`duplicate-code` all feed `danger-comment`, which posts ONE combined sticky
PR comment and files/comments-on a Linear ticket (via
`scripts/file-linear-ticket.sh`) for whichever of them failed — see
"Aggregated reporting" above. `security-scan`/`secret-scan`/
`dependency-audit` are still HARD gates (a finding still fails the job, via
an explicit final `exit 1` step); `peer-deps`/`dead-code`/`duplicate-code`
stay advisory-only, same as before — a finding is surfaced in the comment/
ticket but never fails the job. Two gates are worth calling out explicitly
because this shared workflow can't fully enforce them on its own:

- **`changes` (LAB-2097)** runs `dorny/paths-filter@v3` against the caller
  repo's changed files first (no dependencies, overlaps with `setup`) and
  produces a `node` output. `lint`/`typecheck`/`build`/`test` each AND
  `needs.changes.outputs.node == 'true'` onto their existing `if:`
  condition, so a PR that only touches docs/unrelated files skips all four
  as `skipped` (which satisfies branch-protection required checks
  identically to `success`) instead of re-running them for nothing. A
  `ls_lint` output is also produced, gating the optional `ls-lint` job
  (`enable_ls_lint`) below — `main-node-ci.yml` still doesn't run an
  `ls-lint` job. `security-scan`/`dependency-audit`/`dead-code`/
  `duplicate-code` are intentionally NOT gated by `changes` (out of scope
  for LAB-2097). The `node`/`ls_lint`
  filter glob lists were derived from what `lint`/`typecheck`/`build`/
  `test`'s own steps consume (TS/JS source, `package.json`,
  `yarn.lock`/`pnpm-lock.yaml`, `tsconfig*.json`, eslint/jest/vitest
  config) but are **not confirmed exhaustive** for every caller — a repo
  whose custom script depends on an unusual extra file (surfaced via
  `extra_deps_cache_key_glob_1`/`_2`, which are caller-specific and can't
  be folded into this static filter) could still see a stale skip. Report
  a miss if you hit one.

- **`lint` is zero-tolerance**, but only if the caller's own `lint` script
  passes `--max-warnings=0` to eslint (e.g. `"lint": "eslint .
  --max-warnings=0"`). This workflow just runs `yarn lint` and fails on
  any non-zero exit — a caller whose script omits that flag gets a green
  check with warnings still present.
- **`test` runs `yarn test:coverage` as a hard gate**, but coverage
  *threshold* enforcement is entirely the caller's responsibility (jest
  `coverageThreshold` / vitest `coverage.thresholds`, recommended default
  90% lines/branches) — this workflow has no visibility into per-service
  coverage config and only sees the test runner's exit code.

`security-scan` restores deps, then runs the same Trivy invocation as
`security-scan.yml`'s own `trivy` job (`severity: HIGH,CRITICAL`,
`exit-code: '1'`), against the working directory. `dependency-audit` runs
`yarn npm audit` (`package_manager: yarn` callers — this repo and its
yarn-based Node/NestJS callers are on Yarn Berry) or `pnpm audit`
(`package_manager: pnpm` callers) as a hard gate with no severity floor —
any known vulnerability fails the job.

**`required-checks` (LAB-2103):** a final aggregator job that `needs:`
every REAL (blocking) gate job above - `lint`, `ls-lint`, `typecheck`,
`build`, `test`, `security-scan`, `secret-scan`, `dependency-audit`,
`actionlint` - and fails (`exit 1`) if any of them resolves to `failure` or
`cancelled` (`if: always()`, so it still runs even when an upstream gate
didn't). `changes`/`setup` (infra, not gates), the advisory-only
`peer-deps`/`dead-code`/`duplicate-code` jobs (`blocking: 'false'`/
`continue-on-error: true`), and `danger-comment` itself are deliberately
**not** dependencies - see the job's own comment in the workflow file.
**Caller repos' branch protection should require ONLY this
one context (`required-checks`) going forward, not the individual per-job
contexts** - that's what prevents required-check drift when a job inside
this shared workflow is renamed/added/removed, which previously desynced
every caller's branch protection silently (no visible error - just
permanently blocked merges). This PR does **not** change branch protection
on any caller repo itself - that's a separate follow-up once this merges
(the `required-checks` context doesn't exist until then, so requiring it
now would immediately and permanently block every caller).

For a pnpm-based backend service (e.g. a repo with `packageManager:
pnpm@...`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`), just add
`package_manager: pnpm` to the caller snippet above:

```yaml
  ci:
    uses: PeterChauYEG/labone-actions/.github/workflows/develop-node-ci.yml@main
    secrets: inherit
    with:
      package_manager: pnpm
      is_dependabot: ${{ github.event.pull_request.user.login == 'dependabot[bot]' }}
```

### `main-node-ci.yml` — inputs and jobs

Same `working-directory`/`enable_*`/`is_dependabot`/
`security_scan_trivyignores` inputs as `develop-node-ci.yml`
(`is_dependabot` here is caller-computed from
`github.event.head_commit.author.name` instead — there's no PR at
push-to-main time), plus:

- `enable_deploy` (boolean, default `true`)
- `dokku_remote_url` (string) — required if `enable_deploy` is true.
- `enable_slack_notification` (boolean, default `true`)

This workflow also has `enable_dead_code` (boolean, default **`false`**,
LAB-1866), but unlike `develop-node-ci.yml`'s version it's a plain
pass/fail gate — no sticky comment/Linear ticket filing, no `pr_number`/
`pr_url` inputs, since there's no PR to comment on at push-to-main time
(matching `main-ci.yml`'s `dead-code` job, which runs `yarn dead-code`
directly instead of going through `scan-with-report`). Yarn-only, same
caveat as `develop-node-ci.yml`'s `enable_dead_code`.

Jobs: `changes` (LAB-2097, same `dorny/paths-filter@v3` pattern as
`develop-node-ci.yml`'s `changes` job — see that section for the full
`node`/`ls_lint` filter rationale and its "not confirmed exhaustive"
caveat; this one diffs against `github.event.before` since this workflow
triggers on `push`, not `pull_request`, so it needs `contents: read` only,
no `pull-requests: read`), then `setup`/`lint`/`typecheck`/`build`/`test`
as plain pass/fail gates (`lint`/`typecheck`/`build`/`test` additionally
gated on `needs.changes.outputs.node == 'true'`), plus optional
`dead-code` (off by default) and `deploy` (pushes to `dokku_remote_url`
using secret `DOKKU_DEPLOY_SSH_KEY`) and `slack-notification` (posts the
deploy result using secret `SLACK_WEBHOOK_URL`), identical semantics to
`main-ci.yml`'s `deploy`/`slack-notification` — `deploy` runs only if
every enabled gate job actually passed (skipped-via-`enable_*: false` or
skipped-via-`changes` doesn't block it, but any real failure or
cancellation does) and is skipped entirely for `is_dependabot`. Note:
unlike `main-ci.yml`'s `deploy` job (whose `needs:` list includes
`dead-code`), this workflow's `deploy` job's `needs:` list was
deliberately left unchanged (LAB-1866 scope) — `dead-code` is not a
dependency of `deploy` here, so a caller that enables it should be aware
`deploy` doesn't wait on it.

**`required-checks` (LAB-2103):** same aggregator pattern as
`develop-node-ci.yml`'s job (see that section for the full rationale),
scoped to this file's actual job list - `needs: [lint, typecheck, build,
test]` (this file has no `security-scan`/`dependency-audit` jobs at all,
unlike `develop-node-ci.yml`, so there's nothing advisory to exclude
besides `changes`/`setup`). `deploy`/`slack-notification` are also
excluded - `deploy` already has its own well-established
`needs.*.result` failure/cancelled check (see that job's own comment
above), so folding it into `required-checks` too would be redundant.
Since this workflow only runs on `push` to `main`, not `pull_request`,
branch protection's required-status-checks mechanism never actually gates
it - this job exists here for parity with `develop-node-ci.yml` and as a
single visible pass/fail signal on the run summary, not because any caller
repo's branch protection currently (or will) point at it.

## Caching strategy

This section describes `setup-node-yarn`; `setup-node-pnpm` (LAB-1268,
`develop-node-ci.yml`'s `package_manager: pnpm` variant) mirrors the same
strategy one-for-one — a pnpm content-addressable store in place of Yarn's
package-download cache, `pnpm-lock.yaml` in place of `yarn.lock`.

Every job used to do its own checkout + `setup-node` + cache-restore +
full `yarn install --frozen-lockfile` — up to ~12 redundant installs per PR
across the full job set. This repo's workflows fixed that in three
generations; the first two are historical context, generation 3 is current:

**Generation 1 (superseded): shared `setup` job + artifact.** A single
`setup` job installed once and uploaded `node_modules` as a
`deps-${{ github.run_id }}` build artifact; every other job downloaded it.
Every run *and* every job in it created its own fresh artifact regardless
of whether `yarn.lock` had actually changed — artifacts aren't deduped or
LRU-evicted, so this repeatedly blew the account-wide Actions artifact
storage quota (LAB-1371).

**Generation 2 (superseded): `actions/cache`, keyed on the lockfile and the
job.** Fixed the storage-quota blowup, but every job still paid a network
round-trip to GitHub's cache service to restore its own job-scoped
`node_modules` entry — even on a hit, and even though every job installing
from the same lockfile was restoring an *identical* tree under a different
key (`os-node-modules-lint-<hash>` vs. `os-node-modules-test-<hash>`, ...).
On a genuine miss, every job that needed deps ran its own full
`yarn install --frozen-lockfile` independently.

**Generation 3 (current): host-local, content-addressed by lockfile hash,
shared by every job.** These are self-hosted, ephemeral-per-job Docker
containers (gha-runner-docker's `dispatch-one.sh`), not GitHub-hosted
runners — so unlike generation 2, there's a real host filesystem underneath
that persists across containers, the same one already used for sccache's
compiler-object cache. `dispatch-one.sh` bind-mounts a persistent per-repo
directory at `/root/.cache/dep-cache-main`; `setup-node-yarn`/
`setup-node-pnpm` content-address `node_modules` (+ `.next/cache` + any
`extra-paths`) by a hash of `yarn.lock`/`pnpm-lock.yaml` (+ any
`extra-cache-key-glob-*`) into an immutable `bundle-<hash>/` directory
under that mount — one bundle per distinct hash ever seen, shared by
*every* job (lint, typecheck, build, test, ...) that needs the same
resolved tree, not one copy per job the way generations 1–2 both were.

`node_modules` isn't content-addressed the way sccache's compiler-object
cache is — it's a full resolved tree tied to exactly one lockfile, not a
pile of independently-cacheable objects — so this doesn't reuse sccache's
own main/scratch-copy split. Instead:

- **`cache-write: 'true'`** (`main-ci.yml`/`main-node-ci.yml`'s `setup` job
  only) is the only path that ever writes: if `bundle-<hash>/` doesn't
  exist yet, it installs into a private scratch dir first, then claims the
  final `bundle-<hash>/` name (an `mv`, only if nothing else already
  claimed it — see the action's own script for the race between two main
  runs computing an identical hash at once) and marks it `.complete`.
- **`cache-write: 'false'`** (every other job, on every workflow —
  `develop-*-ci.yml` and `develop-mobile-ci.yml` alike, the latter having
  no push-to-main trigger to gate on at all) **only ever reads**: if a
  matching `bundle-<hash>/` already exists, it symlinks `node_modules`
  straight to it and never runs an install. If not — this job's lockfile
  actually differs from whatever's on `main` — it falls back to a fully
  local, unshared `yarn install --frozen-lockfile`, exactly like
  generation 2's miss path. Nothing is ever written to the shared mount by
  a non-cache-write job, under any circumstances, even into a uniquely-
  hashed slot nothing else would ever read — a deliberate choice, not
  just a simplicity shortcut.

Because a `bundle-<hash>/` is immutable once `.complete` exists, any number
of concurrent PR-job readers are safe — there's nothing to race with.

Yarn's own package-download cache (`.yarn/cache`) — and pnpm's content-
addressable store — are a separate, simpler tier under the same mount:
genuinely content-addressed by package name+version+hash, so a new tarball
written by any branch can never invalidate or corrupt what another branch
reads. That tier is shared read+write by *every* job, `cache-write` or not,
with no isolation needed at all.

**Pruning.** Nothing here is per-branch/commit (only a `cache-write: true`
run ever creates a new bundle, and only when its hash is genuinely new), so
this doesn't grow the way a naive per-branch cache would — but a repo's
dependency tree still drifts over time, and an old hash is dead weight once
superseded. `gha-cleanup-daily.sh` (gha-runner-docker, already
cron-scheduled on the runner host) removes any `bundle-*/` whose
`.last-used` marker (touched on every read *and* write) is older than 7
days.

If a repo ever needs a job that's genuinely independent of `setup` (rare —
none of the current jobs are), it's fine for that job to opt out of
`needs: setup` and call `setup-node-yarn`/`setup-node-pnpm` directly; they
don't assume `setup` is the only way to get dependencies in place.

### Install-time memory pressure (`YARN_NETWORK_CONCURRENCY`)

The `node_modules` cache above only helps when it hits — a `yarn.lock`
change (common on an active PR) still forces a real `yarn install
--frozen-lockfile`. Yarn Berry's default `networkConcurrency` (8) opens
that many parallel fetch/extract workers at once, each holding its own
decompression buffers in memory — the single biggest driver of that
install's peak RSS. `setup-node-yarn`'s install step caps this to 4 via
`YARN_NETWORK_CONCURRENCY`, trading a bit of wall-clock for lower peak
memory per install (LAB-1301: this is what was OOM-killing budget's `setup`
job under concurrent PR load — see "Concurrency" point 3 below for the
complementary queueing fix).

### ESLint (`.eslintcache`) and TypeScript (`tsconfig.tsbuildinfo`) caches

`develop-ci.yml`/`main-ci.yml`, `develop-node-ci.yml`/`main-node-ci.yml`,
and `develop-mobile-ci.yml` each cache their `lint` job's `.eslintcache`
and `typecheck` job's `tsconfig.tsbuildinfo`, keyed on `yarn.lock` (plus
any `.eslintrc*`/`eslint.config.*` file for the ESLint cache, or any
`tsconfig*.json` for the TS one — so a config edit alone still busts the
cache even with an unchanged lockfile). `--cache --cache-location
.eslintcache` and `--incremental --tsBuildInfoFile tsconfig.tsbuildinfo`
are passed straight through to the caller's own `lint`/`typecheck` scripts
(Yarn forwards extra CLI args to the underlying command) — this assumes
those scripts ultimately invoke `eslint`/`tsc`, true for every existing
caller.

### Jest (`.jestcache`) cache (LAB-1333)

Same pattern as the ESLint/TypeScript caches above: `develop-ci.yml`/
`main-ci.yml`, `develop-node-ci.yml`/`main-node-ci.yml`, and
`develop-mobile-ci.yml` each cache their `test` job's Jest transform cache
at `.jestcache`, keyed on `yarn.lock`/`pnpm-lock.yaml` plus any
`jest.config.*` file. `--cache --cacheDirectory .jestcache` is passed
straight through to the caller's own `test:coverage` script the same way
as the lint/typecheck flags — this assumes that script ultimately invokes
`jest` (directly or via `react-scripts`/`next test`-style wrappers that
forward unknown flags to Jest), true for every existing caller. Before this,
`test:coverage` ran with Jest's default cache directory (an ephemeral OS
temp dir, per-runner and never persisted via `actions/cache`), so every run
paid a cold-cache transform cost that `lint`/`typecheck` had already been
spared.

`main-node-ci.yml`'s `test` job exposes this as the `test_script_args`
input (default `--cache --cacheDirectory .jestcache`, identical to the
prior hardcoded behavior) so a caller whose `test:coverage` script isn't
Jest-based (e.g. Vitest, which doesn't recognize `--cache`/
`--cacheDirectory` and exits with `CACError: Unknown option
--cacheDirectory`) can override it — typically to `''` — instead of the
job failing outright.

### Trivy DB cache

`security-scan.yml`'s `trivy` job caches Trivy's vulnerability DB
(`.cache/trivy`, trivy-action's default `cache-dir`) keyed on the current
UTC date (`trivy-db-YYYY-MM-DD`, `restore-keys: trivy-db-` falling back to
the nearest older day) since the DB updates roughly daily. trivy-action
ships its own built-in DB caching, but it always restores *and* saves on
every run with no read-only mode — exactly the churn the `cache-write`
split below exists to avoid — so it's disabled here (`cache: false`) in
favor of explicit `actions/cache`/`actions/cache/restore` steps pointed at
the same cache dir.

### Cargo cache scoping (`develop-rust-ci.yml`)

`develop-rust-ci.yml` has no shared `setup` job (see that workflow's own
README section), so its `fmt`, `clippy`, `test`, `build`, `dead-code`,
`duplicate-code`, and `dependency-audit` jobs each call `setup-rust` with
their own `cache-key-prefix` (`fmt`, `clippy`, `test`, `build`, ...),
giving each job its own `${{ runner.os }}-cargo-<prefix>-${{
hashFiles('Cargo.lock') }}` `actions/cache` entry — `cargo-fmt-`,
`cargo-clippy-`, `cargo-test-`, `cargo-build-`, etc. — instead of one entry
shared across every job. Unlike `setup-node-yarn`/`setup-node-pnpm`'s
generation-3 host-cache (above), `setup-rust` hasn't been migrated off
`actions/cache` yet — a natural next candidate, since `~/.cargo/registry`/
`~/.cargo/git` are genuinely content-addressed the same way Yarn's package
cache is (crate name+version+hash), so they wouldn't even need the
lockfile-hash-bundle treatment `node_modules` needed. `target/` itself
would still need to stay out of any such migration — concurrent writers to
one `target/` dir isn't safe, which is exactly the problem sccache (already
host-cached, see its own section above) exists to solve instead.

### Cache-to-main: read/write split

Software caches change infrequently — there's no need for every PR run to
write its own copy. `setup-node-yarn`/`setup-node-pnpm`, `security-scan.yml`,
and the `lint`/`typecheck`/`test` script-cache steps (via `cached-script`)
all take a `cache-write` input (`'false'`/`false` by default — read-only).
For `setup-node-yarn`/`setup-node-pnpm` specifically this is now the
write-vs-read-only-with-local-fallback contract described above (generation
3), not an `actions/cache` restore-vs-restore+save split; for everything
else still on `actions/cache` (`.eslintcache`/`tsconfig.tsbuildinfo`/
`.jestcache`, Trivy DB, cargo) it's still the original restore-vs-
restore+save behavior. GitHub Actions cache scoping already lets a PR
branch read its base/default branch's cache via an exact key match or
`restore-keys`, so the `actions/cache`-based tiers work naturally without
any extra plumbing — a PR run just reads whatever `main` last wrote.

Only the push-to-main workflows write:

- `main-ci.yml`/`main-node-ci.yml` pass `cache-write: 'true'` to
  `setup-node-yarn` and use the full `actions/cache` action for their own
  `.eslintcache`/`tsconfig.tsbuildinfo` steps. `develop-ci.yml`/
  `develop-node-ci.yml` pass `'false'`/use `actions/cache/restore`.
- `security.yml` (this repo's own `security-scan.yml` caller) passes
  `cache-write: ${{ github.event_name == 'push' }}` — true only for its
  push-to-main trigger, false for its `pull_request`/`schedule` triggers.
- `develop-mobile-ci.yml` has **no** `main-*-ci.yml` counterpart in this
  repo, so its `.eslintcache`/`tsconfig.tsbuildinfo`/`.jestcache` script
  caches (still `actions/cache`, safely branch-scoped by GitHub itself)
  stay a plain restore+save via `cache-write: 'true'`, same as before —
  but its `deps-cache-write` (the generation-3 host-cache tier) is always
  explicitly `'false'`: that tier has no per-branch GitHub-side scoping to
  fall back on (it's one shared directory per repo, not a
  GitHub-cache-service entry), so with no push-to-main trigger to gate a
  write on at all, every mobile job only ever reads or falls back to a
  fully local install — never writes into the shared store. See
  `cached-script`'s `deps-cache-write` input and the generation-3
  description above.
- `develop-rust-ci.yml`'s per-job cargo caches (above) are exempt from the
  explicit `cache-write` gate — `setup-rust` has no such input; its
  `actions/cache` step always restores+saves. This still fits the overall
  policy: a PR-branch job's own save is scoped to that PR branch
  (`actions/cache`'s default per-`github.ref` save behavior), never
  overwriting/clobbering `main`'s entry, and a PR job with no branch-scoped
  entry yet still restore-falls-back to whatever `main`'s same-job-scoped
  entry last wrote.

Rationale: avoids cache-storage churn/eviction from every PR branch
writing its own short-lived copy of a cache that's about to be discarded
when the branch merges or closes, while still giving PR runs a warm cache
(populated only by `main`) instead of a cold one.

### Scheduled cache GC (`cache-gc.yml`)

Covers every `actions/cache`-based tier (`.eslintcache`/`tsconfig.
tsbuildinfo`/`.jestcache`, Trivy DB, cargo) — NOT `setup-node-yarn`/
`setup-node-pnpm`'s generation-3 host cache, which was deliberately moved
off `actions/cache` entirely and is pruned separately by
`gha-cleanup-daily.sh` on the runner host instead (see the caching
strategy section above).

PR-branch cache entries (see the read/write split above) are still real
`actions/cache` writes — GitHub only auto-evicts a cache after **7 days**
idle or when the 10 GiB per-repo cap is hit, whichever comes first, and a
short-lived PR branch's own entry is dead weight the moment its PR merges
or closes. `cache-gc.yml` is a scheduled reusable workflow (daily
`schedule:` cron, plus `workflow_dispatch:` for a manual run) that walks
every repo on the `PeterChauYEG` account (`gh repo list`, not a hardcoded
list) and deletes any Actions cache whose `last_accessed_at` is older than
a threshold:

- `main`-branch (`refs/heads/main`) caches — the canonical entries every
  job's `restore-keys` fallback above depends on — get the longer
  `main_max_idle_days` threshold (default **2** days idle), still well
  inside GitHub's own 7-day eviction window.
- Every other ref (PR branches) gets the shorter `other_max_idle_days`
  threshold (default **1** day idle).

Both thresholds are `workflow_dispatch`/`workflow_call` inputs, not
hardcoded, so a one-off run can override either without editing the
workflow. Uses the same PAT every other cross-repo workflow in this repo
already relies on (see `mirror-to-mecha-industries.yml`/
`version-bump.yml`/`dependabot-automerge.yml`) — cache list/delete is a
repo-scoped `gh` permission that the ephemeral per-run `GITHUB_TOKEN` can't
reach for any repo but the one currently running. Logs a per-repo summary
(caches deleted, bytes reclaimed) to `$GITHUB_STEP_SUMMARY`.

## Concurrency

There are **two separate, non-conflicting concurrency mechanisms** in play
here — don't confuse them:

1. **GitHub Actions `concurrency:` groups** (per-workflow YAML). `main-ci.yml`
   and `version-bump.yml` each declare their own group
   (`main-ci-${{ github.repository }}` / `version-bump-${{ github.repository }}`)
   to stop overlapping *runs of that same reusable workflow* from piling up
   (e.g. two rapid pushes to `main`, or a scheduled version-bump firing while
   the previous one is still open). **These reusable workflows own their
   group — callers must not also declare a `concurrency:` block with the
   same group.** A caller and the nested `workflow_call` it triggers are not
   independent runs GitHub can queue against each other; they're parent and
   child of the same run. Two `concurrency:` blocks resolving to the same
   group across that parent/child boundary deadlocks (the parent holds the
   group and won't release it until the child finishes, but the child can't
   start until it acquires that same group) and GitHub cancels the run. This
   happened in production on `laboratory-one-web`'s `main.yml` (2026-08-04) —
   it redeclared `main-ci-${{ github.repository }}` on top of `main-ci.yml`'s
   own, and every push-to-main deploy got canceled until the caller's
   duplicate was removed. On the PR side, both the `*-pr.yml` caller
   (grouped per PR number, since the reusable workflow can't see that from
   its own context) and the `develop-*-ci.yml`/`godot-develop-ci.yml`
   workflow it calls (grouped by `${{ github.workflow }}-${{ github.repository }}-${{ github.ref }}`)
   each declare their own group — safe, since the two group strings never
   match, just redundant (both would independently cancel a superseded run
   of the same PR). The deadlock only happens when a caller and the exact
   reusable workflow it invokes resolve to the *same* group string, as in
   the incident above — never when the two levels use genuinely different
   groups, whether that's a deliberate design (`main-ci.yml`'s family) or
   incidental redundancy (the PR-side pairs above).
2. **The gha-runner host's job-concurrency semaphore** (`ci-semaphore-acquire.sh`
   / `ci-semaphore-release.sh`, provisioned by the `gha-runners` skill in ops)
   — a *global* cap (`GLOBAL_CI_CONCURRENCY`, default 8) and a *per-repo* cap
   (`REPO_CI_CONCURRENCY`, default 2) across every self-hosted `catfood`
   runner on the host, enforced at the runner-process level via
   `ACTIONS_RUNNER_HOOK_JOB_*` hooks — completely outside GitHub Actions'
   own YAML. This is what actually limits how many of `main-ci.yml`'s/
   `develop-ci.yml`'s ~12 jobs run *simultaneously* for one repo: even though
   the job graph has no `concurrency:` block between `lint`/`typecheck`/
   `build`/etc. and lets them all become runnable at once after `setup`
   finishes, only `REPO_CI_CONCURRENCY` (2) actually execute at a time — the
   rest queue at the host, invisible to the workflow YAML. Don't try to
   "fix" that queueing by adding more `concurrency:` groups here; it's a
   different, correctly-functioning layer, and stacking a YAML-level group
   on top of it is exactly the mistake described in point 1.
   **Unverified as of LAB-1301** — investigating that OOM ticket couldn't
   locate `ci-semaphore-acquire.sh`/`ci-semaphore-release.sh` or those env
   vars anywhere in the current `gha-runners` ops skill, which instead
   documents an ephemeral Docker-dispatch model (`webhook-server.py` +
   `dispatch-one.sh`, per-repo `max-concurrent` in `repos.json` on the
   runner host). If this section is stale, point 3 below is not a
   redundant stack on top of a working per-repo job cap — it may be the
   only thing actually limiting simultaneous `setup` jobs for one repo.
   Flagging for whoever owns the runner host to confirm/update this
   section rather than silently leaving it wrong.
3. **`develop-ci.yml`'s `setup` job concurrency group**
   (`catfood-yarn-install-${{ github.repository }}`, `cancel-in-progress:
   false`) — added for LAB-1301 after budget PRs #170/#171/#173-#176 all
   got OOM-killed ~28s into `yarn install --frozen-lockfile` when their
   runs landed on the runner pool within seconds of each other (PR #169
   passed cleanly at a quieter moment). This is a **job-level** group
   (`jobs.setup.concurrency`), not a workflow-level one, so it can't
   deadlock against the caller's own per-PR-number group the way two
   workflow-level groups sharing a name would (point 1) — it only ever
   queues *this job*, letting a same-repo PR's `setup` wait for another
   same-repo PR's `setup` to finish rather than run alongside it, while
   every downstream job (`lint`/`typecheck`/`build`/etc., which read the
   now-warm `node_modules` cache `setup` primed and so normally skip their
   own install) stays fully parallel. Paired with the `YARN_NETWORK_CONCURRENCY` cap in
   "Caching strategy" above — fewer simultaneous installs, and each one
   cheaper in peak memory.

## Aggregated reporting — the `danger-comment` job

Every `develop-*-ci.yml` workflow used to have each of its scan/gate jobs
(`dead-code`, `duplicate-code`, `design-system`, `react-tech-debt`,
`max-lines`, `tech-debt`, `peer-deps`, `security-scan`, `secret-scan`,
`dependency-audit`, and — in `develop-rust-ci.yml` — `fmt`/`clippy`/`test`/
`file-size` too) independently generate its own Dangerfile, post its own
sticky PR comment, and file its own Linear ticket on failure. That meant N
separate sticky comments cluttering one PR and N copies of the same
ticket-filing boilerplate (and its dedup logic) spread across every job in
every workflow.

That's now centralized: every reporting-worthy job in every
`develop-*-ci.yml` file instead exposes job-level `outputs: {outcome,
report}` (a metrics-only job like `tech-debt`/`file-size` that never fails
only exposes `report` — there's no `outcome` and no corresponding
ticket-filing step for it) and stops posting/filing anything itself. Each
workflow then has exactly ONE new `danger-comment` job (`needs:` every
reporting job, `if: always()` so it still runs when an upstream job failed)
that:

1. Checks out `labone-actions` itself (not the caller repo — a second,
   `path:`-scoped, sparse checkout alongside the caller's own) purely to
   get `scripts/file-linear-ticket.sh`, which lives here regardless of
   which repo calls the workflow.
2. Builds ONE combined markdown report by concatenating every non-skipped
   upstream job's `report` output, and posts it as a single sticky PR
   comment via `.github/actions/post-danger-comment` (one `danger ci --id`
   per workflow run, not one per job).
3. Files a Linear ticket — one "File Linear ticket for `<job>`" step per
   reporting job, each gated on `needs.<job>.outputs.outcome == 'failure'`
   — via `scripts/file-linear-ticket.sh <job-name> <report-file>`.
   `file-linear-ticket.sh`'s own dedup logic (search for an already-open
   ticket with this exact per-PR-per-job title before creating a new one,
   comment "still failing" on it instead of duplicating) is completely
   unchanged — it's just invoked from this one job N times now, instead of
   from N different jobs each calling it once.

`danger-comment` is always excluded from that workflow's `required-checks`
`needs:` list, same as `dead-code`/`duplicate-code` always were — it's
purely advisory/reporting and never fails on its own, even when every job
feeding it failed.

A job that's still a HARD gate (`security-scan`, `secret-scan`,
`dependency-audit`, and in `develop-rust-ci.yml` `fmt`/`clippy`/`test`) has
its check step changed to `continue-on-error: true` with an `id`, followed
by an `if: always()` "Build report" step that captures `outcome`/`report`,
followed by a final `if: steps.<id>.outcome == 'failure'` → `exit 1` step —
this preserves the exact same blocking behavior toward
`required-checks`/branch protection as before; only *how* the result gets
surfaced changed (via `danger-comment` instead of nothing, or its own
per-job Dangerfile).

## Scan job dedup — `.github/actions/scan-with-report`

`develop-ci.yml`'s 5 scan jobs (`design-system`, `dead-code`,
`duplicate-code`, `react-tech-debt`, `max-lines`) all
follow the same shape: run a yarn script that writes a markdown report,
expose that report and the scan's outcome as this action's outputs, then
fail the job if the script failed *and the job is configured as blocking*.
That's factored into `.github/actions/scan-with-report/action.yml`, a
composite action with inputs:

- `script` (required) — yarn script to run.
- `working-directory` (string, default `.`).
- `report-file` (required) — markdown report path the script writes.
- `gh-token` (string, default `''`) — forwarded as `GH_TOKEN`/`GITHUB_TOKEN`
  to the `yarn <script>` step, for scripts that transitively need `gh`
  CLI/GitHub REST access.
- `blocking` (boolean-as-string, default `'true'`) — set `'false'` for
  `design-system`, `dead-code`, `duplicate-code`, `react-tech-debt`,
  and `max-lines` (nextjs-ci v1.0.2, 2026-08-20): the scan still runs and
  still exposes its outputs, but the composite action's final `exit 1` is
  skipped, so a finding never fails the containing job.

Outputs: `outcome` (`success`/`failure` — the `yarn <script>` step's own
outcome) and `report` (the contents of `report-file`, or a placeholder if
it wasn't written). Posting a sticky comment and filing a Linear ticket
used to live in this action too, one independent comment/ticket per
calling job — that's now centralized in each workflow's single
`danger-comment` aggregator job instead; see "Aggregated reporting" above.
This action only produces the raw material (`outcome`, `report`) that
aggregator consumes.

(`a11y` and `run-e2e-tests` — the two jobs that used to set `playwright:
'true'` to install Chromium first — were removed org-wide, along with the
`playwright` input itself; see the top of this file's `develop-ci.yml`
section.)

Each of the 5 scan jobs in `develop-ci.yml` now shrinks to its
`needs`/`runs-on`/`if` header, a `setup-node-yarn` call, one
`scan-with-report` call (with an `id`), and a job-level `outputs: {outcome,
report}` pointing at that step's own outputs.

The `continue-on-error` + `steps.scan.outcome == 'failure'` + final `exit 1`
pattern still works correctly inside a composite action: composite action
steps execute in the same job/runner context as the caller, with their own
scoped `steps` context, so a step failing (via that final `exit 1`) still
fails the containing job exactly as it did when the steps were written
inline. Verified with `actionlint`.

`main-ci.yml`'s equivalent jobs (no sticky comments, no ticket filing) are
already minimal 2-step bodies and were left as-is — not worth
composite-izing further.

### Sticky comments via `danger ci --id`

`danger-comment` (see "Aggregated reporting" above) posts its one combined
comment via [danger-js](https://danger.systems/js/)'s CLI (`npx --yes
danger@14.0.7 ci --id <sticky-header> --dangerfile <path>`) rather than
`marocchino/sticky-pull-request-comment`. It writes a tiny Dangerfile to
`$RUNNER_TEMP` at run time (never committed) that reads the combined report
and, if present, calls `markdown()` with its contents.

`danger ci`'s `--id` is what makes a sticky comment updatable in place
across re-runs instead of posted fresh each time: the id gets its own
hidden marker embedded in the comment body, which is how a later run finds
and updates that exact comment. Each workflow's `danger-comment` job uses
one fixed `sticky-header` (e.g. `dependency-checks`, `ci-scans`,
`rust-checks`) for its one combined comment — the same mechanism that used
to back N separate per-job ids now backs this one.

The danger step authenticates via `github.token` (the aggregator job has no
caller-supplied `gh-token` to fall back to, unlike the individual scan jobs
it replaces — it doesn't need one, since it only ever reads job outputs and
posts a comment, never runs a caller script).

## Shared danger comment posting — `.github/actions/post-danger-comment`

Posts/updates a single sticky PR comment with arbitrary markdown via
`danger ci --id` — the same underlying mechanism `scan-with-report` used to
use directly. Inputs: `report` (required, the markdown body) and
`sticky-header` (required, `danger ci`'s `--id`). Used by every
`develop-*-ci.yml` workflow's `danger-comment` aggregator job (see
"Aggregated reporting" above) to post its one combined comment, without
pulling `actions/setup-node@v7` into every job that only needs to hand off
a `report` output. Never fails the job.

## Tech debt metrics report — `.github/actions/tech-debt-report`

`develop-ci.yml` and `develop-mobile-ci.yml` both have an opt-in `tech-debt`
job (`enable_tech_debt`, default **false** — see each workflow's own
section above) that greps the caller's tracked `.ts`/`.tsx` tree for seven
tech-debt signals and emits the totals as a `report` output. `tech-debt`
computes the metrics (this action) and never runs a yarn script or needs
`node_modules` or a Node runtime at all, so it stays on a minimal runner —
just `actions/checkout@v7` before calling the action, no `setup-node-yarn`
and no `setup-node` either.

`tech-debt`'s `report` output now feeds directly into the workflow's
`danger-comment` aggregator job (see "Aggregated reporting" above), which
posts it as part of the one combined sticky comment — the separate
`tech-debt-comment` job that used to exist purely to post this one report
via `.github/actions/post-danger-comment` is gone; `danger-comment` already
needs `actions/setup-node@v7`/npx for its own comment step regardless, so
there's no longer a reason for a second Node-capable job just for this.
(The original single-job shape this superseded assumed `catfood-minimal`
had `npx` on `PATH` for a comment step — it doesn't, which is what broke
budget PR #330, LAB-2328, and is why the split into a separate comment job
existed at all before `danger-comment` centralized it.) `tech-debt` never
fails the job either way — it's a metrics report, not a gate — so it has no
`outcome` output and `danger-comment` never files a ticket for it.

Metrics (repo-wide totals, not diff-only counts):

- `useEffect` call sites (`useEffect(`)
- React Native's built-in `Animated.*` usage (not third-party animation
  libraries — a known, accepted imprecision of a plain `Animated\.` grep,
  see the action's `count-metrics.sh`)
- Lint/format disable comments: `eslint-disable`/`eslint-disable-next-line`,
  `prettier-ignore`, `biome-ignore`
- `@ts-ignore`/`@ts-expect-error` suppressions
- `any` usage (`: any`, `as any`, `@ts-nocheck` files, summed)
- `TODO`/`FIXME`/`HACK` comments
- `console.log` calls

File discovery is `git ls-files` (tracked + untracked-but-not-ignored),
not a hardcoded exclude list, so it automatically respects whatever the
repo's own `.gitignore` excludes — `node_modules`, build output, or
anything else a repo chooses to ignore — rather than a fixed guess-list
that silently misses whatever wasn't thought of. Falls back to a plain
`find` with a hardcoded exclude list (`node_modules`, `.next`, `dist`,
`build`, `coverage`, `.expo`, `.git`) only if `working-directory` isn't
inside a git working tree at all.

`.github/actions/tech-debt-report/action.yml` inputs:

- `working-directory` (string, default `.`) — same convention as every
  other action in this repo.
- `pr-number` (required) — forwarded from the caller workflow's
  `pr_number` input. `danger ci` detects the PR from the GitHub Actions
  environment itself, so this is kept only for input-compatibility with
  existing callers, not read by the comment step.
- `base-sha` (string, default `''`) — forwarded from the caller workflow's
  `pr_base_sha` input (`github.event.pull_request.base.sha`). When set,
  the action fetches that SHA and checks it out into a throwaway `git
  worktree` (not a second full checkout) to compute the same metrics
  there, adding a "Δ vs. base" column to the report. A fetch/worktree
  failure (e.g. an unreachable SHA) degrades to current-totals-only
  instead of failing the job — this is a nice-to-have, not something worth
  blocking a PR over.

Output: `report` — the full markdown report, folded into the workflow's
`danger-comment` aggregator job's combined comment (see "Aggregated
reporting" above).

The actual counting logic lives in one place,
`.github/actions/tech-debt-report/count-metrics.sh <dir>`, invoked by both
the "current tree" and "base branch worktree" steps so it isn't duplicated
across two `run:` blocks.

To opt a repo in, set `enable_tech_debt: true` on the `develop-ci.yml`/
`develop-mobile-ci.yml` call (see `templates/web-pr.yml`/
`templates/mobile-pr.yml`) and, for the delta column, also pass
`pr_base_sha: ${{ github.event.pull_request.base.sha }}`.

## Rust tech debt metrics report — `.github/actions/tech-debt-report-rust`

`develop-rust-ci.yml` has an opt-in `tech-debt` job (`enable_tech_debt`,
default **false**, same convention as `develop-ci.yml`'s equivalent above)
that greps the caller's tracked `.rs` tree for two tech-debt signals and
emits the totals as a `report` output — the metrics job never runs cargo or
needs a built workspace, so it stays on `catfood-minimal` with just
`actions/checkout@v7`. Its `report` output feeds straight into
`danger-comment` (see "Aggregated reporting" above); the separate
`tech-debt-comment` job that used to post this report on its own via
`.github/actions/post-danger-comment` is gone, same rationale as
`develop-ci.yml`'s equivalent above. Never fails the job — a metrics
report, not a gate — so it has no `outcome` output and no corresponding
ticket-filing step in `danger-comment`.

Metrics (repo-wide totals, not diff-only counts):

- `TODO`/`FIXME`/`HACK` comments — same meaning as the TS/TSX report above
- `#[allow(...)]`/`#![allow(...)]` lint-suppression attributes — Rust's
  `eslint-disable`(-next-line): both suppress a specific lint at a
  specific site

File discovery is `git ls-files` (tracked + untracked-but-not-ignored),
respecting the repo's own `.gitignore` (`target/`, generated code, etc.)
rather than a hardcoded exclude list. Falls back to a plain `find`
(excluding only `target/` and `.git/`) if `working-directory` isn't
inside a git working tree at all.

`.github/actions/tech-debt-report-rust/action.yml` inputs mirror
`tech-debt-report`'s exactly (`working-directory`, `pr-number`, `base-sha`)
and it emits the same `report` output — see that section above for the
full contract. The counting logic lives in
`.github/actions/tech-debt-report-rust/count-metrics.sh <dir>`, invoked by
both the "current tree" and "base branch worktree" steps.

To opt a repo in, set `enable_tech_debt: true` on the `develop-rust-ci.yml`
call and, for the delta column, also pass
`pr_base_sha: ${{ github.event.pull_request.base.sha }}`.

## `security-scan.yml`

Reusable, `workflow_call` inputs `scan-ref` (string, default `.`),
`trivyignores` (string, default `''`), and `cache-write` (boolean, default
`false`), single `trivy` job. Call it directly with `secrets: inherit`.
`cache-write` controls the Trivy DB cache's read-only-vs-write split — see
"Caching strategy" → "Trivy DB cache" / "Cache-to-main: read/write split"
above. This repo's own caller, `security.yml`, passes
`cache-write: ${{ github.event_name == 'push' }}`.

If your repo has a `.trivyignore.yaml` (the structured, path-scoped ignore
format), you MUST pass `trivyignores: '.trivyignore.yaml'` explicitly —
trivy-action only auto-discovers a plain `.trivyignore` in the scan root on
its own; a `.trivyignore.yaml` silently does nothing without this input
(discovered via chuunibyou's pre-existing, correctly-written
`.trivyignore.yaml` for a fictional in-game "leaked secret" that Trivy kept
flagging anyway because nothing was telling it the file existed).

```yaml
jobs:
  trivy:
    uses: PeterChauYEG/labone-actions/.github/workflows/security-scan.yml@main
    secrets: inherit
    with:
      trivyignores: '.trivyignore.yaml'
```

## `actionlint.yml`

Reusable, stack-agnostic workflow: lints the caller's own `.github/workflows/*.yml` with
[actionlint](https://github.com/rhysd/actionlint) (catches invalid expressions, unknown inputs on
`uses:` reusable-workflow calls, shellcheck issues inside `run:` blocks, etc.). Extracted from
this repo's own `ci.yml`, which has run actionlint against its own workflows since before this
reusable workflow existed — every other repo in the org should call this instead of hand-rolling
the same `curl | bash` install step. `workflow_call` inputs:

- `actionlint-version` (string, default `1.7.12`) — pinned actionlint version, kept in lockstep
  with the version this repo's own `ci.yml` uses.
- `pr_number` (number, default `0`) / `pr_url` (string, default `''`) — caller-supplied, used for
  Linear ticket filing on failure (same `continue-on-error` + `file-linear-ticket.sh` + explicit
  `exit 1` pattern as `godot-develop-ci.yml`). **Requires the caller repo to already have its own
  `scripts/file-linear-ticket.sh`** (not something this reusable workflow ships itself) — every
  repo already onboarded onto Linear-ticket-filing CI has one; a repo with none should add
  `scripts/file-linear-ticket.sh` before adopting this workflow, or the ticket-filing step
  itself will fail (file not found) whenever actionlint fails.

Caller example:

```yaml
name: Actionlint
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  actionlint:
    uses: PeterChauYEG/labone-actions/.github/workflows/actionlint.yml@main
    secrets: inherit
    with:
      pr_number: ${{ github.event.pull_request.number }}
      pr_url: ${{ github.event.pull_request.html_url }}
```

## `godot-develop-ci.yml`

Reusable PR-time CI for Godot 4/GDScript repos, mirroring `develop-ci.yml`'s
caller pattern for the web stack. `workflow_call` inputs:

- `working-directory` (string, default `.`) — directory the Godot project
  lives in, for monorepo callers.
- `pr_number` / `pr_url` (number / string) — forwarded from the caller's
  `github.event.pull_request` context (needed for the Linear ticket-filing
  and sticky PR comment steps below).
- `is_dependabot` (boolean, default `false`) — caller must compute this
  from `github.event.pull_request.user.login`. `format`/`lint` always run in
  full (there's no separate build/typecheck concept in GDScript);
  `duplicate-code` and `test` are skipped for dependabot PRs, the same way
  `develop-ci.yml` gates its optional scan jobs.
- `enable_test` (boolean, default `true`) — run GUT tests under
  `tests-path`. Set `false` only for repos that structurally can't run GUT
  standalone (e.g. a plugin monorepo whose `class_name` symbols only
  resolve inside a separate host project) — document why in the caller.
- `tests-path` (string, default `tests`) — GUT test directory, relative to
  `working-directory`.

Jobs:

- `format` — `gdformat --check .`, gated on `.gdlintrc`-adjacent gdtoolkit
  install via the `setup-gdtoolkit` composite action (itself a thin wrapper
  around `setup-python-uv` — see `develop-python-ci.yml`'s section above).
- `lint` — `gdlint .` against this repo's canonical, intentionally strict
  `.gdlintrc`.
- `duplicate-code` — `jscpd` against the caller repo's own `.jscpd.json`,
  with a sticky PR comment posted from the generated report.
- `test` — runs GUT (`addons/gut/gut_cmdln.gd`) headless against
  `tests-path`.

`format`, `lint`, and `duplicate-code` are mandatory — unlike `develop-ci.yml`'s
optional web scan jobs, there's no `enable_*` toggle for them, because the
whole point of this workflow is a floor every Godot repo shares. `test` is
the one job that flexes, via `enable_test`, for repos that structurally
can't run GUT standalone.

`format`/`lint`/`duplicate-code`/`test` each file a Linear ticket on failure by
invoking `scripts/file-linear-ticket.sh` with a bare relative path, the same
convention `develop-ci.yml`'s plain (non-composite-action) jobs use — every
caller repo keeps its own copy of that script at
`scripts/file-linear-ticket.sh`.

**Never keep a `.gdlintrc` in a consumer repo.** The `setup-gdtoolkit`
composite action installs (and overwrites) this repo's canonical
`.gdlintrc` into `working-directory` on every run — see the action's own
description in `.github/actions/setup-gdtoolkit/action.yml`. That's what
makes "change GDScript lint rules in one place" actually true instead of
aspirational: a local `.gdlintrc` in a caller repo would silently take
precedence over gdlint's own config discovery and reintroduce exactly the
per-repo drift this workflow exists to eliminate.

Caller example:

```yaml
name: Develop CI
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  ci:
    uses: PeterChauYEG/labone-actions/.github/workflows/godot-develop-ci.yml@main
    secrets: inherit
    with:
      pr_number: ${{ github.event.pull_request.number }}
      pr_url: ${{ github.event.pull_request.html_url }}
      is_dependabot: ${{ github.event.pull_request.user.login == 'dependabot[bot]' }}
  security:
    uses: PeterChauYEG/labone-actions/.github/workflows/security-scan.yml@main
    secrets: inherit
```

## `develop-python-ci.yml`

Reusable PR-time CI for Python repos (data pipelines, MCP servers, ML/robotics
scripts). Unlike `develop-node-ci.yml`, there's no shared `setup` +
cache-restore stage installing the *project's own* deps — Python dependency
management isn't uniform across consumer repos (`pyproject.toml`,
`requirements.txt`, or neither). The standalone dev tools each job needs
(`ruff`, `pip-audit`) don't have that problem though, so `lint` and
`dependency-audit` both install theirs via `setup-python-uv` — a cached
`uv tool install` wrapper (`.github/actions/setup-python-uv/action.yml`,
mirrors `setup-node-yarn`/`setup-node-pnpm`'s shape) instead of a bare,
uncached `pip install --break-system-packages <tool>` on every run.
`setup-python-uv` assumes `uv` is already on the runner image — see that
action's own description. `workflow_call` inputs:

- `working-directory` (string, default `.`) — directory the Python project
  lives in, for monorepo callers.
- `is_dependabot` (boolean, default `false`) — caller must compute this from
  `github.event.pull_request.user.login`. `lint` always runs; `test`,
  `security-scan` and `dependency-audit` are skipped for dependabot PRs.
- `lint_path` (string, default `.`) — path passed to `ruff check`.
- `enable_test` (boolean, default `true`) / `test_command` (string, default
  `python3 -m pytest`) — there's no standard Python equivalent of
  package.json's `test` script name, so the command itself is an input.
- `enable_security_scan` (boolean, default `true`) /
  `security_scan_trivyignores` (string) — same contract as
  `develop-node-ci.yml`'s equivalents.
- `enable_dependency_audit` (boolean, default **`false`**) /
  `requirements_file` (string, default `requirements.txt`) — runs
  `pip-audit`. Off by default, unlike `develop-node-ci.yml`'s
  `dependency-audit`: Node callers share one lockfile format (`yarn.lock`);
  Python callers here don't share one dependency-declaration format, so
  forcing this on would fail loudly for a repo with neither a
  `requirements.txt` nor a `pyproject.toml`. Opt in explicitly per caller.

Jobs: `lint`, `test`, `security-scan`, `secret-scan`, `dependency-audit`,
`danger-comment`. `lint`/`test` are plain pass/fail gates with no comment/
ticket. `security-scan`/`secret-scan`/`dependency-audit` stay HARD gates
(a finding still fails the job) but now also feed `danger-comment`, which
posts ONE combined sticky PR comment and files/comments-on a Linear ticket
(via `scripts/file-linear-ticket.sh`) for whichever of them failed — see
"Aggregated reporting" above. Repo-specific checks (e.g. a
project-specific smoke test, a domain validation script) stay as additional
jobs in the caller's own workflow file alongside the `uses:` call — this
workflow only covers the common shape every Python repo shares.

Caller example:

```yaml
name: Develop CI
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  ci:
    uses: PeterChauYEG/labone-actions/.github/workflows/develop-python-ci.yml@main
    secrets: inherit
    with:
      is_dependabot: ${{ github.event.pull_request.user.login == 'dependabot[bot]' }}
```
## `develop-rust-ci.yml`

Reusable PR-time CI for Rust CLI/tool repos (`gdscript-lsp`, `ai-harness-cli`).
Unlike `develop-node-ci.yml`, there's no shared `setup` + cache-restore
stage — cargo's own registry/git/target caching (via
`actions/cache`, keyed on `Cargo.lock`'s hash) already avoids redundant
network fetches per job without needing a single upstream install step to
fan out from. The `fmt`/`clippy`/`test`/`build` jobs' cache blocks each use
their own job-scoped key rather than one shared across jobs — see "Caching
strategy" → "Cargo cache scoping" above. `workflow_call` inputs:

- `working-directory` (string, default `.`) — directory the Cargo project
  lives in, for monorepo callers.
- `pr_number` (number, default `0`) / `pr_url` (string, default `''`) —
  caller-supplied, since a reusable workflow can't always see
  `github.event.pull_request` directly. Used for Linear ticket filing and
  sticky PR comments.
- `is_dependabot` (boolean, default `false`) — caller must compute this from
  `github.event.pull_request.user.login`. `fmt`/`clippy` always run in
  full; `test`, `build`, and every optional scan job are skipped for
  dependabot PRs.
- `pre_build_command` (string, default `''`) — arbitrary shell run once per
  job (`fmt`/`clippy`/`test`/`build`), after checkout and toolchain setup
  but before the job's actual cargo command. Exists because a caller may
  need to install private-git SDK dependencies before `cargo` can even
  resolve its dependency graph — there's no way to generalize "install my
  private deps" into a fixed shape, so it's caller-supplied shell rather
  than a boolean toggle.
- `enable_build` (boolean, default `false`) — runs `cargo build --release`.
- `enable_dead_code` (boolean, default `true`) / `dead_code_script` (string,
  default `scripts/dead-code-scan.sh`) / `cargo_machete_version` (string,
  default `0.9.2`) — a cargo-machete dead-dependency scan. Both known
  callers run this today with the same pinned tool version, so it defaults
  on. `cargo_machete_version` is informational only — cargo-machete is
  baked into the `rust` self-hosted runner image at build time, not
  installed per-run, so keep this value in sync with the image's pin.
- `enable_duplicate_code` (boolean, default `false`) /
  `duplicate_code_script` (string, default
  `scripts/ci/duplicate-code-scan.sh`) / `cargo_dupes_version` (string,
  default `0.2.1`) — a cargo-dupes duplicate-code scan. Off by default —
  only one of the two known callers has this today. Unlike cargo-machete,
  cargo-dupes is not baked into the runner image, so it's still installed
  and cached per-run.
- `enable_file_size` (boolean, default `false`) / `file_size_script`
  (string, default `scripts/ci/file-size-scan.sh`) — a report-only file-size
  scan (never fails the job). Off by default, same reasoning.
- `enable_security_scan` (boolean, default `true`) /
  `security_scan_trivyignores` (string) — same contract as
  `develop-node-ci.yml`'s equivalents.
- `enable_dependency_audit` (boolean, default `false`) — runs `cargo audit`.
  Off by default: neither known caller has this today, so there's no
  established precedent to default on.
- `pr_base_sha` (string, default `''`) — only used by the `tech-debt` job
  (when `enable_tech_debt` is true) to compute a delta vs. the PR's base
  branch. Leave empty (default) for current-totals only.
- `enable_tech_debt` (boolean, default `false`) — runs the grep-based Rust
  tech-debt metrics report (TODO/FIXME/HACK comments, `#[allow(...)]`/
  `#![allow(...)]` lint suppressions) and posts it as a sticky PR comment,
  via `.github/actions/tech-debt-report-rust` — the Rust sibling of
  `develop-ci.yml`'s `enable_tech_debt`. Opt-in like that one, since no
  Rust repo has this today.

Jobs: `fmt`, `clippy`, `test`, `build`, `dead-code`, `duplicate-code`,
`file-size`, `security-scan`, `secret-scan`, `dependency-audit`,
`tech-debt`, `danger-comment`. `fmt`, `clippy`, `test`, `dead-code`,
`duplicate-code`, `security-scan`, `secret-scan`, and `dependency-audit`
all expose `outcome`/`report` outputs that feed `danger-comment`, which
posts ONE combined sticky PR comment (`rust-checks`) and files/comments-on
a Linear ticket (via `scripts/file-linear-ticket.sh`) for whichever of them
failed — see "Aggregated reporting" above. `fmt`/`clippy`/`test`/
`security-scan`/`secret-scan`/`dependency-audit` stay HARD gates (a
finding still fails the job, via an explicit final `exit 1` step, same as
before); `dead-code`/`duplicate-code` stay advisory-only. `file-size` is
report-only (never fails, no ticket, matching its prior no-ticket
behavior) and `tech-debt` is metrics-only (see "Rust tech debt metrics
report" below) — both still get a section in the combined comment.
Repo-specific release/build/publish machinery (version bump,
cross-compiled release binaries, Homebrew tap notifications, etc.) stays
entirely in the caller's own `main.yml` — this workflow only covers the
common PR-time quality-gate shape.

Caller example:

```yaml
name: Develop CI
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  ci:
    uses: PeterChauYEG/labone-actions/.github/workflows/develop-rust-ci.yml@main
    secrets: inherit
    with:
      pr_number: ${{ github.event.pull_request.number }}
      pr_url: ${{ github.event.pull_request.html_url }}
      is_dependabot: ${{ github.event.pull_request.user.login == 'dependabot[bot]' }}
```

## `develop-mobile-ci.yml`

Reusable PR-time CI for Expo/React Native mobile repos
(`mc-training-arc-sung-jinwoo-mobile`, `mangalab`, `shout-mobile`). Same
cache-restore-per-job caching strategy as `develop-node-ci.yml` (both
are Yarn Berry — reuses the same `setup-node-yarn` action as-is), but a
mobile-app-shaped job set: `lint`/`ls-lint`/
`typecheck`/`test` plus the web-style `a11y`/`design-system`/`dead-code`/
`duplicate-code` scans all three known callers already run (closer in
spirit to `develop-ci.yml`'s Next.js job set than `develop-node-ci.yml`'s
plain NestJS one). `workflow_call` inputs:

- `working-directory` (string, default `.`) — directory the Expo app lives
  in, for monorepo callers.
- `pr_number` (number, default `0`) / `pr_url` (string, default `''`) —
  same reasoning as `develop-rust-ci.yml`.
- `pr_base_sha` (string, default `''`) — `github.event.pull_request.base.sha`,
  only used by `tech-debt` (when `enable_tech_debt` is true) for the
  delta-vs-base-branch column.
- `is_dependabot` (boolean, default `false`) — caller must compute this from
  `github.event.pull_request.user.login`, and per known callers' CalVer
  version-bump PRs, should probably also cover `github-actions[bot]`. When
  true, `ls-lint`, `test`, `a11y`, `design-system`, `dead-code`,
  `duplicate-code`, `security-scan` and `dependency-audit` are skipped
  (`lint`/`typecheck` stay on).
- `enable_ls_lint` (boolean, default `true`) — runs `yarn lint:ls`.
- `enable_test` (boolean, default `true`) — runs `yarn test:coverage` +
  Codecov upload.
- `codecov_use_oidc` (boolean, default `false`) — use Codecov's OIDC auth
  instead of a token. Known callers use both modes, even inconsistently
  within a single repo.
- `codecov_token_secret_name` (string, default `CODECOV_TOKEN`) —
  documentation only (a reusable workflow can't reference a
  dynamically-named secret); the job always reads `secrets.CODECOV_TOKEN`.
- `enable_a11y` / `enable_design_system` / `enable_dead_code` (boolean,
  default `true`) — run `yarn a11y` / `yarn design-system` / `yarn
  dead-code` (knip).
- `enable_duplicate_code` (boolean, default `false`) — runs `yarn
  duplicate-code` (jscpd). Off by default — not every known caller has this
  job today.
- `enable_security_scan` (boolean, default `true`) /
  `security_scan_trivyignores` (string) — same contract as
  `develop-node-ci.yml`'s equivalents.
- `enable_dependency_audit` (boolean, default `false`) — runs `yarn npm
  audit`. Off by default — genuinely new, no known caller has this in its
  PR workflow today.
- `extra_deps_paths` (string, default `''`) — same as
  `develop-node-ci.yml`'s equivalent.
- `enable_tech_debt` (boolean, default `false`) — run the grep-based
  tech-debt metrics report and post it as a sticky PR comment. Opt-in — see
  "Tech debt metrics report" below.

Jobs: `setup`, `lint`, `ls-lint`, `typecheck`, `test`, `peer-deps`, `a11y`,
`design-system`, `dead-code`, `duplicate-code`, `security-scan`,
`secret-scan`, `dependency-audit`, `tech-debt` (opt-in), `danger-comment`.
`lint`/`typecheck` are plain, always-on pass/fail gates (no dependabot skip
— a broken lint/type error is exactly what a dependency bump can cause).
`peer-deps`, `a11y`, `design-system`, `dead-code`, `duplicate-code`,
`security-scan`, `secret-scan`, `dependency-audit`, and `tech-debt` all
feed `danger-comment`, which posts ONE combined sticky PR comment and
files/comments-on a Linear ticket (via `scripts/file-linear-ticket.sh`) for
whichever of them failed — see "Aggregated reporting" above.
`security-scan`/`secret-scan`/`dependency-audit` stay HARD gates (a finding
still fails the job); `peer-deps`/`a11y`/`design-system`/`dead-code`/
`duplicate-code` stay advisory-only, matching prior behavior;
`tech-debt` is metrics-only (never fails, no ticket). Repo-specific
release/publish machinery (EAS build, OTA `publish-update.yml`, version
bump) stays in the caller's own workflow files — this workflow only covers
the common PR-time shape.

Caller example:

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
    uses: PeterChauYEG/labone-actions/.github/workflows/develop-mobile-ci.yml@main
    secrets: inherit
    with:
      pr_number: ${{ github.event.pull_request.number }}
      pr_url: ${{ github.event.pull_request.html_url }}
      is_dependabot: ${{ github.event.pull_request.user.login == 'dependabot[bot]' }}
```

**The `ci` job's `permissions: {contents: read, pull-requests: write}`
block above is REQUIRED, not optional** — see the identical callout under
`develop-node-ci.yml`'s caller example above for the full explanation.
This repo's own `templates/mobile-pr.yml` already carries this block
correctly; `templates/node-pr.yml` does not yet, so copy the block above
by hand for now if you're wiring up a Node/NestJS caller from that
template. `main-node-ci.yml` does **not** need this
block — its `dead-code` job has no sticky-PR-comment feature (plain
pass/fail, no `permissions:` override), and `main-mobile-ci.yml` doesn't
exist in this repo (see "`develop-mobile-ci.yml` has no `main-*-ci.yml`
counterpart" above), so there's nothing to document for either of those
two push-to-main paths.

## `dependabot-automerge.yml`

Now a `workflow_call` reusable workflow (previously a standalone,
non-reusable workflow that consumer repos had to copy verbatim). Converged
from three near-identical copies — this repo's own prior version (no
`--delete-branch`, PR-URL-based merge, `[opened, synchronize]` trigger) and
laboratory-one-web's/ai-harness-web's byte-identical copies
(`--delete-branch`, PR-number-based merge,
`[opened, synchronize, reopened]` trigger) — keeping `--delete-branch` and
the three-event trigger, since those matched 2 of the 3 prior copies. No
`workflow_call` inputs: none of the three copies varied in anything worth
parameterizing. Call it with `secrets: inherit`; see the caller example
above.

## `version-bump.yml`

Now a `workflow_call` reusable workflow, converged from
laboratory-one-web's and ai-harness-web's byte-identical
`.github/workflows/version-bump.yml`. CalVer-bumps the caller repo on a
schedule (or `workflow_dispatch`), opens a PR, waits on that caller repo's
own real CI, and auto-merges + tags a release once it's green.

**Requires a `GH_PAT` secret on every caller repo** (a PAT with at least
Contents: read/write and Pull requests: read/write on that repo) — the
bump-branch push and PR creation must authenticate as a real user, not
`secrets.GITHUB_TOKEN`. GitHub's anti-recursion rule silently drops
`pull_request`/`push` events for anything authored by `GITHUB_TOKEN`
itself, and this used to bite every caller in practice: the bot-authored
bump commit never triggered real CI, so the job used to paper over it by
POSTing fabricated `completed`/`success` check-runs for the base branch's
required-status-check contexts before merging — bypassing real CI review
of the bump commit entirely (LAB-2087). That fabrication is gone; with a
real PAT, the push and PR both raise genuine events, real CI runs and
posts its own real check-runs, and `auto_merge` simply waits on those like
it would for any other PR. The "Verify GH_PAT is configured" step fails
fast with a pointer here if the secret is missing, rather than the job
either silently falling back to `GITHUB_TOKEN` or failing with an opaque
checkout auth error.

**Depends on the caller repo providing its own
`./scripts/bump-version.sh <new-version>`** — that script actually rewrites
version strings in the repo's files, which varies per repo, so it is
deliberately not centralized here. Call it with `secrets: inherit`; see the
caller example above.
