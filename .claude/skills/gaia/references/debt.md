# /gaia-debt

Drain the `tech-debt` backlog the audit files. `/gaia-debt` reads the open `tech-debt` issues, orders them deterministically (highest severity then oldest first, no model call), recommends the top candidate, and resolves **exactly one** issue per invocation on a fresh branch through the same `code-review-audit` marker gate every feature PR passes, with `Closes #N` in the PR body so the merge closes the issue natively.

The ordering is a pure, source-checkable sort over the issues' severity labels and `createdAt` timestamps. It never calls a model to rank the backlog, and it never resolves more than one issue per run.

## Execution model, READ FIRST

Execute the playbook yourself in the current conversation. This is an interactive, human-gated flow: the human picks or confirms the candidate, the skill does not auto-advance to the next issue. Resolve **exactly one** issue per invocation; there is no batch drain.

The skill drives a fix PR through the **full** PR Merge Workflow (cut a branch, implement, run the Quality Gate, commit, push, `gh pr create`, then the marker handshake and merge). After the PR is up it confirms intent, defaulting to merge, and on **merge** resolves the PR to completion the standard way: the same `code-review-audit` marker gate every feature PR passes, then `gh pr merge`. The gate is inviolate: never bypass, fake, or pre-empt the marker, and never substitute a bare `gh pr merge` for the workflow's handshake.

## Argument parsing

Tokenize the first whitespace-separated word of `$ARGUMENTS`:

- `drain` (or empty `$ARGUMENTS`) → the full interactive flow. This is the default the statusline nudge (`Run /gaia-debt (N issues)`) points at.
- `list` → print the ordered backlog and stop. No branch, no PR, no prompts.
- `why` → the remainder of `$ARGUMENTS` is an issue number. Explain where that issue sits in the ordering, its recommended handler class, and the rationale, then stop. No authoring, no prompts.

If the first token is none of `drain` / `list` / `why` and `$ARGUMENTS` is non-empty, treat the whole string as a `why <issue-number>` target only when it parses as a single integer; otherwise default to `drain`.

## Backend probe

Probe the issue backend before reading the backlog. Three outcomes:

- **Definitive-absent** → report "no GitHub issues backend; /gaia-debt no-ops" and stop. Triggers: repo unresolvable, `gh` unauthenticated, Issues disabled (`gh repo view --json hasIssuesEnabled` false **or** a structurally-failing issue-list probe, **never** `gh repo view` resolution alone), or the viewer lacks write permission.
- **Transient/ambiguous** (timeout, rate-limit, 5xx) → surface the failure and stop without action. Retrying later is safe; nothing was authored.
- **Present** → proceed.

## Read and order the backlog (deterministic, no LLM evaluator)

Read the open backlog and order it with a pure sort. No model call ranks the backlog; the order is reproducible from this source.

```bash
gh issue list --label tech-debt --state open \
  --json number,title,labels,createdAt,body \
  --jq '
    map({
      number, title, createdAt,
      sev: ([.labels[].name]
            | if   index("severity:critical")  then 3
              elif index("severity:important") then 2
              else 1 end)
    })
    | sort_by([(-.sev), .createdAt])
  '
```

How the sort works, and why it is deterministic:

- **Severity descending.** Each issue's one severity label maps to a rank: `severity:critical → 3`, `severity:important → 2`, `severity:suggestion → 1`. An issue with **no** severity label falls through the `else` branch to rank `1`, the **suggestion** band, so a human-filed fieldless issue is a valid candidate and sorts with the suggestions.
- **`createdAt` ascending within a band.** `sort_by([(-.sev), .createdAt])` sorts by negated rank first (highest severity first) then by `createdAt`. `gh` returns `createdAt` as a `Z`-normalized RFC 3339 string, so a lexicographic ascending sort is chronological ascending: of two equal-severity issues, the **older** one sorts first (FIFO within the band).

The entire ordering is this one `--jq` expression over fields GitHub returns. There is no judgment step, so `list`, `why`, and `drain` all agree on the order and anyone can reproduce it by re-running the command.

## Recommend and present (drain)

Recommend the top candidate (first in the sorted list). Print the ordered backlog so the human can override: per issue, the number, title, severity band, and age (derived from `createdAt`). The human picks the candidate to drain; if they pick a different one, honor it. The skill never auto-advances past the human's choice.

## Drain-time security screen

Before opening any fix PR, screen the **selected** issue. Apply the fail-safe security classification to the issue's content (machine-filed or human-filed): a finding is security-class if it reads as a security concern, carries no stable `finding_class`, was a Critical, or is secret-shaped. When in doubt, treat it as security-class.

If the selected issue screens security-class, **do not open a public `Closes #N` fix PR.** Apply the visibility gate, re-reading `gh repo view --json visibility` immediately before acting (a repo can flip from PRIVATE to PUBLIC):

- **PUBLIC or INTERNAL** → **divert** to the redacted operator/advisory surface and stop. Surface a count-only pointer to the operator and wait; never auto-disclose, never auto-draft an advisory, never open a public fix PR. On a public repo, opening a `Closes #N` PR for a security issue completes a coordinated-disclosure failure, which this screen exists to prevent.
- **confirmed PRIVATE** → the fix PR stays inside the private repo, so draining proceeds normally.

A security-class issue's detail never reaches a public PR, the PR comment, or the Actions log.

## Resolve one issue

For the selected (non-diverted) issue:

