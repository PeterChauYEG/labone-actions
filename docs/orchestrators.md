# Orchestrator workflows — design rationale

Full history and rationale behind the type-specific orchestrator workflows (LAB-2096). See the main [README](../README.md) for the quick-start: which orchestrator to use and the `templates/` table.


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
