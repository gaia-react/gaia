---
type: concept
status: active
created: 2026-05-08
updated: 2026-05-08
tags: [concept, ci, audit, claude]
---

# Code Review Audit CI

A GitHub Actions pre-merge gate that runs the [[Code Review Audit Agent]] against every PR. The workflow lives at `.github/workflows/code-review-audit.yml` and exposes a stable check named `code-review-audit` that branch protection on `main` requires before merge.

The gate has two complementary signals: the existing local marker file at `.gaia/local/audit/<sha>.ok` (gates `gh pr merge` on the contributor's machine — see [[PR Merge Workflow]]) and the `GAIA-Audit:` commit trailer (travels with the commit so CI can recognize an already-audited tree and skip its own run).

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

Version mismatch (a newer GAIA release shipped) and tree mismatch (HEAD amended after the trailer was written) both invalidate the stamp automatically. Only the PR-HEAD commit's trailers are inspected — stale trailers in earlier commits on the branch do not satisfy the gate.

The trailer is written by `.claude/hooks/audit-stamp-trailer.sh` at the end of a clean local run of the audit agent. Stamp placement is automatic: amend on un-pushed HEADs, an empty `chore: code review audit passed` commit on already-pushed HEADs (never silently rewriting published history), and amend on the audit's own self-heal commits regardless of push state. The full stamp invariant and placement rule live alongside the workflow's frozen contracts at `.gaia/local/plans/code-review-audit-ci/trailer-format.md`.

## Adopter knobs

The four adopter-tunable knobs live at `.gaia/audit-ci.yml`. The workflow reads the file at job start via `.gaia/scripts/read-audit-ci-config.sh`; missing file or missing keys fall back to documented defaults.

| Knob | Default | Purpose |
| --- | --- | --- |
| `gate_label` | `null` | Run the audit only when the PR carries this label. `null` runs on every PR. Maintainer recommendation: leave `null` until the audit is stable in CI; flip to `ready-for-review` once it is. |
| `budget_seconds` | `1800` | Hard wall-clock budget for the audit invocation. The workflow times out the agent step at this value and reports `audit aborted: budget` rather than failing red. |
| `max_turns` | `30` | Maximum fix turns the agent is allowed inside CI. Maps to `claude_args`'s `--max-turns`. Lower = cheaper. Higher = more chance to self-heal. |
| `push_fixes` | `true` | Whether the agent may push self-heal commits to the PR branch. Set `false` to make the audit advisory-only (it comments findings but does not push). |

## How to enable as a required check

After the workflow lands on `main`, the maintainer (or an adopter applying the same posture on their fork) configures branch protection:

1. Repo **Settings** → **Branches** → **Branch protection rules**.
2. Edit the rule for `main` (or add one if none exists).
3. Enable **Require status checks to pass before merging**.
4. Add `code-review-audit` to the required checks list. The check name is frozen — do not rename even if the workflow grows internal steps.

## How to skip an audit run locally

A clean local run of the [[Code Review Audit Agent]] stamps the trailer automatically; the next push carries it, and CI's skip logic short-circuits. The end-to-end recipe:

1. Spawn the audit agent on the PR branch (per [[PR Merge Workflow]]).
2. Address every Critical and Important finding; re-run until the agent reports `Audit marker written for HEAD ... GAIA-Audit trailer ...; gh pr merge is unblocked.`
3. Push the branch (or push the empty trailer commit if the audit ran against an already-pushed HEAD).
4. Run `gh pr merge`. CI sees the matching trailer on PR HEAD and reports `code-review-audit` as a green skipped check.

Editing HEAD between the local stamp and `gh pr merge` invalidates the trailer (tree mismatch); CI then runs a fresh audit.

## Source-of-truth links

- Agent definition: `.claude/agents/code-review-audit.md`
- Workflow: `.github/workflows/code-review-audit.yml`
- Stamp helper (local): `.claude/hooks/audit-stamp-trailer.sh`
- Skip-logic helper (CI): `.github/audit/check-trailer.sh`
- Config reader: `.gaia/scripts/read-audit-ci-config.sh`
- Default config: `.gaia/audit-ci.yml`
- Frozen contracts (trailer format, skip logic, check name, event triggers): `.gaia/local/plans/code-review-audit-ci/trailer-format.md`

## See also

- [[Code Review Audit Agent]] — the agent the workflow invokes.
- [[PR Merge Workflow]] — the local-side gate handshake (`.gaia/local/audit/<sha>.ok` marker file).
- [[Quality Gate]] — the lint/typecheck/test/knip gate that still runs alongside this audit.
- [[Forensics Triage Workflow]] — sibling autonomous CI workflow built on the same `claude-code-action` setup.
