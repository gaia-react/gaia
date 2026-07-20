---
type: concept
status: active
created: 2026-06-30
updated: 2026-07-16
tags: [concept, claude, review]
---

# Audit Disposition and Debt Fix

Every finding the [[Code Review Audit Agent]] surfaces carries a **forced disposition** before its marker clears. In-scope findings keep their existing handling (a self-heal commit or an escalation that blocks the marker). Out-of-scope findings, debt in code the PR did not change but the audit opened anyway within its review radius, route out of the gating Critical/Important/Suggestions sections into a separate disposition: a deduped, severity-labeled `tech-debt` GitHub issue, a diverted security surface, or a backend-absent waive. The `/gaia-debt` skill then fixes that backlog one fix unit at a time, a unit being a single issue or a user-approved related batch, and a statusline segment surfaces the open count.

The system **fails open**. A definitively-absent issue backend makes the whole feature inert. A transient backend failure never silently drops a finding and never blocks the merge. The single intended block is a genuinely-missing disposition on a present, writable backend.

## Two-axis disposition matrix

A finding sorts on two axes: **scope** (in-scope vs out-of-scope) and **resolution** (auto-safe vs needs-human). Only the out-of-scope row is new; the in-scope row is the existing audit behavior.

| | auto-safe | needs-human |
|---|---|---|
| **in-scope** | self-heal commit in the working tree | escalation; blocks the marker until the operator resolves it |
| **out-of-scope** | filed `tech-debt` issue (non-security), or backend-absent waive | diverted security surface (never a public channel); `/gaia-debt` fixes the filed backlog |

The audit never edits the reviewed PR's working tree for an out-of-scope finding: it files, it does not fix. Auto-fixing debt the PR did not touch would breach surgical-changes.

## Scope classification

Each surviving finding (one that clears the proof gate and any adversarial verification) is tagged against the audit base's changed line ranges:

- **in-scope**: the finding's `file:line` falls inside the PR's changed line ranges. It flows into the Critical/Important/Suggestions sections and gates the marker exactly as before.
- **out-of-scope**: the defective line is outside those ranges, but the audit already opened the file within its review radius, a caller, a test, an upstream guard, or an importer of a changed export (the same files the incremental-scope importer recheck opens).

The bound is hard: the audit **never opens an unrelated file to hunt for debt**. Out-of-scope filing is a byproduct of reviewing the diff and its review radius, never a whole-file or whole-repo sweep. A file the audit never opened to review the diff is out of bounds and its debt is not filed.

## Out-of-scope disposition

For each out-of-scope finding the audit classifies security first (below), probes the backend, then either files or diverts.

### Filing a tech-debt issue

A non-security out-of-scope finding on a present backend files as a `tech-debt` GitHub issue carrying a **frozen versioned dedup key**, a single HTML-comment line present verbatim in the body:

```
<!-- gaia-debt-key: v1 class=<finding_class> path=<repo-relative-posix-path> line=<integer> -->
```