1. **Confirm the handler class.** The issue body carries an advisory `Handler: prompt` or `Handler: plan`. Read the code and override it if warranted. A fieldless human-filed issue carries no `Handler:` line, classify it on selection: `prompt` when the fix is a single logical unit confined to one file with no public-contract change and no cross-module ripple, `plan` otherwise. The resulting fix PR's scope must match the assigned class. When the honest class is `plan` (cross-module or contract-changing), say so before implementing so the human knows the fix is larger than a one-file edit; it is still one issue per invocation.
2. **Cut a fresh branch** from the default branch.
3. **Implement the fix** following the project's normal conventions (TDD, surgical changes).
4. **Run the Quality Gate** (`.claude/rules/quality-gate.md`) before committing, then commit and push.
5. **Open the PR** with `gh pr create`. The PR body includes `Closes #N` (GitHub's auto-close keyword) so the merge closes the issue natively.

The PR is an ordinary in-scope source change: it passes the **same** `code-review-audit` marker gate as any feature PR. Let the normal gate produce a real marker; do not bypass, fake, or pre-empt it. Getting that marker and completing the merge are covered under *Confirm intent, then drive the PR to merge* below.

## Touch the debt-count sentinel

After opening the fix PR, set the staleness sentinel so the statusline recomputes the open count on the next tick:

```bash
mkdir -p .gaia/local/debt && : > .gaia/local/debt/refresh-requested
```

**Create the parent dir first.** On a fresh clone or in CI no statusline tick has run, so `.gaia/local/debt/` may not exist and a bare `touch` would fail silently and leave the sentinel unset. The deterministic merge-event sentinel-set is owned by the `gh pr merge` PostToolUse hook; when the skill drives the merge that hook fires in-session, and on an open-PR-only run or a queued `--auto` merge the merge lands later, so this in-conversation touch is best-effort belt-and-suspenders.

## Confirm intent, then drive the PR to merge

After the PR is up, ask the human whether to **open the PR only** or **open and merge**. Default to **merge** on empty input: the candidate was already chosen, so this is a light checkpoint, not a second selection. On **open only**, stop here; the PR clears the gate and a human merges it later.

On **merge**, resolve the PR to completion through `wiki/concepts/PR Merge Workflow.md`, read it, don't merge from memory. Follow its marker handshake; do **not** substitute a bare `gh pr merge`:

- **Resolve the audit mode** for the PR author with the workflow's portable helper (`.gaia/scripts/read-audit-ci-config.sh --resolve-author <login>`). This reads the project's own `.gaia/audit-ci.yml` (team `default_mode` plus per-author overrides), so the flow obeys an adopter's config instead of assuming the maintainer's CI.
- **Get a real marker for HEAD.** In `ci` mode, wait for CI's `GAIA-Audit` success status (a `pending` status is not a marker, and `--auto` cannot skip this: the local merge hook denies `gh pr merge` until the marker exists). In `local` mode, or when the audit workflow is absent, run the `code-review-audit` agent as the producer; on a clean pass it writes the marker and posts the success status. If the whole diff is out of audit scope, the workflow's out-of-scope bypass clears the merge with no marker. Never hand-write, fake, or pre-empt the marker, an in-scope debt fix earns its marker the same way every feature PR does.
  <!-- gaia:maintainer-only:start -->
- **Clear the CHANGELOG gate.** The workflow's maintainer-only CHANGELOG gate applies to debt PRs too: decide whether the fix needs an `## [Unreleased]` entry and, if so, land it on the branch before merging (re-confirm the marker still covers HEAD after the extra commit). Scrubbed from adopter bundles, so adopters never run this step.
  <!-- gaia:maintainer-only:end -->
- **Merge, then verify before cleanup.** Run `gh pr merge <N> --squash --delete-branch`; if branch protection rejects with "base branch policy prohibits the merge", add `--auto` (never `--admin` without explicit permission) so GitHub queues the merge behind the remaining required checks (Tests, Chromatic). Bounded-poll `gh pr view <N> --json state` for `MERGED` (~2-3 minutes). On `MERGED`, run post-merge cleanup: `git checkout main && git pull`, `git branch -D <branch>`, `git fetch --prune`. If it is still queued when the poll window closes, report "merge queued via --auto; completes when checks pass" and return **without** cleanup, deleting the local branch before `MERGED` strands it against an open PR.

`Closes #N` in the PR body auto-closes the issue on merge, so no separate close call is needed.

## list subcommand

Run the ordering command above and print the backlog in sorted order: per issue, the number, title, severity band, and age. Author nothing and prompt for nothing.

## why subcommand

Run the ordering command, find the issue whose number matches the argument. Explain it: where it sits in the ordering (its severity band and its position among equal-severity issues by age), its recommended handler class (the issue's advisory `Handler:` line, or your on-the-fly classification for a fieldless issue), and the rationale. If no open `tech-debt` issue matches the number, say so and print the ordered backlog. Author nothing and prompt for nothing.

## Guardrails

- **Exactly one issue per invocation.** No batch draining.
- **Deterministic ordering, never an LLM evaluator.** The order is the `--jq` sort above over severity labels and `createdAt`; no model ranks the backlog.
- **Within-band FIFO, severity-first.** Highest severity first, oldest first within a band. Cross-band fairness / anti-starvation is out of scope.
- **The skill drives the merge, never the gate.** After a default-merge confirmation it resolves the fix PR to completion through the standard PR Merge Workflow's marker handshake, running `gh pr merge` only once a real marker exists for HEAD. Never bypass, fake, or pre-empt the marker, and never substitute a bare `gh pr merge` for the workflow's gate.
- **Security screen before any public PR.** A security-class selected issue diverts via the visibility gate on PUBLIC/INTERNAL; only a confirmed-PRIVATE repo drains it as a normal fix PR.
- Use repo-relative paths only.
