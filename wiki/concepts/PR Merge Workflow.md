---
type: concept
status: active
created: 2026-04-20
updated: 2026-10-01
tags: [concept, ci, review]
---

# PR Merge Workflow

Mandatory before any `gh pr merge`. Machine-enforced by `.claude/hooks/pr-merge-audit-check.sh`, which denies `gh pr merge` calls until every Code Audit Team member this diff dispatches has its own clearance marker for that member's own current content digest (see [[#Marker key]]).

The gate is **repo-scoped** via `.claude/hooks/lib/repo-scope.sh`: it enforces this repo's audit contract only. A `gh pr merge` positively aimed at a different repo (`-R owner/other`, or `cd <other> &&`) is allowed; this repo's audit markers have no bearing on a sibling repo's merge. The verdict covers the whole tool call, so a call that also holds a command acting on this repository, even a read-only one, is enforced: run the sibling command as its own call. Scoping is fail-closed: any ambiguity still enforces.

## First step: refuse a fork PR

Before any checkout of the PR head and before any script on this page runs, ask whether the pull request comes from a fork:

```bash
gh pr view <N> --json isCrossRepository --jq .isCrossRepository
```

`true` means a cross-repository pull request. Stop, run nothing else on this page, and give the operator the manual path: review the harness diff by hand (`.claude/`, `.gaia/`, `.github/`, `.specify/`), push the branch to origin so it becomes a same-repo pull request, and run this workflow on that one. A `gh` call that cannot answer (no authentication, no network) is a stop as well, never a "not a fork". `false` continues.

The order matters because every script step here (the member resolver, the clearance writer, the verifier) runs from the checked-out tree. A fork head in the working tree turns those scripts into the fork's own code running with the operator's credentials. The merge hook (`pr-merge-audit-check.sh`) and the dispatch hook (`audit-loop-bound.sh`) both refuse a cross-repository pull request and fail closed when `gh` cannot answer. The pre-checkout guard `.claude/hooks/block-fork-pr-checkout.sh` denies `gh pr checkout <n>` and a `git fetch` of `pull/<n>/head` for a fork pull request before its head reaches the working tree. The residual: once a fork head is checked out by any other route, every guard runs fork-controlled code and cannot be trusted to refuse, so the pre-checkout guard and this step are the only controls that act in time.

## Who audits: the dispatched member set

