---
type: concept
status: active
created: 2026-04-20
updated: 2026-10-09
tags: [concept, ci, review]
---

# PR Merge Workflow

The main thread reads this page: the merge runbook, from the fork-PR refusal through the pre-dispatch verification, the dispatch of the audit loop unit, the branch checkpoint, the `GAIA-Audit` status, the merge and the post-merge cleanup. The audit loop unit follows [[Audit Round Procedure]], which the main thread does not read; the handshake signals, the bypass stamp and the accepted limits of a status-based gate are in [[Audit Gate Reference]].

Mandatory before any `gh pr merge`. Machine-enforced by `.claude/hooks/pr-merge-audit-check.sh`, which denies `gh pr merge` calls until every Code Audit Team member this diff dispatches has its own clearance marker for that member's own current content digest (see [[Audit Round Procedure#Marker key]]).

The gate is **repo-scoped** via `.claude/hooks/lib/repo-scope.sh`: it enforces this repo's audit contract only. A `gh pr merge` positively aimed at a different repo (`-R owner/other`, or `cd <other> &&`) is allowed; this repo's audit markers have no bearing on a sibling repo's merge. The verdict covers the whole tool call, so a call that also holds a command acting on this repository, even a read-only one, is enforced: run the sibling command as its own call. Scoping is fail-closed: any ambiguity still enforces.

## First step: refuse a fork PR

Before any checkout of the PR head and before any script on this page runs, ask whether the pull request comes from a fork:

```bash
gh pr view <N> --json isCrossRepository --jq .isCrossRepository
```

`true` means a cross-repository pull request. Stop, run nothing else on this page, and give the operator the manual path: review the harness diff by hand (`.claude/`, `.gaia/`, `.github/`), push the branch to origin so it becomes a same-repo pull request, and run this workflow on that one. A `gh` call that cannot answer (no authentication, no network) is a stop as well, never a "not a fork". `false` continues.

The order matters because every script step here (the member resolver, the clearance writer, the verifier) runs from the checked-out tree. A fork head in the working tree turns those scripts into the fork's own code running with the operator's credentials. The merge hook (`pr-merge-audit-check.sh`) and the dispatch hook (`audit-loop-bound.sh`) both refuse a cross-repository pull request and fail closed when `gh` cannot answer. The pre-checkout guard `.claude/hooks/block-fork-pr-checkout.sh` denies `gh pr checkout <n>` and a `git fetch` of `pull/<n>/head` for a fork pull request before its head reaches the working tree. The residual: once a fork head is checked out by any other route, every guard runs fork-controlled code and cannot be trusted to refuse, so the pre-checkout guard and this step are the only controls that act in time.

## Who audits: the dispatched member set

