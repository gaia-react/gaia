---
type: concept
status: active
created: 2026-06-30
updated: 2026-10-08
tags: [concept, claude, review]
---

# Audit Disposition and Debt Fix

Every finding the [[Code Review Audit Agent]] surfaces carries a **forced disposition** before its marker clears. In-scope findings keep their existing handling (a self-heal commit or an escalation that blocks the marker). Out-of-scope findings, debt in code the PR did not change but the audit opened anyway within its review radius, route out of the gating Critical/Important/Suggestions sections into a separate disposition: a same-run repair through the self-heal path when the finding qualifies for in-flight-fix promotion (below), a deduped, severity-labeled `tech-debt` GitHub issue, a recorded waive (not filed) when the finding's path is gate machinery or a file the pull request already changes and the finding itself clears both disqualifiers, a diverted security surface, or a backend-absent waive. The `/gaia-debt` skill then fixes the filed backlog one fix unit at a time, a unit being a single issue or a user-approved related batch, and a statusline segment surfaces the open count.

The system **fails open**. A definitively-absent issue backend makes the whole feature inert. A transient backend failure never silently drops a finding and never blocks the merge. The single intended block is a genuinely-missing disposition on a present, writable backend.

## Two-axis disposition matrix

A finding sorts on two axes: **scope** (in-scope vs out-of-scope) and **resolution** (auto-safe vs needs-human). Only the out-of-scope row is new; the in-scope row is the existing audit behavior.

| | auto-safe | needs-human |
|---|---|---|
| **in-scope** | self-heal commit in the working tree | escalation; blocks the marker until the operator resolves it |
| **out-of-scope** | repaired in-flight when it qualifies for promotion (below); recorded `machinery_waived` (not filed) when it is non-security and its path is gate machinery or a file the pull request already changes and the finding itself clears both disqualifiers; otherwise filed as a `tech-debt` issue (non-security); or a backend-absent waive | diverted security surface (never a public channel); `/gaia-debt` fixes the filed backlog |

For most out-of-scope findings the audit never edits the reviewed PR's working tree: it files, it does not fix, since auto-fixing debt the PR did not touch would breach surgical-changes. The one exception is in-flight-fix promotion.

### In-flight-fix promotion

A non-security, in-remit, narrow-footprint out-of-scope finding in a changed TS/TSX file, inside the self-heal repair boundary, is repaired through the existing self-heal path in the same run instead of filed: it rides that path's edit guard, marker-withhold, digest-rotation re-dispatch, and fixed-round recording, with no separate disposition machinery. A finding outside that boundary, security-class, or not prompt-shaped, still files normally, and a filed finding runs a best-effort per-bucket classification, seeding a `finding_class` the debt-drain clustering rule groups on.

## Scope classification

Each surviving finding (one that clears the proof gate and any adversarial verification) is tagged against the audit base's changed line ranges:

- **in-scope**: the finding's `file:line` falls inside the PR's changed line ranges. It flows into the Critical/Important/Suggestions sections and gates the marker exactly as before.
- **out-of-scope**: the defective line is outside those ranges, but the audit already opened the file within its review radius, a caller, a test, an upstream guard, or an importer of a changed export (the same files the incremental-scope importer recheck opens).

The bound is hard: the audit **never opens an unrelated file to hunt for debt**. Out-of-scope filing is a byproduct of reviewing the diff and its review radius, never a whole-file or whole-repo sweep. A file the audit never opened to review the diff is out of bounds and its debt is not filed.

## Out-of-scope disposition

For each out-of-scope finding the audit classifies security first (below), then, for a non-security finding whose path is either the gate machinery itself or a file the pull request already changes and the finding itself clears both disqualifiers, records a waive; otherwise it probes the backend and either files or diverts.

### Out-of-scope waive

An out-of-scope finding whose path is the **gate machinery itself**, or a file the **pull request already changes**, regenerates its own backlog when filed: the next PR that touches the same machinery, or the same file, has its audit re-surface the identical finding, a regeneration loop the `filed` disposition cannot escape. The `machinery_waived` disposition breaks that loop: it records the finding without filing it, so a PR does not seed the backlog with debt about a path it just touched.