The body is self-contained: the dedup-key line, the `file:line`, a concrete failure mode, a suggested fix, and a handler-class line (`prompt` or `plan`, advisory only). The issue carries exactly one `severity:*` label (mapped from the finding's report tier) plus `tech-debt`; a machine-graded filing also carries exactly one `difficulty:*` label, and an issue carrying none is ungraded, a normal case; a deliberately-closed finding carries the GitHub `wontfix` label instead so it is not re-filed.

The `file-tech-debt` skill (`.claude/skills/file-tech-debt/SKILL.md`) is the source of truth for the filing mechanics: key construction, the `--body-file` invocation, idempotent labels, the body schema, and the sentinel touch.

### Idempotent dedup

Filing is idempotent. Before creating, the audit dedups by **exact local substring match** (never `gh` full-text search, which tokenizes on `/ : @` and cannot reliably match the key):

1. `gh issue list --label tech-debt --state open` → exact substring match of the key line in each body.
2. `--state closed` → an exact key match on a closed issue carrying `wontfix` (or closed as not-planned) is a **declined** finding; do not re-file.
3. Keyless human-filed fallback → a bare `<path>:<line>` substring in an open `tech-debt` body suppresses the re-file even with no machine key present.

The dedup is re-checked immediately before `gh issue create` to shrink the TOCTOU window for a concurrent CI-plus-local run.

## Security classification and divert

Security classification runs **before** any filing path, and it screens the finding's **content and severity, never its `finding_class` field**. A finding is **security-class** (fail-safe) if any of these hold, regardless of its `finding_class` tag: it came from the security review dimension, its content reads as a security concern (an exploitable weakness), its severity is Critical, it is secret-shaped, or its `finding_class` field is absent or malformed (a broken finding record, which diverts rather than publishes). Exact-string matching on the seeded security classes alone is insufficient, severity is demotable and several security dimensions have no seeded class, so when in doubt the audit treats a finding as security-class.

The authoritative `finding_class` vocabulary (`HOLISTIC_FINDING_CLASSES`, `RULE_FINDING_CLASSES`, and the oracle prefixes) is the closed canonical set defined in the CLI schema; this page references it rather than re-listing the security members. `OUT_OF_SCOPE_FALLBACK_FINDING_CLASS` (`holistic/unclassified`) is the dedup-key fallback for a finding that maps to no seeded class; that constant is not a member of the closed finding-class vocabulary and is never emitted in the findings block; it only builds a dedup key.

**`holistic/unclassified` is not a security trigger.** The closed vocabulary is small by design, so the fallback is the *expected* class for most out-of-scope findings, not a signal that a finding is unknown or dangerous. It means the finding sits outside the closed finding-class vocabulary and nothing more. Keying the security screen on it would divert every out-of-scope finding on a public repo, file nothing, and leave the debt backlog permanently empty and `/gaia-debt` unable to fix anything: an off switch rather than a gate. The security screen and the finding-class vocabulary are independent axes.

Because "any Critical" and "security-shaped content" are both security-class triggers, an out-of-scope **Critical** or a finding whose content reads as a security concern is security-class and routes through the visibility gate before any public filing. `gh repo view --json visibility` returns `PUBLIC | PRIVATE | INTERNAL`, re-read immediately before each security-relevant write (a repo can flip); any non-confirmed-`PRIVATE` state diverts.

- security-class on **PUBLIC or INTERNAL** → **divert**, never a public or internal issue:
  - **local run**: a redacted operator surface at `.gaia/local/audit/security/<HEAD-sha>.md` (gitignored) plus a count-only pointer (no detail) in the report. The operator is surfaced to and the flow waits; nothing is auto-drafted or auto-disclosed.
  - **CI run**: a redacted count-only signal in the public PR comment (`N security-class findings diverted; maintainer must review`), never the detail.
- security-class on **confirmed PRIVATE** → file as a normal private `tech-debt` issue, fully dedupable and fixable.

A security-class finding's detail never reaches a public or internal issue, the PR comment, the Actions log, or the progress breadcrumb file (`.gaia/local/audit/<tree-sha>.progress.log`); a diverted finding contributes only to counts on those surfaces. A diverting finding that maps to no seeded class still builds its dedup key with the fallback class, so the operator surface and any future dedup stay well-formed; the fallback is what the key is built with, never what makes the finding divert. Either disposition (`filed` or `diverted`) lets the marker write, so the never-public guarantee never deadlocks the merge.

## The disposition gate and the marker

The disposition gate is the **fourth marker precondition**, alongside the three existing ones (no in-scope Critical, every in-scope Important addressed, every in-scope Suggestion auto-fixed or escalated), which are now scoped to in-scope findings. Before writing the marker the audit re-queries open `tech-debt` issues for each out-of-scope key and confirms each `filed` entry still resolves to an open issue carrying the key.

The audit records its decision in a gitignored **disposition-ledger sidecar** at `.gaia/local/audit/<frontend-digest>.dispositions.json`, keyed to the frontend member's own content digest (`findings: []` when none were identified, so a reader can tell "audit ran, none identified" from "no sidecar"). Each entry carries the dedup key's inner content (the `v1 class=… path=… line=…` text without the `<!-- gaia-debt-key: … -->` wrapper), its severity, `security_class`, and a `disposition`:

- `filed`: an open `tech-debt` issue carries the key (`issue_number` set).
- `diverted`: security-class diverted; no public issue.
- `waived`: backend definitively absent; the finding reverts to prose only.
- `pending` with `pending_reason: "transient"`: a transient `gh` failure; the finding is surfaced and retained for the next idempotent run.
- `pending` with `pending_reason: "definitive"`: a definitive filing failure on a present, writable backend; the disposition is genuinely missing.

The marker writes when every entry is `filed`, `diverted`, `waived`, or `pending(transient)`. It is withheld **only** on `pending(definitive)`, the one intended block: the operator resolves the filing failure and re-invokes before the marker clears. Backend-absent, transient, and diversion-failure cases all fail open and never block the merge.

### Backend probe (three outcomes)

The audit probes the issue backend once at the start of the disposition flow:

- **Definitive-absent** → waive: file nothing, the gate waives, out-of-scope findings revert to prose, the marker writes. Triggers: repo unresolvable, `gh` unauthenticated, Issues disabled (`gh repo view --json hasIssuesEnabled` false or a structurally-failing issue-list probe, never `gh repo view` resolution alone), or the viewer lacks write permission.
- **Transient/ambiguous** → do not waive, do not drop: timeout, rate-limit, 5xx. Surface the finding and retain it for the next run; dedup makes the retry safe. Never block the merge.
- **Present** → proceed with dedup, filing, or divert.

### Deterministic backstop hook

The audit's verify-after-file re-query is agent behavior, not code. `.claude/hooks/audit-disposition-check.sh` is the deterministic backstop: a PreToolUse hook that gates `gh pr merge` alongside `pr-merge-audit-check.sh` and `worthiness-presence-check.sh`, each denying independently. It re-reads the sidecar for the current frontend content digest and denies the merge on exactly three conditions:

1. a `filed` entry whose key has **no** matching open `tech-debt` issue on a reachable backend,
2. a `pending(definitive)` entry, or
3. a valid frontend earned marker for the current digest whose sidecar is absent (every audit run writes a sidecar, even an empty one, so a missing sidecar alongside a valid marker means the sidecar was lost, not that nothing was ever filed).

It fails open everywhere else: no sidecar with no valid marker either, backend `absent`, every `filed` entry confirmed, all entries diverted/waived/pending(transient), or any `gh`/tooling failure. It also fails closed when the frontend digest itself cannot be derived (a missing sha256 tool, an unloadable classifier/machinery library, or a failing `git ls-tree`), since a digest-keyed gate that cannot compute its own key has no sidecar to check. A match is an issue body that **contains** the sidecar key as a substring, never whole-line equality. The CI workflow grants the job `issues: write` and adds `Bash(gh:*)` to the agent's `--allowedTools` so the same filing path runs from CI.

### Seed-forward

The audit agent is not the sidecar's only writer. When `code-audit-frontend` writes the sidecar for a new frontend digest, it seeds it from the immediately-prior frontend digest's sidecar (located deterministically by recomputing the frontend digest at the incremental base, no anchor selection) via `disposition_seed_forward`: every still-open entry (`filed`, or `pending` with `pending_reason: "definitive"`) in the predecessor sidecar unions into the new one, in place. HEAD's own fresh entry always wins a key collision; a seeded entry may only add keys it does not already have, so a fresh incremental audit that does not re-encounter a prior out-of-scope finding can never silently drop its still-open receipt across a digest rotation, and an already-satisfied disposition is never resurrected by a stale entry. Because each rotation seeds from its own immediate predecessor, a still-open receipt propagates across an arbitrary run of digest rotations that never re-encounter the finding.

Seed-forward alone would not survive a long idle gap between audit rounds: the SessionStart janitor's ordinary retention window would age out and reap the predecessor sidecar (and its co-keyed frontend marker) once the marker ages past `GAIA_AUDIT_MARKER_RETENTION_HOURS`. The janitor closes that gap with a keep-arm: a `<digest>.dispositions.json` sidecar that still holds at least one still-open entry, and its co-keyed frontend `<digest>.ok` marker, are exempt from the retention reap regardless of age, so seed-forward always finds a live predecessor to read from. See [[Local Working State]] for the full janitor keep-arm contract.

### Sibling: the re-run carry-forward ledger

The local re-run carry-forward ledger (`.gaia/local/audit/<base-sha>.rerun.json`) is a distinct artifact from this disposition-ledger sidecar, not an overlap. The sidecar holds **out-of-scope** findings keyed to the frontend member's content digest and gates the merge through the backstop hook; the re-run ledger holds **in-scope** remaining work keyed to the incremental base and never gates anything. They do not overlap and do not read each other: `audit-disposition-check.sh` reads only the dispositions sidecar by exact path, so the re-run ledger is invisible to merge gating. See [[Code Review Audit Agent]] for the ledger's role in the local fix → re-audit loop.

## /gaia-debt: fixing the backlog

`/gaia-debt` (`.claude/commands/gaia-debt.md`, playbook at `.claude/skills/gaia/references/debt.md`) fixes the `tech-debt` backlog the audit files, resolving **one fix unit per invocation**: a single issue, or a user-approved related batch of issues that share a file or subsystem. The unit runs on a fresh isolated branch through the same `code-audit-frontend` marker gate every feature PR passes, with one `Closes #N` line per member issue in the PR body so the single merge closes every issue in the unit natively. The happy path runs start to finish like `/update-deps`: once the unit is chosen and isolated the skill implements the fix(es), gates, commits, pushes, opens the PR, and drives straight to merge with no second confirmation, resolving the PR to completion through the same [[PR Merge Workflow]] every standard merge follows: resolve the audit mode, earn a real `code-audit-frontend` marker for HEAD, clear the maintainer-only CHANGELOG gate, merge with `--auto` under branch protection (never `--admin`), then verify the PR reports `MERGED` before cleanup. It never bypasses, fakes, or pre-empts the marker gate, and never substitutes a bare `gh pr merge` for the workflow's handshake.

Before reading the backlog, `fix` reconciles stale claims left by an ungraceful session death: a claim is live if a `debt/…` branch names the issue, an open PR closes it, or it was updated within a ~30-minute grace; otherwise the label is stripped and the issue re-enters the backlog. The age grace makes claim-first safe, a just-locked issue has no branch yet. Only `fix` reconciles or strips a claim; `list` and `why` are read-only. `fix` excludes in-progress issues from both the candidate pool and the clustering pass; `list` still shows them annotated `[in progress]`, and `why <issue-number>` reports an issue's claim status alongside its severity band and cluster.

The ordering is a pure, source-checkable sort, never an LLM evaluator: severity descending (`severity:critical → 3`, `severity:important → 2`, `severity:suggestion → 1`, a label-less issue falls to the suggestion band), then `createdAt` ascending within a band (oldest first, FIFO). `list` prints the ordered backlog, annotated with each issue's difficulty grade; `why <issue-number>` explains where one issue sits, its recommended handler class, its difficulty grade, and any related cluster it belongs to; an ungraded issue shows no difficulty annotation in either case; bare or `fix` runs the fix flow, which pauses only for the up-front candidate/batch pick and, depending on the team's isolation policy, the isolation pick, then runs start to finish to merge. A bare issue number (`999` or `#999`, equivalently `fix 999`) fixes that specific issue directly, bypassing the top-of-backlog recommendation.

After the sort, a second deterministic pass clusters the ordered backlog into related groups: no model call ranks or clusters the backlog, clustering is a pure function of parsed fields, exactly like the sort. Two issues cluster when they share the dedup-key `path` (primary signal, byte-identical `path=`), or share the same `class` and the same directory (secondary signal; a shared directory alone is too weak). A cluster of two or more members is a batch candidate; a singleton fixes the normal one-issue way. Clustering itself is security-blind, but the **offer** is not: before presenting the choice, `/gaia-debt` reads repo visibility once. On a confirmed-PRIVATE repo every cluster is batch-eligible; on any non-PRIVATE repo a security-class issue is never public-batch-eligible, so a security-class top candidate never anchors a public batch and surfaces only as its own single candidate. The recommended batch, when one exists, is the top cluster all of whose members are public-batch-eligible.

With exactly one open issue, the skill states it (number, title, severity band, age) and fixes it directly, no prompt. With two or more, it presents the choice through a single `AskUserQuestion` (header `Debt item`, single-select, built-in **Other**, capped at 4 options). When the top candidate heads a public-batch-eligible cluster, a batch is recommended: option 1 is `Batch #<A> #<B> #<C> (Recommended)`, option 2 is the explicit one-at-a-time opt-out `#<A> only`, and any remaining slot is the next distinct candidate (itself offered as a batch when it heads its own cluster). When the top candidate is a singleton, the singleton path is unchanged: the top three candidates as options, top one first and labeled `(Recommended)`, each carrying the severity band and age, and any shown candidate that heads a cluster rendered as a batch option instead. One-at-a-time stays an explicit, always-available choice: the `#<A> only` option, the built-in **Other** (type any open issue number to fix it alone), and the singleton path together guarantee it; a batch is always a recommendation the human approves, never a default that skips the choice. A backlog deeper than the shown options first prints the full ordered list, annotated with cluster membership, so numbers beyond the shown options are visible before choosing. A typed value that isn't an open `tech-debt` issue number triggers a re-prompt rather than fixing an off-list issue.

Once the unit is picked, `/gaia-debt` claims each selected member with the gaia-owned `debt:in-progress` label as the first action, before the security screen and before isolation, so a concurrent session on the same checkout stops offering the same ticket and its statusline count drops. On a race, a peer session already holding the label, `fix` drops that member: a single-issue pick re-presents the refreshed backlog, and a batch proceeds with the surviving members.

Before opening any fix PR, the skill re-applies the fail-safe security screen to every member of the selected fix unit and re-reads visibility. It screens each member's **content**, never the dedup key's `class=` field, so `holistic/unclassified` peels nothing. On a PUBLIC or INTERNAL repo, any member that screens security-class is peeled from the unit and diverts individually to the redacted operator surface, opening a public `Closes #N` PR for a security issue would complete a disclosure failure the screen exists to prevent; the remaining non-security members proceed as the (possibly smaller) unit; a peeled member's claim releases too, the label stripped and the issue restored to the backlog offer, since it no longer proceeds in this unit. Only a confirmed-PRIVATE repo fixes a security-class member as a normal fix PR. A `/gaia-debt` fix PR is otherwise an ordinary in-scope change that passes the normal gate.

The audit's filing screen runs first and never files a security-class finding as an issue on a PUBLIC or INTERNAL repo, so every machine-filed issue in a public backlog is non-security by construction. That makes this screen a backstop over a small, well-defined set rather than a re-judgment of the whole backlog: it exists to catch a **human-filed** security-sensitive issue, and a repo that **flips PRIVATE → PUBLIC** with previously-filed security issues still in its backlog.

Before creating the fix unit's branch, `/gaia-debt` chooses isolation the same way the plan orchestrator does; see [[Task Orchestration]] for the mirrored machinery. On `main`/`master`, `/gaia-debt` resolves isolation through the shared isolation reference, which reads the team's committed isolation policy from `.gaia/automation.json`. Depending on that policy it either goes straight to a worktree or presents the choice with the team's preferred mode leading. A team that has never set a policy sees the choice presented exactly as it always has been. On any other branch no prompt fires and a worktree is forced, under every policy value, because work already on a branch must not tangle with a second branch's work in one checkout. Worktree mode runs the whole fix, implementation, Quality Gate, commit, push, PR, marker gate, and merge, inside `.claude/worktrees/<branch-name>/`, and discards the worktree after a confirmed squash-merge, or, when running in an isolated subagent context, emits a copy-paste continuation prompt whose cleanup command is a session-independent `git worktree remove --force` rather than a call to `ExitWorktree`. Feature-branch isolation cuts the branch in place and cleans up with the ordinary `git branch -D` delete. The isolation choice fires exactly once per fix, whether the unit is a single issue or a batch, after the security screen and before any branch exists. The branch name follows a fixed convention: `debt/<issue-number>-<slug>` for a single issue, `debt/<members-joined-by-dash>-batch` (ascending, e.g. `debt/42-45-47-batch`) for a batch, naming every member so the reconcile's branch-liveness check protects every member, not just the lowest.

The claim's lifecycle closes out with the unit: a controlled stop before merge releases it, and a confirmed merge best-effort clears it, the `Closes #N` close already drops the issue from the open count independent of the label, so the clear is a courtesy, not a dependency. Anything left dangling after an ungraceful session death is recovered by the next fix-start reconcile rather than a dedicated cleanup step.

## Statusline and debt-count refresh

A statusline segment, `Run /gaia-debt (N issues)` (`issue` singular at N==1), surfaces the open count, matching the other right-side `Run /<skill> (N noun)` indicators and suppressed in linked worktrees and before per-clone setup. It reads a pinned cache at `.gaia/local/debt/count.json` (`{"schema":1,"openCount":<int>,"computedAt":<unix-epoch>}`), so the no-network statusline hot path never recomputes inline. A worktree-mode debt fix therefore shows no `Run /gaia-debt` nudge inside its own worktree, expected and harmless: the background refresher still writes the canonical shared cache the main checkout reads.

`.gaia/scripts/debt-count-refresh.sh` runs detached in the background each tick. It recomputes `openCount` via `gh issue list --label tech-debt --state open` and subtracts open issues carrying `debt:in-progress`, so a claimed issue does not inflate the `Run /gaia-debt` nudge for a peer session on the same checkout, then rewrites the cache when a staleness sentinel (`.gaia/local/debt/refresh-requested`, an empty marker file) is present or the cache is older than its own TTL, independent of the aggregate update-check TTL. On any `gh` failure it preserves the previous count rather than blanking it; a backend-absent run with no prior cache seeds `openCount` 0 so no segment renders. The 120-second settle grace below, which tolerates GitHub's eventually-consistent index for a just-closed issue, covers a claim the same way: a recompute that fires immediately after a claim and still counts the issue is corrected once a later tick observes the settled label.

A single `gh` PostToolUse hook (`.claude/hooks/debt-sentinel-touch.sh`) sets the sentinel deterministically after any of the five commands that move the open count: `gh issue create`, `gh issue edit`, `gh pr merge`, `gh issue close`, and `gh issue reopen`. `gh issue edit` arms the hook alongside the other four because the `/gaia-debt` in-progress claim toggles `debt:in-progress` via that exact command, and since the count excludes a claimed issue, an edit that adds or removes the label changes the displayed count. The hook matches on the command shape alone and does not resolve whether the issue carried the `tech-debt` label: touching the sentinel only schedules a recompute, so a broad match is harmless. Two in-flow touches complement it as best-effort belt-and-suspenders, not replacements: the audit touches the sentinel after it files an issue (the file-tech-debt skill's sentinel-touch step, which runs inside the audit subagent), and the `/gaia-debt` skill touches it after opening a fix PR. A mutation performed directly in the **main** session, most notably a `gh issue create` or `gh issue close` a human or the assistant runs by hand, is caught only by the hook, so the hook is what keeps those prompt rather than TTL-delayed. Every sentinel or cache writer runs `mkdir -p .gaia/local/debt` first, because the directory is not assumed to pre-exist on a fresh clone or in CI.

A mutation that never reaches a first-party hook, a close from the GitHub web UI, a teammate, or a plain `gh issue close` in a non-hooked shell, is reconciled on the next session start. The `startup|resume` SessionStart hook (`.claude/hooks/debt-session-reconcile.sh`) arms the sentinel when, and only when, the pinned cache already shows an open count greater than zero, so an empty backlog stays fully network-free (no sentinel, no `gh` call). It therefore reconciles the count **downward** only: a `tech-debt` issue opened externally while the local count is zero still surfaces on the next TTL, not the session start. A count that is stale-high, the case where the nudge lingers after the backlog has actually emptied, clears on the first session start after the close.

GitHub's issue-list index is eventually consistent, so a recompute fired immediately after a merge can still count the just-closed issue for a few seconds. The refresher holds the sentinel armed through a 120-second settle grace after each recompute, writing the fresh count but not yet clearing the sentinel, so a later tick re-reads the now-consistent count before the nudge clears; a sentinel older than the grace clears normally on the next genuine recompute. Sentinel age is read via a portable mtime probe, GNU `stat -c %Y` first, falling back to BSD/macOS `stat -f %m`, with a numeric check between the two attempts (GNU's `-f` variant exits 0 with a non-numeric result instead of failing, so the check rejects rather than accepts that garbage); an unreadable mtime reads as already past the grace so a stat failure never wedges the sentinel armed indefinitely.

## Relationship to the Policy-Memory Loop

`/gaia-debt` and `/gaia-harden` (the [[Policy-Memory Loop]]) share the `finding_class` vocabulary but do not overlap. `/gaia-harden` hardens recurring **forms**: when the same `finding_class` recurs across distinct PRs, it drafts the lowest-context-weight guard (a deterministic check, skill, or path-scoped rule) so the class stops recurring. `/gaia-debt` fixes concrete **instances**: the specific out-of-scope defects the audit filed as `tech-debt` issues, one fix PR at a time. One governs the rule that prevents a pattern; the other clears the individual debts already on the books.

## Deferred (not yet built)

The following are intentionally out of scope for the current implementation and are not yet built:

- **Line-drift-tolerant dedup.** The dedup key is `finding_class` + `file:line`; a residual line-drift duplicate risk is accepted.
- **CI security-advisory credential mechanism.** The default `GITHUB_TOKEN` cannot create a repository advisory, so a CI security divert reverts to a redacted maintainer count-only surface rather than a private advisory.
- **Durable fix for diverted PUBLIC/INTERNAL security findings.** Only the confirmed-PRIVATE-repo private-issue path is dedupable and fixable; a diverted PUBLIC/INTERNAL security finding has no durable backlog.
- **Cross-band fix fairness.** `/gaia-debt` is within-band FIFO, severity-first; cross-band fairness and a starvation guard are out of scope.
- **Schema-level same-run identifier.** The relatedness heuristic clusters on the existing dedup-key `path`/`class`+dirname fields, deriving relatedness without a new field; a same-run identifier for tighter batch grouping is a possible future refinement.

## Pairs with

- [[Code Review Audit Agent]]: the producer; classifies scope, disposes out-of-scope findings, and writes the disposition-ledger sidecar.
- [[PR Merge Workflow]]: the disposition gate is the fourth marker precondition; the backstop hook gates `gh pr merge`.
- [[Policy-Memory Loop]]: the sibling `finding_class` consumer; hardens recurring forms while `/gaia-debt` fixes concrete instances.
