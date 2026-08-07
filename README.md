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
| `.github/workflows/develop-ci.yml` | `pull_request` | Full PR-time quality gate set (lint, typecheck, tests, scans) with sticky PR comments + Linear ticket filing on failure. For yarn/Next.js-ish **web** repos. |
| `.github/workflows/main-ci.yml` | `push` to `main` | Same gate set as plain pass/fail checks, plus `deploy` (Dokku) and `slack-notification`. For yarn/Next.js-ish **web** repos. |
| `.github/workflows/develop-node-ci.yml` | `pull_request` | PR-time quality gate set (lint, typecheck, test, build, security-scan, dependency-audit) as plain pass/fail checks. For yarn- or pnpm-based (`package_manager` input, LAB-1268) Node/NestJS **backend service** repos. |
| `.github/workflows/main-node-ci.yml` | `push` to `main` | Same gate set as `develop-node-ci.yml`, plus `deploy` (Dokku) and `slack-notification`. For yarn/Node/NestJS **backend service** repos. |
| `.github/workflows/godot-develop-ci.yml` | `pull_request` | format/lint/duplicate-code/test quality gate (gdformat, gdlint, jscpd, GUT) with Linear ticket filing on failure. For Godot 4/GDScript **game** repos. |
| `.github/workflows/develop-python-ci.yml` | `pull_request` | lint (ruff), test, security-scan, optional dependency-audit (pip-audit) as plain pass/fail checks. For **Python** repos (data pipelines, MCP servers, ML/robotics scripts). |
| `.github/workflows/develop-rust-ci.yml` | `pull_request` | fmt/clippy/test as Linear-ticket-filing gates, optional build/dead-code (cargo-machete)/duplicate-code (cargo-dupes)/file-size/security-scan/dependency-audit (cargo-audit). For **Rust CLI/tool** repos. |
| `.github/workflows/develop-mobile-ci.yml` | `pull_request` | lint/typecheck as plain pass/fail checks, optional ls-lint/test/a11y/design-system/dead-code (knip)/duplicate-code (jscpd)/security-scan/dependency-audit. For **Expo/React Native mobile** repos. |
| `.github/workflows/security-scan.yml` | either | Trivy filesystem vuln/secret scan. |
| `.github/workflows/actionlint.yml` | `pull_request` | Lints the caller's own `.github/workflows/*.yml` with actionlint. Stack-agnostic — any repo with a `.github/workflows/` directory can call it. |
| `.github/workflows/dependabot-automerge.yml` | `pull_request` | Auto-merges dependabot minor/patch PRs. |
| `.github/workflows/version-bump.yml` | `schedule` + `workflow_dispatch` | CalVer version bump: opens+auto-merges a PR and tags a release when there are new commits since the last tag. Requires the caller repo to provide `./scripts/bump-version.sh` (see below). |

### `templates/` — canonical caller files, one per repo type

Every reusable workflow above has a matching canonical caller file under `templates/` in this
repo (`templates/node-pr.yml`, `templates/godot-pr.yml`, `templates/mobile-pr.yml`, etc.) — the
exact `.github/workflows/<name>.yml` content a consumer repo of that type should have, not just
a code block in this README. **Copy the template file verbatim** into the consumer repo (as
`develop.yml`/`pr.yml`, matching whatever the repo already calls its PR-CI file) rather than
hand-authoring a new wrapper from scratch — hand-authored wrappers drift (different job names
across repos of the same type, different file names, missing the `actionlint` sibling job,
etc.), which is exactly what this whole repo exists to prevent.

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
      # enable_e2e: false
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
    uses: PeterChauYEG/labone-actions/.github/workflows/develop-node-ci.yml@main
    secrets: inherit
    with:
      is_dependabot: ${{ github.event.pull_request.user.login == 'dependabot[bot]' }}
      # Turn off any job your repo doesn't have a yarn script for, e.g.:
      # enable_security_scan: false