The disposition is restricted by a deterministic **path eligibility test**, and by two disqualifiers no gate checks, so it cannot become a universal escape hatch. A finding is `machinery_waived`-eligible only when it is non-security (the security screen runs first, and a security-class finding diverts, never waives) **and** its dedup-key `path` is in the **union** of two sets:

- a **gate-machinery path**, the self-referential set `audit_path_is_machinery` defines (`.claude/hooks/lib/audit-machinery.sh`), the files whose bytes change what a member reviews, who reviews it, where a clearance lands, or whether a clearance is believed;
- a file the **pull request under judgment already changes**: its whole-pull-request fork point against the branch the pull request merges into, unfiltered by file type, resolved against the **acting** tree that holds HEAD rather than the main checkout that holds the marker store, so a merge driven from a linked worktree evaluates its own diff.

Two disqualifiers narrow what may be waived inside that eligible set, and neither widens it: a finding must clear both to stay eligible. No gate checks either one; they sit on the same agent-judgment wall the non-security screen sits on.

**The change authored the inconsistency.** A finding is not waive-eligible when this change is what authors the inconsistency the finding names: the finding's site sits inside this change's own diff, or it is a sibling of a set this change adds a member to, or it is a claim this change falsifies. *Pre-existing* describes a sibling this change leaves untouched, never an asymmetry this change introduces. The bound is not optional: a finding whose defect is latent at the fork point, reading the same whether or not this change lands, is untouched-sibling debt and stays eligible even when it sits in a file this change edits.

**A pointer written into shipped content owes a tracked destination.** A finding is not waive-eligible when this change leaves a pointer in shipped content, a code comment, a header note, a documented limit, or a test rationale, saying that a separate change handles what the finding names. The waive is unavailable and the finding is filed, so the pointer resolves to a tracked destination rather than to prose. This is a rule rather than a standing judgment call: a finding whose destination is named in shipped content is filed, and that filing is correct even when both path terms fire. The obligation runs from the pointer to the filing, never from the filing to the pointer, so omitting the pointer removes the obligation and removes the explanation from the shipped content along with it, and the cost lands on the author's own artifact rather than on the reader.

Either path term alone is sufficient, and a gate-machinery finding satisfies the path condition whether or not the pull request touches it. An empty eligibility set disengages the waive rather than opening it, and a finding satisfying neither term files or diverts as usual. Comparison is **exact whole-string equality** against repo-relative POSIX paths, never a prefix, suffix, basename, or substring match; the changed-file enumeration is NUL-delimited so a legitimately quoted path never reads as an offender. A dedup key the path extractor cannot parse is itself an offender, failing closed.

A machinery-waived finding is recorded as a `machinery_waived` disposition and listed in the PR body under the heading `## Out-of-scope machinery findings (recorded, not filed)`, its dedup key written there in the wrapped `<!-- gaia-debt-key: … -->` form (`.claude/skills/file-tech-debt/SKILL.md`). The PR body is the durable, human-readable record of what was waived. The disposition enum value `machinery_waived` carries no field for the changed-files term; the union lives entirely in how the eligibility test reads the existing `path=`.

An **accepted residual** is a distinct disposition from a machinery waive: a waive covers an out-of-scope finding on an eligible path, while an accepted residual is an in-scope Suggestion or finding the operator defers rather than fixing in this pull request, in the member's own remit ([[PR Merge Workflow#Applying the audit's own Suggestions: digest economics]]). It is recorded under the heading `## Accepted residuals (recorded, not fixed)` in the pull request body and nowhere else: no dependence on any gitignored `.gaia/local` store.

Eligibility is partly **author-controlled**: touching a file at all makes that file's non-security out-of-scope findings waivable, so the eligibility test bounds **where** a waive may be recorded, not **which** findings may be waived. Three walls stand on that second question, all of them agent judgment and none of them gate-checked: the non-security screen, and the two disqualifiers above.

### Filing a tech-debt issue

