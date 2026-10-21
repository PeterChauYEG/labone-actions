# Aggregated reporting and scan internals

How `danger-comment`, `scan-with-report`, and the tech-debt metrics reports work internally. See the main [README](../README.md) for the quick-reference workflow table.

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

