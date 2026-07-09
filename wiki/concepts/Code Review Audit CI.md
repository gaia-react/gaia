---
type: concept
status: active
created: 2026-05-08
updated: 2026-07-03
tags: [concept, ci, audit, claude]
---

# Code Review Audit CI

A GitHub Actions pre-merge gate that runs the [[Code Review Audit Agent]] against every PR in repos where it is installed. The workflow installs on demand via `/setup-gaia` (alongside the cron workflows); it is not shipped by default, so adopters who have not enabled GAIA CI do not carry `.github/workflows/code-review-audit.yml`. Its presence in a repo signals that CI is configured to audit. Once installed, the workflow exposes a stable check named `code-review-audit` that branch protection on `main` requires before merge.

<!-- gaia:maintainer-only:start -->
The maintainer repo keeps it in-tree as the live gate.
<!-- gaia:maintainer-only:end -->

The workflow authenticates via whichever secret `/setup-gaia` wires: it always wires both `claude_code_oauth_token` and `anthropic_api_key`, so a repo using `ANTHROPIC_API_KEY` instead of `CLAUDE_CODE_OAUTH_TOKEN` (or vice versa) authenticates without any extra configuration. Before asking which token type to provision, `/setup-gaia` checks whether a `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` secret is already reachable by the repo, at repo scope or via an org-wide secret, and reuses it instead of provisioning a new one, so a repo inside an org that sets the token org-wide never needs a repo-level copy.