A non-security out-of-scope finding on a present backend files as a `tech-debt` GitHub issue carrying a **frozen versioned dedup key**, a single HTML-comment line present verbatim in the body:

```
<!-- gaia-debt-key: v1 class=<finding_class> path=<repo-relative-posix-path> line=<integer> -->
```

The body is self-contained and carries no classification fields: the dedup-key line, the `file:line`, a concrete failure mode, and a suggested fix. Every classification axis rides as a label. The issue carries exactly one `severity:*` label (mapped from the finding's report tier, or `severity:investigate` when the tier is not yet knowable, which obliges the body to carry a research block naming the open question and caps how many such issues may be open at once), and exactly one `footprint:*` label (`narrow`, `wide`, or `spec`, recording how far the fix reaches, advisory only), plus `tech-debt`; a filing that reads the cited code as it files also carries exactly one `difficulty:*` label, and an issue carrying none is ungraded, a normal case; a deliberately-closed finding carries the GitHub `wontfix` label instead so it is not re-filed.
<!-- gaia:maintainer-only:start -->

On the GAIA maintainer repository the issue carries one more, exactly one `audience:*` label (`adopter` or `maintainer`, recording who can observe the defect, resolved from the cited path and overridden by the failure mode where the two disagree).
<!-- gaia:maintainer-only:end -->

A deterministic check reads that metadata back before the issue is created, and the filing does not proceed on a finding. It verifies the label vocabulary and counts, the dedup key's shape, and that no label belonging to a later lifecycle stage (the drain's claim and park labels) has been applied by a filing. It runs offline, so it needs neither network nor `gh`. What it deliberately cannot check is whether a grade was applied honestly: whether a fix carries a design decision is a judgment about code, so the mechanical half of the rules is enforced and the rubric half stays a filer's obligation. The same check has advisory modes that audit one already-filed issue or sweep the whole open backlog, and those relabel nothing: repairing an existing issue is a decision per issue.

The `file-tech-debt` skill (`.claude/skills/file-tech-debt/SKILL.md`) is the source of truth for the filing mechanics: key construction, the `--body-file` invocation, idempotent labels, the metadata check, the body schema, and the sentinel touch.

### Idempotent dedup

Filing is idempotent. The check runs at step 2 of `.claude/skills/file-tech-debt/SKILL.md` through `.gaia/scripts/debt-dedup.sh`, whose header owns the matching rules, the tiers, and the exit contract. This page keeps the reasons.

- **Local matching, not `gh` search.** Full-text search tokenizes on `/ : @`, so it cannot reliably match a key line. The script lists the `tech-debt` issues and compares parsed fields itself.
- **`class` is ignored.** The same defect is often classified differently by two runs, and one defect at one location is one issue however it was named. Identity is the path plus the line.
- **Declined-closed suppresses re-filing permanently.** A finding closed as `wontfix` or not-planned records a decision. Re-filing it would reopen a question the maintainer already answered, on every audit that rediscovers it. A closed issue that was fixed is not a match, since a recurrence is a new defect.
- **Keyless human-filed issues still suppress.** A bare `<path>:<line>` in an open body with no machine key matches, so a hand-filed issue is not duplicated by the audit.
- **The check re-runs right before create.** That shrinks the TOCTOU window for a concurrent run. An unreadable input or a saturated result blocks the filing rather than passing as "no match", because a silent miss files a duplicate.

### Milestone assignment

A tech-debt issue filed while draining a milestone joins that same milestone rather than an unmilestoned backlog: fixing one issue routinely turns up another, and that by-product belongs to the same release. When the `file-tech-debt` skill or a manual filing creates an issue during milestone work, set the milestone in the same step: the skill does not do this on its own, so it depends on the filer remembering. The milestone is a live worklist, not a release manifest: set it going forward, but do not backfill already-closed issues into it even when they technically belong to the release. The authoritative release record is `CHANGELOG.md` and git history, which is what release-notes generation reads; the milestone's day-to-day value is showing what is left.

## Security classification and divert

