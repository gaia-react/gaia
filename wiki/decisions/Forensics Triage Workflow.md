---
type: decision
status: active
priority: 1
date: 2026-05-08
created: 2026-05-08
updated: 2026-05-08
tags: [decision, ci, automation, security]
---

# Decision: Forensics Triage Workflow

A GitHub Actions workflow at `.github/workflows/forensics-triage.yml` triages every `gaia-forensics`-labeled issue on the upstream repo without human action. It closes non-issues, escalates real-but-out-of-scope reports to the maintainer, and opens scope-bounded draft PRs (gated by the [[Quality Gate]] and human review on `main`) for fixable defects.

The workflow is autonomous by design. The maintainer's irreducible attention surface is reviewing the candidate fix on the draft PR — never reading raw issue traffic, never running mechanical classification.

## What it does

Trigger: `issues.opened` and `issues.labeled` events. The job-level `if` filter exits unless the issue carries the `gaia-forensics` label, so unrelated issue traffic is free.

Lifecycle:

1. **Idempotency check.** If the issue already carries `gaia-triaged`, the workflow exits with no work. The fail-forward final step also suppresses re-application of the label.
2. **Body parse.** A pure-shell parser at `.github/forensics/parse-issue-body.sh` extracts the four required sections (`## Symptom`, `## Classification`, `## Capture`, `## Reproduction context`) plus frontmatter from the strict-schema issue body. The LLM is never invoked for extraction. Missing or malformed sections route the issue to `needs-human` with a comment naming the offending section, and no classification runs.
3. **Classify.** `anthropics/claude-code-action` runs the prompt at `.github/forensics/prompt.md` with the parsed sections rendered in. The action runs with `--max-turns 1` and tool access disabled (no `Bash`, `Read`, `Edit`, `Write`, `WebFetch`, `WebSearch`) — judgment only, no side effects on the working tree. The classifier emits a single trailing `GAIA-VERDICT: <class>` line; `parse-verdict.sh` extracts it deterministically. Missing, duplicated, or out-of-set verdict lines downgrade to `ambiguous` and route to `needs-human`.
4. **Act on verdict.**
   - `non-issue` — close the issue, comment with the classifier's reasoning, label `non-issue`.
   - `needs-human` — label `needs-human`, comment with the reasoning, mention the maintainer. Issue stays open.
   - `auto-fixable` — proceed to the fix-attempt path.
5. **Scope check (pre-fix).** `check-scope.sh` runs over the classifier's `Proposed paths` block. Any path outside the allowlist (or on the explicit denylist) demotes the issue to `needs-human` with a comment naming the rejected paths. No branch is created.
6. **Apply fix.** A second `claude-code-action` invocation runs the fix-application prompt with `--allowedTools Edit,Read,Write` only — no shell, no git, no network. The branch `forensics/<issue-num>-<class-slug>` is created locally from `origin/main`.
7. **Post-fix scope check.** Even within the allowlist, the diff must be a subset of the classifier's proposed paths. Any deviation aborts before commit and demotes to `needs-human`.
8. **Quality Gate.** `.github/forensics/run-quality-gate.sh` runs `pnpm install --frozen-lockfile`, `pnpm typecheck`, `pnpm lint`, `pnpm test --run`, and `pnpm knip` in order, halt-on-first-fail. Gate failure abandons the branch (it was never pushed) and demotes the issue to `needs-human` with a comment naming the failed step and a log excerpt.
9. **Open draft PR.** Gate pass pushes the branch and opens a draft PR. PR body cites the `## Capture` section verbatim. Labels `auto-fixable` and `gaia-bug-confirmed` attach to the issue.
10. **Idempotency key.** Every triaged issue receives the `gaia-triaged` label as the final, always-run step.

The workflow file at `.github/workflows/forensics-triage.yml` is on the canonical denylist below: triage runs cannot self-modify, and `check-scope.sh` rejects any attempt to edit a path under `.github/workflows/`.

## Path policy

Default-deny. Any path in neither list below is denylisted by default; allowlist expansion requires a SPEC reopen, not a PR-time decision.

### Allowlist (eligible for autonomous fixes)

| Path | Notes |
| --- | --- |
| `.gaia/cli/` | GAIA CLI source. |
| `.claude/hooks/` | Shell hooks. |
| `.claude/skills/` | Skill markdown. |
| `.claude/commands/` | Slash command definitions. |
| `.claude/agents/` | Sub-agent definitions. |
| `.gaia/statusline/` | Statusline scripts. |
| `.specify/extensions/gaia/` | GAIA spec-kit extension — excluding `templates/`. |
| `.gaia/manifest.json` | Distribution manifest. |