```

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
- `enable_ls_lint`, `enable_build`, `enable_test`, `enable_a11y`,
  `enable_design_system`, `enable_dead_code`, `enable_duplicate_code`,
  `enable_e2e`, `enable_react_tech_debt`, `enable_max_lines` (boolean,
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

Jobs: `setup`, `lint`, `ls-lint`, `typecheck`, `build`, `test`, `a11y`,
`design-system`, `dead-code`, `duplicate-code`, `run-e2e-tests`,
`react-tech-debt`, `max-lines`, `tech-debt` (opt-in, see "Tech debt metrics
report" below). Scan jobs (`a11y`, `design-system`,
`dead-code`, `duplicate-code`, `run-e2e-tests`) post a sticky PR comment on
every run and file/comment-on a Linear ticket (via
`scripts/file-linear-ticket.sh`) when they fail; `react-tech-debt` and
`max-lines` only post the sticky comment (no ticket), matching prior
per-repo behavior. Internally, each of these 7 jobs is just a
`setup-node-yarn` call followed by one call to the
`.github/actions/scan-with-report` composite action — see "Scan job
dedup" below.

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

Jobs: `setup`, `lint`, `typecheck`, `build`, `test`, `security-scan`,
`dependency-audit`. All plain pass/fail gates — no sticky PR comments, no
Linear ticket filing (unlike `develop-ci.yml`'s scan jobs). Two gates are
worth calling out explicitly because this shared workflow can't fully
enforce them on its own:

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

Jobs: the same `setup`/`lint`/`typecheck`/`build`/`test`/`security-scan`/
`dependency-audit` set as plain pass/fail gates, plus `deploy` (pushes to
`dokku_remote_url` using secret `DOKKU_DEPLOY_SSH_KEY`) and
`slack-notification` (posts the deploy result using secret
`SLACK_WEBHOOK_URL`), identical semantics to `main-ci.yml`'s `deploy`/
`slack-notification` — `deploy` runs only if every enabled gate job
actually passed (skipped-via-`enable_*: false` doesn't block it, but any
real failure or cancellation does) and is skipped entirely for
`is_dependabot`.

## Caching strategy

This section describes `setup-node-yarn`; `setup-node-pnpm` (LAB-1268,
`develop-node-ci.yml`'s `package_manager: pnpm` variant) mirrors the same
strategy one-for-one — a repo-local pnpm store cache (`.pnpm-store`, in
place of `.yarn/cache`) plus a `node_modules` cache keyed on
`pnpm-lock.yaml`'s hash instead of `yarn.lock`'s.

Every job used to do its own checkout + `setup-node` + cache-restore +
full `yarn install --frozen-lockfile` — up to ~12 redundant installs per PR
across the full job set, on top of two repos using incompatible cache key
conventions (flat `.yarn-cache` vs. Yarn Berry's `.yarn/cache` +
`.yarn/install-state.gz`, meaning the cache wasn't even shared across those
two repos' historical CI). This repo's workflows fixed that in two
generations:

**Generation 1 (superseded): shared `setup` job + artifact.** A single
`setup` job installed once and uploaded `node_modules` (+ `.next/cache`) as
a `deps-${{ github.run_id }}` build artifact; every other job downloaded it
via a `restore-deps` composite action instead of installing itself. This
avoided N redundant "resolve + link" costs per run, but every single run
*and* every job in it created its own fresh artifact upload/download
regardless of whether `yarn.lock` had actually changed — since artifacts
(unlike `actions/cache` entries) aren't deduped or LRU-evicted, this is what
was repeatedly blowing the account-wide Actions artifact storage quota
(LAB-1371) across every Node/web/mobile repo on this account, faster than
the 1-day artifact retention plus GitHub's 6–12h usage-recalculation delay
could drain it.

**Generation 2 (current): cache-only, keyed on the lockfile, not the run.**
`setup-node-yarn` (called directly by every job that needs deps — no
artifact fan-out) restores `node_modules` from an `actions/cache` entry
keyed on `${{ runner.os }}-node-modules-${{ hashFiles('yarn.lock') }}` and
only runs `yarn install --frozen-lockfile` itself on a miss:

1. `setup` runs first: checkout, enable Corepack, `actions/setup-node`,
   restore the Yarn cache (standardized on the Yarn Berry paths), restore
   or (on push-to-main only) write the `node_modules` cache — see
   "`node_modules` cache" below. All of the paths involved (Node version
   detection, the Yarn/node_modules cache dirs, the `yarn.lock` hash key)
   are qualified with the `working-directory` input, defaulting to `.` so
   this is a no-op for every existing root-level caller.
2. Every other job `needs: setup` (so the cache is already warm by the
   time they read it) and calls `setup-node-yarn` itself — directly for
   plain jobs (`ls-lint`, `a11y`, `design-system`, ...), or via
   `cached-script` for jobs that also wrap a script-specific incremental
   cache (`lint`, `typecheck`, `test`) — always with `cache-write: 'false'`,
   since only `setup`'s write should ever create a fresh entry.

Cache-write is deliberately split the same way it already was for the
script-specific caches: only the push-to-main workflow's `setup` job passes
`cache-write: 'true'`; every PR job, and every non-`setup` job even on
main, only ever reads. This means the *cache* is written once per actual
`yarn.lock` change (main only), not once per run — the fix the user asked
for directly.

**Known tradeoff, and it's intentional:** on a genuine cache miss (a
`yarn.lock` this account has never cached before — e.g. the very first run
after a dependency bump on a brand-new PR, before it's landed on main),
every job that needs deps runs its own full `yarn install
--frozen-lockfile` independently, since none of them persist what they
install. That's more redundant work than generation 1 paid on a miss, but
it's rare (most PRs don't touch the lockfile) and self-hosted runners don't
meter per-minute cost the way GitHub-hosted ones do — a better trade than
an artifact quota outage blocking every repo's CI account-wide.

If a repo ever needs a job that's genuinely independent of `setup` (rare —
none of the current jobs are), it's fine for that job to opt out of
`needs: setup` and install directly; the composite actions don't assume
they're the only way to get dependencies in place.

### `node_modules` cache

`setup-node-yarn` caches `node_modules` (+ `.next/cache` if present, + any
`extra-paths`; path list qualified with `working-directory`), keyed on
`${{ runner.os }}-node-modules-${{ hashFiles('yarn.lock') }}` with
`restore-keys` falling back to the nearest older entry for that OS. This is
the highest-value cache in this repo: even with a warm Yarn package cache,
`yarn install --frozen-lockfile` previously still paid the full
resolve/link cost on *every single run*, regardless of whether `yarn.lock`
had changed. On a cache hit, the install step is skipped entirely — except
when `extra_deps_paths`/`extra-paths` is set, in which case install always
reruns regardless of hit/miss: those are `postinstall`-generated outputs
(e.g. SDK codegen) that only exist after a real install ever regenerates
them, and their content can drift from causes the `yarn.lock` hash alone
wouldn't catch (e.g. a codegen script itself changing), so this repo
chooses to always regenerate them fresh rather than risk serving a stale
copy indefinitely off the lockfile-keyed cache.

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

### Cargo cache convergence (`develop-rust-ci.yml`)

`develop-rust-ci.yml` has no shared `setup` job or `main-*-ci.yml`
counterpart (see that workflow's own README section), so its `clippy`,
`test`, and `build` jobs' `actions/cache` blocks (`~/.cargo/registry` +
`~/.cargo/git` + `target`) now all share one key, `${{ runner.os }}-cargo-
${{ hashFiles('Cargo.lock') }}`, instead of three separate `cargo-clippy-`/
`cargo-test-`/`cargo-build-` namespaces. Those three jobs still run in
parallel and can't share a cache *within* the same run (GitHub only saves
a cache at job end, and only the first job to finish actually wins the
save — the rest no-op), but every subsequent run for an unchanged
`Cargo.lock` now hits one warm, shared cache instead of rebuilding
`target` from scratch in up to three separate jobs.

### Cache-to-main: read/write split

Software caches (the ones above, plus the pre-existing Yarn package cache)
change infrequently — there's no need for every PR run to write its own
copy. `setup-node-yarn`, `security-scan.yml`, and the `lint`/`typecheck`
cache steps in `develop-ci.yml`/`develop-node-ci.yml` all take a
`cache-write` input (`'false'`/`false` by default — read-only): when true,
the normal `actions/cache` action runs (restores *and* saves); when false,
only `actions/cache/restore` runs (restores, never writes a new entry).
GitHub Actions cache scoping already lets a PR branch read its base/
default branch's cache via an exact key match or `restore-keys`, so this
works naturally — a PR run just reads whatever `main` last wrote.

Only the push-to-main workflows write:

- `main-ci.yml`/`main-node-ci.yml` pass `cache-write: 'true'` to
  `setup-node-yarn` and use the full `actions/cache` action for their own
  `.eslintcache`/`tsconfig.tsbuildinfo` steps. `develop-ci.yml`/
  `develop-node-ci.yml` pass `'false'`/use `actions/cache/restore`.
- `security.yml` (this repo's own `security-scan.yml` caller) passes
  `cache-write: ${{ github.event_name == 'push' }}` — true only for its
  push-to-main trigger, false for its `pull_request`/`schedule` triggers.
- `develop-mobile-ci.yml` has **no** `main-*-ci.yml` counterpart in this
  repo, so it's exempt from the split entirely — every cache there
  (including its `node_modules` cache, via `cache-write: 'true'` to
  `setup-node-yarn`) stays a plain restore+save `actions/cache`, same as
  before this change.
- `develop-rust-ci.yml`'s converged cargo caches (above) are also exempt —
  no `main-*-ci.yml` exists for Rust in this repo at all, so there's no
  push-to-main run to designate as the writer.

Rationale: avoids cache-storage churn/eviction from every PR branch
writing its own short-lived copy of a cache that's about to be discarded
when the branch merges or closes, while still giving PR runs a warm cache
(populated only by `main`) instead of a cold one.

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
   duplicate was removed. `develop-ci.yml` has no group of its own for this
   reason — concurrency for PR runs is owned entirely by the caller instead
   (grouped per PR number, which the reusable workflow can't see from its own
   context anyway).
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

## Scan job dedup — `.github/actions/scan-with-report`

`develop-ci.yml`'s 7 scan jobs (`a11y`, `design-system`, `dead-code`,
`duplicate-code`, `run-e2e-tests`, `react-tech-debt`, `max-lines`) all
follow the same shape: run a yarn script that writes a markdown report,
post/update a sticky PR comment with that report regardless of outcome,
optionally file/comment-on a Linear ticket on failure, then fail the job if
the script failed. That's factored into
`.github/actions/scan-with-report/action.yml`, a composite action with
inputs:

- `script` (required) — yarn script to run.
- `report-file` (required) — markdown report path the script writes.
- `sticky-header` (required) — unique sticky-pull-request-comment header.
- `job-name` (required) — first arg to `scripts/file-linear-ticket.sh`
  (note `run-e2e-tests`'s `job-name` is `e2e`, not `run-e2e-tests`, matching
  prior behavior).
- `file-ticket` (boolean-as-string, default `'true'`) — set `'false'` for
  `react-tech-debt`/`max-lines`, which only get the sticky comment.
- `pr-number` / `pr-url` (string) — forwarded from the caller's inputs.
- `playwright` (boolean-as-string, default `'false'`) — set `'true'` for
  `a11y`/`run-e2e-tests` to install Playwright's chromium first.
- `linear-api-key` (string, default `''`) — composite actions can't see the
  caller's `secrets` context directly, so each job passes
  `secrets.LINEAR_API_KEY` in explicitly.

Each of the 7 scan jobs in `develop-ci.yml` now shrinks to its
`needs`/`runs-on`/`if`/`permissions` header, a `setup-node-yarn` call, and
one `scan-with-report` call. `scripts/file-linear-ticket.sh` is invoked with a
bare relative path (`bash scripts/file-linear-ticket.sh ...`), same as
before the extraction — this still resolves correctly because every caller
repo keeps its own copy of that script at `scripts/file-linear-ticket.sh`
(it's not part of labone-actions' own checkout at runtime; reusable
workflows and the composite actions they call run with the *caller's*
repo checked out as the working directory, not labone-actions' own).

The `continue-on-error` + `steps.scan.outcome == 'failure'` + final `exit 1`
pattern still works correctly inside a composite action: composite action
steps execute in the same job/runner context as the caller, with their own
scoped `steps` context, so a step failing (via that final `exit 1`) still
fails the containing job exactly as it did when the steps were written
inline. Verified with `actionlint`.

`main-ci.yml`'s equivalent jobs (no sticky comments, no ticket filing) are
already minimal 2-step bodies and were left as-is — not worth
composite-izing further.

## Tech debt metrics report — `.github/actions/tech-debt-report`

`develop-ci.yml` and `develop-mobile-ci.yml` both have an opt-in `tech-debt`
job (`enable_tech_debt`, default **false** — see each workflow's own
section above) that greps the caller's tracked `.ts`/`.tsx` tree for seven
tech-debt signals and posts the totals as a sticky PR comment, updated in
place on every push rather than posted fresh each time (same
`marocchino/sticky-pull-request-comment@v3` action `scan-with-report`
already uses). Unlike every scan job above, it never fails the job — it's a
metrics report, not a gate — and it never runs a yarn script or needs
`node_modules`, so the job just does a plain `actions/checkout@v7` before
calling the action (no `setup-node-yarn` step).

Metrics (repo-wide totals, not diff-only counts):

- `useEffect` call sites (`useEffect(`)
- React Native's built-in `Animated.*` usage (not third-party animation
  libraries — a known, accepted imprecision of a plain `Animated\.` grep,
  see the action's `count-metrics.sh`)
- `eslint-disable`/`eslint-disable-next-line` suppressions
- `@ts-ignore`/`@ts-expect-error` suppressions
- `any` usage (`: any`, `as any`, `@ts-nocheck` files, summed)
- `TODO`/`FIXME`/`HACK` comments
- `console.log` calls

Every file under `node_modules`, `.next`, `dist`, `build`, `coverage`,
`.expo`, and `.git` is excluded from the count.

`.github/actions/tech-debt-report/action.yml` inputs:

- `working-directory` (string, default `.`) — same convention as every
  other action in this repo.
- `pr-number` (required) — forwarded from the caller workflow's
  `pr_number` input, for the sticky comment.
- `base-sha` (string, default `''`) — forwarded from the caller workflow's
  `pr_base_sha` input (`github.event.pull_request.base.sha`). When set,
  the action fetches that SHA and checks it out into a throwaway `git
  worktree` (not a second full checkout) to compute the same metrics
  there, adding a "Δ vs. base" column to the report. A fetch/worktree
  failure (e.g. an unreachable SHA) degrades to current-totals-only
  instead of failing the job — this is a nice-to-have, not something worth
  blocking a PR over.
- `sticky-header` (string, default `tech-debt-report`) — unique
  sticky-pull-request-comment header, same convention as
  `scan-with-report`'s `sticky-header` input.

The actual counting logic lives in one place,
`.github/actions/tech-debt-report/count-metrics.sh <dir>`, invoked by both
the "current tree" and "base branch worktree" steps so it isn't duplicated
across two `run:` blocks.

To opt a repo in, set `enable_tech_debt: true` on the `develop-ci.yml`/
`develop-mobile-ci.yml` call (see `templates/web-pr.yml`/
`templates/mobile-pr.yml`) and, for the delta column, also pass
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
  install via the `setup-gdtoolkit` composite action.
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
cache-restore stage — Python dependency management isn't uniform
across consumer repos (`pyproject.toml`, `requirements.txt`, or neither), and
`pip install ruff` is cheap enough that every job just installs what it
needs directly. `workflow_call` inputs:

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

Jobs: `lint`, `test`, `security-scan`, `dependency-audit` — every job is a
plain pass/fail gate (no sticky PR comments, no Linear ticket filing), same
philosophy as `develop-node-ci.yml`. Repo-specific checks (e.g. a
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
fan out from. The `clippy`/`test`/`build` jobs' cache blocks share one
converged key rather than three separate namespaces — see "Caching
strategy" → "Cargo cache convergence" above. `workflow_call` inputs:

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

Jobs: `fmt`, `clippy`, `test`, `build`, `dead-code`, `duplicate-code`,
`file-size`, `security-scan`, `dependency-audit`. `fmt`/`clippy`/`test` and
every optional scan job follow the same continue-on-error + sticky PR
comment (scans only) + `file-linear-ticket.sh` + explicit `exit 1` pattern
`godot-develop-ci.yml` established, since both known callers already file
Linear tickets on these failures today — unlike `develop-node-ci.yml`/
`develop-python-ci.yml`, which are plain pass/fail gates with no ticket
filing. Repo-specific release/build/publish machinery (version bump,
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

Jobs: `setup`, `lint`, `ls-lint`, `typecheck`, `test`, `a11y`,
`design-system`, `dead-code`, `duplicate-code`, `security-scan`,
`dependency-audit`, `tech-debt` (opt-in). `lint`/`typecheck` are plain, always-on pass/fail gates
(no dependabot skip — a broken lint/type error is exactly what a dependency
bump can cause); the scan jobs follow the same continue-on-error + sticky
PR comment + `file-linear-ticket.sh` + explicit `exit 1` pattern all known
callers already use. Repo-specific release/publish machinery (EAS build,
OTA `publish-update.yml`, version bump) stays in the caller's own
workflow files — this workflow only covers the common PR-time shape.

Caller example:

```yaml
name: Develop CI
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  ci:
    uses: PeterChauYEG/labone-actions/.github/workflows/develop-mobile-ci.yml@main
    secrets: inherit
    with:
      pr_number: ${{ github.event.pull_request.number }}
      pr_url: ${{ github.event.pull_request.html_url }}
      is_dependabot: ${{ github.event.pull_request.user.login == 'dependabot[bot]' }}
```

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
schedule (or `workflow_dispatch`), opens+auto-merges a PR, tags a release,
and fakes `lint`/`ls-lint`/`typecheck`/`build`/`test` check-runs as skipped
(hardcoded — both existing callers use exactly this same 5-name set, so an
input wasn't added for it; add one later if a caller ever needs a different
set). **Depends on the caller repo providing its own
`./scripts/bump-version.sh <new-version>`** — that script actually rewrites
version strings in the repo's files, which varies per repo, so it is
deliberately not centralized here. Call it with `secrets: inherit`; see the
caller example above.