The gate has two complementary signals: the existing local marker file at `.gaia/local/audit/<sha>.ok` (gates `gh pr merge` on the contributor's machine, see [[PR Merge Workflow]]) and the `GAIA-Audit:` commit trailer (travels with the commit so CI can recognize an already-audited tree and skip its own run).

## Trigger

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, labeled, unlabeled]
```

The `labeled` / `unlabeled` events are present so flipping the `gate_label` knob on an existing PR re-evaluates the gate.

## Skip rule (GAIA-Audit trailer)

The workflow's first agent-invocation step is preceded by a `Check audit trailer` step that runs `.github/audit/check-trailer.sh`. The helper:

1. Reads `cur_version` from `.gaia/VERSION` and `cur_tree` from `git rev-parse HEAD^{tree}`.
2. Parses trailers on the PR HEAD via `git interpret-trailers --parse`.
3. Matches each trailer line against `^GAIA-Audit:[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9a-f]{40})[[:space:]]*$`.
4. If any line's version equals `cur_version` AND tree-sha equals `cur_tree`, emits `skip=true` and the workflow short-circuits the agent invocation while still reporting `code-review-audit` as a green check.

Version mismatch (a newer GAIA release shipped) and tree mismatch (HEAD amended after the trailer was written) both invalidate the stamp automatically. Only the PR-HEAD commit's trailers are inspected; stale trailers in earlier commits on the branch do not satisfy the gate.

The trailer is written by `.claude/hooks/audit-stamp-trailer.sh` at the end of a clean local run of the audit agent. Stamp placement is automatic: amend on un-pushed HEADs, an empty `chore: code review audit passed` commit on already-pushed HEADs (never silently rewriting published history), and amend on the audit's own self-heal commits regardless of push state. The frozen trailer format and skip decision live in `.github/audit/check-trailer.sh`; the stamp placement rule lives in `.claude/hooks/audit-stamp-trailer.sh`.

## Skip rule (chore-deps PRs)

PRs whose title starts with `chore(deps):` or `chore(deps-dev):` skip the audit entirely. These come from the `/update-deps` wrapper, which runs the full quality gate (`pnpm typecheck`, `pnpm lint`, `pnpm test`, `pnpm pw`, `pnpm build`) locally before pushing; the local pass is equivalent to the audit's CI signal for dep-only changes. The workflow's `Check chore-deps title` step reads `github.event.pull_request.title`, sets `skip=true` when the prefix matches, and the gate cascades through the rest of the steps. The terminal `Status: skipped (chore-deps PR)` step posts the explanation and reports `code-review-audit` as a green skipped check.

Other `chore:` prefixes (e.g. `chore: bump version`, `chore: tidy imports`) still run the audit; only the dep-specific narrowing skips. `tests.yml` and `chromatic.yml` carry the same skip pattern so all three required checks short-circuit on chore-deps PRs.

## Skip rule (no auditable delta)

The `Check for source-code changes` step diffs only the **un-audited delta**: `<audit-base>...HEAD`, where `<audit-base>` is the most recent ancestor that already passed a clean audit (resolved by `.github/audit/resolve-audit-base.sh`, the same base the agent reviews). When that delta touches no audit-relevant files (TS/TSX/CSS under `app/`, tests, `.storybook`, workflow files, or root-level build/lint/test configs), the gate short-circuits and reports `code-review-audit` green. Because the base is the last clean-audited commit, a PR that audits clean and then adds a prose-only commit (wiki, CHANGELOG, instruction files) reviews an empty auditable delta and skips; it does not re-run on a tree whose code was already cleared. With no audited ancestor the base is `origin/main`, so the delta is the full PR diff and first-audit behavior is unchanged.

On this skip path the `Write GAIA-Audit commit status (out-of-scope skip)` step stamps a `GAIA-Audit` commit status (`<version> <tree>`) on HEAD, mirroring the full-audit path's status. An out-of-scope PR (CLI-only, docs-only, wiki-only, `.claude`-only) therefore satisfies the [[PR Merge Workflow]] merge hook with no local audit run; the agent would find nothing in scope to review. The description carries HEAD's own tree, since the hook checks tree equality against the content being merged.

The stamp fires on the out-of-scope reason only. The already-audited reason (the `GAIA-Audit:` trailer already matches, so a status is redundant) and the workflow-self-modification reason (auto-approving a change to the audit gate itself would be a security hole) do not stamp. The `has_source == 'false'` condition structurally enforces this: both other reasons require `has_source == 'true'`. A self-modifying PR (including one editing `code-review-audit.yml`) gets no auto-stamp and still needs a local marker to merge.

## Workflow refresh on /update-gaia

The installed `code-review-audit.yml` is not synced by `/update-gaia`'s manifest walk; it tracks its own template. When an update finds the installed workflow stale, `/update-gaia` refreshes it **inside the update PR** via a 3-way classify (`gaia setup-ci check-audit-drift --baseline <prior-template> --latest <new-template>`), overwriting only when the installed file is an un-customized copy of the prior release's template. Adopter customizations classify as `conflict` and are never clobbered; the workflow is adopter-tunable (see [[Update Workflow]] for the full verdict table).

The refresh is deliberately self-modifying, and that is the point. A GAIA-update PR whose payload changes auditable files (a dependency or config bump making `has_source=true`) would otherwise run a **full** audit under the **stale** workflow, which cannot earn a clean stamp, then need a separate manual `/setup-gaia` commit. Landing the refresh in the same PR collapses both into one expected self-mod-skip: the `Check workflow self-modification` step trips on the changed `code-review-audit.yml`, the agent never runs, and the terminal `Status: skipped (workflow self-modification)` step reports green.

This is a UX/ordering cleanup, not a clean-stamp path. The self-mod-skip stamps no `GAIA-Audit` status (auto-approving a change to the audit gate would be a security hole). When the re-render is verbatim (the installed workflow's bytes equal the bundled `code-review-audit.yml.tmpl`), the merge hook's self-mod-only bypass clears the update PR locally with no audit run; the changed bytes are GAIA's own template, not adopter code, so there is nothing to review. The out-of-scope bypass cannot clear it (the workflow path is in scope), so this dedicated bypass is what makes the verbatim re-render mergeable. If the installed workflow carries adopter customizations (the re-render diverges from the template) or the PR touches another in-scope path, the bypass fail-closes and the PR merges on a local audit marker / `GAIA-Audit:` trailer instead. See [[PR Merge Workflow]]. Earning a CI stamp would require landing the workflow refresh on `main` in a separate PR merged before the payload, which is not worth it for a tooling-only update.

## Clean audit, no push

A genuinely-clean audit that produces no self-heal commits and no empty trailer commit leaves the `push-fixes` step with neither `pushed` nor `marker_only` set. Without intervention, HEAD carries no `GAIA-Audit` status and the merge hook blocks the merge even though the audit passed. The same gap opens when the audit is clean but its only tree delta is a **refused** self-heal (see [[#Self-heal staging guards]]): the staged diff landed on an off-limits surface (`.claude/**`, `.specify/**`, `wiki/**`) or exceeded ten files. `refused` means the fix was off-limits to auto-apply, not that the audit failed or the tree is dirty, so it does not gate this stamp either.

The `Write GAIA-Audit commit status (clean, no push)` step closes this gap: it stamps the `GAIA-Audit` commit status directly on the current PR HEAD with no empty commit, covering both the no-delta case and the refused-self-heal case. A proven-clean guard prevents false passes: the audit agent writes `.gaia/local/audit/<HEAD>.ok` only on a clean pass (no Critical Issues, all Important Issues addressed, all Suggestions resolved). The step checks for this marker before stamping; a dirty audit that pushed nothing has no marker and receives no status, keeping the merge blocked until the audit clears.

This is the audit's instance of the cross-workflow mechanism in [[Incremental CI Skipping]].

## Progress breadcrumbs

The agent's own SDK output is not surfaced in the public Actions log: `claude-code-action` does not echo tool results unless explicitly enabled, and the workflow leaves that off (it passes only `--max-turns`, `--allowedTools`, and `--verbose` in `claude_args`). This is deliberate: on a public repo the Actions log is world-readable, so echoing tool results that may contain secrets is unsafe.

To provide a public-safe, post-hoc view of audit progress, the agent writes a curated per-phase breadcrumb line to `.gaia/local/audit/progress.log` (runner-local, gitignored; the same directory as the `<sha>.ok` clean marker) via its `Write`/`Edit` tool. Each line is a phase label plus integer counts only: no code, no file contents, no raw tool output, no secrets. These writes are best-effort: a write failure never blocks or fails the audit.

A trailing workflow step (`Print audit progress breadcrumbs`) reads that file after the agent step completes and prints it into `$GITHUB_STEP_SUMMARY`. Its gate mirrors the agent step's gate exactly (gate label present, source changes present, no workflow self-modification, no matching trailer), so breadcrumbs surface whenever the audit ran. Partial breadcrumbs appear even when the audit aborts due to max-turns or an SDK error. The step always exits successfully, so it never affects the required `code-review-audit` check status.

The agent itself cannot write directly to the runner log because its `Bash` tool is captured by the SDK and bare `echo`/`cat` commands are not in the workflow `allowedTools` globs. The progress file plus trailing print step is the split that makes runner-log output possible.

Five phases emit a breadcrumb, in run order:

| # | Phase label | Emitted when |
|---|---|---|
| 1 | `scope resolved` | Changed-file list resolved against the incremental base, before dispatch |
| 2 | `oracles done` | Parallel oracle dispatch returns (react-doctor, pnpm knip, pnpm audit, rule subagents) |
| 3 | `holistic review done` | Cross-cutting review produces candidate findings, before the adversarial pass |
| 4 | `adversarial verify done` | Finding Proof Gate adversarial refuter pass completes |
| 5 | `report stamped` | Audit-marker decision complete: marker written or not, self-heal applied or not |

## Adopter knobs

The adopter-tunable knobs live at `.gaia/audit-ci.yml`. The workflow reads the file at job start via `.gaia/scripts/read-audit-ci-config.sh`; missing file or missing keys fall back to documented defaults.

| Knob                  | Default              | Purpose                                                                                                                                                                                                                                                                                                     |
| --------------------- | -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gate_label`          | `null`               | Run the audit only when the PR carries this label. `null` runs on every PR. Maintainer recommendation: leave `null` until the audit is stable in CI; flip to `ready-for-review` once it is.                                                                                                                 |
| `budget_seconds`      | `1800`               | Hard wall-clock budget for the audit invocation. The workflow times out the agent step at this value and reports `audit aborted: budget` rather than failing red.                                                                                                                                           |
| `max_turns`           | `30`                 | Maximum fix turns the agent is allowed inside CI. Maps to `claude_args`'s `--max-turns`. Lower = cheaper. Higher = more chance to self-heal. `30` is the script fallback when the key is missing; the bundled `.gaia/audit-ci.yml` ships `60`.                                                                |
| `push_fixes`          | `true`               | Whether the agent may push self-heal commits to the PR branch. Set `false` to make the audit advisory-only (it comments findings but does not push).                                                                                                                                                        |
| `retrigger_workflows` | `[Chromatic, Tests]` | Workflows the audit re-dispatches against the PR branch after a self-heal push (see [[#Self-heal re-trigger]]). Each entry is the workflow's `name:` field, not the filename. Workflows listed must declare `workflow_dispatch:` in their triggers; the GAIA template's `chromatic.yml` and `tests.yml` do. |
| `default_mode`        | `ci`                 | Per-author fallback audit mode when no `audit_authors` pair matches (see [[#Per-author audit mode]]). `ci` runs the audit in CI; `local` stands CI down and defers to the local merge path.                                                                                                                  |
| `override_label`      | `run-audit`          | PR label that forces CI to run the audit regardless of the author's resolved mode. Present on the PR ⇒ `ci`.                                                                                                                                                                                                |
| `audit_authors`       | `""` (empty)         | `login=mode` pairs (case-insensitive login) overriding `default_mode` per author. First matching login wins; an unmatched author falls back to `default_mode`.                                                                                                                                              |

`/setup-gaia` seeds `default_mode` and `audit_authors` during onboarding rather than leaving the adopter to hand-edit the file. It opens with a solo-or-team gate: a solo engineer is set to local audits automatically (better day-to-day feedback loop, with CI kept as a failsafe) and their own `audit_authors` entry is pre-recorded, so no further prompt appears. A team instead gets a single Local-recommended-or-CI choice per developer, with the fail-closed guarantee (see [[#Ruleset-protected repos: `local` mode is unreachable]]) spelled out before they choose.

## Per-author audit mode

The `Resolve audit decision` step computes whether CI itself runs the audit (`should_run`) by delegating to `.gaia/scripts/read-audit-ci-config.sh --resolve-author <login>`. The same resolver feeds the local merge path, so both derive an author's mode from one source with identical precedence. Resolution precedence:

1. `override_label` present on the PR ⇒ `ci`.
2. else the first matching `audit_authors` `login=mode` pair (case-insensitive).
3. else `default_mode` (itself defaulting to `ci`).

When an author resolves to `local` mode with no override label and the change is in audit scope, CI stands down: every expensive step is gated on `should_run == 'true'`, so the audit spends no tokens. The `Stand down (local-mode, no override)` step posts a `pending` `GAIA-Audit` commit status on HEAD with a fixed non-cleared description, so the required check keeps the merge button blocked until the local audit clears it.

On the local merge path the resolver fail-closes to `ci` when it cannot confirm `GAIA-Audit` is a registered required check on the default branch (network failure, unauthenticated, no repo slug): an unverifiable gate must not silently disable the audit.

Under GitHub Actions the confirmation is skipped entirely. The branch-protection read it performs needs repository-admin rights the Actions `GITHUB_TOKEN` does not carry (and returns `404` on a ruleset-protected branch), so in CI it can never succeed; left unguarded it forces every local-mode author into a redundant full CI audit that duplicates the authoritative local run. CI therefore honors the resolved `local` mode directly and stands down. The gate the confirmation guards still holds: a registered `GAIA-Audit` required check keeps a button-merge blocked behind the `pending` status the stand-down posts, and `/setup-gaia` registers that check when an author opts into local mode.

### Ruleset-protected repos: prefer the trailer handshake over `local` mode

The confirmation helper (`required_check_confirmed` in the resolver) queries only the classic API `repos/{owner}/{repo}/branches/{branch}/protection/required_status_checks` for a `GAIA-Audit` context; it does not consult the rulesets API. A branch protected by a **repository ruleset** rather than classic branch protection carries no classic protection, so that endpoint returns `404 Branch not protected` and the confirmation fails. On such a repo CI honors a `local` pin and stands down (its confirmation is skipped), but the local merge path fails closed to `ci` and waits for a CI `GAIA-Audit` success the stand-down never posts, so each producer defers to the other and the audit lands from neither. Do not pin `local` on a ruleset-protected repo; use the trailer handshake, which stands CI down per-branch regardless of resolved mode (see [[#How to skip an audit run locally]]).

<!-- gaia:maintainer-only:start -->
The maintainer repo is exactly this case: `main` is protected by a ruleset, and the ruleset's required context is the job name `code-review-audit`, not the `GAIA-Audit` status the confirmation greps for. Pinning `local` here strands the audit, CI stands down while the local path fails closed on the absent classic endpoint, so `default_mode` stays `ci` and the audit runs locally through the trailer handshake.
<!-- gaia:maintainer-only:end -->

## Self-heal staging guards

The `Commit and push self-heal` step decides what, if anything, the audit commits back to the PR branch. It stages tracked modifications only (`git add -u`, never `git add -A`, so runner artifacts such as `.claude-pr/` never enter a commit), and refuses the entire self-heal when the staged diff touches an instruction/convention surface (`.claude/`, `.specify/`, `wiki/`) or exceeds ten files: both indicate the agent undoing intentional work rather than fixing a defect.

Before that, the step resets `claude-code-action`'s untrusted-PR restore set to HEAD. The action restores a fixed set of sensitive config and hook paths (`.husky`, `.mcp.json`, `.claude.json`, `.gitmodules`, `.ripgreprc`, `CLAUDE.md`, `CLAUDE.local.md`) from the base branch into the runner's working tree before the agent runs, so an untrusted PR cannot inject a hook or MCP config that executes inside the action. When the PR legitimately modifies one of those paths, the base-branch copy predates the change, so the restore reverts it in the working tree. Without the reset, `git add -u` stages that revert and commits it as a self-heal, silently dropping what the PR added (a `.husky/pre-commit` guard is the canonical case). The agent is never an allowed editor of these surfaces, so the step runs `git checkout HEAD -- <path>` across the set: any working-tree delta on them is either the action's restore or a forbidden edit, and resetting to HEAD is correct either way. The action's restore set also includes `.claude`, whose reverts the instruction/convention refusal above already catches, so the reset loop covers the remaining paths. The list must track `claude-code-action`'s restore set; keep the loop rather than collapsing it.

## Self-heal re-trigger

When the audit's self-heal step pushes a new commit, GitHub does not fire `push` or `pull_request` events for the GITHUB_TOKEN-authored push, its recursion guard. Without intervention, the new HEAD has zero check runs, and branch protection blocks the merge indefinitely. The workflow closes that loop in three parts:

1. **Stamp `code-review-audit` on the new HEAD.** The `Re-trigger and stamp required checks on new HEAD` step uses the Checks API to create a `code-review-audit` check run on the self-heal SHA with `conclusion=success`. The audit produced the new tree, so it is vouching for its own output; the `GAIA-Audit` commit status stamped on the same SHA records the version + tree binding.
2. **Dispatch each `retrigger_workflows` entry via `workflow_dispatch`.** The step calls `gh workflow run <name> --ref <pr-branch>` for every workflow in the list. `workflow_dispatch` is one of the few event types allowed to start a new run under `GITHUB_TOKEN`, so the dispatched runs execute on the self-heal HEAD.
3. **Poll each dispatched run to completion and stamp its jobs.** GitHub excludes `workflow_dispatch`-event check suites from `statusCheckRollup` when the suite's `pull_requests` link is empty, the case for every `GITHUB_TOKEN`-attributed dispatch. Branch protection reads the rollup, so the dispatched check runs alone never satisfy a required-check rule. The step polls each dispatched run via the Actions API, enumerates its jobs, and POSTs a matching check run per job to the self-heal HEAD via the Checks API. Direct-POST check runs land in the rollup regardless of suite linkage, the same mechanism the `code-review-audit` stamp in part 1 uses.

Polling is parallel: one background process per dispatched workflow, so total wait time tracks the slowest dispatched run rather than the sum. Each poller resolves a run id within 90 s, polls for completion for up to 25 min, and tolerates internal failures by logging a warning rather than failing the step. A dispatch failure (workflow not present, missing `workflow_dispatch:` trigger) is also logged and tolerated; the audit does not fail the PR over an adopter-listed workflow that doesn't exist in their repo.

The audit step's `budget_seconds` plus the slowest dispatched run plus a small overhead must fit within the job-level `timeout-minutes: 60` cap. Adopters who raise `budget_seconds` above ~1800 should make sure their dispatched-workflow runtimes stay under the remaining headroom.

This mechanism is invisible when `push_fixes: false`; the audit posts comments and never advances HEAD.

[[Dispatched-Check Rollup via Polling]] documents the polling architecture in full and explains why a `workflow_run`-event listener does not work under `GITHUB_TOKEN`.

## How to enable as a required check

After the workflow lands on `main`, the maintainer (or an adopter applying the same posture on their fork) configures branch protection:

1. Repo **Settings** → **Branches** → **Branch protection rules**.
2. Edit the rule for `main` (or add one if none exists).
3. Enable **Require status checks to pass before merging**.
4. Add `code-review-audit` to the required checks list. The check name is frozen; do not rename even if the workflow grows internal steps.
5. If the rule also requires checks from sibling workflows (e.g. `Run Chromatic`, `Vitest and Playwright`), list those workflows in `retrigger_workflows` so the self-heal re-trigger restores them on the new HEAD. Without this, a self-heal push will strand the PR with the sibling checks missing.

## How to skip an audit run locally

This trailer handshake is also the way to run the audit locally on a ruleset-protected repo, where `local` mode is unreachable (see [[#Ruleset-protected repos: `local` mode is unreachable]]). A clean local run of the [[Code Review Audit Agent]] stamps the trailer automatically; the next push carries it, and CI's skip logic short-circuits, so `code-review-audit` reports green in seconds without spending CI audit tokens. The end-to-end recipe:

1. Spawn the audit agent on the PR branch (per [[PR Merge Workflow]]).
2. Address every Critical and Important finding; re-run until the agent reports `Audit marker written for HEAD ... GAIA-Audit trailer ...; gh pr merge is unblocked.`
3. Push the branch (or push the empty trailer commit if the audit ran against an already-pushed HEAD).
4. Run `gh pr merge`. CI sees the matching trailer on PR HEAD and reports `code-review-audit` as a green skipped check.

Editing HEAD between the local stamp and `gh pr merge` invalidates the trailer (tree mismatch); CI then runs a fresh audit.

<!-- gaia:maintainer-only:start -->

## Template sync (three tracked copies)

In the maintainer repo the audit workflow lives in three byte-identical tracked copies:

1. `.github/workflows/code-review-audit.yml` — the live gate that runs on every PR.
2. `.gaia/cli/templates/workflows/code-review-audit.yml.tmpl` — the build artifact `gaia automation install-audit-workflow` installs from, sitting next to the bundled binary.
3. `.gaia/cli/src/automation/templates/workflows/code-review-audit.yml.tmpl` — the source of truth.

`.gaia/cli`'s `pnpm bundle` regenerates copy #2 from copy #3 (its `bundle:adopter` step copies `src/automation/templates/workflows/` into `templates/workflows/`). The `audit-template-dogfood` test (`.gaia/cli/src/automation/__tests__/audit-template-dogfood.test.ts`) reads copy #3 through `workflowAuditTemplatePath()` and asserts the live workflow (#1) is byte-identical to it, so a mismatch flags the live gate and the source template out of sync.

A workflow-touching PR edits copy #3, regenerates copy #2 with `pnpm bundle`, and syncs copy #1 to match, all up front in the same PR. The drift-guard is a backstop, not the sync mechanism, and it compares only #1 against #3: a stale #2 slips past it, so propagate the edit deliberately across all three rather than pushing one copy and trusting the test to catch the miss.

<!-- gaia:maintainer-only:end -->

## Source-of-truth links

- Agent definition: `.claude/agents/code-audit-frontend.md`
- Workflow: `.github/workflows/code-review-audit.yml`
- Workflow template (install source): bundled in the CLI binary; installed via `gaia automation install-audit-workflow`
- Install primitive: `gaia automation install-audit-workflow`
- Stamp helper (local): `.claude/hooks/audit-stamp-trailer.sh`
- Skip-logic helper (CI): `.github/audit/check-trailer.sh`
- Incremental-base helper (CI): `.github/audit/resolve-audit-base.sh`
- Config reader: `.gaia/scripts/read-audit-ci-config.sh`
- Default config: `.gaia/audit-ci.yml`
- Progress breadcrumb file (runner-local, gitignored): `.gaia/local/audit/progress.log`

## See also

- [[Incremental CI Skipping]]: the cross-workflow "since-last-green" mechanism this audit's no-auditable-delta skip is an instance of.
- [[Code Review Audit Agent]]: the agent the workflow invokes.
- [[Code Audit Team]]: the config-driven roster this workflow's `code-audit-frontend` job is one member of; the dispatch resolver and AND-aggregator that require every dispatched member's clearance at the local merge gate.
- [[PR Merge Workflow]]: the local-side gate handshake (`.gaia/local/audit/<sha>.ok` marker file).
- [[Quality Gate]]: the lint/typecheck/test/knip gate that still runs alongside this audit.
- Forensics Triage Workflow: sibling autonomous CI workflow built on the same `claude-code-action` setup.
