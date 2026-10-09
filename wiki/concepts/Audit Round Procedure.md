---
type: concept
status: active
created: 2026-10-09
updated: 2026-10-09
tags: [concept, ci, review]
---

# Audit Round Procedure

This page is the audit loop unit's only procedure source: how it resolves and dispatches the members, routes a light review, runs each fix round, disposes every finding and writes the marker key. The main thread reads the runbook, [[PR Merge Workflow]], and does not read this page while a unit is available; the handshake signals and the accepted limits of the status gate are in [[Audit Gate Reference]].

#### Dispatching the members

**Roster-first: resolve the members, then spawn exactly those.** Before any `gh pr merge`, resolve which Code Audit Team members this branch's diff dispatches:

```bash
bash .gaia/scripts/resolve-audit-members.sh
```

Run it from the repo root, or pass `--root <path>` from elsewhere. It prints one member (agent) name per line, deduped and sorted. That output is the spawn set.

- **One or more names** → spawn every named member in parallel, from a single tool-call message. Do not wait for the merge deny-hook to name them; that round-trip is friction:

  Immediately before this dispatch wave fires, capture the expected tree fresh: `git -C <RESOLVED_ROOT> rev-parse HEAD^{tree}`. Recapture it before every dispatch wave: HEAD can move between rounds (a member re-spawned after a repair commits runs against a new HEAD), so reusing a stale value would fail a later wave's self-check against a tree it is correctly reviewing. `RESOLVED_ROOT` is the working root `.claude/skills/gaia/references/isolation.md` exports; a caller that never ran that reference, a plain feature-branch session, still resolves it trivially as its own current checkout's absolute path, so the self-check costs nothing there and is not worktree-only machinery.

  Issue every member's `Agent` call from one tool-call message, so they run concurrently.

  **A member's report reaches the orchestrator on disk, not through the dispatch's return value.** The `Agent` call returns dispatch metadata as soon as it is issued; the member's own final text arrives later, asynchronously, as a completion notification. So the moment the call returns is not the moment a report exists, and no parameter changes that: the tool exposes no way to hold the call open until the member finishes. What every member does write is two durable artifacts, its `<digest>[.<member>].ok` / `.refused` marker and its findings sidecar, and those are what the rest of this section reads. This is the idiom `.claude/rules/subagent-dispatch.md` already prescribes for every dispatch whose output is acted on: poll the artifact, never the notification.

  Nothing is lost by that: the marker gate stays fail-closed, so nothing unsafe merges, and [[#No-op detection and retry for each dispatched member]] classifies each dispatch from the artifacts rather than from returned text.

  ```
  Agent(
    subagent_type: "<member-name>",
    prompt: "Working root: <RESOLVED_ROOT>, the absolute path of the checkout under review; the orchestrator substitutes the value it resolved from the isolation reference at dispatch time. Run your definition's root fence with AUDIT_ROOT=<RESOLVED_ROOT> ahead of it, then type <RESOLVED_ROOT> wherever a command in your definition writes <root>, never carrying it in a shell variable. Expected HEAD tree: <EXPECTED_TREE>, the tree captured immediately before this dispatch wave.
    MANDATORY FIRST ACTION, before any review: run `git -C <RESOLVED_ROOT> rev-parse HEAD^{tree}` and compare it to <EXPECTED_TREE>. If that command errors (missing path, git unavailable) OR the value does not match exactly, STOP, do not review, do not write a marker, and return only the mismatch or error as your entire output.
    SECOND ACTION, still before any review: run your definition's scope resolver as its first step. Read your own agent definition at `<RESOLVED_ROOT>/.claude/agents/<member-name>.md` only when the resolver prints `DEFINITION=reread`, and then follow that copy for the rest of this round in place of the definition you were dispatched with; on `DEFINITION=unchanged` the definition you were dispatched with is the working-root copy, so do not re-read it.
    Only on an exact match, review all changes in <RESOLVED_ROOT>'s current branch compared to main, scoping every git command to `git -C <RESOLVED_ROOT>`. Identify security vulnerabilities, performance issues, code smells, anti-patterns, and refactoring opportunities.
    How your run ends: a reply with no tool call ends it, and the orchestrator reads whatever you returned as your finished result. Do not end on a summary that announces a next step, an offer to continue, a list of questions none of which blocks the work, or a progress report because a milestone is done; take the next step instead. Stop only when the task is complete, or when something you cannot resolve blocks it, and then say which."
  )
  ```

  **The conditional re-read is a standing part of the prompt, not an instruction an orchestrator adds when it remembers.** The session resolves agent definitions from the main checkout rather than from the working root under review, so a member dispatched into a worktree whose branch edits that member's own definition runs the pre-branch prompt. That is load-bearing rather than cosmetic: a prompt predating a handshake never learned to satisfy it, the clearance writer refuses the member's earned write, and if every dispatched member is in that state the AND-aggregator holds `GAIA-Audit` shut with nothing left that can clear it, since each re-dispatch loads the same stale prompt. The scope resolver compares the two copies byte for byte, the main checkout's and the working root's, and prints `DEFINITION=reread <path>` exactly when they differ (or when the comparison cannot run), so the member reads its definition exactly when the dispatched copy is stale and never pays the read on a round where it is current.

  Two things do **not** substitute for it. Working in the main checkout sidesteps the mismatch, because there the registry and the tree under review are the same tree, but that is a property of how a given branch chose to isolate rather than something the dispatch can rely on. And the writer's own refusal names this cause at the point of failure, which makes an already-stalled round self-clearing; naming a cause after the stall is a weaker instrument than not stalling.

- **No names** → spawn `code-audit-frontend`, fail-closed: never treat an empty or unanswerable result as "nothing owed". An in-scope file no member owns owes `code-audit-frontend` as well, even when the resolver names other members, and there the merge gate does not check for it (see [[PR Merge Workflow#Who audits: the dispatched member set]]).

  **A result assumes the checkout you ran it in is still on the branch under review, and a clearance check must not assume it.** The resolver answers about the diff the acting checkout currently holds, so a checkout sitting on `main` has no diff and returns empty although nothing was audited. That is reachable without anyone changing branches deliberately, a peer session's cleanup arm can move the main checkout's HEAD out from under a row mid-audit ([[PR Merge Workflow#Cleanup under worktree isolation]]). **Key a clearance check on the marker body's `tree` field matching the row's own tree, never on the spawn set.**

Skip a spawn for a member already cleared: its current-digest marker exists, or (for the default member) one of the bypass signals in the marker-handshake table already applies to this PR. The spawn set names who *can* be required, not who is still outstanding.

On a clean pass each member writes its own marker and creates no commit; it does not call `post-audit-status.sh` itself (see [[PR Merge Workflow#Posting the status last]]). The merge deny-hook requires **every** dispatched member's marker, so one member withholding holds the gate shut for all. If a member declines to write its marker, its report names what remains unaddressed; resolve those, commit, push (HEAD moves), then re-spawn the pending members on the new HEAD. A member that cleared a previous round must be re-spawned too whenever its own owned-plus-machinery content changed since: its marker is keyed to its own content digest, and a commit that touches a path it owns, or any gate-machinery path, rotates that digest. A commit that touches nothing a given member owns and no machinery leaves that member's digest, and its marker, valid, no re-spawn needed. Never hand-write a marker to bypass the gate.

**Re-read the full `gh pr checks <N>` output before every re-spawn, on the same terms as the first dispatch.** Between rounds is where this pays most: the repair commit just pushed can red something the round's own local checks never selected, and the round about to be spawned is already being bought, so a red folded in now rides a re-dispatch that is paid for either way, while the same red found after the round buys a whole extra one. The pushed-head, pending-is-not-green, red-is-not-always-a-code-change, and no-PR-yet caveats above apply unchanged here; the sha caveat binds harder between rounds, because a row read moments after the repair push can still be describing the previous head's run.

#### Parallel dispatch

Markers are keyed to each member's own content digest, so members are order-independent (see [[#Marker key]]). **Dispatch every member in parallel, in any order.** A member edits no tracked file, so the members share nothing they could contend for; the orchestrator commits once after every dispatched member has returned. Per-member content-digest keying means an owned-file change rotates only that member's digest: there is no working-tree race between members and no wave to sequence.

A commit that leaves every blob byte-identical advances HEAD without rotating any member's digest, including its siblings'. A fixer repair that edits a file one member owns rotates only that member's digest; one that touches a gate-machinery path rotates *every* member's digest, correctly invalidating a sibling's in-flight marker, because a machinery change is exactly the case the machinery guard exists to force a re-review on.

#### Light routing

A member that already reviewed the branch, clearing it in full or refusing it with a list of findings, can be re-checked by a cheap Sonnet reviewer instead of a full dispatch when the delta since that review is small. The route is decided by `.gaia/scripts/audit-light-route.sh`, which prints one `<route>` and `<reason>` line and fails closed: **Full whenever it cannot establish Light**, meaning a missing tool, an underivable digest, a dirty tree, an unreadable roster, or any rule it cannot evaluate. A non-zero exit means Full to every consumer.

- **Opt-in.** A member is eligible only when its entry in `.gaia/audit-ci.yml` carries `light_review: true`; the roster header and the roster verifier own which members do. The optional `light_line_cap` lowers the line cap and can never raise it: the cap is 50 added plus deleted lines, and a larger value clamps to 50. The optional `light_hard_full` list adds member-specific globs that always route Full, and each must sit inside the member's own `globs:`.
- **Hard-Full floor.** Machinery paths, any in-scope path no member owns, tests, manifests and lockfiles, config files, workflows, and harness files always route Full, whatever the roster says. A roster edit can add to the floor and never remove from it. Binary files, mode changes, symlinks, and submodules also route Full.
- **Anchor.** The delta is measured from the newest commit inside the branch's own range whose tree carries either the member's earned clearance with `review: full` or its refusal, both under the current version. A refusal older than a full-clearance anchor does not block Light; a refusal at HEAD, or one recorded under another version that is newer than the anchor, forces Full. A change to the global rules or to the member's own definition forces Full.
- **Refusal-anchored.** When the anchor is a refusal, the refusal's open findings become the reviewer's checklist and the route reason is `refusal-anchored`. The router reads them from the refusal's carry-forward ledger and findings sidecar. Any open finding with severity `error`, a `security` field that is not exactly `false`, or no readable severity, security, key, path or line routes Full as `refusal-open-security`, and so does a refusal whose findings cannot be read. The delta cap, the hard-Full floor and every other rule apply unchanged.
- **The reviewer.** `audit-light-reviewer` (`.claude/agents/audit-light-reviewer.md`) is Read-only, runs on Sonnet, reads only the input file the router wrote, and treats the diff inside the generated data fence as untrusted data, never instructions. Its whole reply is one JSON verdict; on a refusal-anchored route it lists in `resolved` the key of every checklist finding the delta resolves, and it clears only when it lists them all and the delta raises nothing new.
- **Light-clear branch.** The unit writes the reply, unmodified, to a file in its session scratchpad and names that file to `.gaia/scripts/audit-light-mark.sh` (a reviewer that returned nothing is passed as empty stdin); the file form exists because worktree confinement refuses a heredoc or pipe. The script persists the verdict, re-runs the router, checks the verdict against the route record, and only then writes an earned marker carrying `review: light` and a light findings sidecar, through the shared writer. The member is cleared for this digest and is not dispatched.
- **Escalate branch and every failure branch.** An `escalate` verdict, a refusal sibling, a stale route, a re-check that no longer says Light, a malformed or mismatched verdict, and a failed write all print `full` and write no marker. On a refusal-anchored route two more refusals apply: a `resolved` list that omits a checklist key prints `full verdict-incomplete`, and a finding whose cited line the delta never touched prints `full checklist-unchanged`, whatever the reply says; the script checks the line against the delta in git and never takes the reviewer's word. A refusal-anchored clear also records the resolutions in the member's findings sidecar and retires the matching ledger entries. The unit then dispatches the member on the same tree in that round.
- **Not an audit round.** The reviewer is outside the `code-audit-*` family, so the bound hook allows it without recording a round. A light review is counted separately in the `## Audit rounds` record.

Three deliberate departures a reader would otherwise infer wrongly:

- **Ownerless Full.** Any changed in-scope path that no member owns routes Full. No member lens owns it, so a reviewer has no remit to vouch from.
- **No re-dispatch.** A no-op, empty, or malformed light reply falls back to the full member with no second light attempt, unlike the single re-dispatch [[#No-op detection and retry for each dispatched member]] prescribes for an agent artifact. The full member is strictly more coverage than a second light attempt, so the fallback is the retry.
- **Main thread stays Full.** Light engages only inside the audit-loop unit's member wave ([[#The audit loop unit]]). The main thread never runs a member wave itself, so every light route is made inside the unit.

#### The repair boundary

No member edits a tracked file during review. A member wave that leaves the tree dirty stops the round with `member-wave-dirty`, and the unit commits nothing (see [[#The audit loop unit]]). The fixer is the one repair path, and `audit-fix-verify.sh` checks its delta before anything is staged ([[#The fix round: fixer, verifier, gate]]). The orchestrator is bounded, not trusted: `audit-dispositions-check.sh` bounds every disposition it makes and `audit-fix-verify.sh` bounds every repair.

#### No-op detection and retry for each dispatched member

A dispatched member can silently no-op: zero tool uses, a return that is just a harness-reminder-echo or output-style fragment instead of a real review. Nothing about the marker gate catches this on its own, fail-closed means no marker and no merge, but with no diagnosis of *why* the gate is stuck, just a stuck gate a human has to notice and investigate by hand. This mirrors, one layer up, the same deterministic classifier `code-audit-frontend` already runs on its own internal specialist and refuter fan-outs (`.claude/agents/code-audit-frontend.md`, "No-op detection and retry for each refuter").

**Classify from the artifacts, and wait for them rather than for the dispatch to return.** The `Agent` call returns before the member has done anything (see [[#Dispatching the members]]), so classifying at that moment hands the guard an empty hand: it reads a no-op, and the orchestrator spends its one hardened re-dispatch on a member that is still running correctly. Poll the audit directory for the member's marker or its findings sidecar, then classify. A dispatched wave is an open round, not a stopping point: while any member's artifact is still absent, keep polling rather than ending the turn on a status note. The stops this page wants are the ones it names: a surfaced double no-op, a round disposition under [[#When rounds stop: pre-commit a disposition for every branch]], and a checkpoint denial from the bound hook ([[PR Merge Workflow#The branch checkpoint]]). A completion notification may arrive first and is a fine prompt to look, but the artifact is the exit condition: `.claude/rules/subagent-dispatch.md` forbids blocking on a signal that may never arrive, and this page states one procedure with it, not a second one.

```bash
bash .gaia/scripts/audit-noop-detect.sh --shape audit-team-member \
  --marker <expected-marker-path> \
  --findings-root <RESOLVED_ROOT> --findings-since <wave-stamp>
```

`--path <tempfile>` is accepted alongside these and stays useful when a member's text *is* in hand (the completion notification carries it): a report-shaped return classifies real on its own, independent of the marker and the findings sidecar. It is not required, and fabricating an empty file to satisfy it classifies no-op.

`<expected-marker-path>` is `.gaia/local/audit/<frontend-digest>.ok` for `code-audit-frontend`, `.gaia/local/audit/<digest>.<member>.ok` for a specialized member, the same marker key each member's own gate handshake writes (see [[Audit Gate Reference#Signals]]). The marker is predictable because its key is the member's content digest, which the orchestrator holds.

**The findings sidecar is not predictable, so do not predict it.** `--findings-root` names the audited working root and the classifier finds that member's newest sidecar under it; `--findings-since` names the wave stamp below, and the resolved sidecar must be newer than it. Pass the pair for every member, `code-audit-frontend` included, whenever the branch resolves, and omit both otherwise (an unresolved base or branch writes no sidecar at all). Exit 0 = real (stdout `real`, or `refused`), exit 1 = no-op. A dispatch is real when it holds a writer-produced earned marker (plus, when the pair is passed, a fresh findings sidecar bound to that member), or when the captured return is report-shaped: a backticked `` `path:line` `` finding location, or, for `code-audit-frontend`'s terse LOCAL return, the literal `Remaining in-scope:` preamble. A report-shaped return classifies real on its own whether or not the pair was passed. A `DIRTY=` withhold writes a sidecar but no marker and no refusal, so its return alone classifies real. Anything short of that, most often a bare harness-reminder / available-agent-types echo, is a no-op.

**A refusal is proof of life, never a no-op.** A member that reviewed the content fully and withheld its clearance writes `<digest>[.<member>].refused` and no `.ok`, so the marker path above names a file that never appears for that run. The classifier derives the refusal sibling from `--marker` and checks it **first**, before the earned family, matching the merge gate's own refusal-first precedence; a writer-shaped refusal for the same member and digest classifies `refused` at exit 0. Nothing about that dispatch is retried: re-dispatching a member that refused with cause returns the identical result, spends the single hardened re-dispatch below on a member that was never broken, and reports "no-op'd twice" for what is actually "refused twice, with cause". The lost-report gate does not apply to the refusal arm either, because a refusal carries its own report forward through the member's findings sidecar and the carry-forward ledger its refusal write produces (see [[Audit Gate Reference#Signals]]). Read those two artifacts to learn what it refused on.

**The findings sidecar, not the returned text, is each member's report of record.** Read it to learn what a member found; the return is a convenience copy, and it is optional classifier input: a report-shaped return classifies real on its own. It reads as a report because it carries one: each entry names the finding's `path` and `line`, the `failure_mode` (input, state, wrong outcome), the `verified_by` evidence that establishes it, and the `suggested_fix`, alongside the `finding_class` / `severity` / `area_tags` the recurrence tally counts. Every member writes it through one shared writer (`.gaia/scripts/audit-write-findings.sh`), which rejects a write whose entries cannot name those fields, so an entry that could not brief a repair never reaches disk in the first place. The detail stays local: `post-findings-block.sh` projects each entry down to the three tally keys when it renders the PR comment. Requiring the sidecar alongside the marker is what makes a lost report detectable: a member that completed, wrote a valid earned marker, and whose report never reached the orchestrator is otherwise indistinguishable from a clean pass, because the marker alone would classify the dispatch real and suppress the retry, leaving a green gate with zero visible findings and any Suggestions the clean-pass contract obliges the operator to resolve silently dropped. A present marker with an absent sidecar therefore classifies no-op and earns the one retry below, unless the captured return carries the report (a backticked `` `path:line` `` or the terse preamble), in which case the report did reach the orchestrator. The check binds to the member the marker names, not merely to the file's shape, so one member's sidecar can never vouch for another's lost report across a multi-member round.

**Stamp each dispatch wave** before it fires, and pass that stamp as `--findings-since`:

```bash
WAVE_STAMP="$(mktemp)"    # immediately before the wave fires, and re-stamped before any retry
```

Put it in the system temporary directory, not under `.gaia/local/audit/`: a linked worktree symlinks that directory to main's, so a stamp there would be shared by every tree auditing at once and one wave would reset another's freshness window.

The stamp is what makes a resolved sidecar a *fresh-write* signal rather than a leftover. Every member spec declares the sidecar write best-effort, so a round whose own write failed leaves the previous round's sidecar as the newest one on disk, and without the stamp the classifier would read it as proof this round's report landed.

Re-stamp before the single hardened re-dispatch below, for the same reason the pre-clear it replaces had to be re-run: the no-op's own round is exactly where a leftover from the round before it sits closest.

**A stamp rather than a pre-clear, because the sidecar's key moves and its history is worth keeping.** The sidecar keys on the incremental audit key, base sha plus branch. The branch half is fixed, but the base half is the shared pull-request-wide base, and that base **advances to the newest ancestor of HEAD carrying a `GAIA-Audit` success status** (a round that posts none does not advance it), resets to `main_reference` on a `machinery-reset` (see the resolver-reason list below), and moves again on a rebase. So there is no single expected path to clear: a caller that computes one gets it right for the first round and reads an absent file from the second round on, which is the lost-report shape, so a healthy round classifies no-op and burns the one hardened re-dispatch. Clearing the whole *set* would work but is worse: every earlier round's sidecar is that round's durable report of record, and the merge-time findings block reads all of them across every base (`.gaia/scripts/post-findings-block.sh`). The stamp gets the freshness guarantee without deleting the record.

Resolution plus a stamp narrows the residual stale-file risk to two dispatches of the same member sharing one stamp, and re-stamping before the retry is what removes that last case.

On a no-op, re-dispatch that member **exactly one** time with the hardened retry prefix (`.claude/agents/code-audit-frontend.md`, "No-op detection and retry for each refuter"), substituting the concrete target with the member's original changed-file list. A second consecutive no-op does not re-dispatch a third time: stop and surface to the operator which member no-op'd twice, rather than looping or silently proceeding to a merge attempt.

**This ending departs from the general contract deliberately.** [[Code Review Audit Agent]] owns the terminal action for every no-op guard and states it as inline fallback: the caller does the unit's work itself and applies the result as if the subagent had returned it. This gate does not, because a member's marker is that member's own attestation. An orchestrator that audited the diff itself inline would be writing a clearance nobody earned, which is precisely the substitution the marker gate exists to refuse. Stopping costs nothing here that it would cost elsewhere: the gate stays fail-closed either way, no marker still means no merge, and a surfaced double no-op tells the operator why the gate is stuck instead of leaving them to notice an odd reply on their own.

### 2. Fix all issues

The round's orchestrator decides what happens to every finding, and a fresh fixer sub-agent makes the repairs ([[#The fix round: fixer, verifier, gate]]). The orchestrator is the `audit-loop-unit` agent when the loop runs through a unit ([[#The audit loop unit]]). The round's finding set comes from the members' findings sidecars, read deterministically with `bash .gaia/scripts/audit-loop-eval.sh findings --root <RESOLVED_ROOT> --round <r>` rather than summarized by the main thread: the sidecars hold every finding of every pass, clean or not. The re-run carry-forward ledger (`.gaia/local/audit/<AUDIT_KEY>.rerun.json`) still exists for the members, whose re-audit reads it for its own open entries and must account for each; it is not the fix round's briefing, because it holds only a refusing member's `remaining[]`.

- **Decide every finding in `dispositions-<r>.json`**, written by the round's orchestrator to the run folder before the baseline: each finding of the round marked `fix`, `accept-residual`, `waive-out-of-scope` or `file`, with a reason. The file's shape lives in `.gaia/scripts/audit-fix-verify.sh`'s header. An in-scope finding defaults to `fix`: fix every Critical Issue, every Important Issue, and every Suggestion the audit identifies.
- If a Suggestion involves an architectural tradeoff, breaking change, or conflicting convention, it is escalated with documented rationale rather than marked `fix`; the operator must resolve the escalation before the marker is written.
- A finding outside the reporting member's remit is disposed by [[#Cross-remit findings]]. A non-fix disposition carries forward by identity key (member, finding class, path, line) to later rounds, and the finding leaves the branch's convergence count `A(r)` ([[PR Merge Workflow#The branch checkpoint]]).
- **During the loop the main thread never hand-edits a file a finding names.** Nor does the unit. The fixer carries every repair; the Quality Gate's autofix is the one exception, and the fix round records which paths it touched.
- The round's orchestrator stages, commits, and pushes the verified round; HEAD must move so the next audit runs against the fixed tree.
- **Land the whole round's fixes in one commit**, never one commit per finding. Each commit rotates the reporting member's content digest and buys a re-dispatch to re-earn its marker, so a round repaired finding-by-finding pays for as many re-audits as the round had findings and clears no more than the single batched commit does. Brief the fixer on everything the round marked `fix`, then commit and push once.
- **Sweep for comment and prose the round falsified, before the last dispatch, and scope the sweep by the claim rather than by the diff.** The fixer's prompt carries the sweep, so its corrections ride the round's one commit. A re-dispatch this round is already being paid, so a correction that rides it adds no marginal audit cost, which is the first arm of the digest economics below. Doing the sweep here also removes most of the need to decide the question after a member has already cleared, which is the expensive place to decide it. For every behaviour the round changed, grep the whole tree for the sentence asserting the old behaviour and read every hit. A citation list assembled by opening the files already suspected is the shape that fails, and it fails while reading as thorough: re-verifying such a list confirms the entries it holds and says nothing about the ones it never had. The sites that go stale sit in files the diff never opened, and no deterministic check here reads a prose claim about another file's behaviour, so the grep is the only instrument that finds them.
- **The sweep has converged when a round reports nothing this change authored.** Not when the gate is green, which it can be from the first round, and not when a round reports nothing at all. A round whose findings are all pre-existing is terminal; a round that falsifies a sentence this branch wrote is not, and the correction that repaired the previous round's false claim is itself a sentence this branch wrote. What to do with each kind of finding is [[#When rounds stop: pre-commit a disposition for every branch]] below; this is only the test for whether the sweep is finished.
- Re-spawn the audit members on the new HEAD until a round reports clean, or until the bound hook ends the unit's window or denies a dispatch at the branch checkpoint ([[PR Merge Workflow#The branch checkpoint]]).

#### The audit loop unit

The loop requires Claude Code 2.1.287 or later (subagent nesting) and runs through the `audit-loop-unit` agent (`.claude/agents/audit-loop-unit.md`): an Opus orchestrator that runs a window of up to K rounds off the main thread, with the members and the Sonnet fixer one level below it, and returns one thin `unit-<u>.json`. `GAIA_CONTEXT_UNIT_ROUNDS` in `.gaia/scripts/context-checkpoint-lib.sh` owns K. The unit follows [[#The fix round: fixer, verifier, gate]] for every round, so that section stays the single round procedure. The main thread's half (the dispatch, the brief, reading the unit file, the stop-reason actions) is [[PR Merge Workflow#Dispatch the audit loop unit]].

**Deny classes.** `.claude/hooks/audit-loop-bound.sh`'s header owns the deny text. The caller sees it as `PreToolUse:Agent hook error: BLOCKED: ...`, so the class is a substring after that prefix, never the start of the string: `BLOCKED: audit checkpoint` maps to `checkpoint-deny`, `BLOCKED: audit window` to `window-end`, `BLOCKED: audit dispositions` to `dispositions-check-failed`, and any other `BLOCKED:` to `failure`. A nested `Agent` call that errors with no `BLOCKED:` is `failure`.

**What counts as inside the unit.** A member dispatch is inside the unit's window only when its payload carries an `agent_id` and its `agent_type` is `audit-loop-unit`. Any other member dispatch, the main thread's included, is judged inline as a one-round unit with the unit-level checks and appends no window.

**PR-body sections.** The unit writes `## Accepted residuals (recorded, not fixed)`, `## Out-of-scope machinery findings (recorded, not filed)` and `## Waived below triage threshold (not filed)` from its dispositions through `bash .gaia/scripts/audit-dispositions-check.sh pr-sections --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER>`. The same call renders `## Not filed (no issue backend)`, one line per finding the backend could not take plus a count of findings still pending a retry, and renders diverted findings as a count only.
**Filing and the unit file.** The unit files every `file` and `divert` disposition through `bash .gaia/scripts/file-tech-debt.sh`, never `gh issue` ([[#The fix round: fixer, verifier, gate]] owns the order). `unit-<u>.json` carries the filing results as `diverted_count`, `diverted_records` (the local record paths), `filing_outcomes` (the outcome files) and `filing_pending` (files left in `<RUN_FOLDER>/filing-retry/`). The file carries counts and paths only and no finding detail, and no PR body, comment or status carries a diverted finding's detail either. Before posting the status the main thread surfaces a non-zero `diverted_count` to the human ([[PR Merge Workflow#Posting the status last]]) and then merges without stopping. A `member-wave-dirty` stop has the same shape in a closing round, which runs no baseline: a dirty tree after the closing wave stops the unit the same way.

**The unit never merges.** It runs no `gh pr merge`, posts no `GAIA-Audit` status, writes no marker, edits no `CHANGELOG.md`, and never writes the loop state or `vetoes.json`. It writes no marker by hand; the light-marker script (`.gaia/scripts/audit-light-mark.sh`, see [[#Light routing]]) is the one scripted exception. The main thread alone merges.

#### The fix round: fixer, verifier, gate

The procedure each round runs, inside the unit, in this order. The round's orchestrator decides, dispatches, verifies, gates, and commits; one fresh fixer sub-agent per round repairs; a deterministic script checks the fixer's work against a baseline recorded before it ran, so nothing rests on the fixer's own account of what it did.

The round's files live in the run folder `.claude/doctrine/execution.md` names for this branch, written `<RUN_FOLDER>` below: the main checkout's `.gaia/local/runs/<branch>/`, at its absolute path. Per round `r` and attempt `k` it holds `dispositions-<r>.json` (the round's orchestrator), `baseline-<r>.json`, `verifier-bin-<r>/` and `verifier-<r>-<k>.json` (the verifier script), `fixer-<r>-audit.json` (the fixer, the round's one dispatch artifact), and `gate-<r>-<k>.log` and `gate-<r>-<k>.paths` (the round's orchestrator). Beside the per-round files sit `unit-<u>.json` (the unit) and `vetoes.json` (the main thread), owned by [[#The audit loop unit]]. `.gaia/scripts/audit-fix-verify.sh`'s header owns the four JSON shapes. In a linked worktree, write each run-folder file with Bash at the main checkout's absolute path and read it back, never with Edit or Write.

**Round index.** Before writing any run-folder file, read `r` from the branch history:

```bash
bash .gaia/scripts/audit-loop-eval.sh current-round --root <RESOLVED_ROOT>
```

The bound hook records a round when its wave is dispatched, so after a wave this prints that wave's index. Never count rounds by hand: a resumed session, or a round another session dispatched on the branch, puts a hand count off by one, and every file below is named by it.

**Dispositions check.** After writing `dispositions-<r>.json`, and on a zero-fix round too, run `bash .gaia/scripts/audit-dispositions-check.sh check --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER> --round <r>` with no `--snapshot-dir` (only the bound hook writes snapshots; the check reads any snapshot the branch already has). A non-zero exit means no commit for the round: the unit stops `dispositions-check-failed`, and in the fallback the round stops and the human is asked. The check reads severity and the `security` flag from the members' findings sidecars, never from the dispositions entry, and refuses a finding with no disposition (a finding the branch did not author included), a non-fix disposition of a Critical or security-class finding the branch authored, a `divert` of anything but a security-class finding outside the branch, an empty reason, a vetoed key not marked `fix`, a waiver whose `basis` is missing or does not match the finding, and any non-empty `enforcement_paths_allowed`; its header owns the list. The bound hook re-runs it at the next dispatch.

**Zero `fix` entries.** When the dispositions file marks no entry `fix` (every finding disposed non-fix, or the closing round after an accept), the round has no baseline, no fixer, no verifier, no gate, and no commit. Publish the record (below), then follow [[#When rounds stop: pre-commit a disposition for every branch]], or re-dispatch where that section says to.

**Baseline.** After every dispatched member has returned, and before any fixer dispatch:

```bash
bash .gaia/scripts/audit-fix-verify.sh baseline --root <RESOLVED_ROOT> --round <r> --out <RUN_FOLDER>/baseline-<r>.json &&
  shasum -a 256 <RUN_FOLDER>/dispositions-<r>.json <RUN_FOLDER>/baseline-<r>.json
```

It refuses (exit 3) when the index differs from HEAD. It refuses with exit 4 when the member wave left the tree dirty, a modified tracked file or an untracked, non-ignored one: it prints `member-wave-dirty` and one `dirty <path>` line per path, writes no baseline, and the unit stops `member-wave-dirty` and commits nothing. Members only report and run in parallel on one tree, so no stray edit is attributable to one of them and nothing in a round repairs but the fixer; git-ignored paths never trip it. It also copies the verifier and the libraries it sources into `<RUN_FOLDER>/verifier-bin-<r>/` and records their digest in the baseline, so the verifier that judges the fixer is a copy outside the tree the fixer edits. Run `check`, `round-check` and `drift` below from that copy by its run-folder path, never from `.gaia/scripts/`; each refuses when the copy no longer hashes to the digest the baseline recorded. The baseline is a clean tree, so the verifier judges only the fixer's delta from it. The baseline also closes the round's evidence: a findings sidecar written after it is never read as that round's finding set. Record both hashes in STATE.md (`sha256sum` gives the same digest where `shasum` is absent); the verifier takes them as `--dispositions-sha` and `--baseline-sha`, so a fixer that rewrites either file fails verification instead of widening its own bounds.

**Fixer dispatch.** Exactly one fresh `general-purpose` sub-agent per round, on `model: "sonnet"` (the scoped-implementation row of [[Workflow Doctrine]]'s model table: the dispositions file carries the judgment and the verifier stands behind it), dispatched with the checkout path it edits. Pre-clear its artifact first, `rm -f <RUN_FOLDER>/fixer-<r>-audit.json`, and capture the expected tree as for a member wave:

```text
Agent(
  subagent_type: "general-purpose",
  model: "sonnet",
  prompt: "Working root: <RESOLVED_ROOT>, the absolute path of the checkout you edit; use absolute paths under it for every file. Expected HEAD tree: <EXPECTED_TREE>, captured immediately before this dispatch.
  MANDATORY FIRST ACTION, before any edit: run `git -C <RESOLVED_ROOT> rev-parse HEAD^{tree}` and compare it to <EXPECTED_TREE>. If that command errors (missing path, git unavailable) OR the value does not match exactly, STOP, edit nothing, and return only the mismatch or error as your entire output.
  Your briefing is the JSON file <RUN_FOLDER>/dispositions-<r>.json. Repair every entry whose disposition is fix, cross-remit repairs included, and no other entry. Where you will not repair a fix entry, return it as disputed or cannot_fix with a reason rather than widening the repair. For every behaviour a repair changes, grep the whole tree for sentences asserting the old behaviour, read every hit, and correct the ones the repair falsified.
  Write your result as JSON to <RUN_FOLDER>/fixer-<r>-audit.json with Bash at that absolute path, never with Edit or Write, then read it back. Its shape is the fixer-<r>-audit.json shape in <RESOLVED_ROOT>/.gaia/scripts/audit-fix-verify.sh's header: "attempt": 1, one results entry per fix entry, and every path you changed or reverted declared.
  Never: run git that changes state (add, commit, push, stash, checkout, switch, reset, restore, rm, mv, branch); write a marker, a ledger, a findings sidecar, or anything under .gaia/local/audit/ or .gaia/local/protected/; post a status; file, edit, or label an issue; edit CHANGELOG.md or the PR body; edit a path in the verifier's ENFORCEMENT_PATHS list unless the dispositions file names it in enforcement_paths_allowed.
  Return only a thin digest: the counts of fixed, disputed, and cannot_fix entries, and the result file's path.
  How your run ends: a reply with no tool call ends it, and the orchestrator reads whatever you returned as your finished result. Do not end on a summary that announces a next step, an offer to continue, a list of questions none of which blocks the work, or a progress report because a milestone is done; take the next step instead. Stop only when the task is complete, or when something you cannot resolve blocks it, and then say which."
)
```

**Classify the fixer from its file**, polling the file rather than the notification, on the same terms as [[#No-op detection and retry for each dispatched member]]:

```bash
bash .gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <RUN_FOLDER>/fixer-<r>-audit.json --report-key results --expect-count <FIX_COUNT>
```

`<FIX_COUNT>` is the number of entries the dispositions file marks `fix`. On a no-op, pre-clear the path and re-dispatch once. A second consecutive no-op from the fixer stops the round with no commit: an interactive run asks the human, an unattended run stops and reports. This departs from `.claude/rules/subagent-dispatch.md`'s inline fallback on purpose, because during the loop the main thread never hand-edits a file a finding names, and doing the fixer's repairs itself would be exactly that.

**Attempts.** `k` starts at 1 for the fixer's first write in a round and increases by 1 on every SendMessage continuation of that fixer, a verifier retry or a gate repair alike. Each continuation states the new `k` and tells the fixer to rewrite `fixer-<r>-audit.json` with `"attempt": k`; `verifier-<r>-<k>.json`, `gate-<r>-<k>.log` and `gate-<r>-<k>.paths` carry the same `k`.

**Verify.**

```bash
bash <RUN_FOLDER>/verifier-bin-<r>/audit-fix-verify.sh check --root <RESOLVED_ROOT> --round <r> --attempt <k> \
  --dispositions <RUN_FOLDER>/dispositions-<r>.json --dispositions-sha <DISPOSITIONS_SHA> \
  --baseline <RUN_FOLDER>/baseline-<r>.json --baseline-sha <BASELINE_SHA> \
  --result <RUN_FOLDER>/fixer-<r>-audit.json --out <RUN_FOLDER>/verifier-<r>-<k>.json
```

After a gate repair, add `--extra-declared <RUN_FOLDER>/gate-<r>-<j>.paths` once for every earlier gate attempt `j` in the round, so the autofix's own edits are not charged to the fixer. On a failure the main thread neither runs the gate nor commits. It continues the same fixer once via SendMessage with the verifier output's path, then verifies again; a second verifier failure in the round stops it: an interactive run asks the human, an unattended run stops and reports.

**Gate.** After a verifier pass, stage exactly the delta: the paths the fixer declared, and any path an earlier gate attempt's autofix changed.

```bash
{
  jq -r '.changed_paths[], .reverted_paths[]' <RUN_FOLDER>/fixer-<r>-audit.json
  cat <RUN_FOLDER>/gate-<r>-*.paths 2>/dev/null
} | sort -u | while IFS= read -r p; do git -C <RESOLVED_ROOT> add -A -- "$p"; done
```

Then run the per-round verification, at the placeholder line of the snapshot block below: the [[Quality Gate]] when its skip logic says it applies, saving each attempt's output to `gate-<r>-<k>.log`.
<!-- gaia:maintainer-only:start -->
In this repo the per-round verification also runs `bash .gaia/tests/verify-harness.sh round`, its output saved to the same log. Round mode scopes its selection to the round's staged delta: the branch as of the previous round's commit already passed this run, at the pre-dispatch verification or the previous round's gate, so re-running every suite the whole branch references repeats that pass at the cost of the full branch set on every round. Branch mode selects for the whole branch, which is right for the pre-dispatch verification and wrong here. Round mode adds the whole-tree suites when the delta touches a harness path, and with nothing staged it selects over the HEAD commit instead. Inside `audit-loop-unit` it runs as a blocking Bash call with `timeout: 600000`; a round-mode run that times out is a failed verification, never a pass: the unit stops that round and reports to the main thread, which re-runs `bash .gaia/tests/verify-harness.sh round` in the background with output redirected to a log.
<!-- gaia:maintainer-only:end -->

Record which paths the gate's autofix changed, by snapshotting the dirty and untracked paths with their content hashes before the gate and after it:

```bash
gate_snapshot() {
  {
    git -C <RESOLVED_ROOT> diff --name-only -z
    git -C <RESOLVED_ROOT> ls-files -z --others --exclude-standard
  } | tr '\0' '\n' | sort -u | while IFS= read -r p; do
    if [ -e "<RESOLVED_ROOT>/$p" ]; then
      printf '%s\t%s\n' "$p" "$(git -C <RESOLVED_ROOT> hash-object -- "$p")"
    else
      printf '%s\tdeleted\n' "$p"
    fi
  done
}
BEFORE="$(mktemp)"
AFTER="$(mktemp)"
gate_snapshot >"$BEFORE"
# run the per-round verification here, its output saved to <RUN_FOLDER>/gate-<r>-<k>.log
gate_snapshot >"$AFTER"
awk -F '\t' -v before="$BEFORE" 'BEGIN { while ((getline line < before) > 0) seen[line] = 1 } !($0 in seen) { print $1 }' "$AFTER" >"<RUN_FOLDER>/gate-<r>-<k>.paths"
```

A path lands in `gate-<r>-<k>.paths` when the gate added it to the list or changed its content. The before-snapshot is read in a `BEGIN` block rather than through `NR == FNR`, because that test marks the first file only when it is non-empty, and the staging block usually leaves the before-snapshot empty, which would make awk treat the after-snapshot as the first file and record nothing. On a gate failure, unstage (`git -C <RESOLVED_ROOT> restore --staged .`), continue the same fixer via SendMessage with the log's path, verify again with the `--extra-declared` files, and gate again: at most two repair attempts per round. A gate log exists only for an attempt whose verifier passed, because the verifier runs again after every repair continuation, before the next gate. A third gate failure stops the round without a commit: an interactive run asks one question, `Stop here and leave the PR open (Recommended)` or `One more repair attempt`, and an unattended run stops and reports.

**Round check.** Before the commit, and after any stopped round:

```bash
bash <RUN_FOLDER>/verifier-bin-<r>/audit-fix-verify.sh round-check --run-folder <RUN_FOLDER> --round <r>
```

A non-zero exit means a gate ran on an attempt the verifier did not pass, and the round does not commit.

**Commit, push, publish.** After a gate pass, run the staging block again so the passing attempt's autofix paths are staged, then make one commit carrying the fixer and autofix edits, and push; the round's orchestrator makes it. Its subject is `fix(<scope>): address audit round <r> findings`, `<scope>` the area the round's fixes touch (`hooks`, `cli`) or `audit` when they span several: this flow is unattended, so a free-form subject the `commit-msg` hook refuses would stop it with nothing to recover (`wiki/decisions/Naming Conventions.md`). The [[Quality Gate]] page's stop-and-report step does not apply inside this loop: the branch checkpoint is where the human reviews, and the gate page carries the matching clause. Then the round's orchestrator rewrites the PR body's record (the unit calls `audit-loop-record.sh` itself, so no main-thread write is involved):

```bash
bash .gaia/scripts/audit-loop-eval.sh record-values --root <RESOLVED_ROOT> |
  bash .gaia/scripts/audit-loop-record.sh --pr <N> --values-json -
```

Nothing reads that section back. Publish it at every round end, not only after a push: a committed round, a clean or zero-fix round that makes no commit, the closing round, and any stop (a verifier, gate, or no-op stop, or a checkpoint). The history counts a round when it is dispatched, so a record written only after pushes undercounts.

**Filing.** After the push (after the dispositions check on a round that makes no commit), the round's orchestrator files, and nothing else files: members only report and the fixer is the only repair path. For each `file` or `divert` entry, write the finding (the sidecar entry plus the dispositions entry's `title`, `failure_mode` and `suggested_fix`) to a temporary JSON file and run `bash .gaia/scripts/file-tech-debt.sh file --finding <that file> --outcome-file <RUN_FOLDER>/filing-outcomes-<r>.jsonl --disposition <file|divert>`. The script screens for security, probes the backend, dedups, files and verifies the filing, appends one outcome line (`filed`, `diverted`, `absent`, `transient` or `failed`) and never runs a write verb for a `divert`. Then run the retry pass: the same command, `--finding <f>` for each file in `<RUN_FOLDER>/filing-retry/` that an earlier `transient` outcome left, into the same outcome file. Then reconcile:

```bash
bash .gaia/scripts/audit-dispositions-check.sh check-outcomes --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER> --round <r>
```

A non-zero exit (an entry with no outcome line, or a `failed` outcome) stops the unit `dispositions-check-failed`, naming the keys; the commit is already pushed, and the stop prevents the next round and the merge. An `absent` backend and a `transient` failure pass: neither blocks the merge, the `absent` finding is listed under `## Not filed (no issue backend)` and the `transient` one is retried every later round. Then count the `diverted` outcomes and the remaining retry files into the unit file and write the PR-body sections ([[#The audit loop unit]]). Then return to step 1 on the new HEAD.

**STATE.md and resume.** The loop keeps the execution doctrine's STATE.md current, one Status line per step above, each naming its expected artifact, plus the `NEXT:` line:

```text
- [ ] round <r> dispositions: dispositions-<r>.json
- [ ] round <r> baseline: baseline-<r>.json; sha256 dispositions <hex>, baseline <hex>
- [ ] round <r> fixer: fixer-<r>-audit.json, real, attempt <k>
- [ ] round <r> verify: verifier-<r>-<k>.json, pass
- [ ] round <r> gate: gate-<r>-<k>.log and gate-<r>-<k>.paths, pass
- [ ] round <r> round-check: exit 0
- [ ] round <r> commit: <sha>, pushed
- [ ] round <r> record: published
- [ ] round <r> filing: filing-outcomes-<r>.jsonl, retry pass done, check-outcomes exit 0
NEXT: <the next step above, by name>
```

On resume, one state overrides the execution doctrine's generic rule to re-dispatch any dispatch whose artifact is missing: a round with `baseline-<r>.json` and no `fixer-<r>-audit.json`. Check the tree against the baseline first:

```bash
bash <RUN_FOLDER>/verifier-bin-<r>/audit-fix-verify.sh drift --root <RESOLVED_ROOT> --baseline <RUN_FOLDER>/baseline-<r>.json
```

Exit 0 means the tree equals the baseline, and re-dispatching the fixer is safe. Exit 1 (it prints `head-moved`, `index-changed`, or one `drift: <path>` line per path that differs) means a fixer edited and never wrote its result: do not re-dispatch the fixer. An interactive run asks the human, an unattended run stops and reports. A second fixer on top of those edits would hand the verifier a delta neither fixer declared.

**Unit recovery.** A next unit rebuilds its position from the branch state and the run folder, not from the dead unit's memory. Before opening a round it republishes the `## Audit rounds` record, checks for a dirty tree and for an unpushed commit, and runs the `drift` check above on any `baseline-<r>.json` that has no `fixer-<r>-audit.json`: exit 1 stops it `needs-human`. The main thread's own recovery is in [[PR Merge Workflow#Dispatch the audit loop unit]]: a missing `unit-<u>.json` stops for the human.

#### Applying the audit's own Suggestions: digest economics

Applying an in-scope Suggestion or an accepted finding is a content edit, so it rotates the reporting member's content digest, invalidates its marker, and forces a fresh re-dispatch of that member to re-earn the clearance. The cost decides whether to fold it into this PR. The two arms are:

- **The member's digest is already rotating in this PR**, you are already changing files it owns this round (the ordinary audit → fix → re-audit loop) or a gate-machinery path every member's digest folds in. The re-dispatch is already being paid, so **apply the Suggestion in the same PR**: the fix rides a re-review that happens anyway and adds no marginal audit cost.
- **The PR is already clean and the member is already marked**, with nothing else rotating its digest. This arm differs from the first in kind, not only in price: no round is currently reading this branch, so whatever the fold adds is content nothing has reviewed, on a branch whose whole review budget is already spent, and a defect in the repair costs a further round on top of the one the fold buys, plus whatever that defect does if it ships instead. **Apply it when the repair is comment-only or prose-only** and the branch still holds an anchor. Those two forms carry almost none of the unreviewed-repair risk, and the re-dispatch they buy is a delta review of the one edit plus the member's fixed dispatch overhead, not a 60-110k full round. **A repair that introduces new logic into an already-marked PR is weighed on the risk of shipping an unreviewed repair, not on the delta-review price alone**, which is the smaller term of the two. **Accept-and-note** is for that case, for an edit that resets the member's review back to full scope (touching the global-rules set or the member's own agent definition), for an unanchored member, and for a finding big enough to deserve its own change, not for a one-line comment or prose correction.

Accept-and-note is not free either, and pricing only the re-dispatch hides its cost: a deferred Suggestion leaves a known defect in the tree and moves the repair to a follow-up that has to rebuild the context this round already holds. Weigh both sides before deferring.

Both arms assume the Suggestion is correct. A Suggestion is a finding, not a specification: it can assert a mechanism the member inferred rather than verified, and a claim about third-party behavior is where that is likeliest and hardest to spot. Verify the claim against the library's own source or a runnable probe before applying it, most of all when the fix is prose that ships as guidance, where implementing it verbatim turns a reviewer's error into a documented one that reads as reviewed. The re-dispatch these economics already price in re-reviews the edit and usually catches it, but only after an extra round.

This is operator guidance about **in-scope Suggestions and accepted findings**: the operator deciding whether an in-scope Suggestion is worth folding into an already-marked PR. Out-of-scope findings are not part of it; they are disposed through [[Audit Disposition and Debt Fix]].

Record accept-and-note under the heading `## Accepted residuals (recorded, not fixed)` in the pull request body, one entry per residual: its `file:line`, a one-line failure mode, and its dedup key. The dedup key is the wrapped `<!-- gaia-debt-key: … -->` HTML-comment form (`.claude/skills/file-tech-debt/SKILL.md`); a bare inline "Dedup key: …" line with no wrapper is refused at merge. The heading stays distinct from the machinery-waive heading beside it because the two mean different things: a waive is an out-of-scope finding on an eligible path, an accepted residual is in the member's own remit.

Every recorded residual is machine-enumerable by one query over merged pull request bodies:

```bash
gh pr list --state merged --limit 2000 --json number,body \
  --jq '.[] as $pr
        | ($pr.body // "") | split("\n")[]
        | select(test("<!-- gaia-debt-key: "))
        | capture("<!-- gaia-debt-key: (?<key>v1 class=[^ ]+ path=(?<path>[^>]+) line=(?<line>[0-9]+)) -->")
        | "\($pr.number)\t\(.path):\(.line)\t\(.key)"'
```

This queries `gh` rather than the working tree because a pull request body lives in GitHub's API, reaching no clone and no release tarball, so `git grep` cannot reach it; the body is the durable record, with no local retention clock to outlive, though it stays editable after merge. `--limit` bounds how far back the query reaches; raise it on a clone whose merged pull request count exceeds it. The `// ""` guard exists because a pull request with no body arrives as JSON `null`, and `null | split("\n")` aborts the whole query.

The convention governs what gets recorded from here on; the existing record in already-merged pull requests is left as it stands. A residual recorded against a merged pull request names a path and a line at a commit a squash-merge has since rewritten, the entries are recoverable only through the same lossy extraction the convention exists to make unnecessary, and repairing the pile at scale forces a full-scope re-review of every dispatched member rather than one delta review.

An accepted in-scope residual adds no dependence on any gitignored `.gaia/local` store; its only record is the pull request body.

#### When rounds stop: pre-commit a disposition for every branch

The fix loop above says to re-spawn until the audit reports clean, and the digest economics beside it license accept-and-note instead. Choosing between them *after* a finding is on the table is the failure, because at that point the question is no longer what the rule was, it is whether this particular finding is worth one more round, and asked that way it answers yes almost every time. Write the rule down before the round runs.

<!-- gaia:maintainer-only:start -->
GAIA maintainers: before disposing any harness-path finding in `dispositions-<r>.json`, read `.claude/rules/maintainers/harness-triage-threshold.md`. On harness paths it decides which findings are marked `fix` or `file` and which are waived, and it overrides this page's fix-every-Suggestion and file-every-out-of-scope-finding terms.
<!-- gaia:maintainer-only:end -->

A usable rule names a disposition for **every** way the round can come back, including carrying on. A rule that says only "stop and reconsider" has decided nothing: the same question returns one round later with no rule left standing. Three branches, and the third is the one commonly left open:

- **Clean** → post the `GAIA-Audit` status (see [[PR Merge Workflow#Posting the status last]]), then merge.
- **Only accepted residuals** → accept-and-note under the heading `## Accepted residuals (recorded, not fixed)` in the PR body, post the `GAIA-Audit` status, then merge. **Prose an earlier round wrote** goes through the checkpoint instead: a round carrying only new findings on prose the previous round wrote reports `enriching`, the bound hook stops the loop at [[PR Merge Workflow#The branch checkpoint]], and accept is the route there. Repeat findings on the previous round's own repair are the signal that each pass is enriching the artifact rather than correcting it, and every widening of a prose list invites the next one.
- **A new, reproduced defect in the logic this change authored** → name the concrete outcome rather than deferring it, because "run another round" is not a disposition, it is the absence of one. Say what ships, what gets filed instead, and who decides. Where the round turns on a design decision an operator settled, retiring that decision is the operator's call, so the fallback is to report and recommend rather than to overturn it.

A `quiet` verdict from the evaluator (no fixable finding this branch authored remains) only proposes this section's disposition; this section's own judgment of what this change authored decides it. The verdict counts findings by where they sit in the branch diff, which is evidence about authorship, not the judgment the three branches above ask for.

The three dispositions are also bounded by the dispositions check: it refuses a round that leaves any finding or a vetoed key with no disposition, disposes a vetoed key or a Critical or security-class finding the branch authored anything but `fix`, or makes a non-fix disposition without a reason or a valid `basis`, and `.gaia/scripts/audit-dispositions-check.sh`'s header owns the list.

**Every finding is disposed, whoever authored it.** A finding outside the branch needs a disposition as much as one the branch authored: `waive-out-of-scope`, `file`, or `divert`, per [[#Cross-remit findings]]. `divert` is the disposition for a security-class finding the branch did not author (a Critical, one its member flags `security`, or one whose `security` field is absent); it files nothing, and the filing script keeps a local record while every other surface carries a count. The check refuses `divert` for anything else and refuses `file` for such a finding unless the repository is confirmed PRIVATE. A finding that is security-class and branch-authored is `fix`, never `divert`.

<!-- gaia:maintainer-only:start -->
GAIA maintainers: a maintainer shell or node member marks a sub-threshold finding on its own harness paths `triage` in its sidecar entry, with a reason. The check honors the mark only for those two members, on their own roster globs, for a non-error finding whose `security` is exactly `false`; an ignored mark leaves the finding to be disposed normally, and an honored one needs no dispositions entry and renders as a line under `## Waived below triage threshold (not filed)`.
<!-- gaia:maintainer-only:end -->

**The honest limit.** The checks bound a mistaken disposition, not a forged input. Divert legality (is the finding security-class and outside the branch), the triage-mark ignore rules and the light route's security bound all read findings sidecars that Claude can write: `.claude/hooks/block-audit-loop-write.sh` guards the loop state and the protected folder, not those sidecars. A sidecar entry that lies about `security`, `triage` or authorship passes a check built on it.

**A round count is evidence, not a verdict.** What says a guard is the wrong instrument is the **direction** of its repairs, whether each one leaves the artifact smaller, and **where** the defects land: in the parser, the comparison, the payload, or the design. A fifth round in a part that has been stable since the third is a different finding from a fifth round in the same place, and the count alone cannot tell them apart.

#### Cross-remit findings

A member can find a genuine defect in a file outside its own declared domain, a **cross-remit finding**. The member that found it applies no repair, whether or not the file's owner has already cleared it and whether or not the fix looks trivial; it reports the finding to the orchestrator instead. The orchestrator disposes of it one of two ways:

- **In scope for the PR** → the orchestrator marks it `fix` in the round's dispositions file and the fixer repairs it ([[#The fix round: fixer, verifier, gate]]). The round's commit rotates the owning member's digest, invalidating that member's marker, so the owner is re-dispatched and reviews the repair made to its own file.
- **Out of scope** → the orchestrator screens security first, on the finding's content and severity and never on its `finding_class` tag (`holistic/unclassified` is a valid class and never a trigger). A security-class finding (any Critical, one its member flags `security`, or one whose `security` field is absent) is disposed `divert`: `.gaia/scripts/file-tech-debt.sh file --disposition divert` runs no write verb, keeps a local record under `.gaia/local/audit/security/`, and every other surface carries the count only. On a confirmed PRIVATE repo it may instead be disposed `file`; `audit-dispositions-check.sh` refuses its `file` disposition elsewhere (`security-file-not-private`) and refuses `divert` for a finding the branch authored (`divert-not-allowed`). A non-security finding is recorded as **waived** (listed in the pull request body, not filed) when its path is either a gate-machinery path or a file this pull request already changes and the finding itself clears both disqualifiers; a non-security finding satisfying neither term is disposed `file` and filed as a tech-debt issue through `.gaia/scripts/file-tech-debt.sh`, which probes the backend, dedups, files and verifies. A backend that is absent or fails transiently never blocks the merge ([[#The fix round: fixer, verifier, gate]], Filing).

Either way the finding is **recorded rather than lost**.

The waive rule applies to every out-of-scope finding the orchestrator disposes, whichever member surfaced it: every specialist surface belongs to a member that files nothing itself, so the orchestrator disposes what they hand it.

<!-- gaia:maintainer-only:start -->
GAIA maintainers: those surfaces are `.gaia/cli/src/**`, `.claude/skills/**`, `.gaia/scripts/**`, `.claude/hooks/**`, `.claude/rules/**`, `.gaia/**/*.bats`, and `.github/workflows/**`. The list is wrapped because the first glob names a maintainer-only tree that no adopter clone carries, and a shipped page asserting it would be describing a directory the reader does not have.
<!-- gaia:maintainer-only:end -->

Either path term alone is sufficient: a gate-machinery finding satisfies the path condition whether or not the pull request touches it. An empty eligibility set disengages the waive rather than opening it, with nothing eligible, a finding routes to the normal filing path. The security screen runs first and is unchanged: a security-class finding never waives.

Two disqualifiers narrow what may be waived inside that eligible set, and neither widens it: a finding must clear both to stay eligible. No gate checks either one; they sit on the same agent-judgment wall the non-security screen sits on.

**The change authored the inconsistency.** A finding is not waive-eligible when this change is what authors the inconsistency the finding names: the finding's site sits inside this change's own diff, or it is a sibling of a set this change adds a member to, or it is a claim this change falsifies. *Pre-existing* describes a sibling this change leaves untouched, never an asymmetry this change introduces. The bound is not optional: a finding whose defect is latent at the fork point, reading the same whether or not this change lands, is untouched-sibling debt and stays eligible even when it sits in a file this change edits.

**A pointer written into shipped content owes a tracked destination.** A finding is not waive-eligible when this change leaves a pointer in shipped content, a code comment, a header note, a documented limit, or a test rationale, saying that a separate change handles what the finding names. The waive is unavailable and the finding is filed, so the pointer resolves to a tracked destination rather than to prose. This is a rule rather than a standing judgment call: a finding whose destination is named in shipped content is filed, and that filing is correct even when both path terms fire. The obligation runs from the pointer to the filing, never from the filing to the pointer, so omitting the pointer removes the obligation and removes the explanation from the shipped content along with it, and the cost lands on the author's own artifact rather than on the reader.

A waive files nothing: no tech-debt issue, no issue number, and no touch of the debt-count staleness sentinel (`.gaia/local/debt/refresh-requested`).

Eligibility bounds where a waive may be recorded, not which findings may be waived. Three walls stand on that second question, all of them agent judgment and none of them gate-checked: the non-security screen and the two disqualifiers above. An entry whose path satisfies neither path term is an unfiled out-of-scope finding wearing a waive label, and is disposed `file` instead.

Every waived finding is listed in the pull request body under the heading `## Out-of-scope machinery findings (recorded, not filed)`, one entry per finding, each carrying its `file:line`, a one-line failure mode, and its dedup key in the wrapped `<!-- gaia-debt-key: … -->` form (`.claude/skills/file-tech-debt/SKILL.md`).

The changed-file set is the `ELIG_CHANGED` lines `.claude/agents/code-audit-frontend.md`'s scope-resolver command prints under `--eligibility` (`.gaia/scripts/audit-resolve-scope.sh`); it is never the member's TS/TSX-filtered review-scope set, which excludes every surface this rule exists for.

The gate-machinery set is whatever `audit_path_is_machinery` (`.claude/hooks/lib/audit-machinery.sh`) accepts.

#### Marker key

Every clearance is written by the **one shared writer** (`.gaia/scripts/audit-write-clearance.sh`); no member hand-writes a marker file. Given the audited root, the writer derives the member's **content digest**, a sha256 over exactly the files that member owns plus the shared gate machinery (plus the in-scope-but-ownerless paths, for the default member; see [[Code Audit Team#Ownership classifier]]), through the digest engine (`.claude/hooks/lib/audit-digest.sh`), resolves HEAD's real tree and commit sha as plain data fields, then writes the body atomically. The body carries a version, `schema: 4`, the audited `member`, a `provenance` (`earned` or `refused` only, there is no carried family), the `digest` (the validity key), `tree` and `sha` (data only, never compared for validity), `audited_at`, and a `sidecar` flag. `sidecar` answers "does this member file a findings sidecar, its report of record": every member does, so it is always true. `schema` is informational, no reader validates it, so a marker written under the previous contract still validates unchanged. The gate's reader (`clearance_acceptable`) accepts a clearance only when it is **well-formed**: the body parses, its recorded `digest` matches the filename key, its `member` matches, and its `provenance` is `earned`; a file that exists but fails that check is neither cleared nor missing, the gate reports it as present but invalid and asks for a re-run. This is a well-formedness check, not an authenticity one, it raises the bar a hand-written marker has to clear; it does not by itself prove who wrote a given file. `jq` is required for every digest-keyed predicate; with `jq` absent every check returns false (fail-closed), it never degrades to a bare-existence match.

Marker bodies carry `review: full` or `review: light`: a full member round writes `full`, and the light-marker script writes `light` ([[#Light routing]]). Only a `review: full` clearance anchors incremental scope, in both the per-member arm and the team-signal arm ([[Code Review Audit Agent#Incremental scope]]); a legacy body with no `review` field and a refusal never anchor. The `GAIA-Audit` commit status stays light-blind: it attests that every dispatched member holds a clearance for this content, not how deeply it was reviewed, and making it carry review depth would change the `<version> <digest> <tree>` shape every parser of it reads.

Provenance gets its own filename, not just a body field:

| Provenance | Default member | Specialized member `<m>` | Meaning |
| --- | --- | --- | --- |
| earned | `<digest>.ok` | `<digest>.<m>.ok` | the member audited this exact content and cleared it |
| refused | `<digest>.refused` | `<digest>.<m>.refused` | the member audited this exact content and withheld its clearance |

Every write lands unconditionally: it overwrites a stale body at the same path. There is no create-only guard and no carried family to dominate; provenance is earned or refused only.

Marker files are named for the member's own **content digest**, not HEAD's tree and not its commit sha. The digest engine enumerates every tracked file at HEAD (`git -C <root> ls-tree -z -r HEAD`, NUL-delimited so no path name can shift the hash input), the ownership classifier and machinery matcher select exactly the member's set (`owned(member) ∪ machinery`, plus in-scope-but-ownerless for the default member), and the selected `<mode> <blob-sha> <path>` records are sorted and sha256'd behind a fixed recipe-version sentinel. Content-addressing falls out of the blob sha, so byte-identical content yields an identical digest regardless of what else in the repo changed; mode catches an exec-bit flip, path catches a rename. A marker attests that a Code Audit Team member reviewed **the content its own digest covers**, never the whole tree.

The digest key is what makes the team's markers order-independent, and it is far narrower than the whole-tree key it replaced: an unrelated or out-of-glob change (a CHANGELOG line, a wiki edit) rotates **no** member's digest at all, so every existing marker keeps validating with zero re-dispatch. A commit that leaves every blob byte-identical (an empty commit) advances HEAD without rotating any member's digest either. Each member writes its marker whenever it finishes; the members can run in parallel and no member creates a commit.

The key does not weaken the gate. A change to a file a member owns rotates only that member's digest, correctly forcing a re-audit of exactly the member whose content changed. A change to any gate-machinery file, anything whose bytes can change what a member reviews, who reviews it, where a clearance lands, or whether a clearance is believed, rotates **every** member's digest, since the machinery path set sits inside every member's input set by construction; this also closes the classifier-version skew hazard, since the classifier's own files are themselves machinery. See [[#Parallel dispatch]] for how this plays out when a repair touches a machinery path.

Two artifacts under `.gaia/local/audit/` key differently from a member's own marker, because their readers resolve identity at a different point than a content digest: the re-run carry-forward ledger (`<audit-key>.rerun.json`, keyed to the incremental base commit plus branch, an in-scope open-finding record the clearance writer holds each member to and the resolver reads for a refusal anchor, never read by the merge gate; see [[Code Review Audit Agent#Re-run carry-forward ledger]]), and the per-member findings sidecar (`<audit-key>.<member>.findings.json`, one per dispatched member, also keyed to the incremental base plus branch; see [[Audit Gate Reference#Findings block]] below). The ledger and the findings sidecar share an audit key but feed different consumers: the ledger briefs a member's **re-audit** (what remains, what the last round already fixed), the findings sidecar feeds the **posted findings block**, one array of every dispatched member's findings regardless of whether the pass was clean. The re-run carry-forward ledger reaps itself: the shared clearance writer removes it once no dispatched member has open entries left. Nothing reaps a marker or a findings sidecar; see [[Local Working State]].

