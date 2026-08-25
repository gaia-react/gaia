---
type: concept
status: active
created: 2026-04-20
updated: 2026-08-01
tags: [concept, ci, review]
---

# PR Merge Workflow

Mandatory before any `gh pr merge`. Machine-enforced by `.claude/hooks/pr-merge-audit-check.sh`, which denies `gh pr merge` calls until every Code Audit Team member this diff dispatches has its own clearance marker for that member's own current content digest (see [[#Marker key]]).

The gate is **repo-scoped** via `.claude/hooks/lib/repo-scope.sh`: it enforces this repo's audit contract only. A `gh pr merge` positively aimed at a different repo (`-R owner/other`, or `cd <other> &&`) is allowed; this repo's audit markers have no bearing on a sibling repo's merge. Scoping is fail-closed: any ambiguity still enforces.

## Who audits: the dispatched member set

The gate is a roster, not a single agent. `bash .gaia/scripts/resolve-audit-spawn.sh` names the Code Audit Team members this diff owes an audit to, one per line, deduped and sorted, and always exits 0. Empty output carries **two** meanings, and either way it is safe to act on directly with no need to unpack which one applies: either nothing in the diff is auditable and no member is owed, or every dispatched member's own valid current-digest marker is already present, so there is nothing left to spawn. Either way `gh pr merge` proceeds with no further agent dispatch, because the oracle, not the raw dispatch resolver, is what accounts for the in-scope-but-ownerless case the merge gate still blocks on. Every member the oracle still names writes its own clearance (see Marker key below). See [[Code Audit Team]] for the roster and dispatch mechanism.

The `code-audit-frontend` agent's own self-skip calls the oracle with `--no-carry-forward` (the flag's own name; it disables the digest-marker-presence filter and emits the unfiltered dispatch set). Its self-skip must key on "the diff does not dispatch me", never on "I was already cleared": a self-skip that read the filtered output would stand down whenever it happened to already hold a valid marker, disabling the one lever that can catch a stale or wrong filter result, spawning the member for real, whose fresh earned clearance then simply overwrites the old one. A human running the oracle by hand, or any other caller, gets the filtered (digest-marker-aware) output by default. There is no carry-forward clearance machinery behind this flag: it toggles a plain presence check, not an anchor-selection or minting step.

## Marker-first: check before you audit

The hook requires a **clearance to exist** for each dispatched member's own content, not that you personally run the audit. `code-audit-frontend`'s clearance comes from one of two producers: CI (`code-review-audit.yml` stamps the `GAIA-Audit` status) or the local `code-audit-frontend` agent (writes `.gaia/local/audit/<frontend-digest>.ok` through the one shared clearance writer, stamps a `GAIA-Audit:` trailer, pushes the stamp commit, and posts a `GAIA-Audit` success status). Which producer runs is a **per-author mode**, `ci` or `local`, resolved by the shared helper both sides call identically:

```bash
eval "$(
  PR_IS_FORK="$(gh pr view <N> --json isCrossRepository --jq .isCrossRepository)" \
  bash .gaia/scripts/read-audit-ci-config.sh --resolve-author "$(gh pr view <N> --json author --jq .author.login)"
)"
# resolved_mode (ci|local) and should_run (true|false) are now in scope
```

The `gh` read for the fork flag lives here, on the caller's own path, deliberately: the resolver performs no `gh` call of its own, which keeps the resolved mode independent of API reachability and of the caller's authority. CI supplies the same flag from `${{ github.event.pull_request.head.repo.fork }}`, no `gh` call needed there either. Simplifying this by moving the read into the script would reintroduce exactly the dependency this design deletes.

CI and the local path read the same `resolved_mode`, so they never disagree about who audits. `default_mode` is `local`, and the resolver's built-in fallback (no config file present at all) agrees, so an unconfigured repo resolves the same `local` as one that ships `default_mode: local` explicitly. A **fork** pull request resolves to `ci` regardless of `default_mode` or any `audit_authors` pin, ahead of every other precedence rule: a local audit would run the fork branch's own audit machinery under the maintainer's full local credentials, where CI runs it on a sandboxed runner with a scoped token. Required-check confirmation runs whenever the resolution is `local` and is **advisory only**: it reports whether `GAIA-Audit` is registered as a required check under either branch-protection model (classic branch protection, then a repository ruleset), names what it tried on stderr when it can't tell, and never changes the resolved mode.

The mode decides who produces the **default member's** signal, CI or a local run; it says nothing about which Code Audit Team members are owed a signal at all, that is the roster's call (see "Who audits" above). Under the one-producer invariant, if CI cannot clear every dispatched member it stands down **entirely** and the local producer owns the whole audit, rather than each producer covering part of the roster. That invariant holds under `resolved_mode=local`, the default. It does not hold under the fork path: a fork PR resolves to `ci`, and if its diff also dispatches a member CI cannot run, the PR reaches no complete producer and waits for a maintainer to handle by hand, rare in practice (see [[Code Audit Team]]). The mode lives in `.gaia/audit-ci.yml`, a team `default_mode` plus per-developer `audit_authors` overrides and a sticky `override_label` that forces `ci`; it is per-author and never `off`. The audit has no `automation.json` entry, so don't look for one. Resolve the mode first:

- `resolved_mode == ci` with the workflow present, or the override label set → **wait for CI's `GAIA-Audit` success** (the check states below).
- `resolved_mode == local`, or the workflow absent → **run the local agent** as the producer; on a clean pass it writes the marker, stamps and pushes the trailer commit, then posts the `GAIA-Audit` success status on the pushed head so the github.com button clears too.

For the `ci` branch, **start with the cheapest deterministic signal: the workflow file:**

```bash
test -f .github/workflows/code-review-audit.yml && echo present || echo absent
git rev-parse HEAD   # the SHA the marker must match
```

`test -f .github/workflows/code-review-audit.yml`: **present** → the CI audit is configured (it installs only via `/setup-gaia`); trust / wait for the `GAIA-Audit` marker. **Absent** → the CI audit is not set up; run the local `code-audit-frontend` agent. The `GAIA-Audit` check state stays authoritative for the final go/no-go (it handles secret-rotated and `gate_label` edge cases where the file is present but no marker lands).

When the file is **present**, consult the PR's check state:

```bash
gh pr checks <N> | grep GAIA-Audit   # what state the audit is in, if any
```