### Denylist (never modify)

| Path | Notes |
| --- | --- |
| `app/` | Application source. |
| `wiki/` | Knowledge base; human-curated. |
| `studio/` | Private maintainer vault. |
| `website/` | Marketing + docs site. |
| `.specify/specs/` | spec-kit specs. |
| `.specify/memory/` | spec-kit memory. |
| `.gaia/local/specs/` | GAIA spec artifacts. |
| `.specify/extensions/gaia/templates/` | Template literals; mutating these affects every adopter. |
| `.github/workflows/` | Workflow files; covers self-modification of the triage workflow itself. |

## Label vocabulary

All five labels must pre-exist on the upstream repo. `bootstrap-labels.sh` asserts the inventory and creates missing entries with the canonical color and description; existing labels with drifted color or description log a notice and stay untouched (operator wins).

| Label | Color | Meaning |
| --- | --- | --- |
| `gaia-triaged` | green (`0e8a16`) | Idempotency key. Set on every triaged issue; presence is the early-exit condition. |
| `non-issue` | grey (`cccccc`) | Not a bug. Issue closed with explanation. |
| `needs-human` | orange (`d93f0b`) | Real bug, but out of autofix scope OR malformed body OR ambiguous classifier verdict OR Quality Gate failure. Maintainer review required. |
| `auto-fixable` | blue (`1d76db`) | Classifier proposed a fix in allowlisted scope. See linked draft PR. |
| `gaia-bug-confirmed` | red (`b60205`) | Quality Gate passed on the auto-fix branch. Draft PR open and ready for human review. |

The `gaia-forensics` trigger label is owned by phase 1 of the forensics arc (the `/gaia forensics` end-user bridge) and is not part of `bootstrap-labels.sh`'s inventory.

## Secret hygiene

The workflow handles two secrets:

- `ANTHROPIC_API_KEY` — consumed only by `anthropics/claude-code-action`. Never echoed.
- `GITHUB_TOKEN` — workflow-default token, scoped to the minimum permissions: `issues: write`, `contents: write`, `pull-requests: write`, `actions: read`.

Secret-shape masking: before rendering either prompt, the workflow scans the parsed issue sections for byte patterns that look like leaked tokens (`sk-ant-…`, `ghp_…`, `github_pat_…`) and emits `::add-mask::` for each match. Phase 1 redacts the body before the issue ever opens — this is defense-in-depth against an unredacted leak slipping through.

Redaction passthrough: phase-1 redaction tokens (`<redacted>`, repo-relative paths derived from absolutes) appear verbatim in every derived artifact — classifier comment, PR body, branch content. The workflow never re-redacts, de-redacts, or normalizes.

Branch protection and the draft-PR contract are the autonomous-mode safety rails:

- Every PR opens as `draft: true`. The workflow has no `gh pr ready` invocation.
- The workflow has no `gh pr merge` invocation.
- Branch protection on `main` requires at least one human review and the standard required status checks. The workflow never bypasses either.

## Failure modes

