# Concurrency

See the main [README](../README.md) for the quick-reference workflow table.


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
   [docs/caching.md](caching.md) — fewer simultaneous installs, and each one
   cheaper in peak memory.

