# /gaia-debt

Drain the `tech-debt` backlog the audit files. `/gaia-debt` reads the open `tech-debt` issues, orders them deterministically (highest severity then oldest first, no model call), recommends the top candidate, and resolves **one drain unit** per invocation, a single issue or a user-approved related batch of issues, on a fresh branch through the same `code-audit-frontend` marker gate every feature PR passes, with one `Closes #N` per member issue in the PR body so the merge closes every issue in the unit natively.

The ordering is a pure, source-checkable sort over the issues' severity labels and `createdAt` timestamps. It never calls a model to rank the backlog, and it never resolves more than one drain unit per run.

## Execution model, READ FIRST

Execute the playbook yourself in the current conversation. The happy path runs start to finish without stopping, exactly like `/update-deps`: once the drain unit is chosen and isolated the skill implements the fix, runs the Quality Gate, commits, pushes, opens the PR, clears the marker gate, and merges, all in one invocation. There are **up to two** up-front interactive decisions, in order: (1) the candidate/batch pick, only when the backlog holds two or more issues, and (2) the isolation-mode pick (`## Pre-flight isolation (branch vs worktree)` below), only when HEAD is on `main`/`master`, a silent forced worktree with no prompt on any other branch. After both, the flow does not pause for confirmation. Pause only when input is genuinely needed (those two picks) or something unexpected blocks the path (a security-class diversion, a rejected push, a gate that will not go green). Resolve **one drain unit** per invocation, a single issue or a user-confirmed related batch; the skill never auto-advances to an unrelated issue.

The skill drives a fix PR through the **full** PR Merge Workflow (cut a branch, implement, run the Quality Gate, commit, push, `gh pr create`, then the marker handshake and merge). Once the PR is up it drives straight through to merge with no second confirmation, resolving the PR to completion the standard way: the same `code-audit-frontend` marker gate every feature PR passes, then `gh pr merge`. The gate is inviolate: never bypass, fake, or pre-empt the marker, and never substitute a bare `gh pr merge` for the workflow's handshake.

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

After the sort, run a second deterministic pass that clusters the ordered backlog into related groups. No model call ranks or clusters the backlog: clustering is a pure function of parsed fields, exactly like the sort. It never changes the sort order, it only groups issues within it, so `list`, `why`, and `drain` all agree on the clusters too.

Parse each issue's dedup key from its `body`, the `<!-- gaia-debt-key: v1 class=<finding_class> path=<repo-relative-posix-path> line=<integer> -->` comment defined by `.claude/skills/file-tech-debt/SKILL.md` step 1, into `class` and `path`. A keyless human-filed issue falls back to the same `<path>:<line>` body scan `file-tech-debt/SKILL.md` step 2.3 uses to recover a `path`; if no path is parseable at all, the issue does not cluster and stands alone.

Two issues belong to the same cluster when either holds, strongest signal first:

1. **Same `path`.** Byte-identical dedup-key `path=` values. Fixing two defects in one file is the canonical case for fixing them together.
2. **Same `class` and same directory.** Identical `class=` values whose `path` share the same `dirname` (immediate parent directory), the same root-cause pattern in one subsystem.

A shared directory alone is too weak to cluster on (a whole `app/services/` directory is not one fix); only same-`path` or same-`class`-plus-same-dirname cluster. A **cluster is a batch candidate only when it has 2 or more members**; a singleton drains the normal one-issue way. Clustering is security-blind: it never looks at severity, security-classification, or repo visibility, those are handled where the batch is offered (below).

## Recommend and present (drain)

The top candidate is the first in the sorted list. Before building the prompt, resolve which cluster, if any, anchors the recommendation.

**Offer-time security read.** Clustering itself is security-blind, but a security-class issue can never share a public `Closes #N` PR, so the offer is not. Before presenting, read repo visibility once: `gh repo view --json visibility`. On a **confirmed-PRIVATE** repo every cluster is public-batch-eligible as-is. On any **non-PRIVATE** repo, apply the same fail-safe security classification the Drain-time security screen (below) defines to every candidate issue in the backlog, and treat any security-class issue as not public-batch-eligible: it never appears inside a batch option, only as its own single candidate. Reuse this one read for the Drain-time security screen after selection; it never becomes a second prompt.