Read the whole output before narrowing to that row: the rows this grep discards answer a question the pre-dispatch verification asks anyway (see [[#Before the first dispatch: verify your own work]]), and discarding them means finding a red check after a round has been spent rather than before it. One note if this call is ever restructured to branch on its result: `gh pr checks` exits non-zero when a check fails, and piping it into `grep` swallows that status, so a version that tests the exit code has to capture the output first and test `$?` on the `gh` invocation itself, not on the tail of a pipeline.

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

### 1. Spawn the dispatched Code Audit Team members

#### Before the first dispatch: verify your own work

The gate is the most expensive feedback in the workflow, and it is a **merge** gate. The **first** dispatch on a branch has no earned clearance to anchor on, so every member reads its whole owned surface: 60-110k tokens per member and several minutes. Spending that to learn something a local check would have reported is a straight loss, because it consumes the round that should be finding what the author cannot see. Each repair then moves HEAD and rotates the digest, buying another round, and what that round costs depends on the scope it actually resolves rather than being another full read, see [[#Applying the audit's own Suggestions: digest economics]].

The failure shape is specific and worth naming, because it does not look like a mistake while it is happening. New parsing, matching, or extraction logic is written; it handles the shapes the author thought of; a member finds a shape it mishandles; the fix ships; the next round finds another. Each round is individually productive, so the loop feels like progress while it is really a debugging session billed at audit rates. Three rounds to converge on one hand-rolled parser is the canonical case.

So before the first dispatch, not after the first refusal:

- **Run the deterministic checks that cover the change.** The test suites for the paths touched, the linters for the languages involved, the [[Quality Gate]] when its skip logic says it applies, and any suite that consumes what changed. Green locally is the entry condition for dispatch, not a milestone passed once: re-run it after the **last** edit. Verifying, then editing prose or docs, then dispatching without re-running is the same defect as never running it, and it is the easier one to commit because the green output is still on screen.
<!-- gaia:maintainer-only:start -->
- **Run the whole-tree invariants as a set: `bash .gaia/tests/whole-tree-invariants.sh`.** The bullet above selects by path, and a check whose input is the whole directory has no path that selects it, so without a named set the ones that run are whichever a currently-loaded rule happens to mention, and rule activation is itself path-scoped. This is the set, and its own header carries the membership rule, the reasoning behind each deliberate non-member, and the measured runtime. It duplicates work CI already does on purpose: CI reports the same failure after the push, which costs a repair commit that moves HEAD, rotates every dispatched member's content digest, and buys a re-audit of each.
<!-- gaia:maintainer-only:end -->
- **Read the whole `gh pr checks <N>` output, not only the `GAIA-Audit` row.** CI is a deterministic check that has already run; it happens to have run remotely, and it covers exactly the complement the path-scoped selection above deliberately skips. That complement is where the one failure shape the author cannot see from their own chair lives: a change to one file reds a guard that lives in another, with nothing in the diff pointing at it. Fold any red into the same repair batch as everything else found pre-dispatch, and read the rows beside it too, a silent pass next to the red is often the same coupling not yet caught. Four things this reading has to carry, or it misfires. It reports on the **pushed head**, so with commits still local it describes older bytes; read it as what has landed, not as a verdict on the tree about to be audited. **Pending is not green**, and it is not a reason to hold the round: audits take minutes too, and serializing behind CI wall-clock can cost more than it saves, so dispatch and re-read before the marker handshake. **Red is not always a code change**: a flake, an infra hiccup, or a rotated secret wants a re-run, so read the failing job's log before folding a repair into the batch. And a branch that is unpushed, or an audit run before the PR is opened, has nothing to read; skip cleanly rather than treating the absence as an error.
- **Write the adversarial fixtures a reviewer would ask for.** One per shape the logic might mishandle, chosen by asking what the input space actually contains rather than what the implementation happens to read. For anything that parses a real format, that space is unbounded: prefer the format's own parser over a hand-rolled scrape, and treat "I will teach it the next shape when something finds one" as the decision to pay for those rounds.
- **Prove each new mechanism can fail, one at a time.** A guard whose assertions cannot be made to fire asserts nothing, and it reports green in exactly the case it exists to catch. Mutate the guard's own logic, not only the thing it watches: drop a term from its formula, weaken a comparison, confirm a test goes red, restore. Doctoring the subject proves the fixture; mutating the guard proves the assertion. Do this per outcome, not per file and not per mechanism: for each distinct outcome the new logic can produce, mutate it to each of the others and confirm some test goes red, which for a predicate means both return values plus the fall-through wherever all three are reachable. A change that adds two mechanisms therefore needs at least two mutants, because the suite going red when you loosen a threshold says nothing about the selection rule added beside it, and one mutant per mechanism still leaves that mechanism's other outcomes untouched. Three traps make a mutant survive that reads as covered. An assertion that **recomputes the production formula in its own body** is testing its own arithmetic, so extract the formula into the helper both the assertion and the fixture call. And a fixture set that is uniform in the dimension the new rule discriminates on cannot see it: if the rule prefers longer-in-hops over larger-in-minutes, every fixture where those coincide agrees under either rule. And the mutant that comes to mind first is the failure you were already imagining, which is the direction you have just defended against, so it proves that direction and no other; the direction you did not consider is both the untested one and the likelier one to break later, which is what makes a single mutant reliably wrong rather than occasionally wrong.
- **Commit before you mutate, or mutate a copy.** Restoring a mutant means putting the file back, and `git checkout -- <path>` restores from the index: it discards *every* uncommitted change to that file, not only the mutation. The moment you are about to mutate is also the moment you are most likely to be mid-edit, so what the restore takes is usually work that has nothing to do with the guard, and it goes without a diagnostic. Commit first, or run the mutation in a scratch `git worktree` and leave the tree under review untouched, which is what a dispatched member does with its own mutation work.
- **A comment making a falsifiable claim about this repository is a query, so run it.** "This pathspec covers every surface", "widening this glob turns X red", "no other caller does this": each has an answer, and getting it costs seconds against the price of a round. Run it, or delete the sentence. A **replacement** comment earns the same treatment as the one it replaces: a correction is new unverified text, and it is the likeliest place for the next wrong claim, because the scrutiny went to the thing being corrected. Where the claim is about what a guard does or does not catch, prefer writing it as a test rather than as prose. A test is a claim that re-checks itself; prose is a claim that decays.
- **Treat "the audit will tell me if this is wrong" as an instruction.** That thought is a precise description of a test that has not been written yet. Write it instead.

None of this substitutes for the gate. It changes what the gate is spent on: the cross-cutting and adversarial findings a member is uniquely positioned to make, rather than defects already visible from the author's own chair.

<!-- gaia:maintainer-only:start -->
When this PR newly ships files, run `/distribution-audit` and land its manifest-answer commit first, before this step. The manifest answer commits `.gaia/manifest.json` and any `.gaia/release-exclude` change; neither path is an audit-machinery digest input nor a reviewed member surface, so the commit rotates no member's content digest and invalidates no marker already earned. It does move HEAD, and the `GAIA-Audit` commit status is keyed to HEAD's sha, so a manifest commit that lands after the handshake strands the just-posted status on the old HEAD and forces an extra status re-post on the new one. Landing the distribution-audit answer first is what leaves the handshake as the last thing to move HEAD: the handshake's own stamp commit is pushed before the status posts, so the status lands on the final PR head and stays put.
<!-- gaia:maintainer-only:end -->

**Roster-first: resolve the members, then spawn exactly those.** Before any `gh pr merge`, resolve which Code Audit Team members this branch's diff dispatches:

```bash
bash .gaia/scripts/resolve-audit-spawn.sh
```

It prints one member (agent) name per line, deduped and sorted, and always exits 0. That output is the spawn set.

- **One or more names** → spawn every named member in parallel, from a single tool-call message. Do not wait for the merge deny-hook to name them; that round-trip is friction:

  Immediately before this dispatch wave fires, capture the expected tree fresh: `git -C <RESOLVED_ROOT> rev-parse HEAD^{tree}`. Recapture it before every dispatch wave: HEAD can move between rounds (a member re-spawned after a repair commits runs against a new HEAD), so reusing a stale value would fail a later wave's self-check against a tree it is correctly reviewing. `RESOLVED_ROOT` is the working root `.claude/skills/gaia/references/isolation.md` exports; a caller that never ran that reference, a plain feature-branch session, still resolves it trivially as its own current checkout's absolute path, so the self-check costs nothing there and is not worktree-only machinery.

  Dispatch every member with `run_in_background: false`. The `Agent` tool runs a subagent in the background by default, and a background subagent's final text does not route back to the orchestrator, so a defaulted dispatch loses the member's entire report: every Critical finding it raised, and every tree-mismatch abort the template below asks it to return. The marker gate stays fail-closed, so nothing unsafe merges, but the operator is left with a stuck gate and no diagnosis, and the no-op classifier below has no returned text to classify. A synchronous dispatch is what makes the returned-text contract hold, here and in [[#No-op detection and retry for each dispatched member]]. Synchronous does not mean sequential: issue every member's `Agent` call from one tool-call message, each carrying `run_in_background: false`, and they still run concurrently.

  ```
  Agent(
    subagent_type: "<member-name>",
    run_in_background: false,
    prompt: "Working root: <RESOLVED_ROOT>, the absolute path of the checkout under review; the orchestrator substitutes the value it resolved from the isolation reference at dispatch time. Before running any handshake command, set AUDIT_ROOT=<RESOLVED_ROOT>. Expected HEAD tree: <EXPECTED_TREE>, the tree captured immediately before this dispatch wave.
    MANDATORY FIRST ACTION, before any review: run `git -C <RESOLVED_ROOT> rev-parse HEAD^{tree}` and compare it to <EXPECTED_TREE>. If that command errors (missing path, git unavailable) OR the value does not match exactly, STOP, do not review, do not write a marker, and return only the mismatch or error as your entire output.
    Only on an exact match, review all changes in <RESOLVED_ROOT>'s current branch compared to main, scoping every git command to `git -C <RESOLVED_ROOT>`. Identify security vulnerabilities, performance issues, code smells, anti-patterns, and refactoring opportunities."
  )
  ```

- **No names** → empty output means either of two different things, and either way it is safe to act on with no further spawn: no changed file is auditable, so no marker is owed, or every dispatched member's own valid current-digest marker is already present, so nothing is left to spawn. Either way `gh pr merge` clears with no audit spawn, *because* the answer came from the oracle: the oracle, not the raw dispatch resolver, is what accounts for the in-scope-but-ownerless case the merge gate still blocks on.

- **The oracle is absent** (an older checkout, an interrupted install) → fall back to `bash .gaia/scripts/resolve-audit-members.sh`, and treat an EMPTY result as "spawn `code-audit-frontend`" (fail-closed). Never treat an unanswerable question as "nothing owed".

Skip a spawn for a member already cleared: its current-digest marker exists, or (for the default member) one of the bypass signals in the marker-handshake table already applies to this PR. The spawn set names who *can* be required, not who is still outstanding.

On a clean pass each member writes its own marker, stamps the `GAIA-Audit:` trailer, pushes the stamp commit, and calls `post-audit-status.sh`. The merge deny-hook requires **every** dispatched member's marker, so one member withholding holds the gate shut for all. If a member declines to write its marker, its report names what remains unaddressed; resolve those, commit, push (HEAD moves), then re-spawn the pending members on the new HEAD. A member that cleared a previous round must be re-spawned too whenever its own owned-plus-machinery content changed since: its marker is keyed to its own content digest, and a commit that touches a path it owns, or any gate-machinery path, rotates that digest. A commit that touches nothing a given member owns and no machinery leaves that member's digest, and its marker, valid, no re-spawn needed. Never hand-write a marker to bypass the gate.

**Re-read the full `gh pr checks <N>` output before every re-spawn, on the same terms as the first dispatch.** Between rounds is where this pays most: the repair commit just pushed can red something the round's own local checks never selected, and the round about to be spawned is already being bought, so a red folded in now rides a re-dispatch that is paid for either way, while the same red found after the round buys a whole extra one. The pushed-head, pending-is-not-green, red-is-not-always-a-code-change, and no-PR-yet caveats above apply unchanged here; the sha caveat binds harder between rounds, because a row read moments after the repair push can still be describing the previous head's run.

#### Parallel dispatch

Markers are keyed to each member's own content digest, so members are order-independent (see [[#Marker key]]). **Dispatch every member in parallel, in any order.** A self-heal edits the working tree and stops there, it makes no commit and no push; the orchestrator commits once after every dispatched member has returned, so the contended resource is the git index and the remote, never the files themselves. Per-member content-digest keying means an owned-file change rotates only that member's digest: there is no working-tree race between members and no wave to sequence.

The **trailer stamp**, landed by whichever dispatched member clears last, is an empty commit: it advances HEAD and leaves every blob byte-identical, so it rotates no member's digest, including its siblings'. A **self-heal is a real content edit**, ordinarily confined to files `code-audit-frontend` itself owns, so under digest keying it rotates only its own digest; a self-heal that happens to touch a gate-machinery path rotates *every* member's digest, correctly invalidating a sibling's in-flight marker, because a machinery change is exactly the case the machinery guard exists to force a re-review on.

#### The repair boundary

A member's self-heal is confined by a **deterministic gate**, not by an instruction alone, on whichever producer runs the audit. Both producers read one sourced refusal set (`.claude/hooks/lib/audit-selfheal-paths.sh`) naming the paths no member may edit: the instruction/convention surfaces (`.claude/`, `.specify/`, `wiki/`), `test/**`, the rest of `.gaia/**`, `.github/**` (the whole tree, so the executables the audit workflow runs to decide its own success status are covered alongside the workflow YAML), and the root package/build/lint config the default member's own glob list already covers (`package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `tsconfig*.json`, `*.config.*`).

- **CI** enforces it at push time: the self-heal step's `run:` body checks the staged diff against the refusal set before committing.
- **Local** enforces it at edit time: a `PreToolUse` hook (`.claude/hooks/block-selfheal-paths.sh`) denies a matching edit the moment a dispatched Code Audit Team member (an `agent_type` carrying the `code-audit-` prefix) attempts it.

Be accurate about two honest limits rather than assuming parity between the two enforcement points. The local hook covers a member's edit tools plus the well-known Bash write shapes (`>`, `>>`, `tee`, `sponge`, `sed -i`, a `cp`/`mv` destination) and is best-effort against an unbounded Bash vector (`dd`, `install`, a subshell or `eval`, a heredoc to an arbitrary file descriptor), the same posture `block-manifest-write.sh` already takes; it also binds only members named with the `code-audit-` prefix, so a member named off-convention escapes it. CI's push gate reads the whole diff at push time and cannot be evaded by the shape of the write. **The orchestrator itself is not bound by either gate**: it is trusted rather than bounded (see Cross-remit findings below), because this same protocol's own execution routinely edits `.gaia/**`, `test/**`, and `.github/workflows/**`, and a hook that refused those paths unconditionally would deny its own commits.

#### No-op detection and retry for each dispatched member

A dispatched member can silently no-op: zero tool uses, a return that is just a harness-reminder-echo or output-style fragment instead of a real review. Nothing about the marker gate catches this on its own, fail-closed means no marker and no merge, but with no diagnosis of *why* the gate is stuck, just a stuck gate a human has to notice and investigate by hand. This mirrors, one layer up, the same deterministic classifier `code-audit-frontend` already runs on its own internal specialist and refuter fan-outs (`.claude/agents/code-audit-frontend.md`, "No-op detection and retry for each refuter").

This classifier reads the member's returned text, which reaches the orchestrator only because the dispatch above is synchronous (`run_in_background: false`). A backgrounded member routes no text back, so there is nothing to classify and this whole guard is inert. After each dispatched member's `Agent` call returns, write its returned text to a temp file and classify it:

```bash
bash .gaia/scripts/audit-noop-detect.sh --shape audit-team-member --path <tempfile> \
  --marker <expected-marker-path> --findings <expected-findings-sidecar>
```

`<expected-marker-path>` is `.gaia/local/audit/<frontend-digest>.ok` for `code-audit-frontend`, `.gaia/local/audit/<digest>.<member>.ok` for a specialized member, the same marker key each member's own gate handshake writes (see Signals below). `<expected-findings-sidecar>` is `.gaia/local/audit/<audit-key>.<member>.findings.json`, that member's durable report of record; pass it for a specialized member whenever the audit key resolves, and omit it otherwise (an unresolved base or branch writes no sidecar, and the default member keys its durable detail to the re-run ledger instead). Exit 0 = real (stdout `real`, or `refused`), exit 1 = no-op. A dispatch holding a writer-produced earned marker **and** its findings sidecar, or whose return carries a backticked `` `path:line` `` finding location, or (for `code-audit-frontend`'s terse LOCAL return) the literal `Remaining in-scope:` preamble, is real; a return matching none of those, most often a bare harness-reminder / available-agent-types echo, is a no-op.

**A refusal is proof of life, never a no-op.** A member that reviewed the content fully and withheld its clearance writes `<digest>[.<member>].refused` and no `.ok`, so the marker path above names a file that never appears for that run. The classifier derives the refusal sibling from `--marker` and checks it **first**, before the earned family, matching the merge gate's own refusal-first precedence; a writer-shaped refusal for the same member and digest classifies `refused` at exit 0. Nothing about that dispatch is retried: re-dispatching a member that refused with cause returns the identical result, spends the single hardened re-dispatch below on a member that was never broken, and reports "no-op'd twice" for what is actually "refused twice, with cause". The lost-report gate does not apply to the refusal arm either, because a refusal carries its own report forward through the member's findings sidecar and the carry-forward ledger its refusal write produces (see [[#Signals]]). Read those two artifacts to learn what it refused on.

**The findings sidecar, not the returned text, is each member's report of record.** Read it to learn what a member found; the return is a convenience copy and this classifier's input. It reads as a report because it carries one: each entry names the finding's `path` and `line`, the `failure_mode` (input, state, wrong outcome), the `verified_by` evidence that establishes it, and the `suggested_fix`, alongside the `finding_class` / `severity` / `area_tags` the recurrence tally counts. Every member writes it through one shared writer (`.gaia/scripts/audit-write-findings.sh`), which rejects a write whose entries cannot name those fields, so an entry that could not brief a repair never reaches disk in the first place. The detail stays local: `post-findings-block.sh` projects each entry down to the three tally keys when it renders the PR comment. Requiring the sidecar alongside the marker is what makes a lost report detectable: a member that completed, wrote a valid earned marker, and whose report never reached the orchestrator is otherwise indistinguishable from a clean pass, because the marker alone would classify the dispatch real and suppress the retry, leaving a green gate with zero visible findings and any Suggestions the clean-pass contract obliges the operator to resolve silently dropped. A present marker with an absent sidecar therefore classifies no-op and earns the one retry below. The check binds to the member the marker names, not merely to the file's shape, so one member's sidecar can never vouch for another's lost report across a multi-member round.

**Clear the expected sidecar before each dispatch wave**, exactly as the captured-return path is cleared, so its presence is a fresh-write signal rather than a leftover. The sidecar keys on the incremental audit key (base sha plus branch), which deliberately does not move across fix rounds, while a member's marker keys on its content digest, which does. Without the pre-clear a sidecar written in an earlier round still sits at the expected path, and since every member spec declares that write best-effort, a later round whose own write failed would read the stale file as proof its report landed.

On a no-op, re-dispatch that member **exactly one** time with the hardened retry prefix (`.claude/agents/code-audit-frontend.md`, "No-op detection and retry for each refuter"), substituting the concrete target with the member's original changed-file list. A second consecutive no-op does not re-dispatch a third time: stop and surface to the operator which member no-op'd twice, rather than looping or silently proceeding to a merge attempt. The marker gate stays fail-closed either way, no marker still means no merge, but a surfaced double no-op tells the operator why the gate is stuck instead of leaving them to notice an odd reply on their own.

### 2. Fix all issues

The local fix loop reads the re-run carry-forward ledger (`.gaia/local/audit/<AUDIT_KEY>.rerun.json`) for a deterministic, lossless briefing rather than a main-thread-authored prompt summary: the fixer reads `remaining[]` for what to fix and `fixed_last_round[]` for what the previous round already cleared, and the next re-audit reads the same ledger. The filename keys on the incremental base plus branch, which is stable across fix rounds, so the path does not change as HEAD moves. Fail-open: when the ledger is absent, corrupt, or stale (a different branch or base), the loop falls back to the full report in the audit's return, which the agent emits whenever it could not write the ledger.

- Fix every Critical Issue, every Important Issue, and every Suggestion the audit identifies.
- If a Suggestion involves an architectural tradeoff, breaking change, or conflicting convention, the agent escalates it with documented rationale rather than auto-fixing; the operator must resolve the escalation before the marker is written.
- Re-run linting and type checking after fixes.
- Stage, commit, and push the fixes; HEAD must move so the next audit runs against the fixed tree.
- **Land the whole round's fixes in one commit**, never one commit per finding. Each commit rotates the reporting member's content digest and buys a re-dispatch to re-earn its marker, so a round repaired finding-by-finding pays for as many re-audits as the round had findings and clears no more than the single batched commit does. Fix everything the round reported, then commit and push once.
- **Sweep the round's touched files for comment and prose repairs before the last dispatch.** A re-dispatch this round is already being paid, so a correction that rides it adds no marginal audit cost, which is the first arm of the digest economics below. Doing the sweep here also removes most of the need to decide the question after a member has already cleared, which is the expensive place to decide it.
- Re-spawn the audit agent on the new HEAD until it reports clean.

#### Applying the audit's own Suggestions: digest economics

Applying an in-scope Suggestion or an accepted finding is a content edit, so it rotates the reporting member's content digest, invalidates its marker, and forces a fresh re-dispatch of that member to re-earn the clearance. **Price that re-dispatch by the scope it resolves, not at full scope by default.** A re-dispatched member re-reads its whole owned surface only when it has nothing to anchor on: `.github/audit/resolve-audit-base.sh --member <member>` resolves a per-member review base, and every member scopes its review to the delta from that base to HEAD (`.claude/agents/code-audit-frontend.md`, "Incremental scope"). Full scope is the reset case, not the default one.

The resolver names the reason it chose on line 2 of its `--member` output, and the review scope on line 1 is full only for these:

- `no-anchor`, no usable clearance in range. This is the state of every first dispatch on a branch.
- `rules-reset-global`, a path in the gate's global-rules set changed since the anchor.
- `rules-reset-member`, this member's own agent definition changed since the anchor.
- `degraded` or `no-version`, the resolver could not source a required library or read `.gaia/VERSION`, so it fails safe to full scope.

On `member-clearance` and `team-signal` the member holds an anchor and reviews a delta. `machinery-reset` is deliberately absent from that list: a merely-shared machinery change resets the shared artifact-keying base on line 3 while line 1's review scope holds.

Against that pricing, the two arms are:

- **The member's digest is already rotating in this PR**, you are already changing files it owns this round (the ordinary audit → fix → re-audit loop) or a gate-machinery path every member's digest folds in. The re-dispatch is already being paid, so **apply the Suggestion in the same PR**: the fix rides a re-review that happens anyway and adds no marginal audit cost.
- **The PR is already clean and the member is already marked**, with nothing else rotating its digest. This arm differs from the first in kind, not only in price: no round is currently reading this branch, so whatever the fold adds is content nothing has reviewed, on a branch whose whole review budget is already spent, and a defect in the repair costs a further round on top of the one the fold buys, plus whatever that defect does if it ships instead. **Apply it when the repair is comment-only or prose-only** and the branch still holds an anchor. Those two forms carry almost none of the unreviewed-repair risk, and the re-dispatch they buy is a delta review of the one edit plus the member's fixed dispatch overhead, not a 60-110k full round. **A repair that introduces new logic into an already-marked PR is weighed on the risk of shipping an unreviewed repair, not on the delta-review price alone**, which is the smaller term of the two. **Accept-and-note** is for that case, for an edit that trips a reset above (touching the global-rules set or the member's own agent definition rotates the review back to full scope), for an unanchored member, and for a finding big enough to deserve its own change, not for a one-line comment or prose correction.

Accept-and-note is not free either, and pricing only the re-dispatch hides its cost: a deferred Suggestion leaves a known defect in the tree and moves the repair to a follow-up that has to rebuild the context this round already holds. Weigh both sides before deferring.

Both arms assume the Suggestion is correct. A Suggestion is a finding, not a specification: it can assert a mechanism the member inferred rather than verified, and a claim about third-party behavior is where that is likeliest and hardest to spot. Verify the claim against the library's own source or a runnable probe before applying it, most of all when the fix is prose that ships as guidance, where implementing it verbatim turns a reviewer's error into a documented one that reads as reviewed. The re-dispatch these economics already price in re-reviews the edit and usually catches it, but only after an extra round.

This is operator guidance about **in-scope Suggestions and accepted findings**, distinct from **in-flight-fix promotion** (the audit's own automatic same-run repair of a qualifying **out-of-scope** finding through the self-heal path; see [[Audit Disposition and Debt Fix]]). In-flight-fix promotion is the audit repairing out-of-scope debt itself as it reviews; this is the operator deciding whether an in-scope Suggestion is worth folding into an already-marked PR. They do not overlap.

#### When rounds stop: pre-commit a disposition for every branch

The fix loop above says to re-spawn until the audit reports clean, and the digest economics beside it license accept-and-note instead. Choosing between them *after* a finding is on the table is the failure, because at that point the question is no longer what the rule was, it is whether this particular finding is worth one more round, and asked that way it answers yes almost every time. Write the rule down before the round runs.

A usable rule names a disposition for **every** way the round can come back, including carrying on. A rule that says only "stop and reconsider" has decided nothing: the same question returns one round later with no rule left standing. Three branches, and the third is the one commonly left open:

- **Clean** → merge.
- **Only accepted residuals, or prose an earlier round wrote** → accept-and-note in the PR body and merge. Repeat findings on the previous round's own repair are the signal that each pass is enriching the artifact rather than correcting it, and every widening of a prose list invites the next one.
- **A new, reproduced defect in the logic this change authored** → name the concrete outcome rather than deferring it, because "run another round" is not a disposition, it is the absence of one. Say what ships, what gets filed instead, and who decides. Where the round turns on a design decision an operator settled, retiring that decision is the operator's call, so the fallback is to report and recommend rather than to overturn it.

**A round count is evidence, not a verdict.** What says a guard is the wrong instrument is the **direction** of its repairs, whether each one leaves the artifact smaller, and **where** the defects land: in the parser, the comparison, the payload, or the design. A fifth round in a part that has been stable since the third is a different finding from a fifth round in the same place, and the count alone cannot tell them apart.

#### Cross-remit findings

A member can find a genuine defect in a file outside its own declared domain, a **cross-remit finding**. The member that found it applies no repair, whether or not the file's owner has already cleared it and whether or not the fix looks trivial; it reports the finding to the orchestrator instead. The orchestrator disposes of it one of two ways:

- **In scope for the PR** → the orchestrator applies the repair itself. Its commit rotates the owning member's digest, invalidating that member's marker, so the owner is re-dispatched and reviews the repair made to its own file.
- **Out of scope** → a non-security finding is recorded as **waived** (listed in the pull request body, not filed) when its path is either a gate-machinery path or a file this pull request already changes and the finding itself clears both disqualifiers; a finding satisfying neither term, or any security-class finding, is filed as a tech-debt issue exactly as it is today, through `/gaia-debt` and the `file-tech-debt` skill.

Either way the finding is **recorded rather than lost**.

When the out-of-scope arm files a tech-debt issue, the filing carries a `gaia-debt-origin` provenance line beside its dedup key, from the shared helper, so a later reader recovers which work surfaced the finding after the branch is squash-merged and deleted. The orchestrator is on the pull request's own branch with a shell, so it resolves `changed` rather than recording `unknown`. The field vocabulary and the convention table live in `.claude/skills/file-tech-debt/SKILL.md`, referenced rather than restated here. A filing is never blocked, failed, retried, or deferred because provenance is partial or absent.

For `changed`, the orchestrator reuses the whole-PR fork point in the same spelling the audit machinery already computes, adding no derivation of a new shape:

```bash
AUDIT_ROOT="${AUDIT_ROOT:-$(git rev-parse --show-toplevel)}"
default_branch=$(git -C "$AUDIT_ROOT" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null \
  | sed 's@^refs/remotes/origin/@@')
[ -n "$default_branch" ] || default_branch="main"
FULL_BASE=$(git -C "$AUDIT_ROOT" merge-base HEAD "origin/${default_branch}" 2>/dev/null \
  || git -C "$AUDIT_ROOT" merge-base HEAD "${default_branch}" 2>/dev/null || true)
pr_changed=$(git -C "$AUDIT_ROOT" diff --name-only -z "${FULL_BASE}...HEAD" 2>/dev/null | tr '\0' '\n' || true)
origin="$(cd "${AUDIT_ROOT:-/dev/null/unset}" 2>/dev/null && bash .gaia/scripts/debt-origin-lib.sh \
  --changed "<0|1|unknown>" --dir . 2>/dev/null || true)"
```

Three-dot, no pathspec, and no `if [ -z "$FULL_BASE" ]; then` stop-guard: a finding on any file the pull request touches reads `changed=1`, and an unresolvable `FULL_BASE` makes `changed` the literal `unknown` for every finding in the run rather than stopping the filing, because `0` would assert the work did not touch the file while an unresolvable base asserts nothing.

The waive rule applies to every out-of-scope finding the orchestrator disposes, whichever member surfaced it: every specialist surface belongs to a member that files nothing itself, so the orchestrator disposes what they hand it.

<!-- gaia:maintainer-only:start -->
GAIA maintainers: those surfaces are `.gaia/cli/src/**`, `.claude/skills/**`, `.gaia/scripts/**`, `.claude/hooks/**`, `.claude/rules/**`, `.gaia/**/*.bats`, and `.github/workflows/**`. The list is wrapped because the first glob names a maintainer-only tree that no adopter clone carries, and a shipped page asserting it would be describing a directory the reader does not have.
<!-- gaia:maintainer-only:end -->

Either path term alone is sufficient: a gate-machinery finding satisfies the path condition whether or not the pull request touches it. An empty eligibility set disengages the waive rather than opening it, with nothing eligible, a finding routes to the normal filing path. The security screen runs first and is unchanged: a security-class finding never waives.

Two disqualifiers narrow what may be waived inside that eligible set, and neither widens it: a finding must clear both to stay eligible. No gate checks either one; they sit on the same agent-judgment wall the non-security screen sits on.

**The change authored the inconsistency.** A finding is not waive-eligible when this change is what authors the inconsistency the finding names: the finding's site sits inside this change's own diff, or it is a sibling of a set this change adds a member to, or it is a claim this change falsifies. *Pre-existing* describes a sibling this change leaves untouched, never an asymmetry this change introduces. The bound is not optional: a finding whose defect is latent at the fork point, reading the same whether or not this change lands, is untouched-sibling debt and stays eligible even when it sits in a file this change edits.

**A pointer written into shipped content owes a tracked destination.** A finding is not waive-eligible when this change leaves a pointer in shipped content, a code comment, a header note, a documented limit, or a test rationale, saying that a separate change handles what the finding names. The waive is unavailable and the finding is filed, so the pointer resolves to a tracked destination rather than to prose. This is a rule rather than a standing judgment call: a finding whose destination is named in shipped content is filed, and that filing is correct even when both path terms fire. The obligation runs from the pointer to the filing, never from the filing to the pointer, so omitting the pointer removes the obligation and removes the explanation from the shipped content along with it, and the cost lands on the author's own artifact rather than on the reader.

A waive files nothing: no tech-debt issue, no issue number, and no touch of the debt-count staleness sentinel (`.gaia/local/debt/refresh-requested`).

Every waived finding is listed in the pull request body under the heading `## Out-of-scope machinery findings (recorded, not filed)`, one entry per finding, each carrying its `file:line`, a one-line failure mode, and its dedup key.

The changed-file set comes from the eligibility derivation block in `.claude/agents/code-audit-frontend.md` (the `FULL_BASE` / `full_changed` fence beside its review-scope block), re-run in the same Bash call because shell state does not persist between calls; it is never the member's TS/TSX-filtered review-scope set, which excludes every surface this rule exists for.

The gate-machinery set is whatever `audit_path_is_machinery` (`.claude/hooks/lib/audit-machinery.sh`) accepts, the same classifier both merge gates apply when they re-verify the waive, so the orchestrator and the gates read one definition of gate machinery rather than two.

**Recording a waive.** The abuse-check both merge gates run reads the disposition-ledger sidecar, so a waive not recorded there is invisible to both gates, and the orchestrator writes it directly. Two roots: the sidecar is main-anchored shared state, and the digest is computed over the acting tree whose HEAD is being merged.

```bash
main_root="$(bash .gaia/scripts/main-root-lib.sh)"
tree_root="$(git rev-parse --show-toplevel)"
digest="$(bash .gaia/scripts/audit-member-digest.sh --root "$tree_root" --member code-audit-frontend)"
sidecar="$main_root/.gaia/local/audit/${digest}.dispositions.json"
```

The orchestrator writes the entry after the final Code Audit Team member clearance and before `gh pr merge`, so the digest it keys to is the one the gates read, and re-applies it after every round in which HEAD moves: a content change rotates the digest, and the seed-forward union carries forward only `filed` and `pending(definitive)` entries, so a `machinery_waived` entry lives exactly one digest and has no re-deriver but the orchestrator.

It is a read-modify-write, never an overwrite. The default member owns this file, and its `filed` receipts and its `backend` field live in it.

- Absent → create `{"schema":1,"sha":"<tree_root HEAD sha>","branch":"<tree_root current branch>","backend":"present","findings":[]}`.
- Present → leave `backend` and every existing entry exactly as they are, and set `.sha` to the acting tree's HEAD sha and `.branch` to its current branch (`git -C "$tree_root" symbolic-ref --quiet --short HEAD`, empty on a detached HEAD); those two are what bind a waive to the pull request under judgment, so the writer that adds an entry is the writer that stamps them.
- Append an entry only when no existing entry carries the same `key`; an existing entry always wins.
- Write atomically: a temp file in the sidecar's own directory, then `mv`.

The entry uses the existing schema, with no new fields:

```json
{ "key": "v1 class=<finding_class> path=<repo-relative-posix-path> line=<int>",
  "severity": "critical|important|suggestion",
  "security_class": false,
  "disposition": "machinery_waived" }
```

`issue_number` and `pending_reason` stay unset.

The sidecar is named by the default member's content digest, which does not rotate for a diff that touches nothing that member owns and no gate machinery, so one file can be read while judging several consecutive pull requests. Both gates read the recorded `branch` and `sha`: an entry whose sidecar belongs to a different pull request is set aside rather than judged against a diff it was never about, and the gate says so out loud. `branch` is the decisive half, because a pull request squash-merged with `--delete-branch` leaves a head reachable from no ref, which no test over `sha` alone can tell from this branch's own rewritten-away commit. That is why the stamp above is not optional.

The orchestrator is trusted rather than bounded here, and this is a member-error guard, not a security boundary: it removes members' write access to files outside their own domain and hands that same access to the orchestrator. What makes that reasonable is stated rather than assumed: under local mode a human watches every turn the orchestrator takes, which is not true of a member dispatched inside a CI job. A bad orchestrator repair is caught by human review of the pull request and by nothing else.

### 3. Marker handshake

#### Marker key

Every clearance is written by the **one shared writer** (`.gaia/scripts/audit-write-clearance.sh`); no member hand-writes a marker file. Given the audited root, the writer derives the member's **content digest**, a sha256 over exactly the files that member owns plus the shared gate machinery (plus the in-scope-but-ownerless paths, for the default member; see [[Code Audit Team#Ownership classifier]]), through the digest engine (`.claude/hooks/lib/audit-digest.sh`), resolves HEAD's real tree and commit sha as plain data fields, then writes the body atomically. The body carries a version, `schema: 4`, the audited `member`, a `provenance` (`earned` or `refused` only, there is no carried family), the `digest` (the validity key), `tree` and `sha` (data only, used by the janitor's live-tree keep-arm, never compared for validity), `audited_at`, and two sidecar flags. `sidecar` answers "does this member file a findings sidecar, its report of record": every member does, so it is always true. `dispositions_sidecar` answers "does it file the out-of-scope disposition sidecar the merge gate's backstop reads": only the default member does. Two flags because there are two sidecars, and one field cannot answer for both; reading `sidecar` as the disposition flag was wrong for four of the five members, and a wrong answer there reads as "this refusal carries no report", which is the state that makes a refusal look unrepairable. `schema` is informational, no reader validates it, so a marker written under the previous contract still validates unchanged. The gate's reader (`clearance_acceptable`) accepts a clearance only when it is **well-formed**: the body parses, its recorded `digest` matches the filename key, its `member` matches, and its `provenance` is `earned`; a file that exists but fails that check is neither cleared nor missing, the gate reports it as present but invalid and asks for a re-run. This is a well-formedness check, not an authenticity one, it raises the bar a hand-written marker has to clear; it does not by itself prove who wrote a given file. `jq` is required for every digest-keyed predicate; with `jq` absent every check returns false (fail-closed), it never degrades to a bare-existence match.

Provenance gets its own filename, not just a body field:

| Provenance | Default member | Specialized member `<m>` | Meaning |
| --- | --- | --- | --- |
| earned | `<digest>.ok` | `<digest>.<m>.ok` | the member audited this exact content and cleared it |
| refused | `<digest>.refused` | `<digest>.<m>.refused` | the member audited this exact content and withheld its clearance |

Every write lands unconditionally: it overwrites a stale body at the same path. There is no create-only guard and no carried family to dominate; provenance is earned or refused only.

Marker files are named for the member's own **content digest**, not HEAD's tree and not its commit sha. The digest engine enumerates every tracked file at HEAD (`git -C <root> ls-tree -z -r HEAD`, NUL-delimited so no path name can shift the hash input), the ownership classifier and machinery matcher select exactly the member's set (`owned(member) ∪ machinery`, plus in-scope-but-ownerless for the default member), and the selected `<mode> <blob-sha> <path>` records are sorted and sha256'd behind a fixed recipe-version sentinel. Content-addressing falls out of the blob sha, so byte-identical content yields an identical digest regardless of what else in the repo changed; mode catches an exec-bit flip, path catches a rename. A marker attests that a Code Audit Team member reviewed **the content its own digest covers**, never the whole tree.

The digest key is what makes the team's markers order-independent, and it is far narrower than the whole-tree key it replaced: an unrelated or out-of-glob change (a CHANGELOG line, a wiki edit) rotates **no** member's digest at all, so every existing marker keeps validating with zero re-dispatch. Whichever dispatched member clears last stamps the `GAIA-Audit:` trailer, and on an already-pushed HEAD that stamp lands as an **empty commit**: it advances HEAD while leaving every blob byte-identical, so it rotates no member's digest either. Each member writes its marker whenever it finishes; the members can run in parallel and the stamp changes nothing.

The key does not weaken the gate. A change to a file a member owns rotates only that member's digest, correctly forcing a re-audit of exactly the member whose content changed. A change to any gate-machinery file, anything whose bytes can change what a member reviews, who reviews it, where a clearance lands, or whether a clearance is believed, rotates **every** member's digest, since the machinery path set sits inside every member's input set by construction; this also closes the classifier-version skew hazard, since the classifier's own files are themselves machinery. See [[#Parallel dispatch]] for how this plays out when `code-audit-frontend` self-heals mid-dispatch.

Three artifacts under `.gaia/local/audit/` key differently from a member's own marker, because their readers resolve identity at a different point than a content digest: the disposition sidecar (`<frontend-digest>.dispositions.json`, keyed to the **frontend member's own content digest**, valid iff the frontend earned marker for that digest is valid; see [[#Out-of-scope dispositions]] below), the re-run carry-forward ledger (`<audit-key>.rerun.json`, keyed to the incremental base commit plus branch, an in-scope fix-loop briefing that never gates a merge; see [[Code Review Audit Agent#Re-run carry-forward ledger]]), and the per-member findings sidecar (`<audit-key>.<member>.findings.json`, one per dispatched member, also keyed to the incremental base plus branch; see [[#Findings block]] below). The ledger and the findings sidecar share an audit key but feed different consumers: the ledger briefs the **fix loop** (what remains, what the last round already fixed), the findings sidecar feeds the **posted findings block**, one array of every dispatched member's findings regardless of whether the pass was clean. `local-janitor.sh` sweeps every key family out of one directory, each by its own liveness rule; see [[Local Working State]].

#### Skipping already-cleared members

There is no carry-forward clearance machinery: no anchor selection, no delta computation, no minting step, and no `.carried` marker family. A member not already cleared for its own current digest simply gets re-dispatched; the digest key itself is what shrinks how often that happens, since an out-of-glob change never rotates it and only an owned-file or machinery change does.

The dispatch-side benefit the old carry-forward `cf_filter` used to deliver still exists, delivered more simply: `resolve-audit-spawn.sh` drops a member from the spawn set whenever its own valid current-digest marker is already present and no live same-digest refusal outranks it, a plain presence check against the shared clearance reader (`clearance_member_cleared` and `clearance_member_refused`), with no anchor selection and no ancestry walk. This is a pure query, it mints nothing; a member the resolver skips still has to hold a genuinely valid marker for its own current digest at merge time, or the gate denies regardless of what the spawn oracle said. See [[#Who audits: the dispatched member set]] for the `--no-carry-forward` flag that disables this filter.

A **refusal** is a first-class artifact keyed the same way as an earned marker (`<digest>[.<member>].refused`), the only way a member records "I read this exact content and I withhold." The gate checks the refusal family before the earned family and treats a live refusal of the current digest as absolute: no earned marker for the same digest, however clean, ever overrides it.

A refusal also carries a **server-side** signal, because the local hook is not the only merge path. GitHub's auto-merge completes on the required `GAIA-Audit` commit status alone and never runs the hook that honors refusal precedence, so a refusal recorded after a sibling member's clean pass already posted `success` would otherwise leave that success standing and the pull request merging over a live refusal, with the artifact on disk and no diagnostic anywhere. On the local path the shared clearance writer therefore posts a `GAIA-Audit` `failure` for the same head as it records the refusal, through the same hook the clean path uses (`post-audit-status.sh`, handed the refusal artifact instead of an earned marker). The latest status for a context wins, so this retracts the stale success and a later genuine clean pass overwrites it in turn; a refusal can never strand a pull request it no longer applies to. The post belongs to the writer rather than to a member's instructions because the one moment a refusal is guaranteed to be recorded is the moment it is written. It is best-effort in both directions: a post that cannot happen (no `gh`, an un-pushed head) leaves the refusal on disk where the local gate still denies the merge, and a failure there never disturbs the refusal that already landed. CI is left alone, since that workflow posts one terminal status per run and there is no window between an earlier wave's success and a later wave's refusal for it to lose.

The spawn oracle reads the refusal family for the same reason the gate does. `resolve-audit-spawn.sh`'s presence filter treats a member as cleared only when its valid current-digest earned marker is present **and** no live same-digest refusal outranks it. Without that second read the oracle and the merge gate answer differently about one state, because the writer publishes a refusal beside any same-digest earned marker rather than replacing it: the oracle reports "nobody owed" while the merge stays denied, and the operator is told there is no member left to run.

A refusal is retired by its **author**, never by the gate inferring supersession from timestamps. Resolving the finding is the ordinary path: the repair edits a file the member owns, which rotates that member's digest and leaves the refusal keyed to content nobody is merging. A second path exists because an Important finding also clears by operator acknowledgment with a stated reason, which moves no bytes and so leaves the digest identical. There the member re-audits and writes its earned marker with `--supersede-refusal "<reason>"`; the shared writer records the reversal in the marker body and removes that member's own refusal, publishing the earned marker first so a crash leaves both artifacts and the gate shut rather than neither. A plain earned write never touches a refusal. That asymmetry is what keeps refusal-precedence from decaying into "newest marker wins" and preserves it as the control that stops someone re-running an auditor until it passes: a bare re-spawn against unchanged, still-unaddressed content refuses again.

#### Signals

The hook (`pr-merge-audit-check.sh`) accepts any one of three signals that prove the **default member's** audit ran clean against the content being merged, plus three bypasses. Two of the three bypasses (out-of-scope, `chore(deps)`) waive only the default member's signal; the third, the audit-workflow re-render bypass, proves a property of the PR rather than of one member, so it can also clear a specialized member's own marker requirement (see its row below). A specialized member's own marker is otherwise a separate, mandatory signal the hook additionally requires whenever the roster dispatches that member:

| Signal                                                                    | Source                       | How it gets there                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------------------------------------------------- | ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.gaia/local/audit/<frontend-digest>.ok` (earned)                        | Local audit agent            | Agent writes the `.ok` file on a clean pass, keyed to its own current content digest (see Marker key above).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `GAIA-Audit:` commit-message trailer on HEAD                              | Local audit agent            | `audit-stamp-trailer.sh` writes an empty commit with the trailer, locally; the member that lands it pushes that commit before posting the status in the row below                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `GAIA-Audit` GitHub commit status on HEAD, `state: success`, description `<version> <frontend-digest> <tree>` | CI (`code-review-audit.yml`) or the local audit agent | CI stamps this after a full audit (on the audit SHA) and on HEAD when the un-audited delta is entirely out of audit scope. On the local path the producing member posts the same `state: success` status as the last step of its own gate handshake: it writes its marker, stamps the trailer, pushes the stamp commit, then posts. Pushing before posting is what puts the trailer commit on the remote PR head first, so the status lands on the sha branch protection checks and a queued merge sees it rather than waiting on a status stranded one commit behind. `post-audit-status.sh` is gated on the marker existing and on local HEAD being the pushed head, and declines rather than posting on a sha the stamp commit is about to replace; when `gh` is unauthenticated the marker still clears the Claude path while the button stays blocked. On a HEAD that was never pushed the stamp amends instead of adding a commit, so there is nothing to push and no status posts that round: the trailer rides the operator's next push, and the marker clears the merge gate meanwhile. The status is a commit-status POST on an existing sha, not a commit, so the button clears without the status path adding to history. (The trailer signal in the row above is what carries the marker in a commit: on an already-pushed HEAD it rides an empty `chore: code review audit passed` commit, since published history is never amended.) Every reader requires `state == success`: a `pending` status (the CI local-mode stand-down) carrying HEAD's version+digest is never treated as cleared. The description is always the fixed three-field shape; field 2 is the frontend digest (the compared validity key), field 3 is the tree (data only, never compared).                                                                                                                                                                                                                                                                                                                                                                                                     |
| PR title matches `^chore\(deps(-dev)?\):` (bypass)                        | `/update-deps` wrapper       | Wrapper opens dep-bump PRs with the canonical prefix; the local quality gate stands in for the audit signal. On a `main`/`master` run the skill also merges the PR itself once required checks are green (`gh pr merge --auto`), verifies the terminal `MERGED` state, and cleans up the local branch; on any other branch it pushes and leaves the PR to the branch owner.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Every changed file is out of audit scope, or the range is empty and decisive (bypass) | `pr-merge-audit-check.sh`    | The diff is scoped to the pull request's own base branch when the record's remote-tracking ref verifies, and falls back to the repository default otherwise. The bypass clears on either of two shapes: every changed file is out of audit scope (`wiki/`, `.claude/`, `.specify/`, `.gaia/`, `docs/`, root-level markdown, the agent has no rules that apply so no marker is required), or the base-to-HEAD range is empty and the base is decisive, meaning the trust token is `remote` or `supplied`, the anchor is `pr-record`, local HEAD equals the pull request's recorded head sha, and the `gh pr merge` being gated names that same pull request. The record comes from a `gh pr view` read for the current branch, so the reference the command carries is what tells "on a pull request" from "on THIS one": a bare number must equal the record's, and an absent one means the current branch, already covered by the conjuncts above. The reference is read by the shared command scanner (`.claude/hooks/lib/repo-scope.sh`), which models `gh pr merge`'s value-taking flags and is quote-, comment- and heredoc-aware; every abstention denies, so a merge that is not the first command in its tool call, a flag shape the scanner declines to model, a branch name, a URL, a separator or comment putting a second command beside the merge, and any byte outside the small set a merge invocation needs, all keep the marker mandatory. The separator half is the tokenizer's answer rather than a scan of the text, because a second merge can be spelled so no literal scan sees it; the byte-set half is a guard of the gate's own, because an expansion is not a question about words and no word-level tokenizer answers it. It is deliberately an allowlist: which text makes a shell run a command depends on the shell and its version, so a list of dangerous spellings is only ever as current as the last person who wrote one. A base that does not resolve at all, a `local`-provenance empty range, a diff command that failed, and any in-scope path all keep the marker mandatory in every one of those directions. The out-of-scope shape mirrors `code-review-audit.yml`'s `has_source` skip locally, so the gate clears even when the installed workflow predates the out-of-scope status stamp or CI is absent. The permit is silent and the provenance reason is a stderr diagnostic line, not a permission-decision payload. |
| Audit-workflow re-render is the only in-scope change (bypass)              | `pr-merge-audit-check.sh`    | The one in-scope path the PR changes is `.github/workflows/code-review-audit.yml` AND its committed bytes are a verbatim re-render of the bundled template (`.gaia/cli/templates/workflows/code-review-audit.yml.tmpl`, proven by git-blob identity: equal blob SHAs mean byte-identical files), with every other changed path out of scope. This is the self-mod-only case `/update-gaia` Step 12 produces: it refreshes a stale audit workflow by copying the release template verbatim. CI self-mod-skips such a PR (no stamp lands), and the out-of-scope bypass above denies because `.github/workflows/` is in scope, so this bypass clears the merge without a ceremonial local re-audit of bytes that are GAIA's own template, not adopter code. It is not relaxed on an empty range, unlike the sibling bypass above: it clears every dispatched member at once, across mismatched anchors, so an empty range must never fire it. **Member-agnostic**: the predicate proves a property of the PR (the sole in-scope change is the pinned artifact), not of one member, so it is resolved once per run and clears **any** dispatched member with no earned marker of its own, not only the default member. A live refusal for a member's current digest is checked first and stays absolute, overriding the bypass either way. Stricter than the out-of-scope bypass and fail-closed: an adopter edit (bytes diverge from the template), a second in-scope path, or an absent template keeps every dispatched member's marker mandatory. |
| `.gaia/local/audit/<digest>.<member>.ok` (earned)                         | Specialized Code Audit Team member | The member writes the `.ok` file on a clean pass, keyed to its own current content digest, the files it owns plus the shared gate machinery (see Marker key above); no CI, trailer, or bypass equivalent produces it. |

A non-empty dispatched set means an in-scope file exists, so the out-of-scope bypass above is unreachable there; that row applies on the zero-match dispatch path only. The audit-workflow re-render bypass below it is reachable from the member-aware path too, since it clears any dispatched member with no earned marker of its own.

**Every signal in the table is bound to the pull request the `gh pr merge` command names.** The two bypasses that read the pull-request record ask at their own site, because each needs the answer to decide whether it fires at all. The clearance signals, a member's own content-digest marker, the commit trailer, and the CI status, ask once at the permit site, because each proves a property of this checkout's *content* and says nothing about which pull request that content belongs to: without the binding, a branch whose dispatched members had all cleared would merge an arbitrary unaudited pull request by number. The reference is read the same way for every signal, through the shared command scanner, and every abstention denies, so a merge that is not the first command in its tool call, a flag shape the scanner declines to model, a branch name or URL in place of a number, a separator or comment putting a second command beside the merge, and any byte outside the small set a merge invocation needs each deny on their own. **What that denial means differs by site, and the difference decides the repair.** On a bypass the binding is a relaxation conjunct, so failing it falls back to requiring a marker. On a clearance the marker is by definition already present, so failing it denies *regardless of any clearance*: re-spawning the members rewrites the same markers for the same unrotated digest and the command denies identically. The repair there is to respell the merge, never to earn another clearance. A command naming no pull request at all still clears on its signal alone: that is `gh`'s current-branch default, which is the very pull request the record describes, so the turnkey `gh pr merge --squash` spelling is unaffected.

The binding costs one `gh pr view` on the clearance path, read once and memoized, and only when the command names a pull request. That is affordable because the command being gated is itself a network round-trip: a permit issued without touching the network is a permit for an operation that immediately touches it, so keeping the clearance path local would move a stall rather than avoid one. A checkout whose pull-request record cannot be read at all, no `gh`, no authentication, no pull request for the branch, cannot confirm the binding and so denies any merge that names a number, whatever clearance is present.

<!-- gaia:maintainer-only:start -->
In this repo the roster also claims framework shell, CLI source, and the live GitHub Actions workflow and action YAML living under some of the out-of-scope bypass's prefixes (`.github/**`, `.gaia/**`); see [[Code Audit Team]] for the full per-member glob table. A diff touching any of those paths dispatches the owning specialized member, so the dispatched set is non-empty and the out-of-scope bypass is never reached there. A bats-only diff is the case that motivates the bats globs on the shell member: without them it matched no member, and the bypass cleared it to merge unaudited.
<!-- gaia:maintainer-only:end -->

Frontend-digest equality is the load-bearing check for both the trailer and the status: identical digests mean identical owned-plus-machinery content, so an audit on a different commit SHA but the same digest is auditing the same code.

The chore(deps) bypass mirrors the same skip narrowing that `code-review-audit.yml`, `tests.yml`, and `chromatic.yml` apply at CI level. All four surfaces (local hook + three required workflows) release together when a `chore(deps):` or `chore(deps-dev):` PR is recognized, so dep-bump PRs from `/update-deps` are turnkey. The bypass requires `gh` to be installed and authenticated; if either is missing the hook falls through to the normal deny path (the bypass is opt-in proof, not a fallback).

When CI self-heals (the audit modifies a file and pushes the fix), the workflow stamps a `code-review-audit` check run on the new HEAD and dispatches the sibling required workflows (e.g. `Chromatic`, `Tests`) via `workflow_dispatch` so their check runs attach to the new SHA. See [[Code Review Audit CI#Self-heal re-trigger]] for the full mechanism and the `retrigger_workflows` knob.

A clean pass requires no Critical Issues, every Important Issue addressed, and every Suggestion either auto-fixed or resolved by the operator. Those three preconditions govern **in-scope** findings (defects inside the PR's changed line ranges). A **fourth precondition** governs out-of-scope findings: every out-of-scope finding the audit identifies within its review radius must carry a disposition before the marker writes, a filed `tech-debt` issue, a diverted security advisory or operator surface, or a backend-absent waive. The marker is withheld only on a genuinely-missing disposition (a present, writable backend where a filing definitively failed); backend-absent, transient, and diverted findings all fail open. Knip, react-doctor, and dependency-CVE (`pnpm audit`) advisories remain advisory and never block signal emission. See [[Audit Disposition and Debt Fix]] for the full disposition contract.

The deterministic backstop hook `.claude/hooks/audit-disposition-check.sh` gates `gh pr merge` alongside `pr-merge-audit-check.sh`: it re-reads the disposition-ledger sidecar for the current frontend digest and denies on a present-backend inconsistency (a `filed` entry whose key resolves to no open `tech-debt` issue, or a genuinely-missing disposition) or on a valid frontend marker whose sidecar is absent, failing open on an absent or transient backend (the never-block invariant). It also denies on a `machinery_waived` entry whose key path is neither a gate-machinery path nor a file this pull request changes, and drops only the changed-files term when it cannot resolve a diff base. A `/gaia-debt` fix PR is an ordinary in-scope change that clears the normal gate.

If the local agent declines to write the marker, its report names what remains unaddressed; resolve those, commit, push, re-spawn.

#### Re-run carry-forward ledger

On a non-clean pass (no marker written) the audit writes a carry-forward ledger keyed to the shared pull-request-wide base plus branch, `.gaia/local/audit/<AUDIT_KEY>.rerun.json`, where `<AUDIT_KEY>` is `gaia_audit_key` (`.gaia/scripts/audit-key-lib.sh`) applied to the fork point `git merge-base "$BASE_REF" HEAD` of the base every dispatched member keys its artifacts to, the resolver's argument-less form, not any member's own narrower per-member review base (see [[Code Review Audit Agent#Incremental scope]]), plus the current branch. Keying on the shared base plus branch, not HEAD alone, keeps the filename stable across fix rounds and distinct across worktrees sharing a base, so remaining work survives the moving HEAD without colliding.

**The shared clearance writer maintains it**, from the `--base <sha>` every member passes to `.gaia/scripts/audit-write-clearance.sh`. That coupling is the point: a refusal is a blocking artifact retired only by its own author, so a refusal that briefs nothing blocks a merge no one can clear, and the one moment a refusal is guaranteed to be written is the moment it is written. On a refusal the writer rebuilds that member's `remaining[]` from its findings sidecar, so each open finding arrives with its path, line, failure mode, verification, and recommended repair already populated (the sidecar's `error`/`warning` severities map onto the ledger's `critical`/`important`). On an earned write it retires that member's entries into `fixed_last_round[]`, stamped with the sha that closed them, and removes the file once no member has anything left. One ledger serves the whole dispatched set, so every entry carries a `member` field and a write only ever touches its own member's entries. The whole of it is best-effort: a ledger failure warns and never fails the clearance write.

The ledger holds in-scope remaining work, the `remaining[]` open findings plus `fixed_last_round[]`, and is a sibling of the `<frontend-digest>.dispositions.json` sidecar, which holds out-of-scope findings and gates the merge. The two do not overlap and neither reads the other; the ledger never gates anything. `pr-merge-audit-check.sh` reads only `<digest>.ok` and `audit-disposition-check.sh` reads only `<frontend-digest>.dispositions.json`, so a `<base>.rerun.json` is invisible to both gates.

The ledger is local-flow-only. In CI each audit runs in a fresh ephemeral job, so it carries cross-round state by git-native means, the `GAIA-Audit` trailer/status (read by `.github/audit/resolve-audit-base.sh`) and the PR-comment findings block, and skips the ledger entirely. A separate per-member findings sidecar shares the ledger's base-sha key but is a different artifact feeding a different consumer; see [[#Marker key]] for how the two are distinguished. See [[Audit Disposition and Debt Fix]].

#### Findings block

The PreToolUse hook `post-findings-block-on-merge.sh` posts one consolidated findings block to the PR on every `gh pr merge` invocation whose resolved audit mode is `local`, deterministically, no hand-run step required. It posts only when the merge is the **first command in its tool call**: whatever sits ahead of a merge decides which repository the merge lands in, and reading that needs the shell's own semantics, so the hook declines rather than guessing and a `<anything> && gh pr merge` posts nothing. Running the merge as its own step, which this workflow prescribes anyway, is what keeps the posting deterministic. It resolves the pull request and calls the existing producer, and it resolves no audit base: the producer selects its sidecars on the branch, not on a base. The rendered payload carries a `review_bases` entry for each member whose sidecar records one: that member's own per-member review base, the reason it anchored there, and the clearance tree that anchored it, so a reviewer sees each member's own scope decision alongside the merged findings.

```bash
bash .gaia/scripts/post-findings-block.sh --pr <N>
```

`post-findings-block.sh` reads every dispatched member's own findings sidecar, merges every member's `findings[]` into one array, and posts-or-updates exactly one PR comment carrying the merged block: it locates an existing comment by its sentinel and edits it, creating one only when none exists. The hook's `resolved_mode=local` guard is load-bearing, not defensive dressing: CI's own workflow prompt already emits its own findings block, and posting unconditionally would overwrite it with one carrying only the locally-dispatched members' findings, losing CI's. The one-producer invariant makes that overwrite unreachable under `local`, the default; it does not make it unreachable under `ci`, which a fork PR still resolves to, so the condition, not the invariant alone, is what keeps the two producers' blocks from colliding on that path. Running the snippet above by hand stays harmless (`post-findings-block.sh` is idempotent), but the hook makes it unnecessary.

**It takes no base, and that is the point.** The sidecar key is `<base-sha>.<branch-slug>` and only the branch half is stable across a fix loop: each cleared round stamps a new `GAIA-Audit:` trailer, the resolver walks to it, and the next round's sidecar lands under a new base. So the producer globs `*.<branch-slug>.*.findings.json`, every base this branch has written under, and a caller that hands it one base narrows the block to one round. That round is the last one, which is clean by construction, because a clean round is what let the pull request merge: the findings fixed during the loop, the ones the recurrence tally most wants, were exactly the ones dropped. The per-round partitioning of the sidecars themselves stays, deliberately, as the durable record of what each round found.

### 4. Merge

<!-- gaia:maintainer-only:start -->
First clear the **CHANGELOG gate** below: decide whether this PR needs an `## [Unreleased]` entry and land it on the branch before merging.
<!-- gaia:maintainer-only:end -->

Once **every dispatched member's** marker exists for HEAD, run `gh pr merge`. The hook short-circuits to allow the call.

<!-- gaia:maintainer-only:start -->
## CHANGELOG gate (maintainer-only)

The last decision before merge: does this PR's change belong in `CHANGELOG.md` under `## [Unreleased]`? Make the call **at merge time**, not authoring time. An entry promised in an earlier session is worthless if it never landed, and a fix that spanned sessions may have changed what's worth noting, so re-run this check on every merge, including a PR resumed days later. GAIA's `CHANGELOG.md` is release-excluded, so this gate and every entry it produces are GAIA-team-only and reach no adopter clone.

**Worthy, add an entry.** Default to yes for anything that moves the GAIA product surface: a new or changed skill, command, hook, rule, agent, or wiki concept page; a behavior or default change; a bugfix in any shipped or maintainer surface; a dependency bump that crosses a security or compatibility floor; an adopter-action change (author it per the Adopter-action convention at the top of `CHANGELOG.md`). The changelog tracks the whole product, maintainer-only tooling included.

**Not worthy, merge as-is.** Typo, formatting, or comment-only edits; a pure internal refactor with no behavior or surface change; test-only changes that alter no shipped behavior; and anything already covered by an existing `## [Unreleased]` line.

When worthy:

1. Add the entry to the right `### Added | Changed | Removed | Fixed` subsection under `## [Unreleased]`, present tense with the trailing `(#<PR>)` reference. Write it at Keep a Changelog altitude: 1-3 sentences on what changed and why it matters, not implementation mechanics (no file/function/flag-internals narration). Preserve any **Action required:** marker and its literal command, breaking/migration substance plus a pointer to the steps, behavior-changing flag names, adopter-relevant version/engine bumps, and a truthful who/why clause; deep detail belongs in the PR and commit.
2. Commit it onto the PR branch and push so it merges with the change. HEAD moves, so re-confirm step 3's audit marker still covers the new HEAD before merging. Cheapest path: decide changelog-worthiness back in step 2 while fixing audit findings, so a single audit pass covers both.
<!-- gaia:maintainer-only:end -->

## Post-merge verification before cleanup

`gh pr merge` can fail without aborting the rest of a script: branch protection ("base branch policy prohibits the merge"), pending CI checks, missing `--auto` for queued merges, or auth issues. Proceeding to local cleanup (`git checkout main`, `git branch -D <pr-branch>`, `git fetch --prune`) before confirming the merge actually succeeded leaves the local branch deleted while the PR is still OPEN. Recoverable via `git checkout -b <branch> origin/<branch>` while the remote ref still exists, but it's avoidable churn.

Verification is identical under both isolation modes: poll the PR's state until it reports `MERGED`.

```bash
gh pr merge <N> --squash --delete-branch [--auto]
for i in 1 2 3 4 5; do
  state=$(gh pr view <N> --json state -q .state)
  [ "$state" = "MERGED" ] && break
  sleep 30
done
[ "$state" = "MERGED" ] || { echo "merge did not complete"; exit 1; }
```

That poll is the whole verification. A local error printed by `gh pr merge` after the state reads `MERGED` does not revise the answer; see [[#Local-sync failure mode]] below.

**`--auto` vs `--admin`:** when `gh pr merge` rejects with "base branch policy prohibits the merge", the right escape is `--auto`; it queues the merge and GitHub completes it once checks pass. Never reach for `--admin` to bypass branch protection without explicit permission; it removes the safety the policy exists to provide.

Cleanup is what differs, because the two isolation modes hold the branch differently. Take the arm matching how the work is isolated; [[Task Orchestration]] covers how that choice is made.

### Cleanup under feature-branch isolation

The session sits in the main checkout and holds the branch directly:

```bash
git checkout main && git pull origin main
git branch -D <pr-branch>  # force needed for squash (orphaned commits)
git fetch --prune origin
```

### Cleanup under worktree isolation

The main checkout already holds `main`, so `git checkout main` from inside a linked worktree fails with `fatal: 'main' is already used by worktree at <path>`. That is a property of linked worktrees, not a merge failure, and it makes the feature-branch sequence above unusable from a worktree. Reap the worktree centrally instead:

```bash
# from a shell in the main checkout, never from the worktree being removed
git worktree remove --force .claude/worktrees/<branch-name>
git branch -D <pr-branch>  # force needed for squash (orphaned commits)
git fetch --prune origin
```

`--force` is required because the worktree holds a branch whose commits the squash merge absorbed without making them ancestors of `main`, so git otherwise refuses to remove it. The `git branch -D` step is what actually drops the local branch on this path: `--delete-branch` deletes the remote branch server-side, but its local half checks out the default branch first, which is precisely the step that fails here. If the branch is already gone, the command reports `branch not found` and nothing is wrong.

An agent driving the merge in-session removes its own worktree with the runtime's `ExitWorktree({action: "remove", discard_changes: true})`, gated on the confirmed `MERGED` state; `discard_changes` is safe there for the same reason `--force` is here. From a context that cannot call it, a fresh session or a sub-agent with a pinned working directory, the shell sequence above is the session-independent equivalent. See [[Audit Disposition and Debt Fix]] and [[Worktrees]].

## Local-sync failure mode

When `gh pr merge` exits with `fatal: 'main' is already used by worktree at <path>`, **the GitHub-side merge has already succeeded**. The local checkout step is what failed, not the merge itself. Under worktree isolation this is the expected outcome rather than an anomaly, and it appears even in runs that perform no manual cleanup at all: `--delete-branch` runs its own local branch delete, which begins by checking out the default branch that the main checkout already holds. Confirm with:

```
gh pr view <N> --json state
```

If `state == "MERGED"`, do NOT retry the merge. Treat it as merged, run any post-merge steps (wiki-sync, spec-close, etc.), and clean up through [[#Cleanup under worktree isolation]] above rather than the feature-branch sequence. Retrying compounds the problem and can produce a duplicate squash on a non-existent branch.

## Second merge gate: the worthiness presence gate

`gh pr merge` passes through a second, independent PreToolUse hook,
`.claude/hooks/worthiness-presence-check.sh`. It denies the merge when an
emergent test the PR changed (under `app/components/**` or `.playwright/**`, as
the [[Determinism Classifier]] labels it) has no worthiness-ledger line matching
its current content. It checks presence and signal match only, never the
keep/fix/delete verdict, scopes to the emergent tests this PR changed (a no-op
when none changed), and fails open on missing tooling. It is a separate denial
from the Code Audit Team markers above; both must clear. See [[Worthiness
Presence Gate]] for the full contract.

## No exceptions

- Never merge without a valid current-digest marker from every member the roster dispatches. The hook denies it. Each member's own audit must cover the merged content; CI produces the default member's marker when it audits the PR, otherwise the local `code-audit-frontend` agent does. A specialized member is always local-only, it has no CI producer.
- Never hand-write a marker file to bypass the gate. Each member (local, or for the default member, CI) owns its own marker's emission.
- When CI is not auditing an **in-scope** PR (`.github/workflows/code-review-audit.yml` is absent, Actions disabled, the workflow inactive, or a `gate_label` excludes it), the local `code-audit-frontend` agent is the only way to produce the default member's marker; run it. A PR whose entire diff is out of audit scope needs no marker; the hook's out-of-scope bypass clears it.

See [[Code Review Audit Agent]], [[Quality Gate]], [[Git Workflow]].