The gate is a roster, not a single agent. `bash .gaia/scripts/resolve-audit-members.sh` (run from the repo root, or with `--root <path>`) names the Code Audit Team members this diff owes an audit to, one per line, deduped and sorted. The owed members are audited by dispatching the audit loop unit ([[#Dispatch the audit loop unit]]). An empty or unanswerable result still owes `code-audit-frontend`, fail-closed. An in-scope file no member owns also owes `code-audit-frontend`: its content digest folds in every in-scope-but-ownerless path (see [[Code Audit Team#Ownership classifier]]). The merge gate enforces that only when the resolver names nobody, where its legacy path denies without the frontend marker. When the resolver names specialists, the gate checks only those, so an audit by `code-audit-frontend` is the only coverage an ownerless file gets. Every named member writes its own clearance (see [[Audit Round Procedure#Marker key]]). See [[Code Audit Team]] for the roster and dispatch mechanism.

## Marker-first: check before you audit

The hook requires a **clearance to exist** for each dispatched member's own content, not that you personally run the audit. The producer is always local: each dispatched `code-audit-*` agent writes `.gaia/local/audit/<digest>.<member>.ok` through the one shared clearance writer and creates no commit. A clean member pass never posts the `GAIA-Audit` status itself; the orchestrator posts it last, after every dispatched member holds a marker and every finding is disposed (see [[Audit Gate Reference#3. Marker handshake]]).

The audit is local for every author. A **fork** pull request is the one case it does not run for: a local audit would execute the fork branch's own audit machinery under the maintainer's full local credentials, so a cross-repository PR is refused rather than audited (see [[#First step: refuse a fork PR]]).

Start with the cheapest deterministic signal, the PR's check state:

```bash
gh pr checks <N> | grep GAIA-Audit   # what state the audit is in, if any
```

Read the whole output before narrowing to that row: the rows this grep discards answer a question the pre-dispatch verification asks anyway (see [[#Before the first dispatch: verify your own work]]), and discarding them means finding a red check after a round has been spent rather than before it. One note if this call is ever restructured to branch on its result: `gh pr checks` exits non-zero when a check fails, and piping it into `grep` swallows that status, so a version that tests the exit code has to capture the output first and test `$?` on the `gh` invocation itself, not on the tail of a pipeline.

| `gh pr checks` result            | Meaning                                  | Action                                                    |
| -------------------------------- | ---------------------------------------- | --------------------------------------------------------- |
| `GAIA-Audit … pass`              | a success is already posted for HEAD     | skip to [[#4. Merge]]                                |
| no `GAIA-Audit` row, or it fails | no audit has cleared this HEAD           | dispatch the audit loop unit ([[#Dispatch the audit loop unit]]), mandatory, not optional |

Member resolution, the out-of-scope bypass, and each member's scope resolver list changed files without rename detection, so a rename counts both its old and its new path: moving an owned file to an unowned path still dispatches its owner and keeps the bypass closed.

The exception is a PR whose entire diff is out of audit scope: the hook's out-of-scope bypass (see [[Audit Gate Reference#Signals]]) clears those with no marker at all, so no local run is needed.

#### Before the first dispatch: verify your own work

The gate is the most expensive feedback in the workflow, and it is a **merge** gate. The **first** dispatch on a branch has no earned clearance to anchor on, so every member reads its whole owned surface: 60-110k tokens per member and several minutes. Spending that to learn something a local check would have reported is a straight loss, because it consumes the round that should be finding what the author cannot see. Each repair then moves HEAD and rotates the digest, buying another round.

The failure shape is specific and worth naming, because it does not look like a mistake while it is happening. New parsing, matching, or extraction logic is written; it handles the shapes the author thought of; a member finds a shape it mishandles; the fix ships; the next round finds another. Each round is individually productive, so the loop feels like progress while it is really a debugging session billed at audit rates. Several rounds to converge on one hand-rolled parser is the canonical case.

So before the first dispatch, not after the first refusal:

- **Absorb `origin/main` first.**

```bash
git fetch origin main
git merge --no-edit origin/main
```

The deterministic checks below are worth more against the merged tree than against the pre-merge one, because main's incoming content is exactly what the branch has not been checked against, and a red found here costs a repair commit rather than a round.
<!-- gaia:maintainer-only:start -->
The same is true of the verification command's branch mode run just after (`bash .gaia/tests/verify-harness.sh branch`): several of its checks read the whole tree, main's incoming content included, and that content goes unchecked until this merge lands.
<!-- gaia:maintainer-only:end -->

A catch-up merge that lands after dispatch instead rotates a member's digest under it, the member's marker is refused as a superseded review, and the round is forfeited. This removes rotations that land before any member starts; it does not reach a merge that lands mid-round or between re-spawn waves, which is what the clearance writer's staleness refusal covers, at the cost of a forfeited round when it fires.

- **Run the deterministic checks that cover the change.** The test suites for the paths touched, the linters for the languages involved, the [[Quality Gate]] when its skip logic says it applies, and any suite that consumes what changed. Green locally is the entry condition for dispatch, not a milestone passed once: re-run it after the **last** edit. Verifying, then editing prose or docs, then dispatching without re-running is the same defect as never running it, and it is the easier one to commit because the green output is still on screen.
<!-- gaia:maintainer-only:start -->
- **Run `bash .gaia/tests/verify-harness.sh branch` as the one verification step, after the catch-up merge and after the last edit.** It runs shell-lint, the three distribution checks (the release-scrub leak check, `01-files-present`, `03-marker-strip`), every bats suite marked as whole-tree, and the bats suites the change selector picks over the branch's range from the merge base. Path-based selection alone misses a suite that names a changed file from somewhere else or checks the whole tree, and shell-lint reads the whole tree, so no path selects it; the marked suites and the shell-lint run cover that. The bats steps run in parallel, about five times faster than serial on a branch-sized set; without GNU parallel installed, `bats5.sh` warns and runs serially. The first member or unit dispatch is refused with `BLOCKED: audit verify` until branch mode has passed for the current HEAD, so branch mode is the last action before that dispatch, after every other pre-dispatch commit, because any commit after the pass needs a new pass. It refuses to start with exit 3 on uncommitted tracked changes or a detached HEAD: commit first, then run it. A failure that also fails on the merge base is reported as pre-existing (main is red) and does not block. A bats test that fails under the parallel run but passes when re-run alone at HEAD is reported as `FLAKY`, listed in the pass record, and does not block. A missing tool skips the steps that need it with a loud `WARN`, never a `PASS`. It takes minutes, so run it in the background with its output redirected to a log and read the log when it finishes.
<!-- gaia:maintainer-only:end -->
- **Read the whole `gh pr checks <N>` output, not only the `GAIA-Audit` row.** CI is a deterministic check that has already run; it happens to have run remotely, and it covers exactly the complement the path-scoped selection above deliberately skips. That complement is where the one failure shape the author cannot see from their own chair lives: a change to one file reds a guard that lives in another, with nothing in the diff pointing at it. Fold any red into the same repair batch as everything else found pre-dispatch, and read the rows beside it too, a silent pass next to the red is often the same coupling not yet caught. Four things this reading has to carry, or it misfires. It reports on the **pushed head**, so with commits still local it describes older bytes; read it as what has landed, not as a verdict on the tree about to be audited. **Pending is not green**, and it is not a reason to hold the round: audits take minutes too, and serializing behind CI wall-clock can cost more than it saves, so dispatch and re-read before the marker handshake. **Red is not always a code change**: a flake, an infra hiccup, or a rotated secret wants a re-run, so read the failing job's log before folding a repair into the batch. And a branch that is unpushed, or an audit run before the PR is opened, has nothing to read; skip cleanly rather than treating the absence as an error.
- **Write the adversarial fixtures a reviewer would ask for.** One per shape the logic might mishandle, chosen by asking what the input space actually contains rather than what the implementation happens to read. For anything that parses a real format, that space is unbounded: prefer the format's own parser over a hand-rolled scrape, and treat "I will teach it the next shape when something finds one" as the decision to pay for those rounds.
- **Prove each new mechanism can fail, one at a time.** A guard whose assertions cannot be made to fire asserts nothing, and it reports green in exactly the case it exists to catch. Mutate the guard's own logic, not only the thing it watches: drop a term from its formula, weaken a comparison, confirm a test goes red, restore. Doctoring the subject proves the fixture; mutating the guard proves the assertion. Do this per outcome, not per file and not per mechanism: for each distinct outcome the new logic can produce, mutate it to each of the others and confirm some test goes red, which for a predicate means both return values plus the fall-through wherever all three are reachable. A change that adds two mechanisms therefore needs at least two mutants, because the suite going red when you loosen a threshold says nothing about the selection rule added beside it, and one mutant per mechanism still leaves that mechanism's other outcomes untouched. Three traps make a mutant survive that reads as covered. An assertion that **recomputes the production formula in its own body** is testing its own arithmetic, so extract the formula into the helper both the assertion and the fixture call. And a fixture set that is uniform in the dimension the new rule discriminates on cannot see it: if the rule prefers longer-in-hops over larger-in-minutes, every fixture where those coincide agrees under either rule. And the mutant that comes to mind first is the failure you were already imagining, which is the direction you have just defended against, so it proves that direction and no other; the direction you did not consider is both the untested one and the likelier one to break later, which is what makes a single mutant reliably wrong rather than occasionally wrong.
- **Commit before you mutate, or mutate a copy.** Restoring a mutant means putting the file back, and `git checkout -- <path>` restores from the index: it discards *every* uncommitted change to that file, not only the mutation. The moment you are about to mutate is also the moment you are most likely to be mid-edit, so what the restore takes is usually work that has nothing to do with the guard, and it goes without a diagnostic. Commit first, or run the mutation in a scratch `git worktree` and leave the tree under review untouched, which is what a dispatched member does with its own mutation work.
- **A comment making a falsifiable claim about this repository is a query, so run it.** "This pathspec covers every surface", "widening this glob turns X red", "no other caller does this": each has an answer, and getting it costs seconds against the price of a round. Run it, or delete the sentence. A **replacement** comment earns the same treatment as the one it replaces: a correction is new unverified text, and it is the likeliest place for the next wrong claim, because the scrutiny went to the thing being corrected. Where the claim is about what a guard does or does not catch, prefer writing it as a test rather than as prose. A test is a claim that re-checks itself; prose is a claim that decays.
- **Treat "the audit will tell me if this is wrong" as an instruction.** That thought is a precise description of a test that has not been written yet. Write it instead.

None of this substitutes for the gate. It changes what the gate is spent on: the cross-cutting and adversarial findings a member is uniquely positioned to make, rather than defects already visible from the author's own chair.

<!-- gaia:maintainer-only:start -->
When this PR newly ships files, run `/distribution-audit` and land its manifest-answer commit first, before this step and before the verification command's branch mode: like every pre-dispatch commit, one that lands after the pass forces a re-run before the gate allows the first dispatch. Every branch push also runs the distribution checks through the pre-push hook, and a push it refuses names the check and the path. The manifest answer commits `.gaia/manifest.json` and any `.gaia/release-exclude` change; neither path is an audit-machinery digest input nor a reviewed member surface, so the commit rotates no member's content digest and invalidates no marker already earned. It does move HEAD, and the `GAIA-Audit` commit status is keyed to HEAD's sha, so a manifest commit that lands after the orchestrator's own status post strands that status on the old HEAD and forces an extra status re-post on the new one. Landing the distribution-audit answer first, before the first dispatch, is what keeps a later manifest commit from ever competing with the orchestrator's one status post for last word on HEAD: no handshake creates a commit, so the orchestrator's status posts directly on the current head once that head is pushed.
<!-- gaia:maintainer-only:end -->

Member resolution, the spawn and the dispatch prompt template are the audit loop unit's procedure ([[Audit Round Procedure#Dispatching the members]]); the main thread dispatches the unit ([[#Dispatch the audit loop unit]]) and never runs them itself.

## Dispatch the audit loop unit

The audit of a branch runs through the `audit-loop-unit` agent (`.claude/agents/audit-loop-unit.md`): an Opus orchestrator that runs a window of up to K rounds off the main thread, with the members and the Sonnet fixer one level below it, and returns one thin `unit-<u>.json`. `GAIA_CONTEXT_UNIT_ROUNDS` in `.gaia/scripts/context-checkpoint-lib.sh` owns K. The loop requires Claude Code 2.1.287 or later (subagent nesting). While a unit is available the main thread reads this page and does not read [[Audit Round Procedure]]: the unit follows that page for every round, member resolution and the member dispatch included. The unit never merges; the main thread alone posts the `GAIA-Audit` status and merges.

**When to dispatch.** After [[#Before the first dispatch: verify your own work]] has passed for the current HEAD and the marker-first check above found no `GAIA-Audit` pass for it. The main thread resolves no member set and dispatches no member itself: the unit does both, so the owed members are audited by dispatching the unit.

**The main thread's loop**, one unit at a time:

1. Run `bash .gaia/scripts/audit-loop-eval.sh next-unit --root <RESOLVED_ROOT>`. It prints `<u> <s>`: the unit number and the round the unit opens. Copy both into the brief; `<s>` is also what a veto records as `effective_from_round`.
2. Pre-clear the unit's artifact: `rm -f <RUN_FOLDER>/unit-<u>.json`.
3. Dispatch the unit with the brief below. The bound hook gates this dispatch ([[#The branch checkpoint]]). K is never in the brief.
4. Wait with one blocking Monitor until-loop on `<RUN_FOLDER>/unit-<u>.json`, not turn by turn. The file does not exist while the unit runs, so its appearance marks the unit's return; the `Agent` call returns before the unit has done anything, so classify only once the file exists, on the same terms as [[Audit Round Procedure#No-op detection and retry for each dispatched member]].
5. Classify the file with `bash .gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <RUN_FOLDER>/unit-<u>.json --report-key rounds --min-count 1`. A unit that opened no round still writes one `rounds[]` element, so a real unit always passes. On a no-op, recompute `next-unit`, pre-clear, and re-dispatch once; a second consecutive no-op stops the main thread for the human; it never runs the round procedure itself.
6. Read the file and branch on its `stop_reason`.

**The brief.** Exactly six fields: `Working root` (the bare absolute path of the checkout under review), `PR`, `Run folder`, `Start round` (the `<s>` from step 1), `Unit` (the `<u>` from step 1) and `Vetoes` (the path of `vetoes.json` in the run folder). K is never in the brief.

```text
Agent(
  subagent_type: "audit-loop-unit",
  prompt: "Working root: <RESOLVED_ROOT>
  PR: <N>
  Run folder: <RUN_FOLDER>
  Start round: <s>
  Unit: <u>
  Vetoes: <RUN_FOLDER>/vetoes.json"
)
```

Write the `Working root:` value as the bare absolute path with nothing after it: a trailing character can stop the hook's resolver from reading the path, and the hook strips wrapping quotes, backticks, and trailing sentence punctuation before resolving, and a named root that still does not resolve is denied with the token named rather than falling back to the session's working directory.

**Reading `unit-<u>.json`.** Branch on `stop_reason`; `stop_detail` carries the reason in words. The file also carries `rounds[]` and, for filing, counts and paths only: `diverted_count`, `diverted_records` (the local record paths), `filing_outcomes` (the outcome files) and `filing_pending` (files left in `<RUN_FOLDER>/filing-retry/`). It carries no finding detail.

| `stop_reason` | The main thread |
| --- | --- |
| `clean` | Runs `bash .gaia/scripts/audit-dispositions-check.sh check-all --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER>` once more as a last guard (read-only: with no `--snapshot-dir` it re-grades each round from the branch's frozen snapshots, and from live findings only for a round with none, and it writes nothing), then the CHANGELOG gate, the `GAIA-Audit` status ([[#Posting the status last]], which surfaces a non-zero `diverted_count` first), and the merge. |
| `window-end` | Starts the next unit at step 1; the bound hook decides whether it is admitted. |
| `checkpoint-deny` | Asks the pinned question ([[#The branch checkpoint]]). |
| `dispositions-check-failed`, `needs-human`, `failure` | Asks the human what to do, naming `stop_detail`; an unattended run stops and reports. A unit that finds the Agent tool absent stops `needs-human` and its `stop_detail` names Claude Code 2.1.287 or later and the upgrade step (`claude update`, then relaunch the session). |
| `member-wave-dirty` | Asks the human what to do, naming the wave's members and the dirty paths from `stop_detail`; an unattended run stops and reports. The unit left the tree as the members left it and committed nothing, so the human cleans or keeps the edits before the next unit starts at step 1. |

**Surface diverted findings before posting the status.** Sum `diverted_count` across the unit files. When it is non-zero, tell the human the count and the `diverted_records` paths, then post the status and merge without stopping ([[#Posting the status last]]). A diverted finding's key, class, path, title and reason never appear in what the human is told, and nothing about it goes into a PR body, comment or status. A denial of the unit dispatch itself carries the same classes as the table: the deny text and its classes are in [[Audit Round Procedure#The audit loop unit]].

**The waiver table and the veto.** After every unit, build the table from the dispositions files, never from the informational `waiver_table` in `unit-<u>.json`: `bash .gaia/scripts/audit-dispositions-check.sh waiver-table --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER> --rounds <a>-<b>`. It has one row per non-fix disposition (key, member, severity, security, disposition, reason). Show it to the human when the run is interactive. To veto a row, write its key into `<RUN_FOLDER>/vetoes.json` with Bash at the main checkout's absolute path, and read it back; `.gaia/scripts/audit-fix-verify.sh`'s header owns the file's shape. Each veto's `effective_from_round` is the `<s>` that `next-unit` prints at that moment, so a veto binds the next unit's rounds and never re-grades the round that held the waiver. A vetoed key is disposed `fix` from then on, and its commit rotates the owning member's digest, which is how a veto invalidates that member's marker with no change to marker semantics. A veto can only demand more `fix`, never less.

After a veto, rewrite the PR-body sections the unit wrote, from the same subcommand and the same flags the unit used: `bash .gaia/scripts/audit-dispositions-check.sh pr-sections --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER>`.

**Recovery and relaunch.** A unit that returns with no `unit-<u>.json` stops the main thread for the human; it never falls back inline on its own. After a human resolves a stop, the next unit starts at step 1: `next-unit` recomputes the unit number and the start round, and the new unit rebuilds its position from the branch state and the run folder, not from the dead unit's memory ([[Audit Round Procedure#The fix round: fixer, verifier, gate]], `Unit recovery`). A session that must be relaunched to pick up a changed agent definition or hook wiring resumes with the continuation prompt the checkpoint prints ([[#The branch checkpoint]]).

#### The branch checkpoint

Machine-enforced by `.claude/hooks/audit-loop-bound.sh` on every dispatch of the `audit-loop-unit` agent and of a Code Audit Team member. A unit dispatch is gated against the main session's context; a member dispatch inside the unit's recorded window passes. A member dispatch on a HEAD tree this branch has already audited passes free: every member of one wave shares that tree, and so does the single hardened re-dispatch of a member that no-op'd ([[Audit Round Procedure#No-op detection and retry for each dispatched member]]). A member dispatch on a tree not yet audited starts a new round. The hook first evaluates the previous round itself, from that round's findings sidecars, and stores the result in the branch history; it then decides whether to admit the dispatch, and records the new round when it does. The deny is not a merge blocker: it denies a dispatch, never `gh pr merge`, and clearance semantics are untouched.

The state is per branch, never per session. History, written only by that hook, and allowance, written only by the two grant hooks (`.claude/hooks/audit-loop-ask-grant.sh` for a selection, `.claude/hooks/audit-loop-grant.sh` for a typed line), live in one main-anchored file keyed by the normalized branch and linked to the PR, so clearing or compacting the context, a new session, a fork, and a sub-agent all leave both byte-identical. The hook denies loudly, and never allows, on corrupt state, missing jq or git, a detached HEAD, a new-tree dispatch from a checkout with uncommitted tracked or staged changes (commit the round first), or an exceeded internal deadline. Two files own the numbers: the round-count checkpoint, the grant size, the knobs, the verdict and rubric-signal formulas, the allowance fold, the hard round cap and the decision order live in `.gaia/scripts/audit-loop-eval.sh`'s header; the context line, the statusline bands, K and the reading's freshness limit live in `.gaia/scripts/context-checkpoint-lib.sh`. This page restates none of them.

**The context gate.** Before each unit dispatch the hook reads the main session's context reading, the file the statusline writes for that session under the main checkout's `.gaia/local/cache/shared/context/`, and asks only when the reading is at or above the effective line. The line is the lower of a token count and a share of the reading's own context window. A human may lower it for a machine by hand in `.gaia/local/protected/checkpoint-override.json`; a raised or invalid value reads as the default, and Claude's writes to that file are denied. The hook freezes the line's configuration into the branch history at the first unit or round and afterwards applies only a lowering. A reading that is missing, stale, future-dated or unparseable falls back to the round-count checkpoint and never allows past it. The reading changes only when the statusline renders on a main-thread turn, so a unit's off-thread spend stays invisible to it until the unit returns: the rubric signals and the hard round cap are independent backstops. A denying rubric signal denies whatever the reading says, a dispatch that would open a round past the hard cap is denied whatever was granted, unless a human answered the checkpoint the cap pins: past the cap each unit needs its own answer, a grant buying a whole unit and an accept its one closing round.

**One grant admits one unit.** An allowed unit records a window, the rounds it may open. A grant answering the latest checkpoint admits exactly one unit of K rounds; the next unit dispatch evaluates every trigger afresh and is denied again while the reading stays over the line. The grant-size fold of the round-count checkpoint applies only on the round-count fallback.

Each evaluated round gets one verdict, built on `A(r)`, the round's count of findings this branch authored that no earlier round disposed non-fix:

- `continue`: the evidence shows the loop converging, so the round runs within the allowance.
- `quiet`: `A(r)` is zero; a stop heuristic that proposes the [[Audit Round Procedure#When rounds stop: pre-commit a disposition for every branch]] disposition and decides nothing on its own.
- `stalled`: the branch-authored count has stopped falling across the latest rounds, so another round is unlikely to move it.
- `enriching`: the latest round found a new finding on lines the previous round's repair wrote, the sign that each pass is adding to the artifact rather than correcting it.
- `unknown`: a dispatched member left no readable findings sidecar for the round; missing evidence still counts as a round and is never read as `quiet`.

**An interactive run asks the human, in this session.** A checkpoint deny (`BLOCKED: audit checkpoint`, or a unit stopped `checkpoint-deny`) has already pinned the whole question in guarded state, with a fresh nonce. Print it with `bash .gaia/scripts/audit-loop-eval.sh pinned-question --root <RESOLVED_ROOT>` and ask it as one AskUserQuestion, with exactly that `tool_input` and nothing changed: Claude authors no word of it, and a changed word makes the recorder decline. Put the evidence beside it first, from the evaluator, which is read-only:

```bash
bash .gaia/scripts/audit-loop-eval.sh brief --root <RESOLVED_ROOT>
```

The evidence is the rounds run, `A(r)` per round, the verdict and its evidence, the remaining findings by severity, and the spend, labeled information only (or `unavailable`); spend never grants and never blocks. The question text and each grant option's description carry the main session's context reading from the moment the checkpoint was pinned (percent and tokens of the window, or `context unavailable` when the reading is missing or stale), because the statusline is hidden while a question shows and never visible over Remote Control, and the human reads the choices rather than the text above them. Exactly one option is recommended: it leads and its label ends in ` (Recommended)`; the rest keep the order below. A `context` checkpoint always recommends the new-session grant, with the in-session grant right after it as the opt-out. For any other trigger the evaluator's `recommended` value decides: `accept` leads with `Accept the remainder` when it is offered, `stop` leads with `Stop and file the remainder`, and a grant (or an accept that is not offered) chooses between the two grants by the context line, the in-session grant when the reading is below it and the new-session grant when the reading is at or above it or unavailable. The line is `gaia_context_line` in `.gaia/scripts/context-checkpoint-lib.sh`, computed with the same knobs the gate uses. The options, quoted as the evaluator builds them, each present only when it applies:

- `Continue audit in this session` and `Continue audit in a new session`, each recording a grant of K from `.gaia/scripts/context-checkpoint-lib.sh`. Past the hard cap a grant still admits one unit of K rounds, and the next unit asks again.
- `Accept the remainder`, only when the evaluator reports the branch accept-eligible: a rubric signal holds, no remaining finding is Critical or security-class, and the verdict is not `unknown`.
- `Type audit-accept instead`, only at the cap when accept is not eligible; it records nothing, and its description says the human may type `audit-accept` as the whole prompt, a deliberate override of the eligibility gate.
- `Stop and file the remainder`, always.

`.claude/hooks/audit-loop-ask-grant.sh` records a selection as the answer only when the question came from the main thread of an interactive session in a permission mode it measured, the call's `tool_input` equals the pinned question exactly, and the answer is exactly one pinned label. The selected label must equal a pinned label exactly, with or without the ` (Recommended)` suffix the pin carries on its leading option. Either grant label records a grant of K for that checkpoint, and `Accept the remainder` records an accept. `Stop and file the remainder` and `Type audit-accept instead` record nothing: file the remaining in-scope findings through the `file-tech-debt` skill, leave the PR open, and report. Any other answer records nothing and leaves the state byte-identical, and the hook says so and names the typed fallback. The typed lines stay as that fallback: `.claude/hooks/audit-loop-grant.sh` records a whole prompt that is exactly `audit-grant <n>` or `audit-accept`, in an interactive session, and reaches the checkpoint through this session's id when the session's working directory is on another branch. Claude never types, writes, or simulates the line, and never writes the branch state file.

`Continue audit in a new session` records the same grant as the in-session option and then asks the main thread to print one instruction line, then this continuation prompt in a fenced block for the human to paste into a fresh session, and to stop. The line is "Run `/clear`, then paste the prompt below." by default. Only when the next audit unit would run stale without a fresh launch is the line instead "Press Ctrl+C, run `claude` (with any needed environment variable), then paste the prompt below.": the unit needs an environment variable this session lacks, or the branch changed, since this session started, an agent definition the unit dispatches (`.claude/agents/`) or hook wiring in `.claude/settings.json` that the audit loop or merge gate runs through. Edited skills, rules, CLAUDE.md, wiki pages and hook script bodies are read fresh after `/clear`, and a launch-time change the audit does not exercise does not matter, so neither calls for a relaunch. Whichever line applies is printed on its own line, verbatim, not folded into a paragraph. When the Ctrl+C line applies and the session runs in a linked worktree, one more line follows it, because Claude Code can ask on exit whether to remove the worktree, and removing it mid-audit discards the checkout the next session resumes in: "In a worktree, Claude Code may ask whether to keep or remove it as it exits: choose keep." Either way the new session writes its own statusline reading under its own session id, and the grant is already in the branch state, so the next unit dispatch is admitted without asking again:

```text
Resume the PR merge workflow for PR #<N> on branch <branch>, working root <RESOLVED_ROOT>, run folder <RUN_FOLDER>. Read wiki/concepts/PR Merge Workflow.md, then follow its "Dispatch the audit loop unit" section: run `bash .gaia/scripts/audit-loop-eval.sh next-unit --root <RESOLVED_ROOT>` and dispatch the next audit-loop-unit. A grant is already recorded for the latest checkpoint.
```

**An accept buys exactly one closing round**, flagged in the history, and the unit window it opens is that one round, which `audit-loop-eval.sh unit-window` reports as `closing` so the unit runs it with no fixer. No fixer is dispatched for it, so the round has no `fixer-<r>-audit.json`: the members re-audit the current tree to earn their markers, and the remaining entries are recorded under the heading `## Accepted residuals (recorded, not fixed)` in the PR body, in the entry format `/gaia-residue` already parses (the `file:line`, the one-line failure mode, and the wrapped `gaia-debt-key` form [[Audit Round Procedure#Applying the audit's own Suggestions: digest economics]] states). No member repairs anything in it either: members edit no tracked file, and `code-audit-frontend` reads the same `closing` field, reporting its in-scope Suggestions as residuals rather than withholding its marker on them, because a closing round runs no fixer that could address them. A closing round never re-arms the loop: if it does not clear, the next new-tree dispatch is denied and the human decides again.

**An unattended run never asks and never grants.** A run with no human in the session (a headless, scheduled, or `/loop` run) that reaches a checkpoint pushes the round's fix, leaves the PR open, keeps any claimed issue's `in-progress` label, and reports the verdict, the evidence, a recommendation, and the next step. It prints the typed `audit-grant <n>` line from the brief's `grant_line` and no continuation prompt: a human types the printed line in an interactive session on that branch, then re-runs this workflow. The branch state and the PR body carry everything the next run needs. Interactivity is a property of the session, not the command: `/gaia-debt` invoked by a human in an interactive session asks like any interactive run, and `/gaia-harden` always does.

Three things the checkpoint does not do:

- **It does not license a merge.** Clearance is unchanged: `gh pr merge` stays denied until every dispatched member holds a marker for its own current digest, and a round's fixes rotate the digests they touch, so the merge hook denies with no help from this one. A stop at the checkpoint leaves a pushed branch and an open PR.
- **It does not stop a round that ends the work.** The dispositions above resolve first, at any round number: a clean round posts the `GAIA-Audit` status and merges, and a round carrying only accepted residuals is accept-and-note under the heading `## Accepted residuals (recorded, not fixed)` in the PR body, then the same post-and-merge. The checkpoint binds only where the disposition would be another round.
- **It does not judge the change.** A round count is evidence, not a verdict, so the direction of the repairs and where the defects land still decide whether this branch deserves more rounds or needs a different instrument. The checkpoint hands that question to the human with the evidence beside it.

The bound is on spend and on a loop that is not converging. Every round's fixes buy the next round, so left alone the loop has no stop of its own. The unit keeps the repair history off the main thread, so the context gate tracks what the main session has absorbed rather than how many rounds ran, and the rubric signals and the hard cap end a loop the evidence says is not converging whatever the context holds.

A fail-loud deny names its cause and its repair; for a corrupt state file that repair is a human moving the file aside from a terminal outside Claude Code. At a checkpoint the only recovery is a human answer, a selection of the pinned question or a typed line. A PR-body edit, an environment knob above the default, a question Claude composed, and a recorder Claude ran by hand each raise nothing: `.claude/hooks/block-audit-loop-write.sh` denies Claude's writes to the protected folder `.gaia/local/protected/` (the state and the override) and to the context directory, and any Bash or Monitor command that executes either grant hook. Its path arm reads only commands that name those paths: a context reading minted from Bash by running the statusline or `gaia_context_write` names none of them, so the rubric signals and the hard round cap stay its backstops. It also denies a Bash heredoc or inline script whose text merely names those paths or a recorder's filename, so write such files with the Write or Edit tools.

The PR body's `## Audit rounds` section is the published record of the loop: total rounds, rounds per member, light reviews per member when any ran (a `light reviews:` clause that never counts toward the round total), and human grants. The unit writes it at every round end through `audit-loop-record.sh` ([[Audit Round Procedure#The fix round: fixer, verifier, gate]]). Nothing reads it back to grant a round or set a count.

#### Skipping already-cleared members

There is no carry-forward clearance machinery: no anchor selection, no delta computation, no minting step, and no `.carried` marker family. A member not already cleared for its own current digest simply gets re-dispatched; the digest key itself is what shrinks how often that happens, since an out-of-glob change never rotates it and only an owned-file or machinery change does.

A **refusal** is a first-class artifact keyed the same way as an earned marker (`<digest>[.<member>].refused`), the only way a member records "I read this exact content and I withhold." The gate checks the refusal family before the earned family and treats a live refusal of the current digest as absolute: no earned marker for the same digest, however clean, ever overrides it.

A refusal also carries a **server-side** signal, because the local hook is not the only merge path. GitHub's auto-merge completes on the required `GAIA-Audit` commit status alone and never runs the hook that honors refusal precedence, so a refusal recorded after a `success` status already landed for this head, the orchestrator's earlier post from a prior round on the same digest, would otherwise leave that success standing and the pull request merging over a live refusal, with the artifact on disk and no diagnostic anywhere. On the local path the shared clearance writer therefore posts a `GAIA-Audit` `failure` for the same head as it records the refusal, through the same hook the clean path uses (`post-audit-status.sh`, handed the refusal artifact instead of an earned marker). The latest status for a context wins, so this retracts the stale success and a later genuine clean pass overwrites it in turn; a refusal can never strand a pull request it no longer applies to. The post belongs to the writer rather than to a member's instructions because the one moment a refusal is guaranteed to be recorded is the moment it is written. It is best-effort in both directions: a post that cannot happen (no `gh`, an un-pushed head) leaves the refusal on disk where the local gate still denies the merge, and a failure there never disturbs the refusal that already landed.
A refusal is retired by its **author**, never by the gate inferring supersession from timestamps. Resolving the finding is the ordinary path: the repair edits a file the member owns, which rotates that member's digest and leaves the refusal keyed to content nobody is merging. A second path exists because an Important finding also clears by operator acknowledgment with a stated reason, which moves no bytes and so leaves the digest identical. There the member re-audits and writes its earned marker with `--supersede-refusal "<reason>"`; the shared writer records the reversal in the marker body and removes that member's own refusal, publishing the earned marker first so a crash leaves both artifacts and the gate shut rather than neither. That flag only exempts the write from the writer's review-scope staleness comparison when the refusal it retires is actually on disk; the exact condition is stated in the staleness gate's own header comment in `.gaia/scripts/audit-write-clearance.sh`. A plain earned write never touches a refusal. That asymmetry is what keeps refusal-precedence from decaying into "newest marker wins" and preserves it as the control that stops someone re-running an auditor until it passes: a bare re-spawn against unchanged, still-unaddressed content refuses again.

#### Posting the status last

A member's clean pass writes its earned marker and creates no commit; it never posts the `GAIA-Audit` success status itself (see [[Audit Round Procedure#Marker key]] and [[Audit Gate Reference#Signals]]). An all-green PR reads as done and safe to merge to anyone looking at it, and a clean member pass is not that: the orchestrator is still deciding what to do with the round's findings, folding a Suggestion, weighing accept-and-note, deciding whether to re-dispatch. Posting success ahead of that decision would announce a state that has not been reached yet. Refusals are unaffected: the clearance writer posts a `GAIA-Audit` `failure` itself the moment it records a refusal (see [[#Skipping already-cleared members]]), because a non-green signal never waits on anyone's disposition.

The orchestrator posts the success status itself, last, once every one of these holds:

- Every dispatched Code Audit Team member holds an earned marker for the current tree.
- Every finding from every round is fixed, or recorded under `## Accepted residuals (recorded, not fixed)` or `## Out-of-scope machinery findings (recorded, not filed)`, or filed, or diverted (a count, never the finding).
- The human has been told of any diverted finding: when the sum of `diverted_count` across the unit files is non-zero, surface that count and the `diverted_records` paths to the human before the status is posted, then post and merge without stopping. The surfacing carries the count and the local record paths only, never a diverted finding's key, class, path, title or reason, and nothing about it goes into a PR body, comment or status.
<!-- gaia:maintainer-only:start -->
- The CHANGELOG gate below is resolved, and its entry, if any, has landed on the branch.
<!-- gaia:maintainer-only:end -->
- The last push has landed on the pull request's remote head.

```bash
bash .claude/hooks/post-audit-status.sh <current-member-marker>
```

Any one dispatched member's own current marker path is sufficient; `post-audit-status.sh` already refuses while any dispatched member is pending and posts on the pushed PR head, so it resolves the rest itself (see [[Audit Gate Reference#Signals]]). Run `gh pr merge` only after this call reports a posted status.

Any later HEAD move needs a re-post, the manifest-answer commit above, a CHANGELOG fixup, or a conflict found mid-wait ([[#Conflict found mid-wait]] step 3 already does this for that case). If the orchestrator forgets this step, no `GAIA-Audit` status exists for the head; where `GAIA-Audit` is a required check, branch protection blocks the merge, so the omission fails closed and visibly rather than merging over a status nobody posted.

A bypass pull request needs none of this: the merge hook, or the CLI wiki flow that opened it, posts the `skipped: ...` status itself, so the orchestrator never posts one for it (see [[Audit Gate Reference#The bypass stamp]]).

### 4. Merge

<!-- gaia:maintainer-only:start -->
Two steps come first, in this order:

1. Clear the **CHANGELOG gate** below: decide whether this PR needs an `## [Unreleased]` entry and land it on the branch before merging.
2. **Read the advisory checks on the final head.** A check whose name ends in `(advisory)` is not a required context, so neither the merge hook nor a `--auto` merge waits on it, and no other step on this page reads one. A red one can still be reporting a real defect, the shipped-surface leak check above all, whose leak otherwise surfaces only when the release's bundle-time scrub fails. After the last push, list every advisory check that has not passed:

   ```bash
   gh pr checks <N> --json name,bucket \
     --jq '.[] | select(.name | endswith("(advisory)")) | select(.bucket != "pass" and .bucket != "skipping") | "\(.bucket)\t\(.name)"'
   ```

   Empty output clears the step. A `pending` row has not concluded yet: wait for it with `gh pr checks <N> --watch` rather than merging past it. That wait ends once every check concludes, so it cannot spin on a conflict the way a hand-rolled loop can, and `.claude/hooks/block-handrolled-pr-poll.sh` denies such a loop; a conflict still surfaces in the merge wait below. For every other row, either fix what the check flagged on this branch (a new commit moves HEAD, so the markers and `GAIA-Audit` must cover it again), or record it in the PR body under `## Red advisory checks at merge`, one line per check naming it and why it stays red. Keep the checks advisory: `.github/workflows/cli-tests.yml` states the leak check must not become a required context.
<!-- gaia:maintainer-only:end -->

Once **every dispatched member's** marker exists for HEAD and the `GAIA-Audit` status is posted (see [[#Posting the status last]]), run `gh pr merge`. The hook short-circuits to allow the call.

<!-- gaia:maintainer-only:start -->
GAIA maintainers: light routing appends one event per route and per light outcome to `.gaia/local/telemetry/audit-light-routing.jsonl` in the main checkout, and `bash .gaia/scripts/audit-light-telemetry.sh tally` prints engagement, escalation, and light-miss rates and median light-path tokens against a baseline. The script is release-excluded and writes nothing outside this repo.
<!-- gaia:maintainer-only:end -->

<!-- gaia:maintainer-only:start -->
## CHANGELOG gate (maintainer-only)

The last decision before merge: does this PR's change belong in `CHANGELOG.md` under `## [Unreleased]`? Make the call **at merge time**, not authoring time. An entry promised in an earlier session is worthless if it never landed, and a fix that spanned sessions may have changed what's worth noting, so re-run this check on every merge, including a PR resumed days later. GAIA's `CHANGELOG.md` is release-excluded, so this gate and every entry it produces are GAIA-team-only and reach no adopter clone.

**Worthy, add an entry.** Default to yes for anything that moves the GAIA product surface: a new or changed skill, command, hook, rule, agent, or wiki concept page; a behavior or default change; a bugfix in any shipped or maintainer surface; a dependency bump that crosses a security or compatibility floor; an adopter-action change (author it per the Adopter-action convention at the top of `CHANGELOG.md`). The changelog tracks the whole product, maintainer-only tooling included.

**Not worthy, merge as-is.** Typo, formatting, or comment-only edits; a pure internal refactor with no behavior or surface change; test-only changes that alter no shipped behavior; and anything already covered by an existing `## [Unreleased]` line.

When worthy:

1. Add the entry to the right `### Added | Changed | Removed | Fixed` subsection under `## [Unreleased]`, present tense with the trailing `(#<PR>)` reference. Write it at Keep a Changelog altitude: 1-3 sentences on what changed and why it matters, not implementation mechanics (no file/function/flag-internals narration). Preserve any **Action required:** marker and its literal command, breaking/migration substance plus a pointer to the steps, behavior-changing flag names, adopter-relevant version/engine bumps, and a truthful who/why clause; deep detail belongs in the PR and commit.
2. Commit it onto the PR branch with the subject `docs(changelog): add the entry for #<N>` and push so it merges with the change. HEAD moves, so re-confirm the audit marker still covers the new HEAD, then post the `GAIA-Audit` status ([[#Posting the status last]]) on the new HEAD before merging. Cheapest path: decide changelog-worthiness back in the fix round while fixing audit findings, so a single audit pass covers both.
<!-- gaia:maintainer-only:end -->

## Post-merge verification before cleanup

`gh pr merge` can fail without aborting the rest of a script: branch protection ("base branch policy prohibits the merge"), pending CI checks, missing `--auto` for queued merges, or auth issues. Proceeding to local cleanup (`git checkout main`, `git branch -D <pr-branch>`, `git fetch --prune`) before confirming the merge actually succeeded leaves the local branch deleted while the PR is still OPEN. Recoverable via `git checkout -b <branch> origin/<branch>` while the remote ref still exists, but it's avoidable churn.

Verification is identical under both isolation modes: poll the PR until it reports `MERGED`, and stop early on any state that means it never will.

```bash
gh pr merge <N> --squash --delete-branch [--auto]
```

Then wait. The wait is the reusable part, and it ships as a script: a caller that already issued its own `gh pr merge` runs only this line.

```bash
bash .gaia/scripts/pr-wait-merge.sh --pr <N>
```

It prints one verdict token on stdout and exits on it: `MERGED` (0), `CONFLICTING` (3), `CHECK_FAILED` (4), `TIMEOUT` (5), `CLOSED` (6). `--attempts` changes the default bound of five and `--interval` the default thirty-second spacing, which together are the ~2-3 minutes every caller here cites; a release or a full CI run passes `--attempts 20`. `--repo owner/name` waits on another repository's pull request; omitted, `gh` resolves the repository from the working directory.

<!-- gaia:maintainer-only:start -->
`/gaia-release`'s `create-gaia` lockstep wait uses `--repo`.
<!-- gaia:maintainer-only:end -->

**Exit 2 is a refusal rather than a verdict, and a caller must not read it as "still pending".** It covers a usage error, a `gh` that is not on PATH, and a `gh` that is present but never answered across the whole bound: expired auth, a rate limit, a network outage, or a pull-request number that does not exist. That last case is the one worth naming, because a `gh` that cannot answer returns the same blank state a live pending merge does; without the distinction the wait would report `TIMEOUT` and assert the pull request is still open, having established neither that pull request nor any state of it. A refusal prints no verdict token at all, so nothing on stdout reads as an answer. One transient failure still keeps waiting; the refusal needs every read in the bound to have failed.

The script issues no `gh pr merge` of its own, which is what lets the same invocation serve a caller that queued its merge with `--squash`, one that queued it with `--merge --auto`, and one resuming the wait after a conflict repair, where re-merging would be wrong.

That wait is the whole verification. A local error printed by `gh pr merge` after the state reads `MERGED` does not revise the answer; see [[#Local-sync failure mode]] below.

Rules the script preserves, each of which exists to stop the wait abandoning a merge that is about to land. `mergeable` reads `UNKNOWN` for a short while after any push, while GitHub recomputes it, so that counts as still waiting rather than as clean. Only required checks count: a failed optional check does not block a queued merge, so exiting on one would give up on a live merge. `gh pr checks` prints nothing and exits non-zero while no check has registered yet, which is also still waiting.

**Do not hand-roll this loop, and `.claude/hooks/block-handrolled-pr-poll.sh` denies it when you do.** A loop that waits only for `MERGED` cannot end once the base branch lands a conflicting change: `mergeable` turns `CONFLICTING`, the queued `--auto` merge never lands, and nothing left in the loop can fire, so it spins until a human notices while the in-flight required checks are spent either way. The pressure to hand-roll one is specific rather than hypothetical. A compound `gh pr view --jq 'if .state == "MERGED" …'` is refused outright by the worktree-isolation guard, which cannot verify that a `gh` call wrapped in a construct that complex stays inside the worktree, and whoever holds that refusal is one keystroke from `until [ "$(gh pr view <N> --json state --jq .state)" != "OPEN" ]`. A single `bash .gaia/scripts/pr-wait-merge.sh --pr <N>` is plain enough for that guard to read, so the blessed path is not the one the guard refuses. The hook stands down for a command that reads `mergeable`, and for one naming the script, and its own header carries what it does not catch.

**`--auto` vs `--admin`:** when `gh pr merge` rejects with "base branch policy prohibits the merge", the right escape is `--auto`; it queues the merge and GitHub completes it once checks pass. Never reach for `--admin` to bypass branch protection without explicit permission; it removes the safety the policy exists to provide.

Cleanup is what differs, because the two isolation modes hold the branch differently. Take the arm matching how the work is isolated; [[Task Orchestration]] covers how that choice is made.

**Read what the main checkout is holding before you pick an arm.** Both arms are run from a shell in the main checkout, and only one of them moves that checkout's HEAD, so isolation mode alone does not decide which is safe:

```bash
git -C <main-checkout> rev-parse --abbrev-ref HEAD
```

Anything other than `main` means another session holds the main checkout on its own branch. Take the worktree arm and run no `git checkout` at all. `.claude/hooks/block-main-destructive-git.sh` enforces this read: it denies a checkout or switch that would move the main checkout's HEAD off a branch with an open pull request, unless this session opened that pull request, and its source describes the kinds of spelling it cannot see. This is not a hypothetical: several worktree rows can merge while a separate main-checkout row is mid-audit on its branch, and the feature-branch arm's `git checkout main` then yanks HEAD out from under it. Nothing is lost when that happens, the branch, the pull request and the working tree all survive, but the interrupted member's own tree self-check fires and its round is forfeited, which is a whole member read spent for nothing. The sharper half is quieter: with the main checkout sitting on `main`, `resolve-audit-members.sh` returns an empty spawn set because `main` has no diff, not because anything cleared, and a monitor keyed on emptiness reads that as CLEARED. Such a check keys on the marker body's `tree` field matching the row's own tree instead ([[Audit Round Procedure#Marker key]]).

### Cleanup under feature-branch isolation

The session sits in the main checkout and holds the branch directly, and the precondition above holds, HEAD is the branch being cleaned up rather than a peer's:

```bash
git checkout main && git pull origin main
git branch -D <pr-branch>  # force needed for squash (orphaned commits)
git fetch --prune origin
```

### Cleanup under worktree isolation

A `git checkout main` from inside a linked worktree fails with `fatal: 'main' is already used by worktree at '<path>'` whenever the main checkout is on `main`. That is a property of linked worktrees, not a merge failure, and it makes the feature-branch sequence above unusable from a worktree. Reap the worktree centrally instead:

```bash
# from a shell in the main checkout, never from the worktree being removed
git worktree remove --force .claude/worktrees/<branch-name>
git branch -D <pr-branch>  # force needed for squash (orphaned commits)
git fetch --prune origin
```

**This sequence carries no `git checkout`, and that is load-bearing rather than incidental.** `git worktree remove` followed by `git branch -D` leaves the main checkout's HEAD exactly where it was, which is what makes the arm safe to run while a peer session holds that checkout on its own branch. Do not prepend the feature-branch arm's `git checkout main && git pull` to it: the sequence is not missing a step, and adding one is the precise move the precondition above exists to prevent.

`--force` is required because the worktree holds a branch whose commits the squash merge absorbed without making them ancestors of `main`, so git otherwise refuses to remove it. On a `gh` below 2.99.0 the `git branch -D` step is what actually drops the local branch on this path. `--delete-branch` deletes the local branch first and the remote branch second, and its local half checks out the default branch before deleting, which is precisely the step that fails here; because that step fails, `gh` returns before reaching its own remote delete. The remote branch still disappears on a repository configured to delete head branches on merge, so that setting rather than `gh` is what removes it here. From `gh` 2.99.0 on, the local delete is skipped with a warning naming this cleanup, and `gh` does delete the remote branch itself. If the branch is already gone, the command reports `branch not found` and nothing is wrong.

An agent driving the merge in-session removes its own worktree with the runtime's `ExitWorktree({action: "remove", discard_changes: true})`, gated on the confirmed `MERGED` state; `discard_changes` is safe there for the same reason `--force` is here. From a context that cannot call it, a fresh session or a sub-agent with a pinned working directory, the shell sequence above is the session-independent equivalent. See [[Audit Disposition and Debt Fix]] and [[Worktrees]].

### Conflict found mid-wait

A queued `--auto` merge, and any wait on CI or on a `GAIA-Audit` status between audit rounds, can go dead while it runs: the default branch lands a change that conflicts with the PR, `mergeable` turns `CONFLICTING` within minutes, and GitHub never completes the merge. A file most branches edit makes this common, and running several worktree branches at once makes it more so. Every wait in this workflow exits on `CONFLICTING` for that reason, the same way the poll above does, instead of running out its full bound; the check run in flight is spent either way, because the repair moves HEAD and starts a fresh one.

The repair is the catch-up merge from [[#Before the first dispatch: verify your own work]]:

1. `git fetch origin main` and `git merge --no-edit origin/main`, resolve the conflict, re-run the deterministic checks, and push.
2. Re-run `bash .gaia/scripts/resolve-audit-members.sh`, and for each member it names read its current digest with `bash .gaia/scripts/audit-member-digest.sh --root <root> --member <member>`. The merged content can rotate a member's digest; a member with no `.gaia/local/audit/<digest>.ok` marker for its current digest is re-spawned as a normal round.
3. When every named member still holds a marker for its current digest, the existing markers still cover the tree, but the `GAIA-Audit` status is keyed to the head sha, which the merge commit moved. Re-post it on the new head with `.claude/hooks/post-audit-status.sh <existing-marker>`, then resume the poll, re-running `gh pr merge` first if `gh pr view <N> --json autoMergeRequest` shows the merge is no longer queued.

A conflict found this way is not a merge failure, and it costs no audit round unless step 2 finds a member without a current marker.

## Local-sync failure mode

This failure mode belongs to `gh` below 2.99.0. When `gh pr merge` exits non-zero with `fatal: 'main' is already used by worktree at '<path>'`, **the GitHub-side merge has already succeeded**. The local checkout step is what failed, not the merge itself. Under worktree isolation this is the expected outcome rather than an anomaly, and it appears even in runs that perform no manual cleanup at all: `--delete-branch` runs its own local branch delete, which begins by checking out the default branch that the main checkout already holds. Driving the same merge from the main checkout fails one step later instead, at the delete itself, with `error: cannot delete branch '<branch>' used by worktree at '<path>'`; the merge has equally already succeeded. From `gh` 2.99.0 on, `gh` skips the local delete with a warning, deletes the remote branch, and exits 0, so the merge reports success under both isolation modes and this section describes nothing a reader on that version will see. Confirm with the wait from [[#Post-merge verification before cleanup]]:

```bash
bash .gaia/scripts/pr-wait-merge.sh --pr <N>
```

If it prints `MERGED`, do NOT retry the merge. Treat it as merged, run any post-merge steps (wiki-sync, etc.), and clean up through [[#Cleanup under worktree isolation]] above rather than the feature-branch sequence. Retrying compounds the problem and can produce a duplicate squash on a non-existent branch.

**With `--auto`, the exit status depends on the merge state at call time**, so it is not a property of the isolation mode alone. When GitHub queues the merge behind remaining checks, `gh` deletes neither branch and exits 0, and the repository's own head-branch deletion setting is then the only thing that removes the remote branch once the merge lands. When the pull request is immediately mergeable, `gh` merges on the spot and takes the same local delete path a plain merge takes, so a worktree run on a `gh` below 2.99.0 sees the failure above. Neither case revises what the poll reports.

## Second merge gate: the worthiness presence gate

`gh pr merge` passes through a second, independent PreToolUse hook,
`.claude/hooks/worthiness-presence-check.sh`. It denies the merge when an
emergent test the PR changed (matching the package's `emergentTests` globs in its `gaia.package.json`, as
the [[Determinism Classifier]] labels it) has no worthiness-ledger line matching
its current content. It checks presence and signal match only, never the
keep/fix/delete verdict, scopes to the emergent tests this PR changed (a no-op
when none changed), and fails open on missing tooling. It is a separate denial
from the Code Audit Team markers above; both must clear.
See [[Worthiness Presence Gate]] for the full contract.

## No exceptions

- Never merge without a valid current-digest marker from every member the roster dispatches. The hook denies it. Each member's own audit must cover the merged content, and every member produces its own marker locally.
- Never hand-write a marker file to bypass the gate. Each member owns its own marker's emission.
- A PR whose entire diff is out of audit scope needs no marker; the hook's out-of-scope bypass clears it and posts the stamp.
- Never audit or merge a fork PR locally; follow [[#First step: refuse a fork PR]].

See [[Code Review Audit Agent]], [[Quality Gate]], [[Git Workflow]].
