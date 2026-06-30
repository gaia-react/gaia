---
type: concept
status: active
created: 2026-04-20
updated: 2026-06-03
tags: [concept, ci, review]
---

# PR Merge Workflow

Mandatory before any `gh pr merge`. Machine-enforced by `.claude/hooks/pr-merge-audit-check.sh`, which denies `gh pr merge` calls when no `code-review-audit` marker exists for the current HEAD SHA.

The gate is **repo-scoped** via `.claude/hooks/lib/repo-scope.sh`: it enforces this repo's audit contract only. A `gh pr merge` positively aimed at a different repo (`-R owner/other`, or `cd <other> &&`) is allowed; this repo's audit markers have no bearing on a sibling repo's merge. Scoping is fail-closed: any ambiguity still enforces.

## Marker-first: check before you audit

The hook requires a **marker to exist** for HEAD, not that you personally run the audit. The marker comes from one of two producers: CI (`code-review-audit.yml` stamps the `GAIA-Audit` status) or the local `code-review-audit` agent (writes `.gaia/local/audit/<sha>.ok`, a `GAIA-Audit:` trailer, and a `GAIA-Audit` success status). Which producer runs is a **per-author mode**, `ci` or `local`, resolved by the shared helper both sides call identically:

```bash
eval "$(bash .gaia/scripts/read-audit-ci-config.sh --resolve-author "$(gh pr view <N> --json author --jq .author.login)")"
# resolved_mode (ci|local) and should_run (true|false) are now in scope
```

CI and the local path read the same `resolved_mode`, so they never disagree about who audits. The mode lives in `.gaia/audit-ci.yml`, a team `default_mode` plus per-developer `audit_authors` overrides and a sticky `override_label` that forces `ci`; it is per-author and never `off`. The audit has no `automation.json` entry, so don't look for one. Resolve the mode first:

- `resolved_mode == ci` with the workflow present, or the override label set → **wait for CI's `GAIA-Audit` success** (the check states below).
- `resolved_mode == local`, or the workflow absent → **run the local agent** as the producer; on a clean pass it writes the marker, then posts the `GAIA-Audit` success status so the github.com button clears too.

For the `ci` branch, **start with the cheapest deterministic signal: the workflow file:**

```bash
test -f .github/workflows/code-review-audit.yml && echo present || echo absent
git rev-parse HEAD   # the SHA the marker must match
```

`test -f .github/workflows/code-review-audit.yml`: **present** → the CI audit is configured (it installs only via `/setup-gaia-ci`); trust / wait for the `GAIA-Audit` marker. **Absent** → the CI audit is not set up; run the local `code-review-audit` agent. The `GAIA-Audit` check state stays authoritative for the final go/no-go (it handles secret-rotated and `gate_label` edge cases where the file is present but no marker lands).

When the file is **present**, consult the PR's check state:

```bash
gh pr checks <N> | grep GAIA-Audit   # what state the audit is in, if any
```

| `gh pr checks` result            | Meaning                             | Action                                                    |
| -------------------------------- | ----------------------------------- | --------------------------------------------------------- |
| `GAIA-Audit … pass`              | marker present for HEAD             | skip to **step 4 (merge)**                                |
| `GAIA-Audit … pending`           | CI is enabled and running the audit | wait for it to finish, then merge                         |
| no `GAIA-Audit` row, or it fails | CI is not auditing this PR          | run the local agent (**step 1**), mandatory, not optional |

The third row covers cases where the workflow file is present but CI is not stamping: Actions disabled, the workflow inactive, or a `gate_label` in `.gaia/audit-ci.yml` this PR lacks. To tell "CI is off" apart from "CI just hasn't registered the check yet," confirm the workflow is live before deciding to wait:

```bash
gh api repos/{owner}/{repo}/actions/workflows \
  --jq '.workflows[] | select(.path | endswith("code-review-audit.yml")) | .state'   # active → CI will stamp; wait
gh api repos/{owner}/{repo}/actions/permissions --jq .enabled                          # false → CI cannot run; go local
```