Security classification runs **before** any filing path, and it screens the finding's **content and severity, never its `finding_class` field**. A finding is **security-class** (fail-safe) if any of these hold, regardless of its `finding_class` tag: it came from the security review dimension, its content reads as a security concern (an exploitable weakness), its severity is Critical, it is secret-shaped, or its `finding_class` field is absent or malformed (a broken finding record, which diverts rather than publishes). Exact-string matching on the seeded security classes alone is insufficient, severity is demotable and several security dimensions have no seeded class, so when in doubt the audit treats a finding as security-class.

The authoritative `finding_class` vocabulary (`HOLISTIC_FINDING_CLASSES`, `RULE_FINDING_CLASSES`, and the oracle prefixes) is the closed canonical set defined in the CLI schema; this page references it rather than re-listing the security members. `OUT_OF_SCOPE_FALLBACK_FINDING_CLASS` (`holistic/unclassified`) is the dedup-key fallback for a finding that maps to no seeded class; that constant is not a member of the closed finding-class vocabulary and is never emitted in the findings block; it only builds a dedup key.

**`holistic/unclassified` is not a security trigger.** The closed vocabulary is small by design, so the fallback is the *expected* class for most out-of-scope findings, not a signal that a finding is unknown or dangerous. It means the finding sits outside the closed finding-class vocabulary and nothing more. Keying the security screen on it would divert every out-of-scope finding on a public repo, file nothing, and leave the debt backlog permanently empty and `/gaia-debt` unable to fix anything: an off switch rather than a gate. The security screen and the finding-class vocabulary are independent axes.

Because "any Critical" and "security-shaped content" are both security-class triggers, an out-of-scope **Critical** or a finding whose content reads as a security concern is security-class and routes through the visibility gate before any public filing. `gh repo view --json visibility` returns `PUBLIC | PRIVATE | INTERNAL`, re-read immediately before each security-relevant write (a repo can flip); any non-confirmed-`PRIVATE` state diverts.

- security-class on **PUBLIC or INTERNAL** → **divert**, never a public or internal issue:
  - **local run**: a redacted operator surface at `.gaia/local/audit/security/<HEAD-sha>.md` (gitignored) plus a count-only pointer (no detail) in the report. The operator is surfaced to and the flow waits; nothing is auto-drafted or auto-disclosed.
- security-class on **confirmed PRIVATE** → file as a normal private `tech-debt` issue, fully dedupable and fixable.

A security-class finding's detail never reaches a public or internal issue or the PR comment; a diverted finding contributes only to counts on those surfaces. A diverting finding that maps to no seeded class still builds its dedup key with the fallback class, so the operator surface and any future dedup stay well-formed; the fallback is what the key is built with, never what makes the finding divert. Either disposition (`filed` or `diverted`) lets the marker write, so the never-public guarantee never deadlocks the merge.

## The disposition gate and the marker

The disposition gate is the **fourth marker precondition**, alongside the three existing ones (no in-scope Critical, every in-scope Important addressed, every in-scope Suggestion auto-fixed or escalated), which are now scoped to in-scope findings. Before writing the marker the audit re-queries open `tech-debt` issues for each out-of-scope key and confirms each `filed` entry still resolves to an open issue carrying the key.

The audit decides a disposition for each out-of-scope finding at its marker-decision point; filed `tech-debt` issues and the PR-body headings carry the durable record, never a local file. Each disposition entry carries the dedup key's inner content (the `v1 class=… path=… line=…` text without the `<!-- gaia-debt-key: … -->` wrapper), its severity, `security_class`, and a `disposition`:

- `filed`: an open `tech-debt` issue carries the key (`issue_number` set).
- `diverted`: security-class diverted; no public issue.
- `waived`: backend definitively absent; the finding reverts to prose only.
- `machinery_waived`: a non-security out-of-scope finding whose path is gate machinery or a file the pull request already changes and the finding itself clears both disqualifiers; recorded and listed in the PR body, not filed.
- `pending` with `pending_reason: "transient"`: a transient `gh` failure; the finding is surfaced and retained for the next idempotent run.
- `pending` with `pending_reason: "definitive"`: a definitive filing failure on a present, writable backend; the disposition is genuinely missing.