The **recommended batch**, when one exists, is the top cluster all of whose members are public-batch-eligible: normally the cluster containing the top-ranked candidate, but a security-class top candidate is never public-batch-eligible on a non-PRIVATE repo, so it anchors no batch and is offered only as its own single candidate. An eligible batch may span severities, a `severity:suggestion` in the same file as a `severity:important` is a cheap add-on.

How you present the choice depends on backlog size and cluster shape:

- **Exactly one open issue** → do not prompt. State the issue (number, title, severity band, age derived from `createdAt`) and drain it directly.
- **Top candidate heads a public-batch-eligible cluster of 2 or more** → a batch is recommended. Offer it with a single `AskUserQuestion` prompt (header `Debt item`, single-select), phrased around the batch, for example: `"Top item #<A> is related to <N> other issue(s) (<shared signal>). Fix them together, or one at a time?"`. Options, top option carrying `(Recommended)`:
  1. `Batch #<A> #<B> #<C> (Recommended)`, description: the shared signal (e.g. "all in app/foo/index.ts"), the member count, the severity span, and "one branch, one PR, all close on merge."
  2. `#<A> only`, description: drain just the top issue (its severity band, its age), one at a time.
  3. (optional) the next distinct candidate slot: a batch option when that candidate itself heads a >= 2 cluster, else a single option.
  - The tool's built-in **Other** entry lets the human type any open `tech-debt` issue number to drain that one alone.
- **Top candidate is a singleton (no cluster), or a security-class top candidate on a non-PRIVATE repo** → present exactly today's shape: the top three candidates as options (or both when only two exist), top candidate first and its label suffixed `(Recommended)`. Any shown candidate that itself heads a public-batch-eligible cluster of 2 or more is presented as a **batch** option rather than a single, which keeps one-at-a-time the default natural path.

Cap the option set at **4** (plus the built-in Other), the `AskUserQuestion` maximum. When the backlog is deeper than the shown options, first print the full ordered backlog (per issue: number, title, severity band, age), now annotated with cluster membership (e.g. `[batch with #B #C]`), so numbers beyond the shown options are visible before choosing.

**Opt-out guarantee.** One-at-a-time stays an explicit, always-available choice: the `#<A> only` option, the built-in Other (type any open issue number to drain it alone), and the unchanged singleton path together guarantee it. A batch is always a recommendation the human approves, never a default that skips the choice.

**Security-class members never appear inside a public batch option.** On a non-PRIVATE repo the offer-time read above already withholds them, they surface only as single candidates. On a confirmed-PRIVATE repo they may appear as batch members.

Honor whatever the human picks or types into **Other**. If a typed value is not an open `tech-debt` issue number in the backlog, say so and re-prompt; do not drain an off-list issue. The skill never auto-advances past the human's choice.

## Drain-time security screen

Before opening any fix PR, screen **every member of the selected drain unit** (a single issue, or every issue in a confirmed batch). Apply the fail-safe security classification to each member's content (machine-filed or human-filed): a finding is security-class if it reads as a security concern, carries no stable `finding_class`, was a Critical, or is secret-shaped. When in doubt, treat it as security-class.

Re-read `gh repo view --json visibility` immediately before acting (a repo can flip from PRIVATE to PUBLIC), reusing the offer-time read above when it already ran; do not add a second prompt:

- **confirmed PRIVATE** → no member peels. The whole unit, single or batch, drains as one private PR; draining proceeds normally.
- **PUBLIC or INTERNAL** → any member that screens security-class is **peeled** from the unit and **diverted individually**: surface a count-only pointer to the operator and wait; never auto-disclose, never auto-draft an advisory, never open a public fix PR for it. The remaining non-security members proceed as the (possibly smaller) unit. If every member peels, there is nothing left to open a public PR for: report the diverts and stop. On a public repo, opening a `Closes #N` PR for a security issue completes a coordinated-disclosure failure, which this screen exists to prevent.

This member-level screen is the **backstop** to the offer-time exclusion in "Recommend and present" above: on a non-PRIVATE repo a security-class issue is already withheld from the offered batch, so this screen mainly guarantees the invariant for a member reached via **Other**.

