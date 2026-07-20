---
type: concept
status: active
created: 2026-04-20
updated: 2026-07-18
tags: [concept, ci, review]
---

# PR Merge Workflow

Mandatory before any `gh pr merge`. Machine-enforced by `.claude/hooks/pr-merge-audit-check.sh`, which denies `gh pr merge` calls until every Code Audit Team member this diff dispatches has its own clearance marker for that member's own current content digest (see [[#Marker key]]).

The gate is **repo-scoped** via `.claude/hooks/lib/repo-scope.sh`: it enforces this repo's audit contract only. A `gh pr merge` positively aimed at a different repo (`-R owner/other`, or `cd <other> &&`) is allowed; this repo's audit markers have no bearing on a sibling repo's merge. Scoping is fail-closed: any ambiguity still enforces.

## Who audits: the dispatched member set

The gate is a roster, not a single agent. `bash .gaia/scripts/resolve-audit-spawn.sh` names the Code Audit Team members this diff owes an audit to, one per line, deduped and sorted, and always exits 0. Empty output carries **two** meanings, and either way it is safe to act on directly with no need to unpack which one applies: either nothing in the diff is auditable and no member is owed, or every dispatched member's own valid current-digest marker is already present, so there is nothing left to spawn. Either way `gh pr merge` proceeds with no further agent dispatch, because the oracle, not the raw dispatch resolver, is what accounts for the in-scope-but-ownerless case the merge gate still blocks on. Every member the oracle still names writes its own clearance (see Marker key below). See [[Code Audit Team]] for the roster and dispatch mechanism.

The `code-audit-frontend` agent's own self-skip calls the oracle with `--no-carry-forward` (the flag's own name; it disables the digest-marker-presence filter and emits the unfiltered dispatch set). Its self-skip must key on "the diff does not dispatch me", never on "I was already cleared": a self-skip that read the filtered output would stand down whenever it happened to already hold a valid marker, disabling the one lever that can catch a stale or wrong filter result, spawning the member for real, whose fresh earned clearance then simply overwrites the old one. A human running the oracle by hand, or any other caller, gets the filtered (digest-marker-aware) output by default. There is no carry-forward clearance machinery behind this flag: it toggles a plain presence check, not an anchor-selection or minting step.

## Marker-first: check before you audit

The hook requires a **clearance to exist** for each dispatched member's own content, not that you personally run the audit. `code-audit-frontend`'s clearance comes from one of two producers: CI (`code-review-audit.yml` stamps the `GAIA-Audit` status) or the local `code-audit-frontend` agent (writes `.gaia/local/audit/<frontend-digest>.ok` through the one shared clearance writer, stamps a `GAIA-Audit:` trailer, and posts a `GAIA-Audit` success status). Which producer runs is a **per-author mode**, `ci` or `local`, resolved by the shared helper both sides call identically:

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