Spawning the local agent when CI has already stamped the marker is redundant; skipping it when CI will never stamp leaves the merge permanently blocked. The exception is a PR whose entire diff is out of audit scope: the hook's out-of-scope bypass (see step 3) clears those with no marker at all, so no local run is needed even when CI never stamps.

## Four-step protocol

### 1. Run code-review-audit (when CI is not auditing this PR)

When the decision above sends you here (no `GAIA-Audit` marker and CI will not stamp one), spawn the agent on the PR's changes:

```
Task(
  subagent_type="code-review-audit",
  prompt="Review all changes in the current branch compared to main. Identify security vulnerabilities, performance issues, code smells, anti-patterns, and refactoring opportunities."
)
```

### 2. Fix all issues

- Fix every Critical Issue, every Important Issue, and every Suggestion the audit identifies.
- If a Suggestion involves an architectural tradeoff, breaking change, or conflicting convention, the agent escalates it with documented rationale rather than auto-fixing; the operator must resolve the escalation before the marker is written.
- Re-run linting and type checking after fixes.
- Stage, commit, and push the fixes; HEAD must move so the next audit runs against the fixed tree.
- Re-spawn the audit agent on the new HEAD until it reports clean.

### 3. Marker handshake

The hook (`pr-merge-audit-check.sh`) accepts any one of three signals that prove the audit ran clean against the content being merged, plus three bypasses for PRs that need no audit signal:

