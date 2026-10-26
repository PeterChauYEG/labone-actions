# Caching strategy

See the main [README](../README.md) for the quick-reference workflow table.


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
job under concurrent PR load — see [docs/concurrency.md](concurrency.md), point 3 for the
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

Every other `trivy-scan` caller (every `secret-scan`/`security-scan` job
across `develop-*-ci.yml`/`main-*-ci.yml`) leaves `cache-db` at its default
`'false'` and goes through trivy-action directly instead, with no explicit
`cache:` override of its own. trivy-action's `cache` input still defaults
to `'true'` there — fine for a `vuln` scan, but a `secret`-only scan never
touches the vulnerability DB at all, so letting that default stand meant
every secret-scan run paid a wasted date-keyed `actions/cache` restore
*and* save of a multi-hundred-MB DB nothing used, with wall-clock entirely
at the mercy of that run's cache-service latency — the actual cause of
secret-scan's ~53s-900s+ duration swings (LAB-5026), unrelated to repo
size or git history depth. `trivy-scan/action.yml` now only passes
`cache: true` (and omits `TRIVY_SKIP_DB_UPDATE`) to that step when
`scanners` actually includes `vuln`; a `secret`-only scan skips the DB
cache round-trip entirely.

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
already relies on (see `version-bump.yml`/`dependabot-automerge.yml`) —
cache list/delete is a
repo-scoped `gh` permission that the ephemeral per-run `GITHUB_TOKEN` can't
reach for any repo but the one currently running. Logs a per-repo summary
(caches deleted, bytes reclaimed) to `$GITHUB_STEP_SUMMARY`.

