---
type: concept
status: active
created: 2026-04-20
updated: 2026-07-15
tags: [concept, ci, review]
---

# PR Merge Workflow

Mandatory before any `gh pr merge`. Machine-enforced by `.claude/hooks/pr-merge-audit-check.sh`, which denies `gh pr merge` calls until every Code Audit Team member this diff dispatches has its own clearance marker for the current HEAD.

The gate is **repo-scoped** via `.claude/hooks/lib/repo-scope.sh`: it enforces this repo's audit contract only. A `gh pr merge` positively aimed at a different repo (`-R owner/other`, or `cd <other> &&`) is allowed; this repo's audit markers have no bearing on a sibling repo's merge. Scoping is fail-closed: any ambiguity still enforces.

## Who audits: the dispatched member set

The gate is a roster, not a single agent. `bash .gaia/scripts/resolve-audit-spawn.sh` names the Code Audit Team members this diff owes an audit to, one per line, deduped and sorted. Empty output now carries **two** meanings, told apart on stderr: either nothing in the diff is auditable and no member is owed, or every dispatched member's clearance carried forward from an earlier audited tree, in which case stderr carries `carry-forward: spawn-list empty: all-members-carried` and the merge gate mints each member's carried clearance itself with no spawn needed (see [[#Carry-forward]] below). Read stderr before concluding nothing is owed, an empty spawn list is not on its own proof of that. Every member the oracle still names writes its own clearance (see Marker key below). See [[Code Audit Team]] for the roster and dispatch mechanism.

The `code-audit-frontend` agent's own self-skip calls the oracle with `--no-carry-forward`, which disables this filter and restores the pre-feature output. Its self-skip must key on "the diff does not dispatch me", never on "I was pre-cleared": a self-skip that read the filtered output would stand down on a member being pre-cleared, disabling the one lever that can catch a bad carry (spawning the member for real, whose own earned clearance then dominates any carried one automatically). A human running the oracle by hand, or any other caller, gets the carry-forward-aware (filtered) output by default.

## Marker-first: check before you audit

The hook requires a **clearance to exist** for the content at HEAD, not that you personally run the audit. The clearance comes from one of two producers: CI (`code-review-audit.yml` stamps the `GAIA-Audit` status) or the local `code-audit-frontend` agent (writes `.gaia/local/audit/<tree-sha>.ok` through the one shared clearance writer, stamps a `GAIA-Audit:` trailer, and posts a `GAIA-Audit` success status). Which producer runs is a **per-author mode**, `ci` or `local`, resolved by the shared helper both sides call identically:

```bash
eval "$(bash .gaia/scripts/read-audit-ci-config.sh --resolve-author "$(gh pr view <N> --json author --jq .author.login)")"
# resolved_mode (ci|local) and should_run (true|false) are now in scope
```

CI and the local path read the same `resolved_mode`, so they never disagree about who audits. The mode decides who produces the **default member's** signal, CI or a local run; it says nothing about which Code Audit Team members are owed a signal at all, that is the roster's call (see "Who audits" above). CI audits the default member's surface only, so a diff that also dispatches a specialized member always needs a local spawn for that member regardless of mode. The mode lives in `.gaia/audit-ci.yml`, a team `default_mode` plus per-developer `audit_authors` overrides and a sticky `override_label` that forces `ci`; it is per-author and never `off`. The audit has no `automation.json` entry, so don't look for one. Resolve the mode first:

- `resolved_mode == ci` with the workflow present, or the override label set → **wait for CI's `GAIA-Audit` success** (the check states below).
- `resolved_mode == local`, or the workflow absent → **run the local agent** as the producer; on a clean pass it writes the marker, then posts the `GAIA-Audit` success status so the github.com button clears too.

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

**Roster-first: resolve the members, then spawn exactly those.** Before any `gh pr merge`, resolve which Code Audit Team members this branch's diff dispatches:

```bash
bash .gaia/scripts/resolve-audit-spawn.sh
```

It prints one member (agent) name per line, deduped and sorted, and always exits 0. That output is the spawn set.

- **One or more names** → spawn each named member, in parallel from a single tool-call message (with one exception, see [[#Sequencing a self-healing member]] below). Do not wait for the merge deny-hook to name them; that round-trip is friction:

  Immediately before this dispatch wave fires, capture the expected tree fresh: `git -C <RESOLVED_ROOT> rev-parse HEAD^{tree}`. Recapture it before every dispatch wave this section fires, the solo `code-audit-frontend` wave and the parallel specialist wave both (see [[#Sequencing a self-healing member]] for why the two waves exist); HEAD can move between them, a self-heal is a real content edit, so reusing a stale value would fail a later wave's self-check against a tree it is correctly reviewing. `RESOLVED_ROOT` is the working root `.claude/skills/gaia/references/isolation.md` exports; a caller that never ran that reference, a plain feature-branch session, still resolves it trivially as its own current checkout's absolute path, so the self-check costs nothing there and is not worktree-only machinery.

  ```
  Task(
    subagent_type="<member-name>",
    prompt="Working root: <RESOLVED_ROOT>, the absolute path of the checkout under review; the orchestrator substitutes the value it resolved from the isolation reference at dispatch time. Expected HEAD tree: <EXPECTED_TREE>, the tree captured immediately before this dispatch wave.
    MANDATORY FIRST ACTION, before any review: run `git -C <RESOLVED_ROOT> rev-parse HEAD^{tree}` and compare it to <EXPECTED_TREE>. If that command errors (missing path, git unavailable) OR the value does not match exactly, STOP, do not review, do not write a marker, and return only the mismatch or error as your entire output.
    Only on an exact match, review all changes in <RESOLVED_ROOT>'s current branch compared to main, scoping every git command to `git -C <RESOLVED_ROOT>`. Identify security vulnerabilities, performance issues, code smells, anti-patterns, and refactoring opportunities."
  )
  ```

- **No names** → check stderr before treating this as "nothing owed": empty output now means either of two different things. No `carry-forward:` line on stderr means no changed file is auditable, no marker is owed, and `gh pr merge` clears with no audit spawn. A `carry-forward: spawn-list empty: all-members-carried` line means every dispatched member's clearance already carried forward from an earlier audited tree; nobody needs spawning either, but for a different reason, the merge gate mints each member's carried clearance itself when you call `gh pr merge`. Either way an empty answer is safe to act on *because* it came from the oracle: the oracle, not the raw dispatch resolver, is what accounts for the in-scope-but-ownerless case the merge gate still blocks on.

- **The oracle is absent** (an older checkout, an interrupted install) → fall back to `bash .gaia/scripts/resolve-audit-members.sh`, and treat an EMPTY result as "spawn `code-audit-frontend`" (fail-closed). Never treat an unanswerable question as "nothing owed".

Skip a spawn for a member already cleared for HEAD: its marker exists, or (for the default member) one of the bypass signals in the marker-handshake table already applies to this PR. The spawn set names who *can* be required, not who is still outstanding.

On a clean pass each member writes its own marker and calls `post-audit-status.sh`. The merge deny-hook requires **every** dispatched member's marker, so one member withholding holds the gate shut for all. If a member declines to write its marker, its report names what remains unaddressed; resolve those, commit, push (HEAD moves), then re-spawn the pending members on the new HEAD. A member that cleared the previous tree must be re-spawned too: its marker is keyed to that tree, and a commit that changes content changes the tree. Never hand-write a marker to bypass the gate.

#### Sequencing a self-healing member

Markers are tree-keyed, so members are order-independent and parallel dispatch is the default (see [[#Marker key]]). That holds as long as no member **changes the tree while its siblings are running**, and exactly one member can: `code-audit-frontend` is the only member that self-heals. The others are advisory and edit nothing.

The two things it writes are not equivalent, and the difference is what decides the dispatch order:

- Its **trailer stamp** is an empty commit. It advances HEAD and leaves the tree byte-identical, so it invalidates no marker, including its siblings'. This is the case the tree key exists for, and it is why parallel dispatch is safe in general.
- A **self-heal is a real content edit**. It produces a new tree, which correctly invalidates *every* marker for the old one, its siblings' included. That is the gate working as designed, not a bug: the siblings cleared content that is no longer what would merge, so they genuinely owe a re-audit.

The failure mode is only about wasted work. Dispatch all members at once and a mid-flight self-heal orphans the markers the siblings are in the middle of earning, forcing a full re-spawn of the whole roster. Two members can also race on the working tree, which makes a sibling's oracle runs read a tree that is being rewritten underneath them.

So when a self-heal is plausible (any diff `code-audit-frontend` owns, which is most in-scope diffs), **run `code-audit-frontend` first and alone, let the tree settle, then dispatch the remaining members in parallel against the settled tree.** When the frontend is not in the spawn set, or the diff is one it cannot self-heal (an instruction/convention surface such as `.claude/**`, `.specify/**`, or `wiki/**`, where it refuses by design), the plain parallel dispatch above applies with no sequencing.

#### No-op detection and retry for each dispatched member

A dispatched member can silently no-op: zero tool uses, a return that is just a harness-reminder-echo or output-style fragment instead of a real review. Nothing about the marker gate catches this on its own, fail-closed means no marker and no merge, but with no diagnosis of *why* the gate is stuck, just a stuck gate a human has to notice and investigate by hand. This mirrors, one layer up, the same deterministic classifier `code-audit-frontend` already runs on its own internal specialist and refuter fan-outs (`.claude/agents/code-audit-frontend.md`, "No-op detection and retry for each refuter").

After each dispatched member's `Agent` call returns, write its returned text to a temp file and classify it:

```bash
bash .gaia/scripts/audit-noop-detect.sh --shape audit-team-member --path <tempfile> --marker <expected-marker-path>
```

`<expected-marker-path>` is `.gaia/local/audit/<tree-sha>.ok` for `code-audit-frontend`, `.gaia/local/audit/<tree-sha>.<member>.ok` for a specialized member, the same marker key each member's own gate handshake writes (see Signals below). Exit 0 = real, exit 1 = no-op. A dispatch that already wrote its marker, or whose return carries a backticked `` `path:line` `` finding location, or (for `code-audit-frontend`'s terse LOCAL return) the literal `Remaining in-scope:` preamble, is real; a return matching none of those, most often a bare harness-reminder / available-agent-types echo, is a no-op.

On a no-op, re-dispatch that member **exactly one** time with the hardened retry prefix (`.claude/agents/code-audit-frontend.md`, "No-op detection and retry for each refuter"), substituting the concrete target with the member's original changed-file list. A second consecutive no-op does not re-dispatch a third time: stop and surface to the operator which member no-op'd twice, rather than looping or silently proceeding to a merge attempt. The marker gate stays fail-closed either way, no marker still means no merge, but a surfaced double no-op tells the operator why the gate is stuck instead of leaving them to notice an odd reply on their own.

### 2. Fix all issues

The local fix loop reads the re-run carry-forward ledger (`.gaia/local/audit/<BASE_SHA>.rerun.json`) for a deterministic, lossless briefing rather than a main-thread-authored prompt summary: the fixer reads `remaining[]` for what to fix and `fixed_last_round[]` for what the previous round already cleared, and the next re-audit reads the same ledger. The filename keys on the incremental base, which is stable across fix rounds, so the path does not change as HEAD moves. Fail-open: when the ledger is absent, corrupt, or stale (a different branch or base), the loop falls back to the full report in the audit's return, which the agent emits whenever it could not write the ledger.

- Fix every Critical Issue, every Important Issue, and every Suggestion the audit identifies.
- If a Suggestion involves an architectural tradeoff, breaking change, or conflicting convention, the agent escalates it with documented rationale rather than auto-fixing; the operator must resolve the escalation before the marker is written.
- Re-run linting and type checking after fixes.
- Stage, commit, and push the fixes; HEAD must move so the next audit runs against the fixed tree.
- Re-spawn the audit agent on the new HEAD until it reports clean.

### 3. Marker handshake

#### Marker key

Every clearance is written by the **one shared writer** (`.gaia/scripts/audit-write-clearance.sh`); no member hand-writes a marker file. Given the audited root, the writer resolves HEAD, HEAD's tree, and the filename itself, then writes the body atomically. The body carries a version, a `provenance` (`earned`, `carried`, or `refused`), the audit `sha` and `tree`, and `audited_at`. The gate's reader accepts a clearance only when it is **well-formed**: the body parses, its recorded `tree` matches the filename key, its `member` matches, and it carries a `provenance` of `earned` or `carried`; a file that exists but fails that check is neither cleared nor missing, the gate reports it as present but invalid and asks for a re-run. This is a well-formedness check, not an authenticity one, it lets carry-forward (below) tell an earned clearance from a carried one, and it raises the bar a hand-written marker has to clear; it does not by itself prove who wrote a given file.

Provenance gets its own filename, not just a body field, so a merge gate that predates this feature (an older checkout, a hotfix branch cut from an earlier release) refuses a carried clearance rather than mistakenly honoring it:

| Provenance | Default member | Specialized member `<m>` | Meaning |
| --- | --- | --- | --- |
| earned | `<tree>.ok` | `<tree>.<m>.ok` | the member audited this exact tree and cleared it |
| carried | `<tree>.carried` | `<tree>.<m>.carried` | the merge gate pre-cleared the member from an earlier earned clearance, see [[#Carry-forward]] |
| refused | `<tree>.refused` | `<tree>.<m>.refused` | the member audited this exact tree and withheld its clearance |

An **earned** write always dominates: it lands unconditionally and replaces any carried clearance (or a stale pre-schema marker) at the same path. A **carried** write is create-only, it never overwrites an earned clearance. A member spawned for real after being carried therefore always ends up earned, never stuck behind its own carried file.

Marker files are named for HEAD's **tree** sha (`git rev-parse HEAD^{tree}`), not its commit sha. A marker attests that a Code Audit Team member reviewed **content**, and in git the tree *is* the content: identical trees mean identical files, whatever commit carries them.

The tree key is what makes the team's markers order-independent. `code-audit-frontend` stamps the `GAIA-Audit:` trailer, and on an already-pushed HEAD that stamp lands as an **empty commit**: it advances HEAD while leaving the tree byte-identical. Keyed to the commit sha, that stamp orphans every marker written before it, so on a multi-member diff the members that had already cleared the identical tree would read as pending and the gate would block a PR the whole team had passed. The only way through was to run the frontend first and alone, then re-run every other member against the post-stamp HEAD. Keyed to the tree, each member writes its marker whenever it finishes, the stamp changes nothing, and the members can run in parallel.

The key does not weaken the gate. A commit that genuinely edits the tree produces a different tree sha and invalidates every marker for the old one, which is exactly the re-audit the gate exists to force. What it stops forcing is a re-audit of content that never changed.

That cuts both ways, and it is what [[#Sequencing a self-healing member]] is about: a `code-audit-frontend` **self-heal** is a genuine tree edit, so it invalidates its siblings' markers along with its own. The trailer stamp above is tree-neutral and parallel-safe; a self-heal is neither.

Two artifacts under `.gaia/local/audit/` stay **commit**-keyed, because their readers resolve `git rev-parse HEAD` at merge time rather than comparing content: the disposition sidecar (`<HEAD-sha>.dispositions.json`) and the re-run carry-forward ledger (`<base-sha>.rerun.json`). `local-janitor.sh` sweeps both key families out of one directory, so it accepts either key when deciding whether a file is still live.

#### Carry-forward

A clearance is keyed to the whole audited tree, far coarser than what a member actually reads. Carry-forward lets an already-**earned** clearance for an older tree (the anchor) stand in for HEAD's tree when the delta between the two touches nothing that member owns and no audit machinery. It is a **pre-clearance**: it can spare a member from being spawned, and it can never shrink the required-member set the gate computes from the whole-branch diff. Every member the roster dispatches still has to clear, carried or earned, before `gh pr merge` unblocks.

The merge gate (`pr-merge-audit-check.sh`) is the **sole minting authority**. For any member not already cleared, it alone selects an anchor, checks whether the delta from that anchor to HEAD may carry, mints the carried clearance through the shared writer, and carries the anchor's disposition record forward, all in the same operation. `resolve-audit-spawn.sh` consults the identical predicate purely to decide who not to spawn (see [[#Who audits: the dispatched member set]]); it mints nothing, on any path. A stale or optimistic spawn-side skip therefore never substitutes for the gate's own check: a member the resolver skipped still has to pass the gate's own carry-forward check, or get spawned for real, before the merge clears.

A carry refuses, and the member gets spawned for real, when the delta between the anchor and HEAD:

- touches a path the member owns,
- touches any audit-machinery path (anything whose bytes can change what a member reviews, who reviews it, where a clearance lands, or whether a clearance is believed),
- touches an in-scope path nobody owns (checked for the default member only), or
- HEAD's own tree already carries a live **refusal** artifact for that member.

A **refusal** is a first-class, tree-keyed artifact (`<tree>[.<member>].refused`), the only way a member records "I read this exact tree and I withhold." Carry-forward treats a live refusal of the tree being merged as absolute: no anchor, however clean, ever overrides it.

When a carry succeeds, the gate also carries the anchor's disposition-ledger sidecar into HEAD's own, merging rather than overwriting (a key collision always resolves to HEAD's fresh entry, a carried entry may only add keys), and only when the anchor's recorded commit is an ancestor of HEAD. It then re-verifies every `filed` disposition still resolves to a real, open-or-closed issue before letting the merge proceed, so a carried clearance can never quietly import a disposition that no longer holds.

None of this raises a security bar. The ownership and machinery guards are naming aids for a cooperative pool, not a defense against an actor who can rewrite the working tree; the pool's write-integrity weakness is a separate, still-open concern this feature does not touch. What carry-forward buys is real on its own terms: a member whose earned clearance for an unrelated, still-good tree is not re-spawned to re-review content it already read.

#### Signals

The hook (`pr-merge-audit-check.sh`) accepts any one of three signals that prove the **default member's** audit ran clean against the content being merged, plus three bypasses that waive its signal entirely. A specialized member's own marker (last row below) is a separate, mandatory signal the hook additionally requires whenever the roster dispatches that member:

| Signal                                                                    | Source                       | How it gets there                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------------------------------------------------- | ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.gaia/local/audit/<tree-sha>.ok` (earned) or `.carried` (carried)        | Local audit agent, or the merge gate itself for a carried clearance | Agent writes the `.ok` file on a clean pass, keyed to HEAD's **tree** (see Marker key below). The merge gate mints the `.carried` sibling itself, with no agent spawn, when the member's earlier earned clearance carries forward to HEAD's tree (see [[#Carry-forward]]); either file satisfies this same signal.                                                                                                                                                                                                                                                                                                                                                                                                 |
| `GAIA-Audit:` commit-message trailer on HEAD                              | Local audit agent            | `audit-stamp-trailer.sh` writes an empty commit with the trailer                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `GAIA-Audit` GitHub commit status on HEAD, `state: success`, description `<version> <tree>` | CI (`code-review-audit.yml`) or the local audit agent | CI stamps this after a full audit (on the audit SHA) and on HEAD when the un-audited delta is entirely out of audit scope. The local agent posts the same `state: success` status after it writes the marker, gated on the marker existing first (`post-audit-status.sh`), so a `local`-mode merge clears the github.com button too; when `gh` is unauthenticated the marker still clears the Claude path while the button stays blocked. The status is a commit-status POST on HEAD's existing sha, not a commit, so the button clears without the status path adding to history. (The trailer signal in the row above is what carries the marker in a commit: on an already-pushed HEAD it rides an empty `chore: code review audit passed` commit, since published history is never amended.) Every reader requires `state == success`: a `pending` status (the CI local-mode stand-down) carrying HEAD's version+tree is never treated as cleared. When any dispatched member's clearance is carried rather than earned, the description gains a third field, `<version> <tree> carried`; this gate and the out-of-scope substring check still accept it as cleared, but CI's own incremental-base resolver reads only the first field and treats a three-field description as unusable, so a carried clearance can never anchor the base a future audit reviews from.                                                                                                                                                                                                                                                                                                                                                                                                     |
| PR title matches `^chore\(deps(-dev)?\):` (bypass)                        | `/update-deps` wrapper       | Wrapper opens dep-bump PRs with the canonical prefix; the local quality gate stands in for the audit signal. On a `main`/`master` run the skill also merges the PR itself once required checks are green (`gh pr merge --auto`), verifies the terminal `MERGED` state, and cleans up the local branch; on any other branch it pushes and leaves the PR to the branch owner.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Every changed file is out of audit scope (bypass)                         | `pr-merge-audit-check.sh`    | The PR's full diff against its merge base with the default branch touches only out-of-scope surfaces: `wiki/`, `.claude/`, `.specify/`, `.gaia/`, `docs/`, root-level markdown. The agent has no rules that apply, so no marker is required. This mirrors `code-review-audit.yml`'s `has_source` skip locally, so the gate clears even when the installed workflow predates the out-of-scope status stamp or CI is absent. Evaluated fail-closed: any in-scope path (`app/`, `test/`, configs, `.github/workflows/`) keeps the marker mandatory, so a PR carrying auditable source can never reach this bypass. |
| Audit-workflow re-render is the only in-scope change (bypass)              | `pr-merge-audit-check.sh`    | The one in-scope path the PR changes is `.github/workflows/code-review-audit.yml` AND its committed bytes are a verbatim re-render of the bundled template (`.gaia/cli/templates/workflows/code-review-audit.yml.tmpl`, proven by git-blob identity: equal blob SHAs mean byte-identical files), with every other changed path out of scope. This is the self-mod-only case `/update-gaia` Step 12 produces: it refreshes a stale audit workflow by copying the release template verbatim. CI self-mod-skips such a PR (no stamp lands), and the out-of-scope bypass above denies because `.github/workflows/` is in scope, so this bypass clears the merge without a ceremonial local re-audit of bytes that are GAIA's own template, not adopter code. Stricter than the out-of-scope bypass and fail-closed: an adopter edit (bytes diverge from the template), a second in-scope path, or an absent template keeps the marker mandatory. |
| `.gaia/local/audit/<tree-sha>.<member>.ok` (earned) or `.carried` (carried) | Specialized Code Audit Team member, or the merge gate itself for a carried clearance | The member writes the `.ok` file on a clean pass, keyed to the same tree sha as the default member's marker (see Marker key below); no CI, trailer, or bypass equivalent produces it. The merge gate mints the `.carried` sibling itself, with no agent spawn, when the member's earlier earned clearance carries forward to HEAD's tree (see [[#Carry-forward]]); either file is this specialized member's clearance signal. |

A non-empty dispatched set means an in-scope file exists, so the out-of-scope bypass above is unreachable there; both bypass rows apply on the zero-match dispatch path only.

<!-- gaia:maintainer-only:start -->
In this repo the roster also claims framework shell and CLI source living under some of the out-of-scope bypass's prefixes: `code-audit-maintainer-shell` owns `.gaia/**/*.sh`, `.claude/hooks/**/*.sh`, `.specify/extensions/gaia/lib/*.sh`, and `.github/**/*.sh`, plus the bats suites guarding that shell (`.gaia/**/*.bats`, `.github/**/*.bats`); `code-audit-maintainer-node` owns `.gaia/cli/src/**`. A diff touching any of those paths dispatches that specialized member, so the dispatched set is non-empty and the out-of-scope bypass is never reached there. A bats-only diff is the case that motivates the bats globs: without them it matched no member, and the bypass cleared it to merge unaudited.
<!-- gaia:maintainer-only:end -->

Tree-sha equality is the load-bearing check for both the trailer and the status: identical trees mean identical content, so an audit on a different commit SHA but the same tree is auditing the same code.

The chore(deps) bypass mirrors the same skip narrowing that `code-review-audit.yml`, `tests.yml`, and `chromatic.yml` apply at CI level. All four surfaces (local hook + three required workflows) release together when a `chore(deps):` or `chore(deps-dev):` PR is recognized, so dep-bump PRs from `/update-deps` are turnkey. The bypass requires `gh` to be installed and authenticated; if either is missing the hook falls through to the normal deny path (the bypass is opt-in proof, not a fallback).

When CI self-heals (the audit modifies a file and pushes the fix), the workflow stamps a `code-review-audit` check run on the new HEAD and dispatches the sibling required workflows (e.g. `Chromatic`, `Tests`) via `workflow_dispatch` so their check runs attach to the new SHA. See [[Code Review Audit CI#Self-heal re-trigger]] for the full mechanism and the `retrigger_workflows` knob.

A clean pass requires no Critical Issues, every Important Issue addressed, and every Suggestion either auto-fixed or resolved by the operator. Those three preconditions govern **in-scope** findings (defects inside the PR's changed line ranges). A **fourth precondition** governs out-of-scope findings: every out-of-scope finding the audit identifies within its review radius must carry a disposition before the marker writes, a filed `tech-debt` issue, a diverted security advisory or operator surface, or a backend-absent waive. The marker is withheld only on a genuinely-missing disposition (a present, writable backend where a filing definitively failed); backend-absent, transient, and diverted findings all fail open. Knip, react-doctor, and dependency-CVE (`pnpm audit`) advisories remain advisory and never block signal emission. See [[Audit Disposition and Debt Fix]] for the full disposition contract.

The deterministic backstop hook `.claude/hooks/audit-disposition-check.sh` gates `gh pr merge` alongside `pr-merge-audit-check.sh`: it re-reads the disposition-ledger sidecar for HEAD and denies only on a present-backend inconsistency (a `filed` entry whose key resolves to no open `tech-debt` issue, or a genuinely-missing disposition), failing open on an absent or transient backend (the never-block invariant). A `/gaia-debt` fix PR is an ordinary in-scope change that clears the normal gate.

If the local agent declines to write the marker, its report names what remains unaddressed; resolve those, commit, push, re-spawn.

#### Re-run carry-forward ledger

On a non-clean pass (no marker written) the audit writes a carry-forward ledger keyed to the incremental base, `.gaia/local/audit/<BASE_SHA>.rerun.json`, where `<BASE_SHA>` is the fork point `git merge-base "$BASE_REF" HEAD` of the base [[Code Review Audit Agent]] resolves for scope. Keying on the base, not HEAD, keeps the filename stable across fix rounds, so remaining work survives the moving HEAD. On a clean pass (marker written) the audit removes the ledger.

The ledger holds in-scope remaining work, the `remaining[]` open findings plus `fixed_last_round[]`, and is a sibling of the `<HEAD>.dispositions.json` sidecar, which holds out-of-scope findings and gates the merge. The two do not overlap and neither reads the other; the ledger never gates anything. `pr-merge-audit-check.sh` reads only `<sha>.ok` and `audit-disposition-check.sh` reads only `<sha>.dispositions.json`, so a `<base>.rerun.json` is invisible to both gates.

The ledger is local-flow-only. In CI each audit runs in a fresh ephemeral job, so it carries cross-round state by git-native means, the `GAIA-Audit` trailer/status (read by `.github/audit/resolve-audit-base.sh`) and the PR-comment findings block, and skips the ledger entirely. See [[Audit Disposition and Debt Fix]].

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

The safe pattern after any `gh pr merge`:

```bash
gh pr merge <N> --squash --delete-branch [--auto]
for i in 1 2 3 4 5; do
  state=$(gh pr view <N> --json state -q .state)
  [ "$state" = "MERGED" ] && break
  sleep 30
done
[ "$state" = "MERGED" ] || { echo "merge did not complete"; exit 1; }
git checkout main && git pull origin main
git branch -D <pr-branch>  # force needed for squash (orphaned commits)
git fetch --prune origin
```

**`--auto` vs `--admin`:** when `gh pr merge` rejects with "base branch policy prohibits the merge", the right escape is `--auto`; it queues the merge and GitHub completes it once checks pass. Never reach for `--admin` to bypass branch protection without explicit permission; it removes the safety the policy exists to provide.

## Local-sync failure mode

When `gh pr merge` exits with `fatal: 'main' is already used by worktree at <path>`, **the GitHub-side merge has already succeeded**. The local checkout step is what failed, not the merge itself. Confirm with:

```
gh pr view <N> --json state
```

If `state == "MERGED"`, do NOT retry the merge. Treat it as merged, run any post-merge steps (wiki-sync, spec-close, etc.), and resolve the local worktree conflict separately. Retrying compounds the problem and can produce a duplicate squash on a non-existent branch.

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

- Never merge without a marker for HEAD from every member the roster dispatches. The hook denies it. Each member's own audit must cover the merged content; CI produces the default member's marker when it audits the PR, otherwise the local `code-audit-frontend` agent does. A specialized member is always local-only, it has no CI producer.
- Never hand-write a marker file to bypass the gate. Each member (local, or for the default member, CI) owns its own marker's emission.
- When CI is not auditing an **in-scope** PR (`.github/workflows/code-review-audit.yml` is absent, Actions disabled, the workflow inactive, or a `gate_label` excludes it), the local `code-audit-frontend` agent is the only way to produce the default member's marker; run it. A PR whose entire diff is out of audit scope needs no marker; the hook's out-of-scope bypass clears it.

See [[Code Review Audit Agent]], [[Quality Gate]], [[Git Workflow]].
