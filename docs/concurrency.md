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
2. **The gha-runner host's job-concurrency cap.** This repo's workflows all
   target `runs-on: [self-hosted, catfood, ...]`, which runs on the
   **ephemeral Docker-dispatch system** (`gha-runner-docker`'s
   `webhook-server.py` + `dispatch-one.sh`), not the ARC/k3s scale-set
   pilot — completely outside GitHub Actions' own YAML. There is no
   per-repo concurrency cap (`REPO_CI_CONCURRENCY`-style env var, and no
   `ci-semaphore-acquire.sh`/`ci-semaphore-release.sh` — an earlier version
   of this doc described those and they don't exist): concurrency is capped
   globally (`globalMaxConcurrent` in the runner host's `.env`) and per
   resolved image/flavor only, both via `repos.json` — see the `gha-runners`
   skill's `references/commands.md` and `references/capacity.md` for the
   current mechanism and how to read/tune it. Don't try to "fix" any
   observed queueing by adding more `concurrency:` groups here; it's a
   different, correctly-functioning layer, and stacking a YAML-level group
   on top of it is exactly the mistake described in point 1. Treat the
   `gha-runners` skill as the source of truth for the live cap values —
   don't duplicate the actual numbers here, they drift independently of
   this repo.
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