The marker writes when every entry is `filed`, `diverted`, `waived`, `machinery_waived`, or `pending(transient)`. It is withheld **only** on `pending(definitive)`, the one intended block: the operator resolves the filing failure and re-invokes before the marker clears. Backend-absent, transient, diversion-failure, and machinery-waive cases all fail open and never block the merge.

### Backend probe (three outcomes)

The audit probes the issue backend once at the start of the disposition flow:

- **Definitive-absent** → waive: file nothing, the gate waives, out-of-scope findings revert to prose, the marker writes. Triggers: repo unresolvable, `gh` unauthenticated, Issues disabled (`gh repo view --json hasIssuesEnabled` false or a structurally-failing issue-list probe, never `gh repo view` resolution alone), or the viewer lacks write permission.
- **Transient/ambiguous** → do not waive, do not drop: timeout, rate-limit, 5xx. Surface the finding and retain it for the next run; dedup makes the retry safe. Never block the merge.
- **Present** → proceed with dedup, filing, or divert.

### Sibling: the re-run carry-forward ledger

The local re-run carry-forward ledger (`.gaia/local/audit/<audit-key>.rerun.json`, `<audit-key>` the shared pull-request-wide base sha plus the acting tree's own branch, `.gaia/scripts/audit-key-lib.sh`) is a distinct, non-overlapping concern from the out-of-scope disposition process above: the ledger holds **in-scope** remaining work only, keyed to the shared base plus branch (the same base every dispatched member's artifacts key to, not the frontend member's own narrower per-member review base), so two worktrees sharing a base sha never collide on it. No merge-gate hook reads the ledger, and it does not read or feed the disposition process; the clearance writer reads it to hold each member to accounting for its own open entries, and the resolver reads it to link a member's refusal anchor. See [[Code Review Audit Agent]] for the ledger's role in the local fix → re-audit loop.

## /gaia-debt: fixing the backlog

`/gaia-debt` fixes the `tech-debt` backlog the audit files, one fix unit per run (a single issue, a user-approved related batch, or a batch the operator names), on a fresh isolated branch through the same `code-audit-frontend` marker gate every feature PR passes, then drives to merge through the [[PR Merge Workflow]]. `.claude/commands/gaia-debt.md` and the playbook at `.claude/skills/gaia/references/debt.md` own how it runs: the steps, the prompt shapes, the labels, and the order of the screens. The deterministic parts are scripts the playbook calls, each header owning its own rules: `debt-parse-args.sh` (argument form), `debt-stale-claims.sh` (stale-claim reconcile), `debt-backlog.sh` (exclusions and clustering), `debt-path-probe.sh` (staleness annotation), and `debt-batch-budget.sh` (named-set budget). This section keeps the reasons those mechanics exist; it restates none of them.

### Why

**Claim before isolation.** The window a claim closes sits between picking the work and having a branch that names it, so claiming after the branch exists closes nothing. A claim set first also drops the issue from a peer session's offer and its statusline count at once. The same ordering is why the stale-claim reconcile needs an age grace: a just-locked issue has no branch yet, so "no branch means dead" alone would strip a fresh lock. A recent update protects the fresh lock, and the branch check protects every active fix once past branch-cut, regardless of age. The reconcile reads branch names through the same naming library that mints them, so the two cannot disagree about what a drain's branch looks like. It fails closed: when an input cannot be read it names nothing stale and strips nothing.

**Ordering is a pure sort, and no model ranks.** Severity descending then oldest first is one source-checkable expression over fields GitHub returns, so anyone can reproduce the order by re-running it. Clustering is likewise a pure function of parsed fields. A model that ranked or clustered would make the order unreproducible and let the drainer talk itself into the issue it preferred.

**An unlabelled issue sorts with the suggestions.** A fallback that lands on `investigate` would make "I do not know" the value an issue acquires by default, which is what turned the dedup key's `class=` axis into a graveyard. And because the drain excludes investigate from candidacy, every human-filed fieldless issue would silently leave the fix pool. The fallback assigns a sort position, never a label, so nothing about it is a grade.

**Investigate ranks below every band and is not one.** It records that the severity is not yet known, so it is not a fourth rung on the ramp: its rank only sorts it below the suggestions. What such an issue asks for is research, and `/gaia-debt` fixes, so the drain excludes it outright. It leaves the pool by answering its question and re-grading it, never by the drain doing that research.

**Clustering needs a real shared cause.** The fallback class `holistic/unclassified` never pairs two issues, because two issues that both fall back to it share no root-cause signal, only the absence of one, and pairing them on a shared directory is clustering on the directory. A shared directory alone is too weak to cluster on: a whole services directory is not one fix. A backlog whose issues all carry the fallback class therefore clusters on a shared path alone, and the class-plus-directory signal starts contributing once real classes are seeded. Clustering is security-blind because the offer is where visibility matters: a security-class issue never anchors a public batch.

**The staleness probe annotates and never decides.** A missing path is a strong signal and not a verdict: a finding can stay entirely real while the file it cites is renamed out from under the issue, and the right repair is sometimes the issue and sometimes the code. So the probe puts the fact in front of the choice rather than behind it, and an issue with no key is annotated nothing, because a missing key is not evidence of staleness. The probe deliberately does not re-resolve cited lines or re-derive counts. Both need the body read closely against real code, one issue at a time, and paying that for every open issue on every backlog read would make the read cost grow with the whole backlog rather than the unit being fixed. The two tiers are split on cost: cheap and total at read time, expensive and single-target at fix time.

**The security screen is a backstop.** The audit's filing screen never files a security-class finding as an issue on a public or internal repo, so every machine-filed issue in a public backlog is non-security by construction. The fix-time screen exists for exactly two cases: a human-filed security-sensitive issue, and a repo that flipped private to public with security issues already in its backlog. It reads content, never the key's `class=`, because the fallback class is the expected class for most out-of-scope findings; a screen keyed on it would peel the whole backlog on a public repo and leave the skill unable to fix anything. Opening a closing PR for a security issue on a public repo completes the disclosure failure the screen exists to prevent.

**Screens run before implementation, in a fixed order.** A member peeled before any commit exists has nothing to rewrite, so the peel is complete once its claim is stripped; moving a screen after the commit step would put every peel on the drop path and owe each one a commit-message rewrite. The staleness screen sits ahead of the spec screen because the spec screen decides whether a fix needs a SPEC by reading the cited code, and if the citations no longer resolve that judgment is made against the wrong code.

**The staleness screen blocks.** The failure it prevents is a fix that faithfully implements an issue describing a tree that no longer exists, and the drainer is the same agent that would read its own advisory and rationalize past it. On a mismatch the choice between correcting the issue and correcting the code belongs to the operator, so the screen never repairs the issue in place and never proceeds on a re-derived premise.

**Comments are read per selected unit, not per backlog.** The established way to record "the suggested fix turned out to be wrong" is a correction comment on an unchanged body, so a body-only drain rebuilds work a comment already recorded as reverted, the worst outcome the screen exists to prevent, and one indistinguishable from ordinary progress in the diff. Comments are unbounded text and the backlog read runs over the whole open set, so reading them there would pay across every issue to serve a question about one unit. A comment is a durable correction channel, and nothing asks a corrector to duplicate it into the body; a body edit is the stronger form because it reaches every reader, and both are read.

**The spec hand-off rides the printed block, not a skill.** `/gaia-debt` never invokes `/gaia-spec`, so nothing with standing awareness of the issue is running when the pipeline starts. The block is the only channel that reaches the spec session, and it already directs downstream behavior through the closing-keyword instruction, so the label swap and the release instructions ride it too, and the spec skills gain no debt awareness of their own. The mechanism is deliberately soft: a session that skips the swap leaves the pending label, which parks the issue exactly as the hand-off left it, so a miss degrades to a hand-off that reads as un-started rather than to a worse state.

**The park is two states because an un-started hand-off must stay distinguishable from one in progress.** Under a single label a second person sees a marker that says "waiting for someone" and authors a second SPEC for the same debt. Both labels park the issue identically for every consumer, so nothing downstream branches on which is set.

**The active park label has no automatic release.** Nothing joins a SPEC to its originating issue, so no hook or reconcile can tell a SPEC that finished the work from one that deliberately left the issue open, and releasing on either signal alone would unpark an issue that should stay parked. Every consumer filters on open issues, so a label left on a closed issue is inert.

**The PR body is the sole carrier of the closing keyword.** A squash merge concatenates the branch's commit bodies into the merge commit message, and GitHub reads closing keywords out of that message, so a trailer in a commit closes its issue whatever the PR body says. That would close a member dropped from the unit as completed with nothing fixed. Keeping the keyword in one correctable place is what makes a mid-run drop recoverable.

**The post-merge check is scoped to members dropped after their commits.** A member peeled before isolation, dropped at claim time, or parked pending a SPEC never reached the PR body, so no trailer of that run can close it and there is nothing for the check to catch. Each of them is legitimately closable by something else while the PR is open, a released member by a peer session and a parked one by its own SPEC's implementation PR. For those, a closed issue is the success case, and reopening it would undo a real fix. The check exists because a wrongly-closed issue is otherwise indistinguishable from a fixed one.

**The claim's close-out is a courtesy.** The closing keyword already drops the issue from the open count independent of the label, so clearing the claim on merge is not a dependency. Anything left dangling after an ungraceful session death is recovered by the next fix-start reconcile rather than a dedicated cleanup step.

**Isolation mirrors the plan orchestrator.** See [[Task Orchestration]] for the shared machinery. Work already on a branch must not tangle with a second branch's work in one checkout, which is why a worktree is forced off the default branch under every policy value.

## Statusline and debt-count refresh

A statusline segment, `Run /gaia-debt (N issues)` (`issue` singular at N==1), surfaces the open count, matching the other right-side `Run /<skill> (N noun)` indicators and suppressed before per-clone setup. It reads a pinned cache at `.gaia/local/debt/count.json` (`{"schema":1,"openCount":<int>,"computedAt":<unix-epoch>}`), so the no-network statusline hot path never recomputes inline. The count is one number for the clone, held in shared state under the main checkout, and the nudge that surfaces it renders on the main checkout, which is where a debt fix begins. The fix's own worktree does not re-show it, since the fix is already under way there.

`.gaia/scripts/debt-count-refresh.sh` runs detached in the background each tick. It recomputes `openCount` via `gh issue list --label tech-debt --state open` and subtracts open issues carrying `in-progress`, so a claimed issue does not inflate the `Run /gaia-debt` nudge for a peer session on the same checkout, then rewrites the cache when a staleness sentinel (`.gaia/local/debt/refresh-requested`, an empty marker file) is present or the cache is older than its own TTL, independent of the aggregate update-check TTL. On any `gh` failure it preserves the previous count rather than blanking it; a backend-absent run with no prior cache seeds `openCount` 0 so no segment renders. A genuine recompute (one where the `gh` read succeeds) always clears the sentinel; a failed read keeps it armed so the next tick retries.

A single `gh` PostToolUse hook (`.claude/hooks/debt-sentinel-touch.sh`) sets the sentinel deterministically after any of the five commands that move the open count: `gh issue create`, `gh issue edit`, `gh pr merge`, `gh issue close`, and `gh issue reopen`. `gh issue edit` arms the hook alongside the other four because any `in-progress` claim, `/gaia-debt`'s or a hand-set one, toggles the label via that exact command, and since the count excludes a claimed issue, an edit that adds or removes the label changes the displayed count. The hook matches on the command shape alone and does not resolve whether the issue carried the `tech-debt` label: touching the sentinel only schedules a recompute, so a broad match is harmless. One in-flow touch complements it as best-effort belt-and-suspenders, not a replacement: the audit touches the sentinel after it files an issue (the file-tech-debt skill's sentinel-touch step, which runs inside the audit subagent). `/gaia-debt` makes no touch of its own and relies on the hook for every claim, release, and park. A mutation performed directly in the **main** session, most notably a `gh issue create` or `gh issue close` a human or the assistant runs by hand, is caught only by the hook, so the hook is what keeps those prompt rather than TTL-delayed. Every sentinel or cache writer runs `mkdir -p .gaia/local/debt` first, because the directory is not assumed to pre-exist on a fresh clone or in CI.