<!-- gaia:maintainer-only:start -->
When this PR newly ships files, run `/distribution-audit` and land its manifest-answer commit first, before this step. The manifest answer commits `.gaia/manifest.json` and any `.gaia/release-exclude` change; neither path is an audit-machinery digest input nor a reviewed member surface, so the commit rotates no member's content digest and invalidates no marker already earned. It does move HEAD, and the `GAIA-Audit` commit status is keyed to HEAD's sha, so a manifest commit that lands after the handshake strands the just-posted status on the old HEAD and forces an extra status re-post on the new one. Landing the distribution-audit answer first keeps HEAD stable through the handshake, so the status posts once and stays put.
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
    prompt: "Working root: <RESOLVED_ROOT>, the absolute path of the checkout under review; the orchestrator substitutes the value it resolved from the isolation reference at dispatch time. Expected HEAD tree: <EXPECTED_TREE>, the tree captured immediately before this dispatch wave.
    MANDATORY FIRST ACTION, before any review: run `git -C <RESOLVED_ROOT> rev-parse HEAD^{tree}` and compare it to <EXPECTED_TREE>. If that command errors (missing path, git unavailable) OR the value does not match exactly, STOP, do not review, do not write a marker, and return only the mismatch or error as your entire output.
    Only on an exact match, review all changes in <RESOLVED_ROOT>'s current branch compared to main, scoping every git command to `git -C <RESOLVED_ROOT>`. Identify security vulnerabilities, performance issues, code smells, anti-patterns, and refactoring opportunities."
  )
  ```

- **No names** → empty output means either of two different things, and either way it is safe to act on with no further spawn: no changed file is auditable, so no marker is owed, or every dispatched member's own valid current-digest marker is already present, so nothing is left to spawn. Either way `gh pr merge` clears with no audit spawn, *because* the answer came from the oracle: the oracle, not the raw dispatch resolver, is what accounts for the in-scope-but-ownerless case the merge gate still blocks on.

- **The oracle is absent** (an older checkout, an interrupted install) → fall back to `bash .gaia/scripts/resolve-audit-members.sh`, and treat an EMPTY result as "spawn `code-audit-frontend`" (fail-closed). Never treat an unanswerable question as "nothing owed".

Skip a spawn for a member already cleared: its current-digest marker exists, or (for the default member) one of the bypass signals in the marker-handshake table already applies to this PR. The spawn set names who *can* be required, not who is still outstanding.

On a clean pass each member writes its own marker and calls `post-audit-status.sh`. The merge deny-hook requires **every** dispatched member's marker, so one member withholding holds the gate shut for all. If a member declines to write its marker, its report names what remains unaddressed; resolve those, commit, push (HEAD moves), then re-spawn the pending members on the new HEAD. A member that cleared a previous round must be re-spawned too whenever its own owned-plus-machinery content changed since: its marker is keyed to its own content digest, and a commit that touches a path it owns, or any gate-machinery path, rotates that digest. A commit that touches nothing a given member owns and no machinery leaves that member's digest, and its marker, valid, no re-spawn needed. Never hand-write a marker to bypass the gate.

#### Parallel dispatch

Markers are keyed to each member's own content digest, so members are order-independent (see [[#Marker key]]). **Dispatch every member in parallel, in any order.** A self-heal edits the working tree and stops there, it makes no commit and no push; the orchestrator commits once after every dispatched member has returned, so the contended resource is the git index and the remote, never the files themselves. Per-member content-digest keying means an owned-file change rotates only that member's digest: there is no working-tree race between members and no wave to sequence.

`code-audit-frontend`'s **trailer stamp** is an empty commit: it advances HEAD and leaves every blob byte-identical, so it rotates no member's digest, including its siblings'. A **self-heal is a real content edit**, ordinarily confined to files `code-audit-frontend` itself owns, so under digest keying it rotates only its own digest; a self-heal that happens to touch a gate-machinery path rotates *every* member's digest, correctly invalidating a sibling's in-flight marker, because a machinery change is exactly the case the machinery guard exists to force a re-review on.

#### The repair boundary

A member's self-heal is confined by a **deterministic gate**, not by an instruction alone, on whichever producer runs the audit. Both producers read one sourced refusal set (`.claude/hooks/lib/audit-selfheal-paths.sh`) naming the paths no member may edit: the instruction/convention surfaces (`.claude/`, `.specify/`, `wiki/`), `test/**`, the rest of `.gaia/**`, `.github/workflows/**`, and the root package/build/lint config the default member's own glob list already covers (`package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `tsconfig*.json`, `*.config.*`).

- **CI** enforces it at push time: the self-heal step's `run:` body checks the staged diff against the refusal set before committing.
- **Local** enforces it at edit time: a `PreToolUse` hook (`.claude/hooks/block-selfheal-paths.sh`) denies a matching edit the moment a dispatched Code Audit Team member (an `agent_type` carrying the `code-audit-` prefix) attempts it.

Be accurate about two honest limits rather than assuming parity between the two enforcement points. The local hook covers a member's edit tools plus the well-known Bash write shapes (`>`, `>>`, `tee`, `sponge`, `sed -i`, a `cp`/`mv` destination) and is best-effort against an unbounded Bash vector (`dd`, `install`, a subshell or `eval`, a heredoc to an arbitrary file descriptor), the same posture `block-manifest-write.sh` already takes; it also binds only members named with the `code-audit-` prefix, so a member named off-convention escapes it. CI's push gate reads the whole diff at push time and cannot be evaded by the shape of the write. **The orchestrator itself is not bound by either gate**: it is trusted rather than bounded (see Cross-remit findings below), because this same protocol's own execution routinely edits `.gaia/**`, `test/**`, and `.github/workflows/**`, and a hook that refused those paths unconditionally would deny its own commits.

#### No-op detection and retry for each dispatched member

A dispatched member can silently no-op: zero tool uses, a return that is just a harness-reminder-echo or output-style fragment instead of a real review. Nothing about the marker gate catches this on its own, fail-closed means no marker and no merge, but with no diagnosis of *why* the gate is stuck, just a stuck gate a human has to notice and investigate by hand. This mirrors, one layer up, the same deterministic classifier `code-audit-frontend` already runs on its own internal specialist and refuter fan-outs (`.claude/agents/code-audit-frontend.md`, "No-op detection and retry for each refuter").

This classifier reads the member's returned text, which reaches the orchestrator only because the dispatch above is synchronous (`run_in_background: false`). A backgrounded member routes no text back, so there is nothing to classify and this whole guard is inert. After each dispatched member's `Agent` call returns, write its returned text to a temp file and classify it:

```bash
bash .gaia/scripts/audit-noop-detect.sh --shape audit-team-member --path <tempfile> --marker <expected-marker-path>
```

`<expected-marker-path>` is `.gaia/local/audit/<frontend-digest>.ok` for `code-audit-frontend`, `.gaia/local/audit/<digest>.<member>.ok` for a specialized member, the same marker key each member's own gate handshake writes (see Signals below). Exit 0 = real, exit 1 = no-op. A dispatch that already wrote its marker, or whose return carries a backticked `` `path:line` `` finding location, or (for `code-audit-frontend`'s terse LOCAL return) the literal `Remaining in-scope:` preamble, is real; a return matching none of those, most often a bare harness-reminder / available-agent-types echo, is a no-op.

On a no-op, re-dispatch that member **exactly one** time with the hardened retry prefix (`.claude/agents/code-audit-frontend.md`, "No-op detection and retry for each refuter"), substituting the concrete target with the member's original changed-file list. A second consecutive no-op does not re-dispatch a third time: stop and surface to the operator which member no-op'd twice, rather than looping or silently proceeding to a merge attempt. The marker gate stays fail-closed either way, no marker still means no merge, but a surfaced double no-op tells the operator why the gate is stuck instead of leaving them to notice an odd reply on their own.

### 2. Fix all issues

The local fix loop reads the re-run carry-forward ledger (`.gaia/local/audit/<BASE_SHA>.rerun.json`) for a deterministic, lossless briefing rather than a main-thread-authored prompt summary: the fixer reads `remaining[]` for what to fix and `fixed_last_round[]` for what the previous round already cleared, and the next re-audit reads the same ledger. The filename keys on the incremental base, which is stable across fix rounds, so the path does not change as HEAD moves. Fail-open: when the ledger is absent, corrupt, or stale (a different branch or base), the loop falls back to the full report in the audit's return, which the agent emits whenever it could not write the ledger.

- Fix every Critical Issue, every Important Issue, and every Suggestion the audit identifies.
- If a Suggestion involves an architectural tradeoff, breaking change, or conflicting convention, the agent escalates it with documented rationale rather than auto-fixing; the operator must resolve the escalation before the marker is written.
- Re-run linting and type checking after fixes.
- Stage, commit, and push the fixes; HEAD must move so the next audit runs against the fixed tree.
- Re-spawn the audit agent on the new HEAD until it reports clean.

#### Cross-remit findings

A member can find a genuine defect in a file outside its own declared domain, a **cross-remit finding**. The member that found it applies no repair, whether or not the file's owner has already cleared it and whether or not the fix looks trivial; it reports the finding to the orchestrator instead. The orchestrator disposes of it one of two ways:

- **In scope for the PR** → the orchestrator applies the repair itself. Its commit rotates the owning member's digest, invalidating that member's marker, so the owner is re-dispatched and reviews the repair made to its own file.
- **Out of scope** → filed as a tech-debt issue (see `/gaia-debt` and the `file-tech-debt` skill), and the PR carries no change for it.

Either way the finding is **recorded rather than lost**.

The orchestrator is trusted rather than bounded here, and this is a member-error guard, not a security boundary: it removes members' write access to files outside their own domain and hands that same access to the orchestrator. What makes that reasonable is stated rather than assumed: under local mode a human watches every turn the orchestrator takes, which is not true of a member dispatched inside a CI job. A bad orchestrator repair is caught by human review of the pull request and by nothing else.

### 3. Marker handshake

#### Marker key

Every clearance is written by the **one shared writer** (`.gaia/scripts/audit-write-clearance.sh`); no member hand-writes a marker file. Given the audited root, the writer derives the member's **content digest**, a sha256 over exactly the files that member owns plus the shared gate machinery (plus the in-scope-but-ownerless paths, for the default member; see [[Code Audit Team#Ownership classifier]]), through the digest engine (`.claude/hooks/lib/audit-digest.sh`), resolves HEAD's real tree and commit sha as plain data fields, then writes the body atomically. The body carries a version, `schema: 3`, the audited `member`, a `provenance` (`earned` or `refused` only, there is no carried family), the `digest` (the validity key), `tree` and `sha` (data only, used by the janitor's live-tree keep-arm, never compared for validity), `audited_at`, and `sidecar` (true only for the default member, the sole sidecar filer). The gate's reader (`clearance_acceptable`) accepts a clearance only when it is **well-formed**: the body parses, its recorded `digest` matches the filename key, its `member` matches, and its `provenance` is `earned`; a file that exists but fails that check is neither cleared nor missing, the gate reports it as present but invalid and asks for a re-run. This is a well-formedness check, not an authenticity one, it raises the bar a hand-written marker has to clear; it does not by itself prove who wrote a given file. `jq` is required for every digest-keyed predicate; with `jq` absent every check returns false (fail-closed), it never degrades to a bare-existence match.

Provenance gets its own filename, not just a body field:

| Provenance | Default member | Specialized member `<m>` | Meaning |
| --- | --- | --- | --- |
| earned | `<digest>.ok` | `<digest>.<m>.ok` | the member audited this exact content and cleared it |
| refused | `<digest>.refused` | `<digest>.<m>.refused` | the member audited this exact content and withheld its clearance |

Every write lands unconditionally: it overwrites a stale body at the same path. There is no create-only guard and no carried family to dominate; provenance is earned or refused only.

Marker files are named for the member's own **content digest**, not HEAD's tree and not its commit sha. The digest engine enumerates every tracked file at HEAD (`git -C <root> ls-tree -z -r HEAD`, NUL-delimited so no path name can shift the hash input), the ownership classifier and machinery matcher select exactly the member's set (`owned(member) ∪ machinery`, plus in-scope-but-ownerless for the default member), and the selected `<mode> <blob-sha> <path>` records are sorted and sha256'd behind a fixed recipe-version sentinel. Content-addressing falls out of the blob sha, so byte-identical content yields an identical digest regardless of what else in the repo changed; mode catches an exec-bit flip, path catches a rename. A marker attests that a Code Audit Team member reviewed **the content its own digest covers**, never the whole tree.

The digest key is what makes the team's markers order-independent, and it is far narrower than the whole-tree key it replaced: an unrelated or out-of-glob change (a CHANGELOG line, a wiki edit) rotates **no** member's digest at all, so every existing marker keeps validating with zero re-dispatch. `code-audit-frontend` stamps the `GAIA-Audit:` trailer, and on an already-pushed HEAD that stamp lands as an **empty commit**: it advances HEAD while leaving every blob byte-identical, so it rotates no member's digest either. Each member writes its marker whenever it finishes; the members can run in parallel and the stamp changes nothing.

The key does not weaken the gate. A change to a file a member owns rotates only that member's digest, correctly forcing a re-audit of exactly the member whose content changed. A change to any gate-machinery file, anything whose bytes can change what a member reviews, who reviews it, where a clearance lands, or whether a clearance is believed, rotates **every** member's digest, since the machinery path set sits inside every member's input set by construction; this also closes the classifier-version skew hazard, since the classifier's own files are themselves machinery. See [[#Parallel dispatch]] for how this plays out when `code-audit-frontend` self-heals mid-dispatch.

Three artifacts under `.gaia/local/audit/` key differently from a member's own marker, because their readers resolve identity at a different point than a content digest: the disposition sidecar (`<frontend-digest>.dispositions.json`, keyed to the **frontend member's own content digest**, valid iff the frontend earned marker for that digest is valid; see [[#Out-of-scope dispositions]] below), the re-run carry-forward ledger (`<base-sha>.rerun.json`, keyed to the incremental base commit, an in-scope fix-loop briefing that never gates a merge; see [[Code Review Audit Agent#Re-run carry-forward ledger]]), and the per-member findings sidecar (`<base-sha>.<member>.findings.json`, one per dispatched member, also keyed to the incremental base; see [[#Findings block]] below). The ledger and the findings sidecar share a base-sha key but feed different consumers: the ledger briefs the **fix loop** (what remains, what the last round already fixed), the findings sidecar feeds the **posted findings block**, one array of every dispatched member's findings regardless of whether the pass was clean. `local-janitor.sh` sweeps every key family out of one directory, each by its own liveness rule; see [[Local Working State]].

#### Skipping already-cleared members

There is no carry-forward clearance machinery: no anchor selection, no delta computation, no minting step, and no `.carried` marker family. A member not already cleared for its own current digest simply gets re-dispatched; the digest key itself is what shrinks how often that happens, since an out-of-glob change never rotates it and only an owned-file or machinery change does.

The dispatch-side benefit the old carry-forward `cf_filter` used to deliver still exists, delivered more simply: `resolve-audit-spawn.sh` drops a member from the spawn set whenever its own valid current-digest marker is already present, a plain presence check against the shared clearance reader (`clearance_member_cleared`), with no anchor selection and no ancestry walk. This is a pure query, it mints nothing; a member the resolver skips still has to hold a genuinely valid marker for its own current digest at merge time, or the gate denies regardless of what the spawn oracle said. See [[#Who audits: the dispatched member set]] for the `--no-carry-forward` flag that disables this filter.

A **refusal** is a first-class artifact keyed the same way as an earned marker (`<digest>[.<member>].refused`), the only way a member records "I read this exact content and I withhold." The gate checks the refusal family before the earned family and treats a live refusal of the current digest as absolute: no earned marker for the same digest, however clean, ever overrides it.

#### Signals

The hook (`pr-merge-audit-check.sh`) accepts any one of three signals that prove the **default member's** audit ran clean against the content being merged, plus three bypasses. Two of the three bypasses (out-of-scope, `chore(deps)`) waive only the default member's signal; the third, the audit-workflow re-render bypass, proves a property of the PR rather than of one member, so it can also clear a specialized member's own marker requirement (see its row below). A specialized member's own marker is otherwise a separate, mandatory signal the hook additionally requires whenever the roster dispatches that member:

| Signal                                                                    | Source                       | How it gets there                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------------------------------------------------- | ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.gaia/local/audit/<frontend-digest>.ok` (earned)                        | Local audit agent            | Agent writes the `.ok` file on a clean pass, keyed to its own current content digest (see Marker key above).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `GAIA-Audit:` commit-message trailer on HEAD                              | Local audit agent            | `audit-stamp-trailer.sh` writes an empty commit with the trailer                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `GAIA-Audit` GitHub commit status on HEAD, `state: success`, description `<version> <frontend-digest> <tree>` | CI (`code-review-audit.yml`) or the local audit agent | CI stamps this after a full audit (on the audit SHA) and on HEAD when the un-audited delta is entirely out of audit scope. The local agent posts the same `state: success` status after it writes the marker, gated on the marker existing first (`post-audit-status.sh`), so a `local`-mode merge clears the github.com button too; when `gh` is unauthenticated the marker still clears the Claude path while the button stays blocked. The status is a commit-status POST on HEAD's existing sha, not a commit, so the button clears without the status path adding to history. (The trailer signal in the row above is what carries the marker in a commit: on an already-pushed HEAD it rides an empty `chore: code review audit passed` commit, since published history is never amended.) Every reader requires `state == success`: a `pending` status (the CI local-mode stand-down) carrying HEAD's version+digest is never treated as cleared. The description is always the fixed three-field shape; field 2 is the frontend digest (the compared validity key), field 3 is the tree (data only, never compared).                                                                                                                                                                                                                                                                                                                                                                                                     |
| PR title matches `^chore\(deps(-dev)?\):` (bypass)                        | `/update-deps` wrapper       | Wrapper opens dep-bump PRs with the canonical prefix; the local quality gate stands in for the audit signal. On a `main`/`master` run the skill also merges the PR itself once required checks are green (`gh pr merge --auto`), verifies the terminal `MERGED` state, and cleans up the local branch; on any other branch it pushes and leaves the PR to the branch owner.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Every changed file is out of audit scope (bypass)                         | `pr-merge-audit-check.sh`    | The PR's full diff against its merge base with the default branch touches only out-of-scope surfaces: `wiki/`, `.claude/`, `.specify/`, `.gaia/`, `docs/`, root-level markdown. The agent has no rules that apply, so no marker is required. This mirrors `code-review-audit.yml`'s `has_source` skip locally, so the gate clears even when the installed workflow predates the out-of-scope status stamp or CI is absent. Evaluated fail-closed: any in-scope path (`app/`, `test/`, configs, `.github/workflows/`) keeps the marker mandatory, so a PR carrying auditable source can never reach this bypass. |
| Audit-workflow re-render is the only in-scope change (bypass)              | `pr-merge-audit-check.sh`    | The one in-scope path the PR changes is `.github/workflows/code-review-audit.yml` AND its committed bytes are a verbatim re-render of the bundled template (`.gaia/cli/templates/workflows/code-review-audit.yml.tmpl`, proven by git-blob identity: equal blob SHAs mean byte-identical files), with every other changed path out of scope. This is the self-mod-only case `/update-gaia` Step 12 produces: it refreshes a stale audit workflow by copying the release template verbatim. CI self-mod-skips such a PR (no stamp lands), and the out-of-scope bypass above denies because `.github/workflows/` is in scope, so this bypass clears the merge without a ceremonial local re-audit of bytes that are GAIA's own template, not adopter code. **Member-agnostic**: the predicate proves a property of the PR (the sole in-scope change is the pinned artifact), not of one member, so it is resolved once per run and clears **any** dispatched member with no earned marker of its own, not only the default member. A live refusal for a member's current digest is checked first and stays absolute, overriding the bypass either way. Stricter than the out-of-scope bypass and fail-closed: an adopter edit (bytes diverge from the template), a second in-scope path, or an absent template keeps every dispatched member's marker mandatory. |
| `.gaia/local/audit/<digest>.<member>.ok` (earned)                         | Specialized Code Audit Team member | The member writes the `.ok` file on a clean pass, keyed to its own current content digest, the files it owns plus the shared gate machinery (see Marker key above); no CI, trailer, or bypass equivalent produces it. |

A non-empty dispatched set means an in-scope file exists, so the out-of-scope bypass above is unreachable there; both bypass rows apply on the zero-match dispatch path only.

<!-- gaia:maintainer-only:start -->
In this repo the roster also claims framework shell, CLI source, and the live GitHub Actions workflow and action YAML living under some of the out-of-scope bypass's prefixes (`.github/**`, `.gaia/**`); see [[Code Audit Team]] for the full per-member glob table. A diff touching any of those paths dispatches the owning specialized member, so the dispatched set is non-empty and the out-of-scope bypass is never reached there. A bats-only diff is the case that motivates the bats globs on the shell member: without them it matched no member, and the bypass cleared it to merge unaudited.
<!-- gaia:maintainer-only:end -->

Frontend-digest equality is the load-bearing check for both the trailer and the status: identical digests mean identical owned-plus-machinery content, so an audit on a different commit SHA but the same digest is auditing the same code.

The chore(deps) bypass mirrors the same skip narrowing that `code-review-audit.yml`, `tests.yml`, and `chromatic.yml` apply at CI level. All four surfaces (local hook + three required workflows) release together when a `chore(deps):` or `chore(deps-dev):` PR is recognized, so dep-bump PRs from `/update-deps` are turnkey. The bypass requires `gh` to be installed and authenticated; if either is missing the hook falls through to the normal deny path (the bypass is opt-in proof, not a fallback).

When CI self-heals (the audit modifies a file and pushes the fix), the workflow stamps a `code-review-audit` check run on the new HEAD and dispatches the sibling required workflows (e.g. `Chromatic`, `Tests`) via `workflow_dispatch` so their check runs attach to the new SHA. See [[Code Review Audit CI#Self-heal re-trigger]] for the full mechanism and the `retrigger_workflows` knob.

A clean pass requires no Critical Issues, every Important Issue addressed, and every Suggestion either auto-fixed or resolved by the operator. Those three preconditions govern **in-scope** findings (defects inside the PR's changed line ranges). A **fourth precondition** governs out-of-scope findings: every out-of-scope finding the audit identifies within its review radius must carry a disposition before the marker writes, a filed `tech-debt` issue, a diverted security advisory or operator surface, or a backend-absent waive. The marker is withheld only on a genuinely-missing disposition (a present, writable backend where a filing definitively failed); backend-absent, transient, and diverted findings all fail open. Knip, react-doctor, and dependency-CVE (`pnpm audit`) advisories remain advisory and never block signal emission. See [[Audit Disposition and Debt Fix]] for the full disposition contract.

The deterministic backstop hook `.claude/hooks/audit-disposition-check.sh` gates `gh pr merge` alongside `pr-merge-audit-check.sh`: it re-reads the disposition-ledger sidecar for the current frontend digest and denies on a present-backend inconsistency (a `filed` entry whose key resolves to no open `tech-debt` issue, or a genuinely-missing disposition) or on a valid frontend marker whose sidecar is absent, failing open on an absent or transient backend (the never-block invariant). A `/gaia-debt` fix PR is an ordinary in-scope change that clears the normal gate.

If the local agent declines to write the marker, its report names what remains unaddressed; resolve those, commit, push, re-spawn.

#### Re-run carry-forward ledger

On a non-clean pass (no marker written) the audit writes a carry-forward ledger keyed to the incremental base, `.gaia/local/audit/<BASE_SHA>.rerun.json`, where `<BASE_SHA>` is the fork point `git merge-base "$BASE_REF" HEAD` of the base [[Code Review Audit Agent]] resolves for scope. Keying on the base, not HEAD, keeps the filename stable across fix rounds, so remaining work survives the moving HEAD. On a clean pass (marker written) the audit removes the ledger.

The ledger holds in-scope remaining work, the `remaining[]` open findings plus `fixed_last_round[]`, and is a sibling of the `<frontend-digest>.dispositions.json` sidecar, which holds out-of-scope findings and gates the merge. The two do not overlap and neither reads the other; the ledger never gates anything. `pr-merge-audit-check.sh` reads only `<digest>.ok` and `audit-disposition-check.sh` reads only `<frontend-digest>.dispositions.json`, so a `<base>.rerun.json` is invisible to both gates.

The ledger is local-flow-only. In CI each audit runs in a fresh ephemeral job, so it carries cross-round state by git-native means, the `GAIA-Audit` trailer/status (read by `.github/audit/resolve-audit-base.sh`) and the PR-comment findings block, and skips the ledger entirely. A separate per-member findings sidecar shares the ledger's base-sha key but is a different artifact feeding a different consumer; see [[#Marker key]] for how the two are distinguished. See [[Audit Disposition and Debt Fix]].

#### Findings block

The PreToolUse hook `post-findings-block-on-merge.sh` posts one consolidated findings block to the PR on every `gh pr merge` invocation whose resolved audit mode is `local`, deterministically, no hand-run step required. It resolves the incremental audit base the same way the audited member(s) do and calls the existing producer:

```bash
BASE_REF="$(.github/audit/resolve-audit-base.sh)"
BASE_SHA="$(git merge-base "${BASE_REF}" HEAD 2>/dev/null || true)"
if [ -n "$BASE_SHA" ]; then
  bash .gaia/scripts/post-findings-block.sh --base "$BASE_SHA" --pr <N>
fi
```

`post-findings-block.sh` reads every dispatched member's own findings sidecar under the resolved base, merges every member's `findings[]` into one array, and posts-or-updates exactly one PR comment carrying the merged block: it locates an existing comment by its sentinel and edits it, creating one only when none exists. The hook's `resolved_mode=local` guard is load-bearing, not defensive dressing: CI's own workflow prompt already emits its own findings block, and posting unconditionally would overwrite it with one carrying only the locally-dispatched members' findings, losing CI's. The one-producer invariant makes that overwrite unreachable under `local`, the default; it does not make it unreachable under `ci`, which a fork PR still resolves to, so the condition, not the invariant alone, is what keeps the two producers' blocks from colliding on that path. Running the snippet above by hand stays harmless (`post-findings-block.sh` is idempotent), but the hook makes it unnecessary.

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

An agent driving the merge in-session removes its own worktree with the runtime's `ExitWorktree({action: "remove", discard_changes: true})`, gated on the confirmed `MERGED` state; `discard_changes` is safe there for the same reason `--force` is here. From a context that cannot call it, a fresh session or a sub-agent with a pinned working directory, the shell sequence above is the session-independent equivalent. See [[Audit Disposition and Debt Fix]].

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