| Signal                                                                    | Source                       | How it gets there                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------------------------------------------------- | ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.gaia/local/audit/<HEAD-sha>.ok`                                         | Local audit agent            | Agent writes it on a clean pass                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `GAIA-Audit:` commit-message trailer on HEAD                              | Local audit agent            | `audit-stamp-trailer.sh` writes an empty commit with the trailer                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `GAIA-Audit` GitHub commit status on HEAD, `state: success`, description `<version> <tree>` | CI (`code-review-audit.yml`) or the local audit agent | CI stamps this after a full audit (on the audit SHA) and on HEAD when the un-audited delta is entirely out of audit scope. The local agent posts the same `state: success` status after it writes the marker, gated on the marker existing first (`post-audit-status.sh`), so a `local`-mode merge clears the github.com button too; when `gh` is unauthenticated the marker still clears the Claude path while the button stays blocked. No empty marker commit is pushed; that would strand HEAD on a check-less commit. Every reader requires `state == success`: a `pending` status (the CI local-mode stand-down) carrying HEAD's version+tree is never treated as cleared.                                                                                                                                                                                                                                                                                                                                                                                                     |
| PR title matches `^chore\(deps(-dev)?\):` (bypass)                        | `/update-deps` wrapper       | Wrapper opens dep-bump PRs with the canonical prefix; the local quality gate stands in for the audit signal.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Every changed file is out of audit scope (bypass)                         | `pr-merge-audit-check.sh`    | The PR's full diff against its merge base with the default branch touches only out-of-scope surfaces: `wiki/`, `.claude/`, `.specify/`, `.gaia/`, `docs/`, root-level markdown. The agent has no rules that apply, so no marker is required. This mirrors `code-review-audit.yml`'s `has_source` skip locally, so the gate clears even when the installed workflow predates the out-of-scope status stamp or CI is absent. Evaluated fail-closed: any in-scope path (`app/`, `test/`, configs, `.github/workflows/`) keeps the marker mandatory, so a PR carrying auditable source can never reach this bypass. |
| Audit-workflow re-render is the only in-scope change (bypass)              | `pr-merge-audit-check.sh`    | The one in-scope path the PR changes is `.github/workflows/code-review-audit.yml` AND its committed bytes are a verbatim re-render of the bundled template (`.gaia/cli/templates/workflows/code-review-audit.yml.tmpl`, proven by git-blob identity: equal blob SHAs mean byte-identical files), with every other changed path out of scope. This is the self-mod-only case `/update-gaia` Step 12 produces: it refreshes a stale audit workflow by copying the release template verbatim. CI self-mod-skips such a PR (no stamp lands), and the out-of-scope bypass above denies because `.github/workflows/` is in scope, so this bypass clears the merge without a ceremonial local re-audit of bytes that are GAIA's own template, not adopter code. Stricter than the out-of-scope bypass and fail-closed: an adopter edit (bytes diverge from the template), a second in-scope path, or an absent template keeps the marker mandatory. |

Tree-sha equality is the load-bearing check for both the trailer and the status: identical trees mean identical content, so an audit on a different commit SHA but the same tree is auditing the same code.

The chore(deps) bypass mirrors the same skip narrowing that `code-review-audit.yml`, `tests.yml`, and `chromatic.yml` apply at CI level. All four surfaces (local hook + three required workflows) release together when a `chore(deps):` or `chore(deps-dev):` PR is recognized, so dep-bump PRs from `/update-deps` are turnkey. The bypass requires `gh` to be installed and authenticated; if either is missing the hook falls through to the normal deny path (the bypass is opt-in proof, not a fallback).

When CI self-heals (the audit modifies a file and pushes the fix), the workflow stamps a `code-review-audit` check run on the new HEAD and dispatches the sibling required workflows (e.g. `Chromatic`, `Tests`) via `workflow_dispatch` so their check runs attach to the new SHA. See [[Code Review Audit CI#Self-heal re-trigger]] for the full mechanism and the `retrigger_workflows` knob.

A clean pass requires no Critical Issues, every Important Issue addressed, and every Suggestion either auto-fixed or resolved by the operator. Those three preconditions govern **in-scope** findings (defects inside the PR's changed line ranges). A **fourth precondition** governs out-of-scope findings: every out-of-scope finding the audit identifies within its review radius must carry a disposition before the marker writes, a filed `tech-debt` issue, a diverted security advisory or operator surface, or a backend-absent waive. The marker is withheld only on a genuinely-missing disposition (a present, writable backend where a filing definitively failed); backend-absent, transient, and diverted findings all fail open. Knip, react-doctor, and dependency-CVE (`pnpm audit`) advisories remain advisory and never block signal emission. See [[Audit Disposition and Debt Drain]] for the full disposition contract.

The deterministic backstop hook `.claude/hooks/audit-disposition-check.sh` gates `gh pr merge` alongside `pr-merge-audit-check.sh`: it re-reads the disposition-ledger sidecar for HEAD and denies only on a present-backend inconsistency (a `filed` entry whose key resolves to no open `tech-debt` issue, or a genuinely-missing disposition), failing open on an absent or transient backend (the never-block invariant). A `/gaia-debt` fix PR is an ordinary in-scope change that clears the normal gate.

If the local agent declines to write the marker, its report names what remains unaddressed; resolve those, commit, push, re-spawn.

### 4. Merge

<!-- gaia:maintainer-only:start -->
First clear the **CHANGELOG gate** below: decide whether this PR needs an `## [Unreleased]` entry and land it on the branch before merging.
<!-- gaia:maintainer-only:end -->

Once the marker exists for HEAD, run `gh pr merge`. The hook short-circuits to allow the call.

<!-- gaia:maintainer-only:start -->
## CHANGELOG gate (maintainer-only)

The last decision before merge: does this PR's change belong in `CHANGELOG.md` under `## [Unreleased]`? Make the call **at merge time**, not authoring time. An entry promised in an earlier session is worthless if it never landed, and a fix that spanned sessions may have changed what's worth noting, so re-run this check on every merge, including a PR resumed days later. GAIA's `CHANGELOG.md` is release-excluded, so this gate and every entry it produces are GAIA-team-only and reach no adopter clone.

**Worthy, add an entry.** Default to yes for anything that moves the GAIA product surface: a new or changed skill, command, hook, rule, agent, or wiki concept page; a behavior or default change; a bugfix in any shipped or maintainer surface; a dependency bump that crosses a security or compatibility floor; an adopter-action change (author it per the Adopter-action convention at the top of `CHANGELOG.md`). The changelog tracks the whole product, maintainer-only tooling included.