The gate is a roster, not a single agent. `bash .gaia/scripts/resolve-audit-members.sh` (run from the repo root, or with `--root <path>`) names the Code Audit Team members this diff owes an audit to, one per line, deduped and sorted. Spawn each member it names. An empty result means spawn `code-audit-frontend`, fail-closed. An in-scope file no member owns also owes `code-audit-frontend`: its content digest folds in every in-scope-but-ownerless path (see [[Code Audit Team#Ownership classifier]]). The merge gate enforces that only when the resolver names nobody, where its legacy path denies without the frontend marker. When the resolver names specialists, the gate checks only those, so spawning `code-audit-frontend` is the only coverage an ownerless file gets. Every named member writes its own clearance (see Marker key below). See [[Code Audit Team]] for the roster and dispatch mechanism.

## Marker-first: check before you audit

The hook requires a **clearance to exist** for each dispatched member's own content, not that you personally run the audit. The producer is always local: each dispatched `code-audit-*` agent writes `.gaia/local/audit/<digest>.<member>.ok` through the one shared clearance writer, stamps a `GAIA-Audit:` trailer, and pushes the stamp commit only when the stamp created one. On an already-pushed HEAD the stamp makes no commit at all. A clean member pass never posts the `GAIA-Audit` status itself; the orchestrator posts it last, after every dispatched member holds a marker and every finding is disposed (see [[#3. Marker handshake]]).

The audit is local for every author. A **fork** pull request is the one case it does not run for: a local audit would execute the fork branch's own audit machinery under the maintainer's full local credentials, so a cross-repository PR is refused rather than audited (see [[#First step: refuse a fork PR]]).

Start with the cheapest deterministic signal, the PR's check state:

```bash
gh pr checks <N> | grep GAIA-Audit   # what state the audit is in, if any
```

Read the whole output before narrowing to that row: the rows this grep discards answer a question the pre-dispatch verification asks anyway (see [[#Before the first dispatch: verify your own work]]), and discarding them means finding a red check after a round has been spent rather than before it. One note if this call is ever restructured to branch on its result: `gh pr checks` exits non-zero when a check fails, and piping it into `grep` swallows that status, so a version that tests the exit code has to capture the output first and test `$?` on the `gh` invocation itself, not on the tail of a pipeline.

| `gh pr checks` result            | Meaning                                  | Action                                                    |
| -------------------------------- | ---------------------------------------- | --------------------------------------------------------- |
| `GAIA-Audit … pass`              | a success is already posted for HEAD     | skip to **step 4 (merge)**                                |
| no `GAIA-Audit` row, or it fails | no audit has cleared this HEAD           | run the local agents (**step 1**), mandatory, not optional |

The exception is a PR whose entire diff is out of audit scope: the hook's out-of-scope bypass (see step 3) clears those with no marker at all, so no local run is needed.

## Four-step protocol

### 1. Spawn the dispatched Code Audit Team members

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
The same is true of the shell-lint run just after: its check surface is the whole tree, main's incoming content included, and that content goes unchecked until this merge lands.
<!-- gaia:maintainer-only:end -->

A catch-up merge that lands after dispatch instead rotates a member's digest under it, the member's marker is refused as a superseded review, and the round is forfeited. This removes rotations that land before any member starts; it does not reach a merge that lands mid-round or between re-spawn waves, which is what the clearance writer's staleness refusal covers, at the cost of a forfeited round when it fires.

- **Run the deterministic checks that cover the change.** The test suites for the paths touched, the linters for the languages involved, the [[Quality Gate]] when its skip logic says it applies, and any suite that consumes what changed. Green locally is the entry condition for dispatch, not a milestone passed once: re-run it after the **last** edit. Verifying, then editing prose or docs, then dispatching without re-running is the same defect as never running it, and it is the easier one to commit because the green output is still on screen.
<!-- gaia:maintainer-only:start -->
- **Run `bash .gaia/tests/shell-lint.sh`, plus every bats suite `git grep -l` finds referencing a file the change edits or deletes.** The bullet above selects suites by the path under test, which misses a suite that names a changed file from somewhere else, and shell-lint reads the whole tree, so no path selects it.
<!-- gaia:maintainer-only:end -->
- **Read the whole `gh pr checks <N>` output, not only the `GAIA-Audit` row.** CI is a deterministic check that has already run; it happens to have run remotely, and it covers exactly the complement the path-scoped selection above deliberately skips. That complement is where the one failure shape the author cannot see from their own chair lives: a change to one file reds a guard that lives in another, with nothing in the diff pointing at it. Fold any red into the same repair batch as everything else found pre-dispatch, and read the rows beside it too, a silent pass next to the red is often the same coupling not yet caught. Four things this reading has to carry, or it misfires. It reports on the **pushed head**, so with commits still local it describes older bytes; read it as what has landed, not as a verdict on the tree about to be audited. **Pending is not green**, and it is not a reason to hold the round: audits take minutes too, and serializing behind CI wall-clock can cost more than it saves, so dispatch and re-read before the marker handshake. **Red is not always a code change**: a flake, an infra hiccup, or a rotated secret wants a re-run, so read the failing job's log before folding a repair into the batch. And a branch that is unpushed, or an audit run before the PR is opened, has nothing to read; skip cleanly rather than treating the absence as an error.
- **Write the adversarial fixtures a reviewer would ask for.** One per shape the logic might mishandle, chosen by asking what the input space actually contains rather than what the implementation happens to read. For anything that parses a real format, that space is unbounded: prefer the format's own parser over a hand-rolled scrape, and treat "I will teach it the next shape when something finds one" as the decision to pay for those rounds.
- **Prove each new mechanism can fail, one at a time.** A guard whose assertions cannot be made to fire asserts nothing, and it reports green in exactly the case it exists to catch. Mutate the guard's own logic, not only the thing it watches: drop a term from its formula, weaken a comparison, confirm a test goes red, restore. Doctoring the subject proves the fixture; mutating the guard proves the assertion. Do this per outcome, not per file and not per mechanism: for each distinct outcome the new logic can produce, mutate it to each of the others and confirm some test goes red, which for a predicate means both return values plus the fall-through wherever all three are reachable. A change that adds two mechanisms therefore needs at least two mutants, because the suite going red when you loosen a threshold says nothing about the selection rule added beside it, and one mutant per mechanism still leaves that mechanism's other outcomes untouched. Three traps make a mutant survive that reads as covered. An assertion that **recomputes the production formula in its own body** is testing its own arithmetic, so extract the formula into the helper both the assertion and the fixture call. And a fixture set that is uniform in the dimension the new rule discriminates on cannot see it: if the rule prefers longer-in-hops over larger-in-minutes, every fixture where those coincide agrees under either rule. And the mutant that comes to mind first is the failure you were already imagining, which is the direction you have just defended against, so it proves that direction and no other; the direction you did not consider is both the untested one and the likelier one to break later, which is what makes a single mutant reliably wrong rather than occasionally wrong.
- **Commit before you mutate, or mutate a copy.** Restoring a mutant means putting the file back, and `git checkout -- <path>` restores from the index: it discards *every* uncommitted change to that file, not only the mutation. The moment you are about to mutate is also the moment you are most likely to be mid-edit, so what the restore takes is usually work that has nothing to do with the guard, and it goes without a diagnostic. Commit first, or run the mutation in a scratch `git worktree` and leave the tree under review untouched, which is what a dispatched member does with its own mutation work.
- **A comment making a falsifiable claim about this repository is a query, so run it.** "This pathspec covers every surface", "widening this glob turns X red", "no other caller does this": each has an answer, and getting it costs seconds against the price of a round. Run it, or delete the sentence. A **replacement** comment earns the same treatment as the one it replaces: a correction is new unverified text, and it is the likeliest place for the next wrong claim, because the scrutiny went to the thing being corrected. Where the claim is about what a guard does or does not catch, prefer writing it as a test rather than as prose. A test is a claim that re-checks itself; prose is a claim that decays.
- **Treat "the audit will tell me if this is wrong" as an instruction.** That thought is a precise description of a test that has not been written yet. Write it instead.

None of this substitutes for the gate. It changes what the gate is spent on: the cross-cutting and adversarial findings a member is uniquely positioned to make, rather than defects already visible from the author's own chair.

<!-- gaia:maintainer-only:start -->
When this PR newly ships files, run `/distribution-audit` and land its manifest-answer commit first, before this step. The manifest answer commits `.gaia/manifest.json` and any `.gaia/release-exclude` change; neither path is an audit-machinery digest input nor a reviewed member surface, so the commit rotates no member's content digest and invalidates no marker already earned. It does move HEAD, and the `GAIA-Audit` commit status is keyed to HEAD's sha, so a manifest commit that lands after the orchestrator's own status post strands that status on the old HEAD and forces an extra status re-post on the new one. Landing the distribution-audit answer first, before the first dispatch, is what keeps a later manifest commit from ever competing with the orchestrator's one status post for last word on HEAD: on an un-pushed or detached HEAD the handshake's own stamp commit still has to be pushed before that later status can land on the final PR head and stay put; on an already-pushed attached HEAD there is no stamp commit to push, and the orchestrator's status posts directly on the current head.
<!-- gaia:maintainer-only:end -->

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
    MANDATORY SECOND ACTION, still before any review: read your own agent definition at `<RESOLVED_ROOT>/.claude/agents/<member-name>.md` and follow that copy for the rest of this round, in place of the definition you were dispatched with. Where the two differ, the copy under the working root wins.
    Only on an exact match, review all changes in <RESOLVED_ROOT>'s current branch compared to main, scoping every git command to `git -C <RESOLVED_ROOT>`. Identify security vulnerabilities, performance issues, code smells, anti-patterns, and refactoring opportunities.
    How your run ends: a reply with no tool call ends it, and the orchestrator reads whatever you returned as your finished result. Do not end on a summary that announces a next step, an offer to continue, a list of questions none of which blocks the work, or a progress report because a milestone is done; take the next step instead. Stop only when the task is complete, or when something you cannot resolve blocks it, and then say which."
  )
  ```

  **The re-read of the member's own definition is a standing part of the prompt, not an instruction an orchestrator adds when it remembers.** The session resolves agent definitions from the main checkout rather than from the working root under review, so a member dispatched into a worktree whose branch edits that member's own definition runs the pre-branch prompt. That is load-bearing rather than cosmetic: a prompt predating a handshake never learned to satisfy it, the clearance writer refuses the member's earned write, and if every dispatched member is in that state the AND-aggregator holds `GAIA-Audit` shut with nothing left that can clear it, since each re-dispatch loads the same stale prompt. A branch that edits every agent definition and must be audited by those same members is exactly the shape that reaches it. The re-read costs one file read on every round and removes the class from the orchestrator's memory.

  Two things do **not** substitute for it. Working in the main checkout sidesteps the mismatch, because there the registry and the tree under review are the same tree, but that is a property of how a given branch chose to isolate rather than something the dispatch can rely on. And the writer's own refusal names this cause at the point of failure, which makes an already-stalled round self-clearing; naming a cause after the stall is a weaker instrument than not stalling.

- **No names** → spawn `code-audit-frontend`, fail-closed: never treat an empty or unanswerable result as "nothing owed". An in-scope file no member owns owes `code-audit-frontend` as well, even when the resolver names other members, and there the merge gate does not check for it (see [[#Who audits: the dispatched member set]]).

  **A result assumes the checkout you ran it in is still on the branch under review, and a clearance check must not assume it.** The resolver answers about the diff the acting checkout currently holds, so a checkout sitting on `main` has no diff and returns empty although nothing was audited. That is reachable without anyone changing branches deliberately, a peer session's cleanup arm can move the main checkout's HEAD out from under a row mid-audit ([[#Cleanup under worktree isolation]]). **Key a clearance check on the marker body's `tree` field matching the row's own tree, never on the spawn set.**

Skip a spawn for a member already cleared: its current-digest marker exists, or (for the default member) one of the bypass signals in the marker-handshake table already applies to this PR. The spawn set names who *can* be required, not who is still outstanding.

On a clean pass each member writes its own marker and stamps the `GAIA-Audit:` trailer (pushing the stamp commit only when the stamp created one); it does not call `post-audit-status.sh` itself (see [[#Posting the status last]]). The merge deny-hook requires **every** dispatched member's marker, so one member withholding holds the gate shut for all. If a member declines to write its marker, its report names what remains unaddressed; resolve those, commit, push (HEAD moves), then re-spawn the pending members on the new HEAD. A member that cleared a previous round must be re-spawned too whenever its own owned-plus-machinery content changed since: its marker is keyed to its own content digest, and a commit that touches a path it owns, or any gate-machinery path, rotates that digest. A commit that touches nothing a given member owns and no machinery leaves that member's digest, and its marker, valid, no re-spawn needed. Never hand-write a marker to bypass the gate.

**Re-read the full `gh pr checks <N>` output before every re-spawn, on the same terms as the first dispatch.** Between rounds is where this pays most: the repair commit just pushed can red something the round's own local checks never selected, and the round about to be spawned is already being bought, so a red folded in now rides a re-dispatch that is paid for either way, while the same red found after the round buys a whole extra one. The pushed-head, pending-is-not-green, red-is-not-always-a-code-change, and no-PR-yet caveats above apply unchanged here; the sha caveat binds harder between rounds, because a row read moments after the repair push can still be describing the previous head's run.

#### Parallel dispatch

Markers are keyed to each member's own content digest, so members are order-independent (see [[#Marker key]]). **Dispatch every member in parallel, in any order.** A self-heal edits the working tree and stops there, it makes no commit and no push; the orchestrator commits once after every dispatched member has returned, so the contended resource is the git index and the remote, never the files themselves. Per-member content-digest keying means an owned-file change rotates only that member's digest: there is no working-tree race between members and no wave to sequence.

The **trailer stamp**, landed by whichever dispatched member clears last, is content-preserving: an empty commit on an un-pushed or detached HEAD, which advances HEAD while leaving every blob byte-identical, or no commit at all on an already-pushed attached HEAD. Either way it rotates no member's digest, including its siblings'. A **self-heal is a real content edit**, ordinarily confined to files `code-audit-frontend` itself owns, so under digest keying it rotates only its own digest; a self-heal that happens to touch a gate-machinery path rotates *every* member's digest, correctly invalidating a sibling's in-flight marker, because a machinery change is exactly the case the machinery guard exists to force a re-review on.

#### The repair boundary

A member's self-heal is confined by instruction alone. `.claude/hooks/lib/audit-selfheal-paths.sh` holds the one sourced refusal set naming the paths no member may edit (the instruction and convention surfaces, the test surface, the rest of `.gaia/**`, `.github/**`, and the root package, build, and lint config), and each member's definition points at it. No deterministic gate enforces it at push time: a dispatched member is instructed to stay inside the boundary, and its working-tree edits reach the branch only through the orchestrator's commit (see [[#Parallel dispatch]]). **The orchestrator itself is not bound by the gate**: it is trusted rather than bounded (see Cross-remit findings below), because this same protocol's own execution routinely edits `.gaia/**`, `test/**`, and `.github/workflows/**`. The fix round's fixer inherits that trust rather than a member's boundary, and its edits reach the branch only through the main thread's verified commit ([[#The fix round: fixer, verifier, gate]]).

#### No-op detection and retry for each dispatched member

A dispatched member can silently no-op: zero tool uses, a return that is just a harness-reminder-echo or output-style fragment instead of a real review. Nothing about the marker gate catches this on its own, fail-closed means no marker and no merge, but with no diagnosis of *why* the gate is stuck, just a stuck gate a human has to notice and investigate by hand. This mirrors, one layer up, the same deterministic classifier `code-audit-frontend` already runs on its own internal specialist and refuter fan-outs (`.claude/agents/code-audit-frontend.md`, "No-op detection and retry for each refuter").

**Classify from the artifacts, and wait for them rather than for the dispatch to return.** The `Agent` call returns before the member has done anything (see the dispatch section above), so classifying at that moment hands the guard an empty hand: it reads a no-op, and the orchestrator spends its one hardened re-dispatch on a member that is still running correctly. Poll the audit directory for the member's marker or its findings sidecar, then classify. A dispatched wave is an open round, not a stopping point: while any member's artifact is still absent, keep polling rather than ending the turn on a status note. The stops this page wants are the ones it names: a surfaced double no-op, a round disposition under "When rounds stop" below, and a checkpoint denial from the bound hook ([[#The branch checkpoint]]). A completion notification may arrive first and is a fine prompt to look, but the artifact is the exit condition: `.claude/rules/subagent-dispatch.md` forbids blocking on a signal that may never arrive, and this page states one procedure with it, not a second one.

```bash
bash .gaia/scripts/audit-noop-detect.sh --shape audit-team-member \
  --marker <expected-marker-path> \
  --findings-root <RESOLVED_ROOT> --findings-since <wave-stamp>
```

`--path <tempfile>` is accepted alongside these and stays useful when a member's text *is* in hand (the completion notification carries it): a report-shaped return classifies real on its own, independent of the marker and the findings sidecar. It is not required, and fabricating an empty file to satisfy it classifies no-op.

`<expected-marker-path>` is `.gaia/local/audit/<frontend-digest>.ok` for `code-audit-frontend`, `.gaia/local/audit/<digest>.<member>.ok` for a specialized member, the same marker key each member's own gate handshake writes (see Signals below). The marker is predictable because its key is the member's content digest, which the orchestrator holds.

**The findings sidecar is not predictable, so do not predict it.** `--findings-root` names the audited working root and the classifier finds that member's newest sidecar under it; `--findings-since` names the wave stamp below, and the resolved sidecar must be newer than it. Pass the pair for every member, `code-audit-frontend` included, whenever the branch resolves, and omit both otherwise (an unresolved base or branch writes no sidecar at all). The older `--findings <path>` form still works for a caller that genuinely knows the path; it is mutually exclusive with the pair. Exit 0 = real (stdout `real`, or `refused`), exit 1 = no-op. A dispatch is real when it holds a writer-produced earned marker (plus, when the pair is passed, a fresh findings sidecar bound to that member), or when the captured return is report-shaped: a backticked `` `path:line` `` finding location, or, for `code-audit-frontend`'s terse LOCAL return, the literal `Remaining in-scope:` preamble. A report-shaped return classifies real on its own whether or not the pair was passed. A self-healed pass or a `DIRTY=` withhold writes a sidecar but no marker and no refusal, so its return alone classifies real. Anything short of that, most often a bare harness-reminder / available-agent-types echo, is a no-op.

**A refusal is proof of life, never a no-op.** A member that reviewed the content fully and withheld its clearance writes `<digest>[.<member>].refused` and no `.ok`, so the marker path above names a file that never appears for that run. The classifier derives the refusal sibling from `--marker` and checks it **first**, before the earned family, matching the merge gate's own refusal-first precedence; a writer-shaped refusal for the same member and digest classifies `refused` at exit 0. Nothing about that dispatch is retried: re-dispatching a member that refused with cause returns the identical result, spends the single hardened re-dispatch below on a member that was never broken, and reports "no-op'd twice" for what is actually "refused twice, with cause". The lost-report gate does not apply to the refusal arm either, because a refusal carries its own report forward through the member's findings sidecar and the carry-forward ledger its refusal write produces (see [[#Signals]]). Read those two artifacts to learn what it refused on.

**The findings sidecar, not the returned text, is each member's report of record.** Read it to learn what a member found; the return is a convenience copy, and it is optional classifier input: a report-shaped return classifies real on its own. It reads as a report because it carries one: each entry names the finding's `path` and `line`, the `failure_mode` (input, state, wrong outcome), the `verified_by` evidence that establishes it, and the `suggested_fix`, alongside the `finding_class` / `severity` / `area_tags` the recurrence tally counts. Every member writes it through one shared writer (`.gaia/scripts/audit-write-findings.sh`), which rejects a write whose entries cannot name those fields, so an entry that could not brief a repair never reaches disk in the first place. The detail stays local: `post-findings-block.sh` projects each entry down to the three tally keys when it renders the PR comment. Requiring the sidecar alongside the marker is what makes a lost report detectable: a member that completed, wrote a valid earned marker, and whose report never reached the orchestrator is otherwise indistinguishable from a clean pass, because the marker alone would classify the dispatch real and suppress the retry, leaving a green gate with zero visible findings and any Suggestions the clean-pass contract obliges the operator to resolve silently dropped. A present marker with an absent sidecar therefore classifies no-op and earns the one retry below, unless the captured return carries the report (a backticked `` `path:line` `` or the terse preamble), in which case the report did reach the orchestrator. The check binds to the member the marker names, not merely to the file's shape, so one member's sidecar can never vouch for another's lost report across a multi-member round.

**Stamp each dispatch wave** before it fires, and pass that stamp as `--findings-since`:

```bash
WAVE_STAMP="$(mktemp)"    # immediately before the wave fires, and re-stamped before any retry
```

Put it in the system temporary directory, not under `.gaia/local/audit/`: a linked worktree symlinks that directory to main's, so a stamp there would be shared by every tree auditing at once and one wave would reset another's freshness window.

The stamp is what makes a resolved sidecar a *fresh-write* signal rather than a leftover. Every member spec declares the sidecar write best-effort, so a round whose own write failed leaves the previous round's sidecar as the newest one on disk, and without the stamp the classifier would read it as proof this round's report landed.

Re-stamp before the single hardened re-dispatch below, for the same reason the pre-clear it replaces had to be re-run: the no-op's own round is exactly where a leftover from the round before it sits closest.

**A stamp rather than a pre-clear, because the sidecar's key moves and its history is worth keeping.** The sidecar keys on the incremental audit key, base sha plus branch. The branch half is fixed, but the base half is the shared pull-request-wide base, and that base **advances roughly one stamp per cleared round that stamps a trailer commit** (a round that clears on an already-pushed attached HEAD makes no commit at all and does not advance it), resets to `main_ref` on a `machinery-reset` (see the resolver-reason list below), and moves again on a rebase. So there is no single expected path to clear: a caller that computes one gets it right for the first round and reads an absent file from the second round on, which is the lost-report shape, so a healthy round classifies no-op and burns the one hardened re-dispatch. Clearing the whole *set* would work but is worse: every earlier round's sidecar is that round's durable report of record, and the merge-time findings block reads all of them across every base (`.gaia/scripts/post-findings-block.sh`). The stamp gets the freshness guarantee without deleting the record.

Resolution plus a stamp narrows the residual stale-file risk to two dispatches of the same member sharing one stamp, and re-stamping before the retry is what removes that last case.

On a no-op, re-dispatch that member **exactly one** time with the hardened retry prefix (`.claude/agents/code-audit-frontend.md`, "No-op detection and retry for each refuter"), substituting the concrete target with the member's original changed-file list. A second consecutive no-op does not re-dispatch a third time: stop and surface to the operator which member no-op'd twice, rather than looping or silently proceeding to a merge attempt.

**This ending departs from the general contract deliberately.** [[Code Review Audit Agent]] owns the terminal action for every no-op guard and states it as inline fallback: the caller does the unit's work itself and applies the result as if the subagent had returned it. This gate does not, because a member's marker is that member's own attestation. An orchestrator that audited the diff itself inline would be writing a clearance nobody earned, which is precisely the substitution the marker gate exists to refuse. Stopping costs nothing here that it would cost elsewhere: the gate stays fail-closed either way, no marker still means no merge, and a surfaced double no-op tells the operator why the gate is stuck instead of leaving them to notice an odd reply on their own.

<!-- gaia:maintainer-only:start -->
GAIA maintainers: the maintainer-only health audit departs as well, escalating a leaf that no-ops twice with reason `leaf-no-op` instead of doing its work inline; `.gaia/cli/health/runbook.md` ("Leaf completion check") states that ending and its reason.
<!-- gaia:maintainer-only:end -->

### 2. Fix all issues

The round's orchestrator decides what happens to every finding, and a fresh fixer sub-agent makes the repairs ([[#The fix round: fixer, verifier, gate]]). The orchestrator is the `audit-loop-unit` agent when the loop runs through a unit ([[#The audit loop unit]]), and the main thread only in the nesting-unavailable fallback, where the same procedure runs inline. The round's finding set comes from the members' findings sidecars, read deterministically with `bash .gaia/scripts/audit-loop-eval.sh findings --root <RESOLVED_ROOT> --round <r>` rather than summarized by the main thread: the sidecars hold every finding of every pass, clean or not. The re-run carry-forward ledger (`.gaia/local/audit/<AUDIT_KEY>.rerun.json`) still exists for the members, whose re-audit reads it as the prior-round briefing; it is not the fix round's briefing, because it holds only a refusing member's `remaining[]`.

- **Decide every finding in `dispositions-<r>.json`**, written by the round's orchestrator to the run folder before the baseline: each finding of the round marked `fix`, `accept-residual`, `waive-out-of-scope` or `file`, with a reason. The file's shape lives in `.gaia/scripts/audit-fix-verify.sh`'s header. An in-scope finding defaults to `fix`: fix every Critical Issue, every Important Issue, and every Suggestion the audit identifies.
- If a Suggestion involves an architectural tradeoff, breaking change, or conflicting convention, it is escalated with documented rationale rather than marked `fix`; the operator must resolve the escalation before the marker is written.
- A finding outside the reporting member's remit is disposed by [[#Cross-remit findings]]. A non-fix disposition carries forward by identity key (member, finding class, path, line) to later rounds, and the finding leaves the branch's convergence count `A(r)` ([[#The branch checkpoint]]).
- **During the loop the main thread never hand-edits a file a finding names.** Nor does the unit. The fixer carries every repair; the Quality Gate's autofix is the one exception, and the fix round records which paths it touched.
- The round's orchestrator stages, commits, and pushes the verified round; HEAD must move so the next audit runs against the fixed tree.
- **Land the whole round's fixes in one commit**, never one commit per finding. Each commit rotates the reporting member's content digest and buys a re-dispatch to re-earn its marker, so a round repaired finding-by-finding pays for as many re-audits as the round had findings and clears no more than the single batched commit does. Brief the fixer on everything the round marked `fix`, then commit and push once.
- **Sweep for comment and prose the round falsified, before the last dispatch, and scope the sweep by the claim rather than by the diff.** The fixer's prompt carries the sweep, so its corrections ride the round's one commit. A re-dispatch this round is already being paid, so a correction that rides it adds no marginal audit cost, which is the first arm of the digest economics below. Doing the sweep here also removes most of the need to decide the question after a member has already cleared, which is the expensive place to decide it. For every behaviour the round changed, grep the whole tree for the sentence asserting the old behaviour and read every hit. A citation list assembled by opening the files already suspected is the shape that fails, and it fails while reading as thorough: re-verifying such a list confirms the entries it holds and says nothing about the ones it never had. The sites that go stale sit in files the diff never opened, and no deterministic check here reads a prose claim about another file's behaviour, so the grep is the only instrument that finds them.
- **The sweep has converged when a round reports nothing this change authored.** Not when the gate is green, which it can be from the first round, and not when a round reports nothing at all. A round whose findings are all pre-existing is terminal; a round that falsifies a sentence this branch wrote is not, and the correction that repaired the previous round's false claim is itself a sentence this branch wrote. What to do with each kind of finding is [[#When rounds stop: pre-commit a disposition for every branch]] below; this is only the test for whether the sweep is finished.
- Re-spawn the audit members on the new HEAD until a round reports clean, or until the bound hook ends the unit's window or denies a dispatch at the branch checkpoint ([[#The branch checkpoint]]).

#### The audit loop unit

When subagent nesting is available (Claude Code 2.1.287 or later), the loop runs through the `audit-loop-unit` agent (`.claude/agents/audit-loop-unit.md`): an Opus orchestrator that runs a window of up to K rounds off the main thread, with the members and the Sonnet fixer one level below it, and returns one thin `unit-<u>.json`. `GAIA_CTX_UNIT_ROUNDS` in `.gaia/scripts/context-checkpoint-lib.sh` owns K. The unit follows [[#The fix round: fixer, verifier, gate]] for every round, so that section stays the single round procedure. While a unit is available the main thread reads this section, [[#The branch checkpoint]], [[#Posting the status last]] and the CHANGELOG gate, and does not read the round procedure.

**The main thread's loop**, one unit at a time:

1. Run `bash .gaia/scripts/audit-loop-eval.sh next-unit --root <RESOLVED_ROOT>`. It prints `<u> <s>`: the unit number and the round the unit opens. Copy both into the brief; `<s>` is also what a veto records as `effective_from_round`.
2. Pre-clear the unit's artifact: `rm -f <RUN_FOLDER>/unit-<u>.json`.
3. Dispatch the unit with the brief below. The bound hook gates this dispatch ([[#The branch checkpoint]]). K is never in the brief.
4. Wait with one blocking Monitor until-loop on `<RUN_FOLDER>/unit-<u>.json`, not turn by turn. The file does not exist while the unit runs, so its appearance marks the unit's return; the `Agent` call returns before the unit has done anything, so classify only once the file exists, on the same terms as [[#No-op detection and retry for each dispatched member]].
5. Classify the file with `bash .gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <RUN_FOLDER>/unit-<u>.json --report-key rounds --min-count 1`. A unit that opened no round still writes one `rounds[]` element, so a real unit always passes. On a no-op, recompute `next-unit`, pre-clear, and re-dispatch once; a second consecutive no-op means running the nesting-unavailable fallback below.
6. Read the file and branch on its `stop_reason`.

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

Write the `Working root:` value as the bare absolute path with nothing after it: a trailing character can stop the hook's resolver from reading the path, and it then audits the session's working directory instead.

| `stop_reason` | The main thread |
| --- | --- |
| `clean` | Runs `bash .gaia/scripts/audit-dispositions-check.sh check-all --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER>` once more as a last guard (read-only: with no `--snapshot-dir` it re-grades each round from the branch's frozen snapshots, and from live findings only for a round with none, and it writes nothing), then the CHANGELOG gate, the `GAIA-Audit` status ([[#Posting the status last]]), and the merge. |
| `window-end` | Starts the next unit at step 1; the bound hook decides whether it is admitted. |
| `checkpoint-deny` | Asks the pinned question ([[#The branch checkpoint]]). |
| `dispositions-check-failed`, `needs-human`, `failure` | Asks the human what to do, naming `stop_detail`; an unattended run stops and reports. |
| `nesting-unavailable` | Runs the fallback below for the rest of the session. |

**Deny classes.** `.claude/hooks/audit-loop-bound.sh`'s header owns the deny text. The caller sees it as `PreToolUse:Agent hook error: BLOCKED: ...`, so the class is a substring after that prefix, never the start of the string: `BLOCKED: audit checkpoint` maps to `checkpoint-deny`, `BLOCKED: audit window` to `window-end`, `BLOCKED: audit dispositions` to `dispositions-check-failed`, and any other `BLOCKED:` to `failure`. A nested `Agent` call that errors with no `BLOCKED:` is `nesting-unavailable` before any round opened and `failure` after one did.

**What counts as inside the unit.** A member dispatch is inside the unit's window only when its payload carries an `agent_id` and its `agent_type` is `audit-loop-unit`. Any other member dispatch, the main thread's included, is judged inline as a one-round unit with the unit-level checks and appends no window.

**The waiver table and the veto.** After every unit, build the table from the dispositions files, never from the informational `waiver_table` in `unit-<u>.json`: `bash .gaia/scripts/audit-dispositions-check.sh waiver-table --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER> --rounds <a>-<b>`. It has one row per non-fix disposition (key, member, severity, security, disposition, reason). Show it to the human when the run is interactive. To veto a row, write its key into `<RUN_FOLDER>/vetoes.json` with Bash at the main checkout's absolute path, and read it back; `.gaia/scripts/audit-fix-verify.sh`'s header owns the file's shape. Each veto's `effective_from_round` is the `<s>` that `next-unit` prints at that moment, so a veto binds the next unit's rounds and never re-grades the round that held the waiver. A vetoed key is disposed `fix` from then on, and its commit rotates the owning member's digest, which is how a veto invalidates that member's marker with no change to marker semantics. A veto can only demand more `fix`, never less.

**PR-body sections.** The unit writes `## Accepted residuals (recorded, not fixed)`, `## Out-of-scope machinery findings (recorded, not filed)` and `## Waived below triage threshold (not filed)` from its dispositions through `bash .gaia/scripts/audit-dispositions-check.sh pr-sections`, and files every `file` disposition through the `file-tech-debt` skill. The main thread rewrites those sections after a veto, from the same subcommand.

**Recovery.** A unit that returns with no `unit-<u>.json` stops the main thread for the human; it never falls back inline on its own. [[#The fix round: fixer, verifier, gate]] states what the next unit checks before it opens a round.

**The unit never merges.** It runs no `gh pr merge`, posts no `GAIA-Audit` status, writes no marker, edits no `CHANGELOG.md`, and never writes the loop state or `vetoes.json`. The main thread alone merges.

**Nesting-unavailable fallback.** When the unit's first nested `Agent` call fails with no `BLOCKED:` prefix, or the harness predates nesting, the main thread runs [[#The fix round: fixer, verifier, gate]] itself for the rest of the session, dispatching members directly. The bound hook then judges each member dispatch as a one-round unit. An answered checkpoint is spent once a later round is recorded, so in the fallback one grant admits the next round, not every dispatch up to the cap. In that fallback the main thread is the round's orchestrator, and nothing else about the procedure changes.

#### The fix round: fixer, verifier, gate

The procedure each round runs, inside the unit (or on the main thread in the nesting-unavailable fallback), in this order. The round's orchestrator decides, dispatches, verifies, gates, and commits; one fresh fixer sub-agent per round repairs; a deterministic script checks the fixer's work against a baseline recorded before it ran, so nothing rests on the fixer's own account of what it did.

The round's files live in the run folder `.claude/doctrine/execution.md` names for this branch, written `<RUN_FOLDER>` below: the main checkout's `.gaia/local/runs/<branch>/`, at its absolute path. Per round `r` and attempt `k` it holds `dispositions-<r>.json` (the round's orchestrator), `baseline-<r>.json`, `verifier-bin-<r>/` and `verifier-<r>-<k>.json` (the verifier script), `fixer-<r>-audit.json` (the fixer, the round's one dispatch artifact), and `gate-<r>-<k>.log` and `gate-<r>-<k>.paths` (the round's orchestrator). Beside the per-round files sit `unit-<u>.json` (the unit) and `vetoes.json` (the main thread), owned by [[#The audit loop unit]]. `.gaia/scripts/audit-fix-verify.sh`'s header owns the four JSON shapes. In a linked worktree, write each run-folder file with Bash at the main checkout's absolute path and read it back, never with Edit or Write.

**Round index.** Before writing any run-folder file, read `r` from the branch history:

```bash
bash .gaia/scripts/audit-loop-eval.sh current-round --root <RESOLVED_ROOT>
```

The bound hook records a round when its wave is dispatched, so after a wave this prints that wave's index. Never count rounds by hand: a resumed session, or a round another session dispatched on the branch, puts a hand count off by one, and every file below is named by it.

**Dispositions check.** After writing `dispositions-<r>.json`, and on a zero-fix round too, run `bash .gaia/scripts/audit-dispositions-check.sh check --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER> --round <r>` with no `--snapshot-dir` (only the bound hook writes snapshots; the check reads any snapshot the branch already has). A non-zero exit means no commit for the round: the unit stops `dispositions-check-failed`, and in the fallback the round stops and the human is asked. The check reads severity and the `security` flag from the members' findings sidecars, never from the dispositions entry, and refuses a non-fix disposition of a Critical or security-class finding, an empty reason, a vetoed key not marked `fix`, a waiver whose `basis` is missing or does not match the finding, and any non-empty `enforcement_paths_allowed`; its header owns the list. The bound hook re-runs it at the next dispatch.

**Zero `fix` entries.** When the dispositions file marks no entry `fix` (every finding disposed non-fix, or the closing round after an accept), the round has no baseline, no fixer, no verifier, no gate, and no commit. Publish the record (below), then follow [[#When rounds stop: pre-commit a disposition for every branch]], or re-dispatch where that section says to.

**Baseline.** After every dispatched member has returned, and before any fixer dispatch:

```bash
bash .gaia/scripts/audit-fix-verify.sh baseline --root <RESOLVED_ROOT> --round <r> --out <RUN_FOLDER>/baseline-<r>.json
shasum -a 256 <RUN_FOLDER>/dispositions-<r>.json <RUN_FOLDER>/baseline-<r>.json
```

It refuses (exit 3) when the index differs from HEAD. It also copies the verifier and the libraries it sources into `<RUN_FOLDER>/verifier-bin-<r>/` and records their digest in the baseline, so the verifier that judges the fixer is a copy outside the tree the fixer edits. Run `check`, `round-check` and `drift` below from that copy by its run-folder path, never from `.gaia/scripts/`; each refuses when the copy no longer hashes to the digest the baseline recorded. A member's self-heal edit sits in the baseline, so the verifier judges only the fixer's delta from it and the round's one commit carries both. The baseline also closes the round's evidence: a findings sidecar written after it is never read as that round's finding set. Record both hashes in STATE.md (`sha256sum` gives the same digest where `shasum` is absent); the verifier takes them as `--dispositions-sha` and `--baseline-sha`, so a fixer that rewrites either file fails verification instead of widening its own bounds.

**Fixer dispatch.** Exactly one fresh `general-purpose` sub-agent per round, on `model: "sonnet"` (the scoped-implementation row of [[Workflow Doctrine]]'s model table: the dispositions file carries the judgment and the verifier stands behind it), dispatched with the checkout path it edits. Pre-clear its artifact first, `rm -f <RUN_FOLDER>/fixer-<r>-audit.json`, and capture the expected tree as for a member wave:

```text
Agent(
  subagent_type: "general-purpose",
  model: "sonnet",
  prompt: "Working root: <RESOLVED_ROOT>, the absolute path of the checkout you edit; use absolute paths under it for every file. Expected HEAD tree: <EXPECTED_TREE>, captured immediately before this dispatch.
  MANDATORY FIRST ACTION, before any edit: run `git -C <RESOLVED_ROOT> rev-parse HEAD^{tree}` and compare it to <EXPECTED_TREE>. If that command errors (missing path, git unavailable) OR the value does not match exactly, STOP, edit nothing, and return only the mismatch or error as your entire output.
  Your briefing is the JSON file <RUN_FOLDER>/dispositions-<r>.json. Repair every entry whose disposition is fix, cross-remit repairs included, and no other entry. Where you will not repair a fix entry, return it as disputed or cannot_fix with a reason rather than widening the repair. For every behaviour a repair changes, grep the whole tree for sentences asserting the old behaviour, read every hit, and correct the ones the repair falsified.
  Write your result as JSON to <RUN_FOLDER>/fixer-<r>-audit.json with Bash at that absolute path, never with Edit or Write, then read it back. Its shape is the fixer-<r>-audit.json shape in <RESOLVED_ROOT>/.gaia/scripts/audit-fix-verify.sh's header: "attempt": 1, one results entry per fix entry, and every path you changed or reverted declared.
  Never: run git that changes state (add, commit, push, stash, checkout, switch, reset, restore, rm, mv, branch); write a marker, a ledger, a findings sidecar, or anything under .gaia/local/audit/ or .gaia/local/audit-loop/; post a status; file, edit, or label an issue; edit CHANGELOG.md or the PR body; edit a path in the verifier's ENFORCEMENT_PATHS list unless the dispositions file names it in enforcement_paths_allowed.
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

**Gate.** After a verifier pass, stage exactly the delta: the baseline's self-heal paths, the paths the fixer declared, and any path an earlier gate attempt's autofix changed.

```bash
{
  jq -r '(.dirty | keys[]), .untracked[]' <RUN_FOLDER>/baseline-<r>.json
  jq -r '.changed_paths[], .reverted_paths[]' <RUN_FOLDER>/fixer-<r>-audit.json
  cat <RUN_FOLDER>/gate-<r>-*.paths 2>/dev/null
} | sort -u | while IFS= read -r p; do git -C <RESOLVED_ROOT> add -A -- "$p"; done
```

Then run the per-round verification, at the placeholder line of the snapshot block below: the [[Quality Gate]] when its skip logic says it applies, saving each attempt's output to `gate-<r>-<k>.log`.
<!-- gaia:maintainer-only:start -->
In this repo the per-round verification also runs `bash .gaia/tests/shell-lint.sh` plus every bats suite `git grep -l` finds referencing a changed file, through `.gaia/scripts/bats5.sh` with stdin closed, its output saved to the same log.
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

**Commit, push, publish.** After a gate pass, run the staging block again so the passing attempt's autofix paths are staged, then make one commit carrying the self-heal, fixer, and autofix edits, and push; the round's orchestrator makes it. The [[Quality Gate]] page's stop-and-report step does not apply inside this loop: the branch checkpoint is where the human reviews, and the gate page carries the matching clause. Then the round's orchestrator rewrites the PR body's record (the unit calls `audit-loop-record.sh` itself, so no main-thread write is involved):

```bash
bash .gaia/scripts/audit-loop-eval.sh record-values --root <RESOLVED_ROOT> |
  bash .gaia/scripts/audit-loop-record.sh --pr <N> --values-json -
```

Nothing reads that section back. Publish it at every round end, not only after a push: a committed round, a clean or zero-fix round that makes no commit, the closing round, and any stop (a verifier, gate, or no-op stop, or a checkpoint). The history counts a round when it is dispatched, so a record written only after pushes undercounts. Then return to step 1 on the new HEAD.

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
NEXT: <the next step above, by name>
```

On resume, one state overrides the execution doctrine's generic rule to re-dispatch any dispatch whose artifact is missing: a round with `baseline-<r>.json` and no `fixer-<r>-audit.json`. Check the tree against the baseline first:

```bash
bash <RUN_FOLDER>/verifier-bin-<r>/audit-fix-verify.sh drift --root <RESOLVED_ROOT> --baseline <RUN_FOLDER>/baseline-<r>.json
```

Exit 0 means the tree equals the baseline, and re-dispatching the fixer is safe. Exit 1 (it prints `head-moved`, `index-changed`, or one `drift: <path>` line per path that differs) means a fixer edited and never wrote its result: do not re-dispatch the fixer. An interactive run asks the human, an unattended run stops and reports. A second fixer on top of those edits would hand the verifier a delta neither fixer declared.

**Unit recovery.** A next unit rebuilds its position from the branch state and the run folder, not from the dead unit's memory. Before opening a round it republishes the `## Audit rounds` record, checks for a dirty tree and for an unpushed commit, and runs the `drift` check above on any `baseline-<r>.json` that has no `fixer-<r>-audit.json`: exit 1 stops it `needs-human`. The main thread's own recovery is in [[#The audit loop unit]]: a missing `unit-<u>.json` stops for the human.

#### Applying the audit's own Suggestions: digest economics

Applying an in-scope Suggestion or an accepted finding is a content edit, so it rotates the reporting member's content digest, invalidates its marker, and forces a fresh re-dispatch of that member to re-earn the clearance. The cost decides whether to fold it into this PR. The two arms are:

- **The member's digest is already rotating in this PR**, you are already changing files it owns this round (the ordinary audit → fix → re-audit loop) or a gate-machinery path every member's digest folds in. The re-dispatch is already being paid, so **apply the Suggestion in the same PR**: the fix rides a re-review that happens anyway and adds no marginal audit cost.
- **The PR is already clean and the member is already marked**, with nothing else rotating its digest. This arm differs from the first in kind, not only in price: no round is currently reading this branch, so whatever the fold adds is content nothing has reviewed, on a branch whose whole review budget is already spent, and a defect in the repair costs a further round on top of the one the fold buys, plus whatever that defect does if it ships instead. **Apply it when the repair is comment-only or prose-only** and the branch still holds an anchor. Those two forms carry almost none of the unreviewed-repair risk, and the re-dispatch they buy is a delta review of the one edit plus the member's fixed dispatch overhead, not a 60-110k full round. **A repair that introduces new logic into an already-marked PR is weighed on the risk of shipping an unreviewed repair, not on the delta-review price alone**, which is the smaller term of the two. **Accept-and-note** is for that case, for an edit that resets the member's review back to full scope (touching the global-rules set or the member's own agent definition), for an unanchored member, and for a finding big enough to deserve its own change, not for a one-line comment or prose correction.

Accept-and-note is not free either, and pricing only the re-dispatch hides its cost: a deferred Suggestion leaves a known defect in the tree and moves the repair to a follow-up that has to rebuild the context this round already holds. Weigh both sides before deferring.

Both arms assume the Suggestion is correct. A Suggestion is a finding, not a specification: it can assert a mechanism the member inferred rather than verified, and a claim about third-party behavior is where that is likeliest and hardest to spot. Verify the claim against the library's own source or a runnable probe before applying it, most of all when the fix is prose that ships as guidance, where implementing it verbatim turns a reviewer's error into a documented one that reads as reviewed. The re-dispatch these economics already price in re-reviews the edit and usually catches it, but only after an extra round.

This is operator guidance about **in-scope Suggestions and accepted findings**, distinct from **in-flight-fix promotion** (the audit's own automatic same-run repair of a qualifying **out-of-scope** finding through the self-heal path; see [[Audit Disposition and Debt Fix]]). In-flight-fix promotion is the audit repairing out-of-scope debt itself as it reviews; this is the operator deciding whether an in-scope Suggestion is worth folding into an already-marked PR. They do not overlap.

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

- **Clean** → post the `GAIA-Audit` status (see [[#Posting the status last]]), then merge.
- **Only accepted residuals** → accept-and-note under the heading `## Accepted residuals (recorded, not fixed)` in the PR body, post the `GAIA-Audit` status, then merge. **Prose an earlier round wrote** goes through the checkpoint instead: a round carrying only new findings on prose the previous round wrote reports `enriching`, the bound hook stops the loop at [[#The branch checkpoint]], and accept is the route there. Repeat findings on the previous round's own repair are the signal that each pass is enriching the artifact rather than correcting it, and every widening of a prose list invites the next one.
- **A new, reproduced defect in the logic this change authored** → name the concrete outcome rather than deferring it, because "run another round" is not a disposition, it is the absence of one. Say what ships, what gets filed instead, and who decides. Where the round turns on a design decision an operator settled, retiring that decision is the operator's call, so the fallback is to report and recommend rather than to overturn it.

A `quiet` verdict from the evaluator (no fixable finding this branch authored remains) only proposes this section's disposition; this section's own judgment of what this change authored decides it. The verdict counts findings by where they sit in the branch diff, which is evidence about authorship, not the judgment the three branches above ask for.

The three dispositions are also bounded by the dispositions check: it refuses a round that leaves a branch-authored finding or a vetoed key with no disposition, disposes a vetoed key or a Critical or security-class finding anything but `fix` (an out-of-branch one may be filed), or makes a non-fix disposition without a reason or a valid `basis`, and `.gaia/scripts/audit-dispositions-check.sh`'s header owns the list.

**A round count is evidence, not a verdict.** What says a guard is the wrong instrument is the **direction** of its repairs, whether each one leaves the artifact smaller, and **where** the defects land: in the parser, the comparison, the payload, or the design. A fifth round in a part that has been stable since the third is a different finding from a fifth round in the same place, and the count alone cannot tell them apart.

#### The branch checkpoint

Machine-enforced by `.claude/hooks/audit-loop-bound.sh` on every dispatch of the `audit-loop-unit` agent and of a Code Audit Team member. A unit dispatch is gated against the main session's context; a member dispatch inside the unit's recorded window passes. A member dispatch on a HEAD tree this branch has already audited passes free: every member of one wave shares that tree, and so does the single hardened re-dispatch of a member that no-op'd ([[#No-op detection and retry for each dispatched member]]). A member dispatch on a tree not yet audited starts a new round. The hook first evaluates the previous round itself, from that round's findings sidecars, and stores the result in the branch history; it then decides whether to admit the dispatch, and records the new round when it does. The deny is not a merge blocker: it denies a dispatch, never `gh pr merge`, and clearance semantics are untouched.

The state is per branch, never per session. History, written only by that hook, and allowance, written only by the two grant hooks (`.claude/hooks/audit-loop-ask-grant.sh` for a selection, `.claude/hooks/audit-loop-grant.sh` for a typed line), live in one main-anchored file keyed by the normalized branch and linked to the PR, so clearing or compacting the context, a new session, a fork, and a sub-agent all leave both byte-identical. The hook denies loudly, and never allows, on corrupt state, missing jq or git, a detached HEAD, a new-tree dispatch from a checkout with uncommitted tracked or staged changes (commit the round first), or an exceeded internal deadline. Two files own the numbers: the round-count checkpoint, the grant size, the knobs, the verdict and rubric-signal formulas, the allowance fold, the hard round cap and the decision order live in `.gaia/scripts/audit-loop-eval.sh`'s header; the context line, the statusline bands, K and the reading's freshness limit live in `.gaia/scripts/context-checkpoint-lib.sh`. This page restates none of them.

**The context gate.** Before each unit dispatch the hook reads the main session's context reading, the file the statusline writes for that session under the main checkout's `.gaia/local/cache/shared/context/`, and asks only when the reading is at or above the effective line. The line is the lower of a token count and a share of the reading's own context window. A human may lower it for a machine in `.gaia/local/settings.json`; a raised or invalid value reads as the default, and Claude's writes to that file are denied. The hook freezes the line's configuration into the branch history at the first unit or round and afterwards applies only a lowering. A reading that is missing, stale, future-dated or unparseable falls back to the round-count checkpoint and never allows past it. The reading changes only when the statusline renders on a main-thread turn, so a unit's off-thread spend stays invisible to it until the unit returns: the rubric signals and the hard round cap are independent backstops. A denying rubric signal denies whatever the reading says, a dispatch that would open a round past the hard cap is denied whatever was granted, and at the cap no grant is offered.

**One grant admits one unit.** An allowed unit records a window, the rounds it may open. A grant answering the latest checkpoint admits exactly one unit of K rounds; the next unit dispatch evaluates every trigger afresh and is denied again while the reading stays over the line. The grant-size fold of the round-count checkpoint applies only on the round-count fallback.

Each evaluated round gets one verdict, built on `A(r)`, the round's count of findings this branch authored that no earlier round disposed non-fix:

- `continue`: the evidence shows the loop converging, so the round runs within the allowance.
- `quiet`: `A(r)` is zero; a stop heuristic that proposes the [[#When rounds stop: pre-commit a disposition for every branch]] disposition and decides nothing on its own.
- `stalled`: the branch-authored count has stopped falling across the latest rounds, so another round is unlikely to move it.
- `enriching`: the latest round found a new finding on lines the previous round's repair wrote, the sign that each pass is adding to the artifact rather than correcting it.
- `unknown`: a dispatched member left no readable findings sidecar for the round; missing evidence still counts as a round and is never read as `quiet`.

**An interactive run asks the human, in this session.** A checkpoint deny (`BLOCKED: audit checkpoint`, or a unit stopped `checkpoint-deny`) has already pinned the whole question in guarded state, with a fresh nonce. Print it with `bash .gaia/scripts/audit-loop-eval.sh pinned-question --root <RESOLVED_ROOT>` and ask it as one AskUserQuestion, with exactly that `tool_input` and nothing changed: Claude authors no word of it, and a changed word makes the recorder decline. Put the evidence beside it first, from the evaluator, which is read-only:

```bash
bash .gaia/scripts/audit-loop-eval.sh brief --root <RESOLVED_ROOT>
```

The evidence is the rounds run, `A(r)` per round, the verdict and its evidence, the remaining findings by severity, and the spend, labeled information only (or `unavailable`); spend never grants and never blocks. The question text and each grant option's description carry the main session's context reading from the moment the checkpoint was pinned (percent and tokens of the window, or `context unavailable` when the reading is missing or stale), because the statusline is hidden while a question shows and never visible over Remote Control, and the human reads the choices rather than the text above them. Exactly one option is recommended: it leads and its label ends in ` (Recommended)`; the rest keep the order below. A `context` checkpoint always recommends the new-session grant, with the in-session grant right after it as the opt-out. For any other trigger the evaluator's `recommended` value decides: `accept` leads with `Accept the remainder` when it is offered, `stop` leads with `Stop and file the remainder`, and a grant (or an accept that is not offered) chooses between the two grants by the context line, the in-session grant when the reading is below it and the new-session grant when the reading is at or above it or unavailable. At the cap `Accept the remainder` leads when offered, else `Stop and file the remainder`. The line is `gaia_ctx_line` in `.gaia/scripts/context-checkpoint-lib.sh`, computed with the same knobs the gate uses. The options, quoted as the evaluator builds them, each present only when it applies:

- `Continue audit in this session` and `Continue audit in a new session`, each recording a grant of K from `.gaia/scripts/context-checkpoint-lib.sh`; absent at the hard cap.
- `Accept the remainder`, only when the evaluator reports the branch accept-eligible: a rubric signal holds, no remaining finding is Critical or security-class, and the verdict is not `unknown`.
- `Type audit-accept instead`, only at the cap when accept is not eligible; it records nothing, and its description says the human may type `audit-accept` as the whole prompt, a deliberate override of the eligibility gate.
- `Stop and file the remainder`, always.

`.claude/hooks/audit-loop-ask-grant.sh` records a selection as the answer only when the question came from the main thread of an interactive session in a permission mode it measured, the call's `tool_input` equals the pinned question exactly, and the answer is exactly one pinned label. The selected label must equal a pinned label exactly, with or without the ` (Recommended)` suffix the pin carries on its leading option. Either grant label records a grant of K for that checkpoint, and `Accept the remainder` records an accept. `Stop and file the remainder` and `Type audit-accept instead` record nothing: file the remaining in-scope findings through the `file-tech-debt` skill, leave the PR open, and report. Any other answer records nothing and leaves the state byte-identical, and the hook says so and names the typed fallback. The typed lines stay as that fallback: `.claude/hooks/audit-loop-grant.sh` records a whole prompt that is exactly `audit-grant <n>` or `audit-accept`, in an interactive session, and reaches the checkpoint through this session's id when the session's working directory is on another branch. Claude never types, writes, or simulates the line, and never writes the branch state file.

`Continue audit in a new session` records the same grant as the in-session option and then asks the main thread to print one instruction line, then this continuation prompt in a fenced block for the human to paste into a fresh session, and to stop. The line is "Run `/clear`, then paste the prompt below." by default. When the next session needs something only a fresh launch provides (an environment variable, or an agent, hook or settings change that loads at session start, such as the branch having edited `.claude/agents/`, `.claude/hooks/` or `.claude/settings.json` since this session started), the line is instead "Kill this session with Ctrl+C, start a new one (`claude`, with any needed environment variable), then paste the prompt below." Either way the new session writes its own statusline reading under its own session id, and the grant is already in the branch state, so the next unit dispatch is admitted without asking again:

```text
Resume the PR merge workflow for PR #<N> on branch <branch>, working root <RESOLVED_ROOT>, run folder <RUN_FOLDER>. Read wiki/concepts/PR Merge Workflow.md, then follow its "The audit loop unit" section: run `bash .gaia/scripts/audit-loop-eval.sh next-unit --root <RESOLVED_ROOT>` and dispatch the next audit-loop-unit. A grant is already recorded for the latest checkpoint.
```

**An accept buys exactly one closing round**, flagged in the history, and the unit window it opens is that one round. No fixer is dispatched for it, so the round has no `fixer-<r>-audit.json`: the members re-audit the current tree to earn their markers, and the remaining entries are recorded under the heading `## Accepted residuals (recorded, not fixed)` in the PR body, in the entry format `/gaia-residue` already parses (the `file:line`, the one-line failure mode, and the wrapped `gaia-debt-key` form [[#Applying the audit's own Suggestions: digest economics]] states). A closing round never re-arms the loop: if it does not clear, the next new-tree dispatch is denied and the human decides again.

**An unattended run never asks and never grants.** A `/gaia-debt` drain that reaches a checkpoint pushes the round's fix, leaves the PR open, keeps the issue's `in-progress` claim, and reports the verdict, the evidence, a recommendation, and the next step. It prints the typed `audit-grant <n>` line from the brief's `grant_line` and no continuation prompt: a human types the printed line in an interactive session on that branch, then re-runs this workflow. The branch state and the PR body carry everything the next run needs. `/gaia-harden` is interactive and asks like any interactive run.

Three things the checkpoint does not do:

- **It does not license a merge.** Clearance is unchanged: `gh pr merge` stays denied until every dispatched member holds a marker for its own current digest, and a round's fixes rotate the digests they touch, so the merge hook denies with no help from this one. A stop at the checkpoint leaves a pushed branch and an open PR.
- **It does not stop a round that ends the work.** The dispositions above resolve first, at any round number: a clean round posts the `GAIA-Audit` status and merges, and a round carrying only accepted residuals is accept-and-note under the heading `## Accepted residuals (recorded, not fixed)` in the PR body, then the same post-and-merge. The checkpoint binds only where the disposition would be another round.
- **It does not judge the change.** A round count is evidence, not a verdict, so the direction of the repairs and where the defects land still decide whether this branch deserves more rounds or needs a different instrument. The checkpoint hands that question to the human with the evidence beside it.

The bound is on spend and on a loop that is not converging. Every round's fixes buy the next round, so left alone the loop has no stop of its own. The unit keeps the repair history off the main thread, so the context gate tracks what the main session has absorbed rather than how many rounds ran, and the rubric signals and the hard cap end a loop the evidence says is not converging whatever the context holds.

A fail-loud deny names its cause and its repair; for a corrupt state file that repair is a human moving the file aside from a terminal outside Claude Code. At a checkpoint the only recovery is a human answer, a selection of the pinned question or a typed line. A PR-body edit, an environment knob above the default, a question Claude composed, and a recorder Claude ran by hand each raise nothing: `.claude/hooks/block-audit-loop-write.sh` denies Claude's writes to the state, the context directory and `.gaia/local/settings.json`, and any Bash or Monitor command that executes either grant hook. Its path arm reads only commands that name those paths: a context reading minted from Bash by running the statusline or `gaia_ctx_write` names none of them, so the rubric signals and the hard round cap stay its backstops. It also denies a Bash heredoc or inline script whose text merely names those paths or a recorder's filename, so write such files with the Write or Edit tools.

The PR body's `## Audit rounds` section is the published record of the loop: total rounds, rounds per member, and human grants. The unit writes it at every round end through `audit-loop-record.sh` ([[#The fix round: fixer, verifier, gate]]), and the main thread writes it only in the nesting-unavailable fallback. Nothing reads it back to grant a round or set a count.

#### Cross-remit findings

A member can find a genuine defect in a file outside its own declared domain, a **cross-remit finding**. The member that found it applies no repair, whether or not the file's owner has already cleared it and whether or not the fix looks trivial; it reports the finding to the orchestrator instead. The orchestrator disposes of it one of two ways:

- **In scope for the PR** → the orchestrator marks it `fix` in the round's dispositions file and the fixer repairs it ([[#The fix round: fixer, verifier, gate]]). The round's commit rotates the owning member's digest, invalidating that member's marker, so the owner is re-dispatched and reviews the repair made to its own file.
- **Out of scope** → a non-security finding is recorded as **waived** (listed in the pull request body, not filed) when its path is either a gate-machinery path or a file this pull request already changes and the finding itself clears both disqualifiers; a finding satisfying neither term, or any security-class finding, is filed as a tech-debt issue exactly as it is today, through `/gaia-debt` and the `file-tech-debt` skill.

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

Every waived finding is listed in the pull request body under the heading `## Out-of-scope machinery findings (recorded, not filed)`, one entry per finding, each carrying its `file:line`, a one-line failure mode, and its dedup key in the wrapped `<!-- gaia-debt-key: … -->` form (`.claude/skills/file-tech-debt/SKILL.md`).

The changed-file set is the `ELIG_CHANGED` lines `.claude/agents/code-audit-frontend.md`'s scope-resolver command prints under `--eligibility` (`.gaia/scripts/audit-resolve-scope.sh`); it is never the member's TS/TSX-filtered review-scope set, which excludes every surface this rule exists for.

The gate-machinery set is whatever `audit_path_is_machinery` (`.claude/hooks/lib/audit-machinery.sh`) accepts.

### 3. Marker handshake

#### Marker key

Every clearance is written by the **one shared writer** (`.gaia/scripts/audit-write-clearance.sh`); no member hand-writes a marker file. Given the audited root, the writer derives the member's **content digest**, a sha256 over exactly the files that member owns plus the shared gate machinery (plus the in-scope-but-ownerless paths, for the default member; see [[Code Audit Team#Ownership classifier]]), through the digest engine (`.claude/hooks/lib/audit-digest.sh`), resolves HEAD's real tree and commit sha as plain data fields, then writes the body atomically. The body carries a version, `schema: 4`, the audited `member`, a `provenance` (`earned` or `refused` only, there is no carried family), the `digest` (the validity key), `tree` and `sha` (data only, never compared for validity), `audited_at`, and a `sidecar` flag. `sidecar` answers "does this member file a findings sidecar, its report of record": every member does, so it is always true. `schema` is informational, no reader validates it, so a marker written under the previous contract still validates unchanged. The gate's reader (`clearance_acceptable`) accepts a clearance only when it is **well-formed**: the body parses, its recorded `digest` matches the filename key, its `member` matches, and its `provenance` is `earned`; a file that exists but fails that check is neither cleared nor missing, the gate reports it as present but invalid and asks for a re-run. This is a well-formedness check, not an authenticity one, it raises the bar a hand-written marker has to clear; it does not by itself prove who wrote a given file. `jq` is required for every digest-keyed predicate; with `jq` absent every check returns false (fail-closed), it never degrades to a bare-existence match.

Provenance gets its own filename, not just a body field:

| Provenance | Default member | Specialized member `<m>` | Meaning |
| --- | --- | --- | --- |
| earned | `<digest>.ok` | `<digest>.<m>.ok` | the member audited this exact content and cleared it |
| refused | `<digest>.refused` | `<digest>.<m>.refused` | the member audited this exact content and withheld its clearance |

Every write lands unconditionally: it overwrites a stale body at the same path. There is no create-only guard and no carried family to dominate; provenance is earned or refused only.

Marker files are named for the member's own **content digest**, not HEAD's tree and not its commit sha. The digest engine enumerates every tracked file at HEAD (`git -C <root> ls-tree -z -r HEAD`, NUL-delimited so no path name can shift the hash input), the ownership classifier and machinery matcher select exactly the member's set (`owned(member) ∪ machinery`, plus in-scope-but-ownerless for the default member), and the selected `<mode> <blob-sha> <path>` records are sorted and sha256'd behind a fixed recipe-version sentinel. Content-addressing falls out of the blob sha, so byte-identical content yields an identical digest regardless of what else in the repo changed; mode catches an exec-bit flip, path catches a rename. A marker attests that a Code Audit Team member reviewed **the content its own digest covers**, never the whole tree.

The digest key is what makes the team's markers order-independent, and it is far narrower than the whole-tree key it replaced: an unrelated or out-of-glob change (a CHANGELOG line, a wiki edit) rotates **no** member's digest at all, so every existing marker keeps validating with zero re-dispatch. Whichever dispatched member clears last stamps the `GAIA-Audit:` trailer, and on a detached HEAD that stamp lands as an **empty commit**: it advances HEAD while leaving every blob byte-identical, so it rotates no member's digest either. On an already-pushed attached HEAD the stamp makes no commit at all, which rotates no digest for the same reason more directly. Each member writes its marker whenever it finishes; the members can run in parallel and the stamp changes nothing.

The key does not weaken the gate. A change to a file a member owns rotates only that member's digest, correctly forcing a re-audit of exactly the member whose content changed. A change to any gate-machinery file, anything whose bytes can change what a member reviews, who reviews it, where a clearance lands, or whether a clearance is believed, rotates **every** member's digest, since the machinery path set sits inside every member's input set by construction; this also closes the classifier-version skew hazard, since the classifier's own files are themselves machinery. See [[#Parallel dispatch]] for how this plays out when `code-audit-frontend` self-heals mid-dispatch.

Two artifacts under `.gaia/local/audit/` key differently from a member's own marker, because their readers resolve identity at a different point than a content digest: the re-run carry-forward ledger (`<audit-key>.rerun.json`, keyed to the incremental base commit plus branch, an in-scope prior-round briefing for the members that never gates a merge; see [[Code Review Audit Agent#Re-run carry-forward ledger]]), and the per-member findings sidecar (`<audit-key>.<member>.findings.json`, one per dispatched member, also keyed to the incremental base plus branch; see [[#Findings block]] below). The ledger and the findings sidecar share an audit key but feed different consumers: the ledger briefs a member's **re-audit** (what remains, what the last round already fixed), the findings sidecar feeds the **posted findings block**, one array of every dispatched member's findings regardless of whether the pass was clean. The re-run carry-forward ledger reaps itself: the shared clearance writer removes it once no dispatched member has open entries left. Nothing reaps a marker or a findings sidecar; see [[Local Working State]].

#### Skipping already-cleared members

There is no carry-forward clearance machinery: no anchor selection, no delta computation, no minting step, and no `.carried` marker family. A member not already cleared for its own current digest simply gets re-dispatched; the digest key itself is what shrinks how often that happens, since an out-of-glob change never rotates it and only an owned-file or machinery change does.

A **refusal** is a first-class artifact keyed the same way as an earned marker (`<digest>[.<member>].refused`), the only way a member records "I read this exact content and I withhold." The gate checks the refusal family before the earned family and treats a live refusal of the current digest as absolute: no earned marker for the same digest, however clean, ever overrides it.

A refusal also carries a **server-side** signal, because the local hook is not the only merge path. GitHub's auto-merge completes on the required `GAIA-Audit` commit status alone and never runs the hook that honors refusal precedence, so a refusal recorded after a `success` status already landed for this head, the orchestrator's earlier post from a prior round on the same digest, would otherwise leave that success standing and the pull request merging over a live refusal, with the artifact on disk and no diagnostic anywhere. On the local path the shared clearance writer therefore posts a `GAIA-Audit` `failure` for the same head as it records the refusal, through the same hook the clean path uses (`post-audit-status.sh`, handed the refusal artifact instead of an earned marker). The latest status for a context wins, so this retracts the stale success and a later genuine clean pass overwrites it in turn; a refusal can never strand a pull request it no longer applies to. The post belongs to the writer rather than to a member's instructions because the one moment a refusal is guaranteed to be recorded is the moment it is written. It is best-effort in both directions: a post that cannot happen (no `gh`, an un-pushed head) leaves the refusal on disk where the local gate still denies the merge, and a failure there never disturbs the refusal that already landed.
A refusal is retired by its **author**, never by the gate inferring supersession from timestamps. Resolving the finding is the ordinary path: the repair edits a file the member owns, which rotates that member's digest and leaves the refusal keyed to content nobody is merging. A second path exists because an Important finding also clears by operator acknowledgment with a stated reason, which moves no bytes and so leaves the digest identical. There the member re-audits and writes its earned marker with `--supersede-refusal "<reason>"`; the shared writer records the reversal in the marker body and removes that member's own refusal, publishing the earned marker first so a crash leaves both artifacts and the gate shut rather than neither. That flag only exempts the write from the writer's review-scope staleness comparison when the refusal it retires is actually on disk; the exact condition is stated in the staleness gate's own header comment in `.gaia/scripts/audit-write-clearance.sh`. A plain earned write never touches a refusal. That asymmetry is what keeps refusal-precedence from decaying into "newest marker wins" and preserves it as the control that stops someone re-running an auditor until it passes: a bare re-spawn against unchanged, still-unaddressed content refuses again.

#### Signals

The hook (`pr-merge-audit-check.sh`) accepts any one of three signals that prove the **default member's** audit ran clean against the content being merged, plus two bypasses (out-of-scope and `chore(deps)`) that waive only the default member's signal. On a bypass the hook posts the `GAIA-Audit` status itself (see [[#The bypass stamp]]). A specialized member's own marker is a separate, mandatory signal the hook additionally requires whenever the roster dispatches that member:

| Signal                                                                    | Source                       | How it gets there                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------------------------------------------------- | ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.gaia/local/audit/<frontend-digest>.ok` (earned)                        | Local audit agent            | Agent writes the `.ok` file on a clean pass, keyed to its own current content digest (see Marker key above).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `GAIA-Audit:` commit-message trailer on HEAD                              | Local audit agent            | `audit-stamp-trailer.sh` amends the trailer onto an un-pushed HEAD, or writes an empty commit with the trailer on a detached HEAD; the member that lands the empty-commit form pushes that commit before posting the status in the row below. On an already-pushed attached HEAD the helper writes no trailer commit at all: the status in the row below carries the signal instead.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `GAIA-Audit` GitHub commit status on HEAD, `state: success`, description `<version> <frontend-digest> <tree>` | The orchestrator, or the bypass stamp | No member posts this on a clean pass: no member's own gate handshake ever calls `post-audit-status.sh` after the marker write and the trailer stamp (pushing that commit only when one was created), and the orchestrator posts the status itself, last, once every dispatched member holds an earned marker and every finding from every round is fixed or recorded (see [[#Posting the status last]]), by calling `post-audit-status.sh` with any one current member's marker. Where a commit was created and pushed, that push already put the trailer commit on the remote PR head, so the orchestrator's later status lands on the sha branch protection checks and a queued merge sees it rather than waiting on a status stranded one commit behind. `post-audit-status.sh` is gated on the marker existing and on local HEAD being the pushed head, and declines rather than posting on a sha a stamp commit is about to replace; when `gh` is unauthenticated the marker still clears the Claude path while the button stays blocked. On a HEAD that was never pushed the stamp amends instead of adding a commit, so there is nothing to push and the orchestrator's post has to wait for the operator's next push; the marker clears the merge gate meanwhile. On an already-pushed attached HEAD the stamp makes no commit at all, local HEAD already equals the pushed head, and the orchestrator's post lands directly once its other preconditions hold. The status is a commit-status POST on an existing sha, not a commit, so the button clears without the status path adding to history. Every reader requires `state == success`: a `pending` status is never treated as cleared. A status the orchestrator posts carries the fixed three-field shape; a bypass stamp carries its own fixed description instead (see [[#The bypass stamp]]). In the three-field shape, field 2 is the frontend digest (the compared validity key), field 3 is the tree (data only, never compared). A refusal is the one signal that still posts immediately: the clearance writer posts `failure` itself the moment it records the refusal, on the same head (see [[#Skipping already-cleared members]]).                                                                                                                                                                                                                                                                                                                                                                                                     |
| PR title matches `^chore\(deps(-dev)?\):` AND every file the PR changes (read from the same pull-request record) is a dependency manifest (bypass) | `/update-deps` wrapper       | Wrapper opens dep-bump PRs with the canonical prefix; the local quality gate stands in for the audit signal, but only for the manifest bump itself, a migration edit or a rebuilt bundle in the same PR denies the bypass. The manifest set lives in `.gaia/scripts/chore-deps-skip.sh`. On this allow the hook posts the `GAIA-Audit` success status `skipped: chore(deps) manifest-only` itself (see [[#The bypass stamp]]). On a `main`/`master` run the skill also merges the PR itself once required checks are green (`gh pr merge --auto`), verifies the terminal `MERGED` state, and cleans up the local branch; on any other branch it pushes and leaves the PR to the branch owner. |
| Every changed file is out of audit scope, or the range is empty and decisive (bypass) | `pr-merge-audit-check.sh`    | The diff is scoped to the pull request's own base branch when the record's remote-tracking ref verifies, and falls back to the repository default otherwise. The bypass clears on either of two shapes: every changed file is out of audit scope (`wiki/`, `.claude/`, `.specify/`, `.gaia/`, `docs/`, root-level markdown, the agent has no rules that apply so no marker is required), or the base-to-HEAD range is empty and the base is decisive, meaning the trust token is `remote` or `supplied`, the anchor is `pr-record`, local HEAD equals the pull request's recorded head sha, and the `gh pr merge` being gated names that same pull request. The record comes from a `gh pr view` read for the current branch, so the reference the command carries is what tells "on a pull request" from "on THIS one": a bare number must equal the record's, and an absent one means the current branch, already covered by the conjuncts above. The reference is read by the shared command scanner (`.claude/hooks/lib/repo-scope.sh`), which models `gh pr merge`'s value-taking flags and is quote-, comment- and heredoc-aware; every abstention denies, so a merge that is not the first command in its tool call, a flag shape the scanner declines to model, a branch name, a URL, a separator or comment putting a second command beside the merge, and any byte outside the small set a merge invocation needs, all keep the marker mandatory. The separator half is the tokenizer's answer rather than a scan of the text, because a second merge can be spelled so no literal scan sees it; the byte-set half is a guard of the gate's own, because an expansion is not a question about words and no word-level tokenizer answers it. It is deliberately an allowlist: which text makes a shell run a command depends on the shell and its version, so a list of dangerous spellings is only ever as current as the last person who wrote one. A base that does not resolve at all, a `local`-provenance empty range, a diff command that failed, and any in-scope path all keep the marker mandatory in every one of those directions. On this allow the hook posts the `GAIA-Audit` success status `skipped: out of scope` itself (see [[#The bypass stamp]]). The permit is silent and the provenance reason is a stderr diagnostic line, not a permission-decision payload. |
| `.gaia/local/audit/<digest>.<member>.ok` (earned)                         | Specialized Code Audit Team member | The member writes the `.ok` file on a clean pass, keyed to its own current content digest, the files it owns plus the shared gate machinery (see Marker key above); no trailer or bypass equivalent produces it. |

A non-empty dispatched set means an in-scope file exists, so the out-of-scope bypass above is unreachable there; that row applies on the zero-match dispatch path only.

**Every signal in the table is bound to the pull request the `gh pr merge` command names.** Both bypasses read the pull-request record and ask at their own site, because each needs the answer to decide whether it fires at all. The clearance signals, a member's own content-digest marker, the commit trailer, and the status, ask once at the permit site, because each proves a property of this checkout's *content* and says nothing about which pull request that content belongs to: without the binding, a branch whose dispatched members had all cleared would merge an arbitrary unaudited pull request by number. The reference is read the same way for every signal, through the shared command scanner, and every abstention denies, so a merge that is not the first command in its tool call, a flag shape the scanner declines to model, a branch name or URL in place of a number, a separator or comment putting a second command beside the merge, and any byte outside the small set a merge invocation needs each deny on their own. **What that denial means differs by site, and the difference decides the repair.** On a bypass the binding is a relaxation conjunct, so failing it falls back to requiring a marker. On a clearance the marker is by definition already present, so failing it denies *regardless of any clearance*: re-spawning the members rewrites the same markers for the same unrotated digest and the command denies identically. The repair there is to respell the merge, never to earn another clearance. A command naming no pull request at all still clears on its signal alone: that is `gh`'s current-branch default, which is the very pull request the record describes, so the turnkey `gh pr merge --squash` spelling is unaffected.

The binding costs one `gh pr view` on the clearance path, read once and memoized, and only when the command names a pull request. That is affordable because the command being gated is itself a network round-trip: a permit issued without touching the network is a permit for an operation that immediately touches it, so keeping the clearance path local would move a stall rather than avoid one. A checkout whose pull-request record cannot be read at all, no `gh`, no authentication, no pull request for the branch, cannot confirm the binding and so denies any merge that names a number, whatever clearance is present.

<!-- gaia:maintainer-only:start -->
In this repo the roster also claims framework shell, CLI source, and the live GitHub Actions workflow and action YAML living under some of the out-of-scope bypass's prefixes (`.github/**`, `.gaia/**`); see `.gaia/audit-ci.yml` for the full per-member glob list. A diff touching any of those paths dispatches the owning specialized member, so the dispatched set is non-empty and the out-of-scope bypass is never reached there. A bats-only diff is the case that motivates the bats globs on the shell member: without them it matched no member, and the bypass cleared it to merge unaudited.
<!-- gaia:maintainer-only:end -->

Frontend-digest equality is the load-bearing check for both the trailer and the status: identical digests mean identical owned-plus-machinery content, so an audit on a different commit SHA but the same digest is auditing the same code.

The chore(deps) bypass mirrors the same skip narrowing that `tests.yml` and `chromatic.yml` apply at CI level. These surfaces (local hook plus the required workflows) release together only for a manifest-only dep-bump PR: a `chore(deps):` or `chore(deps-dev):` title whose recorded file list is confined to a dependency manifest, so a manifest-only dep-bump PR from `/update-deps` is turnkey and one carrying a migration edit or a rebuilt bundle is not. The local path's stamp and status hooks (`audit-stamp-trailer.sh`, `post-audit-status.sh`) read the same predicate against the pull request's title and file list, so on a manifest-only diff that also dispatches a specialized member, that member's own earned marker completes the handshake without a default-member run; both waive the missing default-member marker only, never a default-member refusal, and fail closed when the title or the file list cannot be read or is empty. The stamp hook additionally requires the pull request's recorded head sha to have the same tree as the content being stamped, since it can run on an un-pushed HEAD the server-side file list may not yet describe. The bypass requires `gh` to be installed and authenticated; if either is missing the hook falls through to the normal deny path (the bypass is opt-in proof, not a fallback).

#### The bypass stamp

Branch protection that requires `GAIA-Audit` waits on that context for every pull request, including one no member is dispatched for. A member's marker is what normally causes the status to post, and a bypass has no marker, so whichever of these classified the pull request as a bypass posts the status itself:

- **The merge hook.** `pr-merge-audit-check.sh` posts `GAIA-Audit` success on the head sha it verified equals local HEAD (it never re-reads the pull request head for the POST) immediately before it allows the merge, when its own classification found the pull request out of scope (description `skipped: out of scope`) or a manifest-only `chore(deps)` (description `skipped: chore(deps) manifest-only`). It posts only on an allow it classified itself: never on a deny, never for an in-scope pull request, never when the head already carries a cleared `GAIA-Audit` status, and never when local HEAD is not the pull request's recorded head.
- **The CLI wiki flows.** `gaia wiki sync land` and `gaia wiki chain finish` merge their own wiki-only pull requests with `gh pr merge --auto`, outside the hook, so each posts the `skipped: out of scope` stamp itself after opening the pull request and before queuing the merge. The poster reads the subject from the pull request, never from the local checkout, because the landing branch is cut from a local default branch that can hold commits origin never received. It refuses with one stderr line and posts nothing unless `gh pr view <branch> --json files,headRefOid,baseRefName` lists only `wiki/` paths, the recorded `headRefOid` equals local `HEAD`, and `bash .gaia/scripts/resolve-audit-members.sh --base origin/<baseRefName>`, run after fetching that base, exits 0 naming no member for the diff. A pull request record, fetch, or resolver that cannot answer refuses too, because "could not answer" is not "nobody is owed". The land proceeds to `--auto` either way, and a refused pull request needs this workflow run on it.
- **A pull request merged from the GitHub UI** without the local hook, for example a raw Dependabot PR, is never stamped, so it waits on `GAIA-Audit` indefinitely. Run one local merge of it through Claude Code: the hook classifies it, posts the stamp, and allows the merge.

The stamp is best-effort. A failed POST prints one stderr line naming the manual `gh api` command and never turns the allow into a failure.

A clean pass requires no Critical Issues, every Important Issue addressed, and every Suggestion either auto-fixed or resolved by the operator. Those three preconditions govern **in-scope** findings (defects inside the PR's changed line ranges). A **fourth precondition** governs out-of-scope findings: every out-of-scope finding the audit identifies within its review radius must carry a disposition before the marker writes, a filed `tech-debt` issue, a diverted security advisory or operator surface, or a backend-absent waive. The marker is withheld only on a genuinely-missing disposition (a present, writable backend where a filing definitively failed); backend-absent, transient, and diverted findings all fail open. Knip, react-doctor, and dependency-CVE (`pnpm audit`) advisories remain advisory and never block signal emission. See [[Audit Disposition and Debt Fix]] for the full disposition contract.

If the local agent declines to write the marker, its report names what remains unaddressed; resolve those, commit, push, re-spawn.

#### Re-run carry-forward ledger

On a non-clean pass (no marker written) the audit writes a carry-forward ledger keyed to the shared pull-request-wide base plus branch, `.gaia/local/audit/<AUDIT_KEY>.rerun.json`, where `<AUDIT_KEY>` is `gaia_audit_key` (`.gaia/scripts/audit-key-lib.sh`) applied to the fork point `git merge-base "$BASE_REF" HEAD` of the base every dispatched member keys its artifacts to, the resolver's argument-less form, not any member's own narrower per-member review base (see [[Code Review Audit Agent#Incremental scope]]), plus the current branch. Keying on the shared base plus branch, not HEAD alone, holds the filename still while HEAD moves inside a round and keeps it distinct across worktrees sharing a base, so remaining work survives each fix commit without colliding. The key is stable *within* a round, not across rounds: a round that clears by stamping a trailer commit (un-pushed or detached HEAD) makes that stamp the newest cleared ancestor, and the next round keys on it; a round that clears on an already-pushed attached HEAD makes no commit at all and leaves the key where it was.

**The shared clearance writer maintains it**, from the `--base <sha>` every member passes to `.gaia/scripts/audit-write-clearance.sh`. That coupling is the point: a refusal is a blocking artifact retired only by its own author, so a refusal that briefs nothing blocks a merge no one can clear, and the one moment a refusal is guaranteed to be written is the moment it is written. On a refusal the writer rebuilds that member's `remaining[]` from its findings sidecar, so each open finding arrives with its path, line, failure mode, verification, and recommended repair already populated (the sidecar's `error`/`warning` severities map onto the ledger's `critical`/`important`). On an earned write it retires that member's entries into `fixed_last_round[]`, stamped with the sha that closed them, and removes the file once no member has anything left. One ledger serves the whole dispatched set, so every entry carries a `member` field and a write only ever touches its own member's entries. The whole of it is best-effort: a ledger failure warns and never fails the clearance write.

The ledger holds in-scope remaining work only, the `remaining[]` open findings plus `fixed_last_round[]`; out-of-scope findings live in filed `tech-debt` issues and the PR-body headings instead, a distinct, non-overlapping concern. `pr-merge-audit-check.sh` reads only `<digest>.ok`, so a `<base>.rerun.json` is invisible to it.

The ledger is local-flow-only: the audit skips it when `GITHUB_ACTIONS` or `CI` is set, and carries cross-round state in the `GAIA-Audit` trailer and status (read by `.github/audit/resolve-audit-base.sh`) instead. A separate per-member findings sidecar shares the ledger's base-sha key but is a different artifact feeding a different consumer; see [[#Marker key]] for how the two are distinguished. See [[Audit Disposition and Debt Fix]].

#### Findings block

The PreToolUse hook `post-findings-block-on-merge.sh` posts one consolidated findings block to the PR on every `gh pr merge` invocation whose resolved audit mode is `local`, deterministically, no hand-run step required. It posts only when the merge is the **first command in its tool call**: whatever sits ahead of a merge decides which repository the merge lands in, and reading that needs the shell's own semantics, so the hook declines rather than guessing and a `<anything> && gh pr merge` posts nothing. Running the merge as its own step, which this workflow prescribes anyway, is what keeps the posting deterministic. It resolves the pull request and calls the existing producer, and it resolves no audit base: the producer selects its sidecars on the branch, not on a base. The rendered payload carries a `review_bases` entry for each member whose sidecar records one: that member's own per-member review base, the reason it anchored there, and the clearance tree that anchored it, so a reviewer sees each member's own scope decision alongside the merged findings.

```bash
bash .gaia/scripts/post-findings-block.sh --pr <N>
```

`post-findings-block.sh` reads every dispatched member's own findings sidecar, merges every member's `findings[]` into one array, and posts-or-updates exactly one PR comment carrying the merged block: it locates an existing comment by its sentinel and edits it, creating one only when none exists. The hook posts for every pull request it arms on. Running the snippet above by hand stays harmless (`post-findings-block.sh` is idempotent), but the hook makes it unnecessary.

**It takes no base, and that is the point.** The sidecar key is `<base-sha>.<branch-slug>` and only the branch half is stable across a fix loop: a round that clears by stamping a trailer commit lands under a new base once the resolver walks to it, while a round that clears on an already-pushed attached HEAD makes no commit at all and leaves the base where it was. So the producer globs `*.<branch-slug>.*.findings.json`, every base this branch has written under, and a caller that hands it one base narrows the block to one round. That round is the last one, which is clean by construction, because a clean round is what let the pull request merge: the findings fixed during the loop, the ones the recurrence tally most wants, were exactly the ones dropped. The per-round partitioning of the sidecars themselves stays, deliberately, as the durable record of what each trailer-stamping round found; a round that clears on an already-pushed attached HEAD leaves the base where it was, so its write overwrites the previous round's sidecar for the same member rather than adding a new one.

#### Posting the status last

A member's clean pass writes its earned marker and stamps the trailer; it never posts the `GAIA-Audit` success status itself (see [[#Marker key]] and [[#Signals]]). An all-green PR reads as done and safe to merge to anyone looking at it, and a clean member pass is not that: the orchestrator is still deciding what to do with the round's findings, folding a Suggestion, weighing accept-and-note, deciding whether to re-dispatch. Posting success ahead of that decision would announce a state that has not been reached yet. Refusals are unaffected: the clearance writer posts a `GAIA-Audit` `failure` itself the moment it records a refusal (see [[#Skipping already-cleared members]]), because a non-green signal never waits on anyone's disposition.

The orchestrator posts the success status itself, last, once every one of these holds:

- Every dispatched Code Audit Team member holds an earned marker for the current tree.
- Every finding from every round is fixed, or recorded under `## Accepted residuals (recorded, not fixed)` or `## Out-of-scope machinery findings (recorded, not filed)`.
<!-- gaia:maintainer-only:start -->
- The CHANGELOG gate below is resolved, and its entry, if any, has landed on the branch.
<!-- gaia:maintainer-only:end -->
- The last push has landed on the pull request's remote head.

```bash
bash .claude/hooks/post-audit-status.sh <current-member-marker>
```

Any one dispatched member's own current marker path is sufficient; `post-audit-status.sh` already refuses while any dispatched member is pending and posts on the pushed PR head, so it resolves the rest itself (see [[#Signals]]). Run `gh pr merge` only after this call reports a posted status.

Any later HEAD move needs a re-post, the manifest-answer commit above, a CHANGELOG fixup, or a conflict found mid-wait ([[#Conflict found mid-wait]] step 3 already does this for that case). If the orchestrator forgets this step, no `GAIA-Audit` status exists for the head; where `GAIA-Audit` is a required check, branch protection blocks the merge, so the omission fails closed and visibly rather than merging over a status nobody posted.

A bypass pull request needs none of this: the merge hook, or the CLI wiki flow that opened it, posts the `skipped: ...` status itself, so the orchestrator never posts one for it (see [[#The bypass stamp]]).

### 4. Merge

<!-- gaia:maintainer-only:start -->
First clear the **CHANGELOG gate** below: decide whether this PR needs an `## [Unreleased]` entry and land it on the branch before merging.
<!-- gaia:maintainer-only:end -->

Once **every dispatched member's** marker exists for HEAD and the `GAIA-Audit` status is posted (see [[#Posting the status last]]), run `gh pr merge`. The hook short-circuits to allow the call.

<!-- gaia:maintainer-only:start -->
## CHANGELOG gate (maintainer-only)

The last decision before merge: does this PR's change belong in `CHANGELOG.md` under `## [Unreleased]`? Make the call **at merge time**, not authoring time. An entry promised in an earlier session is worthless if it never landed, and a fix that spanned sessions may have changed what's worth noting, so re-run this check on every merge, including a PR resumed days later. GAIA's `CHANGELOG.md` is release-excluded, so this gate and every entry it produces are GAIA-team-only and reach no adopter clone.

**Worthy, add an entry.** Default to yes for anything that moves the GAIA product surface: a new or changed skill, command, hook, rule, agent, or wiki concept page; a behavior or default change; a bugfix in any shipped or maintainer surface; a dependency bump that crosses a security or compatibility floor; an adopter-action change (author it per the Adopter-action convention at the top of `CHANGELOG.md`). The changelog tracks the whole product, maintainer-only tooling included.

**Not worthy, merge as-is.** Typo, formatting, or comment-only edits; a pure internal refactor with no behavior or surface change; test-only changes that alter no shipped behavior; and anything already covered by an existing `## [Unreleased]` line.

When worthy:

1. Add the entry to the right `### Added | Changed | Removed | Fixed` subsection under `## [Unreleased]`, present tense with the trailing `(#<PR>)` reference. Write it at Keep a Changelog altitude: 1-3 sentences on what changed and why it matters, not implementation mechanics (no file/function/flag-internals narration). Preserve any **Action required:** marker and its literal command, breaking/migration substance plus a pointer to the steps, behavior-changing flag names, adopter-relevant version/engine bumps, and a truthful who/why clause; deep detail belongs in the PR and commit.
2. Commit it onto the PR branch and push so it merges with the change. HEAD moves, so re-confirm step 3's audit marker still covers the new HEAD, then post the `GAIA-Audit` status ([[#Posting the status last]]) on the new HEAD before merging. Cheapest path: decide changelog-worthiness back in step 2 while fixing audit findings, so a single audit pass covers both.
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

Anything other than `main` means another session holds the main checkout on its own branch. Take the worktree arm and run no `git checkout` at all. `.claude/hooks/block-main-destructive-git.sh` enforces this read: it denies a checkout or switch that would move the main checkout's HEAD off a branch with an open pull request, unless this session opened that pull request, and its source describes the kinds of spelling it cannot see. This is not a hypothetical: several worktree rows can merge while a separate main-checkout row is mid-audit on its branch, and the feature-branch arm's `git checkout main` then yanks HEAD out from under it. Nothing is lost when that happens, the branch, the pull request and the working tree all survive, but the interrupted member's own tree self-check fires and its round is forfeited, which is a whole member read spent for nothing. The sharper half is quieter: with the main checkout sitting on `main`, `resolve-audit-members.sh` returns an empty spawn set because `main` has no diff, not because anything cleared, and a monitor keyed on emptiness reads that as CLEARED. Such a check keys on the marker body's `tree` field matching the row's own tree instead ([[#Marker key]]).

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

This failure mode belongs to `gh` below 2.99.0. When `gh pr merge` exits non-zero with `fatal: 'main' is already used by worktree at '<path>'`, **the GitHub-side merge has already succeeded**. The local checkout step is what failed, not the merge itself. Under worktree isolation this is the expected outcome rather than an anomaly, and it appears even in runs that perform no manual cleanup at all: `--delete-branch` runs its own local branch delete, which begins by checking out the default branch that the main checkout already holds. Driving the same merge from the main checkout fails one step later instead, at the delete itself, with `error: cannot delete branch '<branch>' used by worktree at '<path>'`; the merge has equally already succeeded. From `gh` 2.99.0 on, `gh` skips the local delete with a warning, deletes the remote branch, and exits 0, so the merge reports success under both isolation modes and this section describes nothing a reader on that version will see. Confirm with:

```bash
gh pr view <N> --json state
```

If `state == "MERGED"`, do NOT retry the merge. Treat it as merged, run any post-merge steps (wiki-sync, spec-close, etc.), and clean up through [[#Cleanup under worktree isolation]] above rather than the feature-branch sequence. Retrying compounds the problem and can produce a duplicate squash on a non-existent branch.

**With `--auto`, the exit status depends on the merge state at call time**, so it is not a property of the isolation mode alone. When GitHub queues the merge behind remaining checks, `gh` deletes neither branch and exits 0, and the repository's own head-branch deletion setting is then the only thing that removes the remote branch once the merge lands. When the pull request is immediately mergeable, `gh` merges on the spot and takes the same local delete path a plain merge takes, so a worktree run on a `gh` below 2.99.0 sees the failure above. Neither case revises what the poll reports.

## Second merge gate: the worthiness presence gate

`gh pr merge` passes through a second, independent PreToolUse hook,
`.claude/hooks/worthiness-presence-check.sh`. It denies the merge when an
emergent test the PR changed (under `app/components/**` or `.playwright/**`, as
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

### Accepted limits of a status-based gate

A hand-posted `GAIA-Audit` status, an admin bypass of the repository ruleset, and a forgeable `GAIA-Audit` commit trailer each pass the gate without the attested audit. They are known, pre-existing limits of a gate that reads statuses and trailers, not defects this workflow closes.

See [[Code Review Audit Agent]], [[Quality Gate]], [[Git Workflow]].