| Failure | Behavior |
| --- | --- |
| **Issue body missing or malformed.** | Parser detects the missing/malformed section without LLM fallback. Issue is labeled `needs-human`; comment names the section; no classifier runs. |
| **Classifier verdict ambiguous** (no `GAIA-VERDICT:` line, multiple lines, value outside the closed set, or `auto-fixable` without a parseable `Proposed paths` block). | Verdict normalizes to `ambiguous`; `needs-human` handler fires with reason-code `ambiguous-verdict`. |
| **Proposed paths cross the scope boundary.** | `check-scope.sh` rejects before any branch is created. Comment names the rejected paths; issue demoted to `needs-human` with reason-code `out-of-scope`. |
| **Apply-fix model goes off-script** (touches paths it didn't propose, or emits the `GAIA-FIX-ABORT:` escape line). | Pre-commit verification catches the deviation. Local edits are discarded; branch is never pushed; issue demoted to `needs-human`. |
| **Quality Gate fails.** | Branch is never pushed (no `forensics/<issue-num>-*` ref ever exists on origin). `auto-fixable` label is NOT applied. Issue is demoted to `needs-human` with a comment naming the failed step, an excerpt of the failure log, and a link to the workflow run. |
| **Two events for the same issue fire in rapid succession.** | A `concurrency` block keyed on the issue number with `cancel-in-progress: false` queues the second run. The first run applies `gaia-triaged`; the queued run hits the early-exit and does no work. No duplicate label, comment, branch, or PR. |
| **Job exceeds 30 minutes.** | The job-level timeout aborts cleanly. The workflow is fail-forward: any labels applied before the timeout stay (no rollback). |

There is no retry loop. One fix attempt per issue; failure is terminal in autonomous mode. A maintainer can manually unstick by removing `gaia-triaged` and re-firing — that is a manual operation, outside the workflow's contract.

## Amendment process

The auto-fix allowlist and the canonical denylist are part of the workflow's immutable contract. Both lists live in three places that must stay synchronized:

1. The path policy on this page.
2. The classifier prompt at `.github/forensics/prompt.md` (rendered into the `{{ALLOWLIST}}` and `{{DENYLIST}}` placeholders by the workflow YAML).
3. The deterministic check at `.github/forensics/check-scope.sh`.

Amending either list requires a SPEC reopen — adding a path through a PR-only change is not an authorized path. The SPEC artifact is the source of truth; this page and the scripts are derivations.

Adding a new label to the vocabulary:

1. Append the entry to `bootstrap-labels.sh`'s `LABELS` array (`name|color|description`).
2. Re-run `bootstrap-labels.sh` against the upstream repo (idempotent — re-runs are no-ops on existing labels).
3. Update the label vocabulary table on this page.
4. Wire any handler that needs to apply the new label.

Modifying the workflow YAML or any `.github/forensics/` script is a normal PR — except those paths are themselves on the workflow's denylist, so the changes ship through human-authored PRs only, never through autonomous triage.

## Signals to revisit

The default-deny path policy and the no-cross-issue-learning posture are deliberate. Two signal patterns indicate the contract is worth revisiting.

### Allowlist expansion

`needs-human` comments name the rejected paths in their `reason: out-of-scope` body. When a single unenumerated path recurs across five or more distinct issues, it is a candidate for the auto-fix allowlist. Adding the path requires a SPEC reopen — not a PR-only edit — because the allowlist is part of the workflow's immutable contract.

### Cross-issue learning

The classifier runs on each issue independently. Manual maintainer corrections accumulate as a queue of human-corrected outcomes: re-labelled issues, manual closures, rejected draft PRs. When that queue exceeds fifty items across all classes, the data set is worth feeding back into the classifier as priors, batched-triage queues, or supervised retraining loops — work that warrants its own SPEC.

Both signals are tracked by the maintainer health audit, which aggregates the reason-codes and flags threshold crossings.

## Operator runbook

### Halt a runaway run

1. Open the **Actions** tab on the upstream repo.
2. Filter by workflow name `Forensics Triage`.
3. Locate the in-flight run; click **Cancel workflow**.
4. The cancelled run leaves any already-applied labels in place (fail-forward). If `gaia-triaged` was already applied, no further triage will fire on the issue. If not, removing `gaia-forensics` and re-adding it will re-trigger.

### Manually re-trigger triage on an issue

The workflow is idempotent on `gaia-triaged`. To force a re-run:

1. On the issue: remove `gaia-triaged`. (Removing the label re-fires the workflow because of the `issues.labeled` trigger.)
2. The next run treats the issue as untriaged and re-classifies from scratch. Any prior labels (`non-issue`, `needs-human`, etc.) stay attached unless the new run replaces them.

To pre-empt a re-run, leave `gaia-triaged` attached.

### Read the workflow logs without leaking secrets

GitHub Actions logs apply `::add-mask::` automatically: any masked value renders as `***` in the UI and the downloadable log archive. The workflow registers masks for every observed secret-shape on the parsed issue body. Inspecting a run:

1. From the Actions tab, open the run.
2. Each `::group::` block (e.g. `quality-gate: lint`) collapses verbose output. Expand only what is relevant to the question.
3. The `Run Quality Gate` step's `summary_file` JSON is the canonical failure record — it contains the failed step, exit code, and a trimmed log excerpt. The full per-step log lives in the runner's temp dir and only surfaces in the action log; it is never posted to comments or PR bodies.
4. If a comment or PR body looks like it might contain a secret, treat it as a leak and rotate the secret. The workflow never intentionally writes secret-shaped values to derived artifacts; an unmasked secret in a comment is a regression.

### Inspect a fix attempt without merging

Draft PRs the workflow opens are normal PRs in every other respect. Check out the branch (`gh pr checkout <pr-num>`), run the [[Quality Gate]] locally, review the diff. Branch protection blocks merge until human approval; nothing the workflow does forecloses on rejecting the fix and closing the PR.

## See also

- [[Quality Gate]] — the gate this workflow runs on every fix-attempt branch.
- [[Wiki Management]] — adjacent automation primitives (different surface).