**Not worthy, merge as-is.** Typo, formatting, or comment-only edits; a pure internal refactor with no behavior or surface change; test-only changes that alter no shipped behavior; and anything already covered by an existing `## [Unreleased]` line.

When worthy:

1. Add the entry to the right `### Added | Changed | Removed | Fixed` subsection under `## [Unreleased]`, present-tense, with the trailing `(#<PR>)` reference.
2. Commit it onto the PR branch and push so it merges with the change. HEAD moves, so re-confirm step 3's audit marker still covers the new HEAD before merging. Cheapest path: decide changelog-worthiness back in step 2 while fixing audit findings, so a single audit pass covers both.
<!-- gaia:maintainer-only:end -->

## Post-merge verification before cleanup

`gh pr merge` can fail without aborting the rest of a script: branch protection ("base branch policy prohibits the merge"), pending CI checks, missing `--auto` for queued merges, or auth issues. Proceeding to local cleanup (`git checkout main`, `git branch -D <pr-branch>`, `git fetch --prune`) before confirming the merge actually succeeded leaves the local branch deleted while the PR is still OPEN. Recoverable via `git checkout -b <branch> origin/<branch>` while the remote ref still exists, but it's avoidable churn.

The safe pattern after any `gh pr merge`:

```bash
gh pr merge <N> --squash --delete-branch [--auto]
for i in 1 2 3 4 5; do
  state=$(gh pr view <N> --json state -q .state)
  [ "$state" = "MERGED" ] && break
  sleep 30
done
[ "$state" = "MERGED" ] || { echo "merge did not complete"; exit 1; }
git checkout main && git pull origin main
git branch -D <pr-branch>  # force needed for squash (orphaned commits)
git fetch --prune origin
```

**`--auto` vs `--admin`:** when `gh pr merge` rejects with "base branch policy prohibits the merge", the right escape is `--auto`; it queues the merge and GitHub completes it once checks pass. Never reach for `--admin` to bypass branch protection without explicit permission; it removes the safety the policy exists to provide.

## Local-sync failure mode

When `gh pr merge` exits with `fatal: 'main' is already used by worktree at <path>`, **the GitHub-side merge has already succeeded**. The local checkout step is what failed, not the merge itself. Confirm with:

```
gh pr view <N> --json state
```

If `state == "MERGED"`, do NOT retry the merge. Treat it as merged, run any post-merge steps (wiki-sync, spec-close, etc.), and resolve the local worktree conflict separately. Retrying compounds the problem and can produce a duplicate squash on a non-existent branch.

## Second merge gate: the worthiness presence gate

`gh pr merge` passes through a second, independent PreToolUse hook,
`.claude/hooks/worthiness-presence-check.sh`. It denies the merge when an
emergent test the PR changed (under `app/components/**` or `.playwright/**`, as
the [[Determinism Classifier]] labels it) has no worthiness-ledger line matching
its current content. It checks presence and signal match only, never the
keep/fix/delete verdict, scopes to the emergent tests this PR changed (a no-op
when none changed), and fails open on missing tooling. It is a separate denial
from the code-review-audit marker above; both must clear. See [[Worthiness
Presence Gate]] for the full contract.

## No exceptions

- Never merge without a marker for HEAD. The hook denies it. The audit must cover the merged content; CI produces the marker when it audits the PR, otherwise the local agent does.
- Never hand-write a marker file to bypass the gate. The agent (local or CI) owns marker emission.
- When CI is not auditing an **in-scope** PR (`.github/workflows/code-review-audit.yml` is absent, Actions disabled, the workflow inactive, or a `gate_label` excludes it), the local `code-review-audit` agent is the only way to produce the marker; run it. A PR whose entire diff is out of audit scope needs no marker; the hook's out-of-scope bypass clears it.

See [[Code Review Audit Agent]], [[Quality Gate]], [[Git Workflow]].
