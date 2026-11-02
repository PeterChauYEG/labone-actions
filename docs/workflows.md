# Per-workflow inputs and jobs reference

Detailed `workflow_call` inputs, job lists, and gating behavior for every reusable workflow in this repo. See the main [README](../README.md) for the quick-reference table and caller setup snippets.

## `develop-ci.yml` — inputs and jobs

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
  unlike every other `enable_*` above — see [docs/reporting.md](reporting.md)
  ("Tech debt metrics report").
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
see [docs/reporting.md](reporting.md) ("Tech debt metrics report")), and `danger-comment`. All nine
reporting jobs (`peer-deps`, `security-scan`, `secret-scan`,
`design-system`, `dead-code`, `duplicate-code`, `react-tech-debt`,
`max-lines`, `tech-debt`) feed `danger-comment`, which posts ONE combined
sticky PR comment and files/comments-on a Linear ticket (via
`scripts/file-linear-ticket.sh`) for whichever of them failed — see
[docs/reporting.md](reporting.md). Internally, each of the five scan jobs
(`design-system`, `dead-code`, `duplicate-code`, `react-tech-debt`,
`max-lines`) is just a `setup-node-yarn` call followed by one call to the
`.github/actions/scan-with-report` composite action — see
[docs/reporting.md](reporting.md) ("Scan job dedup").

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

## `main-ci.yml` — inputs and jobs

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

## `develop-node-ci.yml` — inputs and jobs

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
  `danger-comment` aggregator job (see [docs/reporting.md](reporting.md)), but
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
[docs/reporting.md](reporting.md). `security-scan`/`secret-scan`/
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