A security-class issue's detail never reaches a public PR, the PR comment, or the Actions log.

## Pre-flight isolation (branch vs worktree)

This section runs once per drain, single issue or batch, after the security screen above and before the drain unit's branch or worktree exists. Ordering rationale: the security screen can divert and stop a security-class drain before any branch exists, so isolation runs after it and a diverted drain never creates a worktree.

**Check the current branch.**

**If HEAD is on `main`/`master`:** ask via `AskUserQuestion` (the one new interactive gate here; it fires every time HEAD is main/master, never silently defaults):

- question: `"On main. How should this debt drain be isolated?"`
- header: `"Branch mode"`
- options (in this exact order):
  1. `{ label: "Create a feature branch in place (Recommended)", description: "Default. Branch is cut from HEAD and the drain works in the current checkout. Simple, predictable, safe." }`
  2. `{ label: "Create a git worktree", description: "Gives this drain its own separate working copy, cut from main under .claude/worktrees/. You can keep working on your current branch, or run another task, at the same time without the two colliding." }`

If the user picks **Other** with custom text, surface a clarifying question rather than guessing; feature-branch and worktree are the two supported modes.

**Branch naming.** Single-issue drain: `debt/<issue-number>-<slug>` (`<slug>` a 2-4 word kebab-case reduction of the issue title). Batch drain: `debt/<lowest-member-issue-number>-batch`. Whichever isolation mode runs, including the forced worktree below, the branch carries this name.

**If HEAD is on any other branch:** do not offer feature-branch-in-place. Because you are already on a branch, this drain's work goes into its own git worktree cut from main so it does not tangle with the current branch. State that to the user in one line, then proceed straight into Worktree creation below. No `AskUserQuestion` fires here.

### Worktree creation (worktree-mode drains only)

When pre-flight selects worktree mode, chosen from main or forced on the not-on-main path, create the worktree with the runtime tool, passing the branch name above as the worktree name:

    EnterWorktree({name: "<branch-name>"})

The `WorktreeCreate` hook (`.gaia/scripts/create-worktree.sh`) cuts the branch fresh from the remote default branch and switches the session into `.claude/worktrees/<branch-name>/`, so run no manual `git checkout -b`. Every later step, implementing the fix(es), the Quality Gate, commit, push, `gh pr create`, the `code-audit-frontend` marker gate, and the merge, runs from inside the worktree.

Feature-branch mode keeps today's behavior: cut the branch of the same name from the default branch and work in the current checkout.

## Resolve the selected unit

The **drain unit** is the selected (non-diverted) member set: a single issue, or every surviving member of a confirmed batch after the security screen above peels any security-class member. It is still **one drain unit per invocation**.