A mutation that never reaches a first-party hook, a close from the GitHub web UI, a teammate, or a plain `gh issue close` in a non-hooked shell, is reconciled on the next session start. The `startup|resume` SessionStart hook (`.claude/hooks/debt-session-reconcile.sh`) arms the sentinel when, and only when, the pinned cache already shows an open count greater than zero, so an empty backlog stays fully network-free (no sentinel, no `gh` call). It therefore reconciles the count **downward** only: a `tech-debt` issue opened externally while the local count is zero still surfaces on the next TTL, not the session start. A count that is stale-high, the case where the nudge lingers after the backlog has actually emptied, clears on the first session start after the close.

## /gaia-residue: draining accepted residuals

`/gaia-residue` (`.claude/commands/gaia-residue.md`, playbook at `.claude/skills/gaia/references/residue.md`) is the triage drain over the keyed residue recorded under `## Accepted residuals (recorded, not fixed)` and the machinery-waive heading in merged pull-request bodies. It reads no sidecar and writes no code: it enumerates candidates, resolves each one's cited `file:line` against the current tree, and takes exactly one disposition per entry, promote to a `tech-debt` issue (via the same `file-tech-debt` recipe `/gaia-debt`'s producer side uses, so a promoted residual's dedup key is byte-identical to the residual's own), dismiss, or keep (a snooze that re-surfaces the entry once its record ages out). Dismiss is the default disposition; promotion is the exception and needs a reason, since a drain whose happy path files issues just grows the backlog it exists to shrink. Every disposition other than promote is recorded in a dedicated append-only store, never hand-written.

