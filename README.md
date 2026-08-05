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
| `.github/workflows/develop-node-ci.yml` | `pull_request` | PR-time quality gate set (lint, typecheck, test, build, security-scan, dependency-audit) as plain pass/fail checks. For yarn/Node/NestJS **backend service** repos. |
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
  `setup-node-yarn`/`restore-deps` (install, Node version detection, yarn
  cache path, lockfile hash key, `node_modules` archive location), every
  `yarn <script>` step (via the step's `working-directory:` property), and
  `scan-with-report` (script working directory + report-file path prefix).
- `pr_number` (number) — for concurrency grouping + Linear ticket linking.
- `pr_url` (string) — for Linear ticket linking.
- `is_dependabot` (boolean) — caller-computed; skips every job below
  `lint`/`typecheck`/`build`.
- `enable_ls_lint`, `enable_build`, `enable_test`, `enable_a11y`,
  `enable_design_system`, `enable_dead_code`, `enable_duplicate_code`,
  `enable_e2e`, `enable_react_tech_debt`, `enable_max_lines` (boolean) —
  turn a job off if your repo has no matching yarn script.
- `extra_deps_paths` (string, default `''`) — space-separated list of
  additional paths (relative to `working-directory`) to carry from `setup`
  into every downstream job, beyond `node_modules`/`.next/cache`. Needed if
  your repo has a `postinstall` script that writes gitignored generated
  code outside `node_modules` (e.g. an SDK codegen step writing to
  `src/generated/`) — without this, only the `setup` job sees that
  directory and every job restoring from the deps artifact fails with
  "Cannot find module". E.g. `extra_deps_paths: 'src/generated'`.

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
`react-tech-debt`, `max-lines`. Scan jobs (`a11y`, `design-system`,
`dead-code`, `duplicate-code`, `run-e2e-tests`) post a sticky PR comment on
every run and file/comment-on a Linear ticket (via
`scripts/file-linear-ticket.sh`) when they fail; `react-tech-debt` and
`max-lines` only post the sticky comment (no ticket), matching prior
per-repo behavior. Internally, each of these 7 jobs is just a
`restore-deps` call followed by one call to the
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
  `develop-ci.yml`, threaded through to `setup-node-yarn`/`restore-deps`
  and every `yarn <script>` step.
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
`yarn npm audit` (this repo and its Node/NestJS callers are on Yarn Berry)
as a hard gate with no severity floor — any known vulnerability fails the
job.

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
   All of the paths involved (Node version detection, the Yarn cache dirs,
   the `yarn.lock` hash key, and the `node_modules`/`.next/cache` archive
   paths) are qualified with the `working-directory` input, defaulting to
   `.` so this is a no-op for every existing root-level caller.
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
`needs`/`runs-on`/`if`/`permissions` header, a `restore-deps` call, and one
`scan-with-report` call. `scripts/file-linear-ticket.sh` is invoked with a
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

## `security-scan.yml`

Reusable, `workflow_call` inputs `scan-ref` (string, default `.`) and
`trivyignores` (string, default `''`), single `trivy` job. Call it directly
with `secrets: inherit`.

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
restore-deps artifact stage — Python dependency management isn't uniform
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
Unlike `develop-node-ci.yml`, there's no shared `setup` + restore-deps
artifact stage — cargo's own registry/git/target caching (via
`actions/cache`, keyed on `Cargo.lock`'s hash) already avoids redundant
network fetches per job without needing a single upstream install step to
fan out from. `workflow_call` inputs:

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
  on.
- `enable_duplicate_code` (boolean, default `false`) /
  `duplicate_code_script` (string, default
  `scripts/ci/duplicate-code-scan.sh`) / `cargo_dupes_version` (string,
  default `0.2.1`) — a cargo-dupes duplicate-code scan. Off by default —
  only one of the two known callers has this today.
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
`setup` + artifact-restore caching strategy as `develop-node-ci.yml` (both
are Yarn Berry — reuses the same `setup-node-yarn`/`restore-deps` composite
actions as-is), but a mobile-app-shaped job set: `lint`/`ls-lint`/
`typecheck`/`test` plus the web-style `a11y`/`design-system`/`dead-code`/
`duplicate-code` scans all three known callers already run (closer in
spirit to `develop-ci.yml`'s Next.js job set than `develop-node-ci.yml`'s
plain NestJS one). `workflow_call` inputs:

- `working-directory` (string, default `.`) — directory the Expo app lives
  in, for monorepo callers.
- `pr_number` (number, default `0`) / `pr_url` (string, default `''`) —
  same reasoning as `develop-rust-ci.yml`.
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

Jobs: `setup`, `lint`, `ls-lint`, `typecheck`, `test`, `a11y`,
`design-system`, `dead-code`, `duplicate-code`, `security-scan`,
`dependency-audit`. `lint`/`typecheck` are plain, always-on pass/fail gates
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