## `main-node-ci.yml` — inputs and jobs

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
`dead-code` (off by default), `coverage-badge` (off by default,
`enable_coverage_badge`, see below) and `deploy` (pushes to `dokku_remote_url`
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

This workflow also has `enable_coverage_badge` (boolean, default
**`false`** — opt-in, same rationale as `enable_dead_code`): runs an
optional `coverage-badge` job that re-runs `<package manager>
test:coverage` a SECOND time with `--coverageReporters=json-summary`
appended (deliberately a separate run from the `test` job above, not a
reuse of its artifact — overriding `test`'s own `test_script_args`
reporters via a shared CLI flag would silently drop whatever reporter(s)
that caller's `enable_coverage_upload`/Codecov step actually needs, e.g.
`lcov`), reads the overall statement-coverage percentage out of
`coverage/coverage-summary.json`, and hands both to the
`.github/actions/coverage-badge` composite action, which:

- updates the caller's `README.md` coverage badge via `npx
  istanbul-badges-readme` (requires the README to already contain at least
  one of its placeholder hashes, e.g. `![Statements](#statements#)` — a
  per-repo follow-up once this capability exists, not something enabling
  this input does for you);
- writes/updates a machine-readable `coverage/coverage-badge.json` (`{
  "statements": <number>, "updatedAt": "<ISO8601>" }`) — this file, not the
  badge image, is the real contract for a downstream consumer (e.g.
  company-system's maintenance-ticket scanner) that needs "current
  coverage %" without parsing badge markdown/SVG. The composite action
  skips rewriting this file (and its `updatedAt`) when the percentage is
  unchanged from the previously-committed value, specifically so a stable
  coverage number doesn't force a commit on every single merge, and
  `git add -f`s it specifically since `coverage/` is gitignored in
  virtually every Node repo - a plain `git add` would be refused there;
- commits + pushes both files straight to `main` (`chore: update coverage
  badge [skip ci]`) if either changed, authenticating the push with
  `secrets.GH_PAT` (the default checkout's `GITHUB_TOKEN` can't push to a
  protected branch — same requirement as `version-bump.yml`). The
  `[skip ci]` marker is what stops this commit from re-triggering this same
  push-triggered workflow.

Never fails the job on a low (or any) coverage number — this input only
makes the number visible (README) and machine-readable
(`coverage/coverage-badge.json`); enforcing an 80%-style target is
explicitly out of scope for this repo (a separate consumer's job). Also
deliberately absent from `develop-node-ci.yml` — coverage only matters for
what's actually merged to `main`, and a badge-update commit on every PR
branch would be noise nobody wants. Node/Jest only today; Python/Rust
variants are a follow-up, not blocked on by this capability existing.

**`required-checks` (LAB-2103):** same aggregator pattern as
`develop-node-ci.yml`'s job (see that section for the full rationale),
scoped to this file's actual job list - `needs: [lint, typecheck, build,
test]` (this file has no `security-scan`/`dependency-audit` jobs at all,
unlike `develop-node-ci.yml`, so there's nothing advisory to exclude
besides `changes`/`setup`/`coverage-badge` - the latter, like `dead-code`,
stays advisory-only and is deliberately never a dependency of either
`required-checks` or `deploy`). `deploy`/`slack-notification` are also
excluded - `deploy` already has its own well-established
`needs.*.result` failure/cancelled check (see that job's own comment
above), so folding it into `required-checks` too would be redundant.
Since this workflow only runs on `push` to `main`, not `pull_request`,
branch protection's required-status-checks mechanism never actually gates
it - this job exists here for parity with `develop-node-ci.yml` and as a
single visible pass/fail signal on the run summary, not because any caller
repo's branch protection currently (or will) point at it.

**`file-ci-failure-ticket`:** files (or comments on) a Linear ticket when
`required-checks` or `deploy` fails, via the same `file-ci-failure-ticket.sh`
script `ci-failure-monitor.yml`'s `file-linear-tickets` job uses (see that
section below for the dedup mechanism). Opt-out via `enable_ci_failure_ticket`
(boolean, default `true` — existing behavior, unchanged for every current
caller); set to `false` for a repo that's been deliberately dropped from
company-system's project registry but is still actively pushed to - its CI
failures would otherwise keep filing tickets that can never actually be
dispatched (the repo isn't in the registry, so `resolveRepoPath` can't route
to it), accumulating as dead weight in Linear.


## `ci-failure-monitor.yml`

PR-time CI failures get one deduped-per-PR-per-job Linear ticket each, via
the `file-linear-tickets` job described below. A broken **main** branch is a
different kind of problem — it blocks every subsequent deploy for everyone,
not just one PR author — so it gets its own mechanism: one Urgent (P0)
ticket per repo, filed the moment main-branch CI goes red, and commented on
(never duplicated) for as long as main stays broken.

This can't be a job inside `main-*-ci.yml`/`develop-*-ci.yml` themselves: a
`workflow_run` trigger only fires once the workflow it's watching has
already completed, so the monitor has to be a separate workflow that reacts
to that completion event. Caller repos wire it up with a thin wrapper:

```yaml
name: CI Monitor

on:
  workflow_run:
    workflows: ["Develop CI", "Main CI"]  # this repo's actual workflow names
    types: [completed]
    branches: [main]

permissions:
  actions: read
  contents: read

jobs:
  monitor:
    uses: PeterChauYEG/labone-actions/.github/workflows/ci-failure-monitor.yml@main
    secrets: inherit
```

`workflows:` should list every workflow in the repo that can run on `main`
(both PR-merge-triggered and push-triggered ones, if the repo has both) —
`ci-failure-monitor.yml` only fires the ticket for a `conclusion: failure`
run, so listing an extra workflow that happens to be healthy costs nothing.
See `.github/workflows/ci-monitor.yml` in this repo for a working example
(watching its own `ci.yml`).

Ticket dedup here is a plain per-repo title match (`🔴 CI failing on main:
<repo>`) rather than `file-linear-ticket.sh`'s title-prefix/job-scoped
search — deliberately coarser, since the point is one open ticket per
broken repo regardless of which job or workflow broke it. Once that ticket
is resolved (main is green again and someone marks it done), the next
failure files a fresh one. Required secret: `LINEAR_API_KEY` (same secret
`file-linear-ticket.sh` already uses).

**mecha-industries org repos**: this reusable workflow can't be called
cross-org (`PeterChauYEG/labone-actions` is a personal-account repo; org
policy blocks depending on it, same reason those repos already inline
`develop-*-ci.yml`'s `file-linear-tickets` job instead of calling it — see
any mecha-industries repo's `develop.yml` header comment). Those repos
instead carry a local, inlined equivalent (own script + own job in
`main.yml`) following this same design.


## `security-scan.yml`

Reusable, `workflow_call` inputs `scan-ref` (string, default `.`),
`trivyignores` (string, default `''`), and `cache-write` (boolean, default
`false`), single `trivy` job. Call it directly with `secrets: inherit`.
`cache-write` controls the Trivy DB cache's read-only-vs-write split — see
[docs/caching.md](caching.md) — "Trivy DB cache" / "Cache-to-main: read/write split"
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
[docs/reporting.md](reporting.md). Repo-specific checks (e.g. a
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
their own job-scoped key rather than one shared across jobs — see [docs/caching.md](caching.md) ("Cargo cache scoping"). `workflow_call` inputs:

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
failed — see [docs/reporting.md](reporting.md). `fmt`/`clippy`/`test`/
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
  [docs/reporting.md](reporting.md) ("Tech debt metrics report").

Jobs: `setup`, `lint`, `ls-lint`, `typecheck`, `test`, `peer-deps`, `a11y`,
`design-system`, `dead-code`, `duplicate-code`, `security-scan`,
`secret-scan`, `dependency-audit`, `tech-debt` (opt-in), `danger-comment`.
`lint`/`typecheck` are plain, always-on pass/fail gates (no dependabot skip
— a broken lint/type error is exactly what a dependency bump can cause).
`peer-deps`, `a11y`, `design-system`, `dead-code`, `duplicate-code`,
`security-scan`, `secret-scan`, `dependency-audit`, and `tech-debt` all
feed `danger-comment`, which posts ONE combined sticky PR comment and
files/comments-on a Linear ticket (via `scripts/file-linear-ticket.sh`) for
whichever of them failed — see [docs/reporting.md](reporting.md).
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