Where `/gaia-debt` fixes the backlog the audit already filed, `/gaia-residue` decides what happens to the debt the audit recorded but never filed in the first place, so the two commands are siblings over the same disposition vocabulary rather than a pipeline: a residual promoted here becomes an ordinary `tech-debt` issue and joins `/gaia-debt`'s FIFO from that point on.

## Relationship to the Policy-Memory Loop

`/gaia-debt` and `/gaia-harden` (the [[Policy-Memory Loop]]) share the `finding_class` vocabulary but do not overlap. `/gaia-harden` hardens recurring **forms**: when the same `finding_class` recurs across distinct PRs, it drafts the lowest-context-weight guard (a deterministic check, skill, or path-scoped rule) so the class stops recurring. `/gaia-debt` fixes concrete **instances**: the specific out-of-scope defects the audit filed as `tech-debt` issues, one fix PR at a time. One governs the rule that prevents a pattern; the other clears the individual debts already on the books.

## Deferred (not yet built)

The following are intentionally out of scope for the current implementation and are not yet built:

- **Line-drift-tolerant dedup.** The dedup key is `finding_class` + `file:line`; a residual line-drift duplicate risk is accepted.
- **Durable fix for diverted PUBLIC/INTERNAL security findings.** Only the confirmed-PRIVATE-repo private-issue path is dedupable and fixable; a diverted PUBLIC/INTERNAL security finding has no durable backlog.
- **Cross-band fix fairness.** `/gaia-debt` is within-band FIFO, severity-first; cross-band fairness and a starvation guard are out of scope.
- **Schema-level same-run identifier.** The relatedness heuristic clusters on the existing dedup-key `path`/`class`+dirname fields, deriving relatedness without a new field; a same-run identifier for tighter batch grouping is a possible future refinement.

## Pairs with

- [[Code Review Audit Agent]]: the producer; classifies scope and disposes out-of-scope findings.
- [[PR Merge Workflow]]: the disposition gate is the fourth marker precondition.
- [[Policy-Memory Loop]]: the sibling `finding_class` consumer; hardens recurring forms while `/gaia-debt` fixes concrete instances.
- [[Worktrees]]: the per-tree/shared state model that `.gaia/local/debt/`'s shared scope and the worktree-mode fix mechanics both follow.