1. **Confirm the handler class for the unit.** Each member issue carries an advisory `Handler: prompt` or `Handler: plan`, or, for a fieldless human-filed issue, no line at all; classify it on selection the same way as today: `prompt` when confined to one file with no public-contract change and no cross-module ripple, `plan` otherwise. The unit's effective class is the **maximum** over members: `plan` if any member is `plan` (or any fix is cross-module / contract-changing), else `prompt`. A multi-issue batch is usually `plan`. State the honest class before implementing so the human knows the scope, exactly as today's single-issue rule does.
2. **The unit is already isolated.** `## Pre-flight isolation (branch vs worktree)` above already cut the branch or created the worktree before this step, on the frozen name (`debt/<issue-number>-<slug>` single, `debt/<lowest-member-issue-number>-batch` batch). This step does no branch creation of its own.
3. **Implement all fixes in the unit** on the one branch, following the project's normal conventions (TDD, surgical changes).
4. **Run the Quality Gate** (`.claude/rules/quality-gate.md`) once for the combined diff, then commit and push.
5. **Open one PR** with `gh pr create`. The PR body includes **one `Closes #N` line per member issue** (GitHub's auto-close keyword) so the single merge closes every issue in the unit natively. Security-class detail still never reaches a public PR: a security-class issue is either withheld from the offered batch or peeled and diverted by the screen above, so no security-class member ever reaches a public `Closes #N` PR.

The PR is an ordinary in-scope source change: it passes the **same** `code-audit-frontend` marker gate as any feature PR, one gate for the combined diff. Let the normal gate produce a real marker; do not bypass, fake, or pre-empt it. Getting that marker and completing the merge are covered under *Drive the PR to merge* below.

## Touch the debt-count sentinel

After opening the PR, set the staleness sentinel **once per drain** (not once per member issue in a batch) so the statusline recomputes the open count on the next tick:

```bash
mkdir -p .gaia/local/debt && : > .gaia/local/debt/refresh-requested
```

**Create the parent dir first.** On a fresh clone or in CI no statusline tick has run, so `.gaia/local/debt/` may not exist and a bare `touch` would fail silently and leave the sentinel unset. The deterministic merge-event sentinel-set is owned by the `gh pr merge` PostToolUse hook; when the skill drives the merge that hook fires in-session, and on an open-PR-only run or a queued `--auto` merge the merge lands later, so this in-conversation touch is best-effort belt-and-suspenders.

## Drive the PR to merge

Once the PR is up, drive it straight to merge with no confirmation prompt: the drain unit (single issue or confirmed batch) was chosen up front, so this back half runs autonomously, exactly like `/update-deps` merging a dep-bump PR on a `main` run. The only things that stop the flow here are genuine blockers, a rejected push, a marker that never goes green, or a `--auto` merge still queued when the poll window closes; those are reported, not worked around.

Resolve the PR to completion through `wiki/concepts/PR Merge Workflow.md`, read it, don't merge from memory. Follow its marker handshake; do **not** substitute a bare `gh pr merge`:

- **Resolve the audit mode** for the PR author with the workflow's portable helper (`.gaia/scripts/read-audit-ci-config.sh --resolve-author <login>`). This reads the project's own `.gaia/audit-ci.yml` (team `default_mode` plus per-author overrides), so the flow obeys an adopter's config instead of assuming the maintainer's CI.
- **Get a real marker for HEAD.** In `ci` mode, wait for CI's `GAIA-Audit` success status (a `pending` status is not a marker, and `--auto` cannot skip this: the local merge hook denies `gh pr merge` until the marker exists). In `local` mode, or when the audit workflow is absent, run the `code-audit-frontend` agent as the producer; on a clean pass it writes the marker and posts the success status. If the whole diff is out of audit scope, the workflow's out-of-scope bypass clears the merge with no marker. Never hand-write, fake, or pre-empt the marker, an in-scope debt fix earns its marker the same way every feature PR does.
  <!-- gaia:maintainer-only:start -->
- **Clear the CHANGELOG gate.** The workflow's maintainer-only CHANGELOG gate applies to debt PRs too: decide whether the fix needs an `## [Unreleased]` entry and, if so, land it on the branch before merging (re-confirm the marker still covers HEAD after the extra commit). Scrubbed from adopter bundles, so adopters never run this step.
  <!-- gaia:maintainer-only:end -->
- **Merge, then verify before cleanup.** Run `gh pr merge <N> --squash --delete-branch`; if branch protection rejects with "base branch policy prohibits the merge", add `--auto` (never `--admin` without explicit permission) so GitHub queues the merge behind the remaining required checks (Tests, Chromatic). Bounded-poll `gh pr view <N> --json state` for `MERGED` (~2-3 minutes). If it is still queued when the poll window closes, report "merge queued via --auto; completes when checks pass" and return **without** cleanup: deleting the local branch, or discarding the worktree, before `MERGED` strands it against an open PR.

  On `MERGED`, run post-merge cleanup by isolation mode:
  - **Feature-branch mode:** unchanged. `git checkout main && git pull`, `git branch -D <branch>`, `git fetch --prune`.
  - **Worktree mode:** run Post-merge worktree cleanup below instead. Do not `git branch -D` a worktree-held branch.

Each `Closes #N` line in the PR body auto-closes its issue on merge, so on a batch, the single merge closes every member issue and no separate close call is needed for any of them.

### Post-merge worktree cleanup (worktree-mode drains only)

1. Confirm merge via `gh pr view <N> --json state`; require `.state == "MERGED"`. If not merged, do not proceed; surface and stop.
2. **Isolation-context check** (below). If running inside an isolated subagent context, emit the continuation prompt and stop; do not call `ExitWorktree`.
3. Otherwise call `ExitWorktree({action: "remove", discard_changes: true})` directly. `discard_changes: true` is safe: the squash-merge absorbed every commit on the worktree branch, but those commits are not ancestors of `main`, so the runtime would otherwise refuse; the merged-state confirmation in step 1 proves the work is preserved.
4. Report one line: `worktree discarded; PR #<N> squash-merged as <short-sha>`.

Never call `ExitWorktree` first and treat its refusal as the discard trigger; the merged-state confirmation is the primary signal.

### Isolation-context detection (worktree-mode drains only)

The runtime refuses `ExitWorktree` from an agent dispatched with `isolation: "worktree"` or a `cwd` override (refusal text: `ExitWorktree cannot be called from a subagent with a cwd override`). `/gaia-debt` normally runs on the user's own main thread, so the direct in-session `ExitWorktree` path above is the common case; still detect the automation case:

- **Primary signal:** the skill was invoked via `Agent(...)` with `isolation: "worktree"` (dispatch was a sub-agent task and cwd is a worktree path under `.claude/worktrees/`).
- **Fallback:** if uncertain, attempt `ExitWorktree({action: "remove", discard_changes: true})`; if the response contains `cannot be called from a subagent`, treat it as never-issued (a refusal, not a destructive action), branch into the continuation-prompt path, and stop.

When detected, emit this copy-paste continuation prompt to the user and stop:

    The worktree at <ABSOLUTE-PATH-TO-WORKTREE> is ready to discard.
    PR #<N> squash-merged as <short-sha>. From a shell at
    <ABSOLUTE-PATH-TO-MAIN-CHECKOUT>, run:

        git worktree remove --force <ABSOLUTE-PATH-TO-WORKTREE>
        git branch -D <branch-name>   # only if the merge did not already delete it

Do not emit an `ExitWorktree({...})` call in this continuation prompt. `ExitWorktree` only operates on a worktree created by `EnterWorktree` in the current session: from a fresh session it is a no-op on a prior-session worktree, and its schema requires `action` and rejects a `worktree` parameter. A plain `git worktree remove --force` is the correct session-independent cleanup. This matches `plan.md`'s Isolation-context detection block, whose continuation prompt emits the same session-independent shell cleanup.

## list subcommand

Run the ordering command above, then the clustering pass, and print the backlog in sorted order: per issue, the number, title, severity band, age, and cluster membership when it has any (e.g. `[batches with #B #C: same file app/foo/index.ts]`). Author nothing and prompt for nothing.

## why subcommand

Run the ordering command and the clustering pass, find the issue whose number matches the argument. Explain it: where it sits in the ordering (its severity band and its position among equal-severity issues by age), its recommended handler class (the issue's advisory `Handler:` line, or your on-the-fly classification for a fieldless issue), and the rationale. Also report whether it is part of a related cluster, which issue(s) it would batch with, and the shared signal (same `path`, or same `class` and dirname). If no open `tech-debt` issue matches the number, say so and print the ordered backlog. Author nothing and prompt for nothing.

## Guardrails

- **One drain unit per invocation.** A single issue, or a user-confirmed related batch; the skill never auto-advances to an unrelated issue and never batches unrelated issues. Batching is always a user-confirmed choice, with one-at-a-time preserved as the explicit opt-out. Security-class issues never join a public batch.
- **Deterministic ordering, never an LLM evaluator.** The order is the `--jq` sort above over severity labels and `createdAt`; no model ranks the backlog.
- **Within-band FIFO, severity-first.** Highest severity first, oldest first within a band. Cross-band fairness / anti-starvation is out of scope.
- **The skill drives the merge, never the gate.** The happy path runs start to finish with no merge-time confirmation: it resolves the fix PR to completion through the standard PR Merge Workflow's marker handshake, running `gh pr merge` only once a real marker exists for HEAD. Never bypass, fake, or pre-empt the marker, and never substitute a bare `gh pr merge` for the workflow's gate.
- **Security screen before any public PR.** A security-class selected issue diverts via the visibility gate on PUBLIC/INTERNAL; only a confirmed-PRIVATE repo drains it as a normal fix PR.
- Use repo-relative paths only.
