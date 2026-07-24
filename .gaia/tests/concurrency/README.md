# The concurrency meter (INV-7)

This directory is the program's **first published progress number**: the count of
concurrency scenarios that pass. It is one test — two worktrees off the same base
running full audit → PR → merge cycles at the same time — written as a frozen list
of named scenarios and **expected to fail**. Every top-ranked failure the worktree
audit found would be caught here, and no other test in the repo catches any of them.

**It is red by design and does not gate CI yet.** No workflow runs
`.gaia/tests/concurrency/`; it is quarantined by directory omission (the same way
`.gaia/tests/sandbox/` is), exactly as the audit-ci-tests manifest requires. The step
that arms it as a required check is named below. Run it by hand with:

```bash
.gaia/scripts/bats5.sh .gaia/tests/concurrency/
```

Everything in this file is **frozen**. The scenario names and *what each one asserts*
freeze together — freezing only the names would let a scenario be quietly weakened to
improve the number. Any later change to a scenario's assertion is published the way an
added scenario is: visibly, in this file's diff, with a note. Do not weaken an
assertion to make a number move.

---

## How to read the meter

- **The number is `scenarios passing / target`.** `bats` reports the passing count;
  the target is stated below.
- **It reads at every step boundary, not just one.** Each scenario is tagged with the
  **tranche** — the program step whose conversion is meant to turn it green. The meter
  moves at steps 3, 4, 5 and 6, not once at step 4. A tranche going green *early*, or a
  later tranche *never arming*, is itself a signal worth stopping on.
- **Each scenario records its execution model.** `direct` means the contamination is
  observed for real (real linked worktrees, real hooks, real files on disk). `simulated`
  means a fixture stands in for a round-trip CI cannot make (chiefly the GitHub PR/merge
  side). `proxy` means a static, deterministic check stands in for a flow too costly to
  drive live (network + `gh` + multi-agent orchestration), named where it is used.
  **Never read a simulated or proxy green as a live one** — the model is stated so nobody
  can.
- **A scenario is a pass when it asserts isolation *or* a loud refusal.** A main-only
  flow that correctly refuses out loud from a worktree is a pass; demanding it fire would
  be wrong. A *silently* wrong answer is never a pass and is never carved out (see the
  target).

## The target, stated up front

**The isolation claim holds when all 21 scenarios pass.** That is the frozen target.

- **Step-7 carve-out accounting.** The three hard-case scenarios (`C7-*`) are in the
  denominator today. Under the program's step-7 bar each must end **fixed, or refusing
  out loud, or removed from the §1 goal in writing** — the first two are passes, so they
  stay in the target. A scenario leaves the denominator (and the target drops by one)
  **only** if the maintainer writes the §1 clause it guards out of the goal, and that
  subtraction is recorded here visibly when it happens. **A silent wrong answer is never
  a carve-out.** No clause is carved at freeze, so the target is the full 21.
- **The contamination tranche is the central claim.** The six `C4-*` scenarios are the
  ones the whole program exists to turn green. **Step 4 (KEYS)** is where that tranche is
  expected green and where this suite becomes a **required CI check** — added to the
  `audit-ci-tests` bats manifest and kept required forever after (one of the three
  permanent defenses, alongside the resolver-singleton build check and the registry
  conformance check). Until then it must not gate: it is red by design from step 2.
- **Six scenarios are green at freeze — the starting reading is `6 / 21`, and none of the
  six is a landed fix.** Five assert a property that already holds through pre-existing
  machinery and must be *preserved* by their owning phase; one is the designated cutover
  guard. They are named and classified under [Green at freeze](#green-at-freeze) so the
  starting number is never read as six fixes. The scenarios that carry the isolation and
  contamination claims — every `C3-*` and every real `C4-*` — are red, so the meter is
  red where it matters most.

## The second number (named here, tracked elsewhere)

One test cannot measure the whole program: "nothing leaked" cannot register a
notification firing, a creation path, or a *deleted file*, so steps 5, 6 and 8 are
largely invisible to this meter. The **deletion meter** is the second published number
and covers that back half: it is the compensating-code inventory's burn-down —
`items closed / items total` — over the frozen denominator in
`../worktree-program/analysis/inventory-compensating-code.md`, where "closed" means
deleted, or carrying a survival reason that passes the counterfactual. It reads `0 / N`
at step 2 and climbs from step 3 through 8. Deletion is an acceptance criterion, so it
gets its own visible number rather than hiding inside a green isolation test. This file
does not compute it; it names it so the two numbers are declared together, as the meter
design requires.

Between them the two numbers cover all eight steps: this meter from step 2 through its
surface and lifecycle tranches at 5–6, the deletion meter from step 3 through 8.

---

## The scenarios

Each row is one real defect, its owning task, the tranche that turns it green, its
execution model, and — frozen — exactly what it asserts. The `@test` names in the bats
suite match the scenario ids.

### Tranche 3 — CONVERT (green when a surface reads the resolver/registry)

State stays separate when nothing is deliberately colliding. These are wrong-tree /
hand-rolled-derivation defects, not keying collisions.

| id | scenario | exec | owning task | frozen assertion |
|---|---|---|---|---|
| **C3-01** | janitor spares a live peer tree | direct | 3.12 janitor | With two linked worktrees both live off one base, the session-start janitor run from tree A reaps none of tree B's per-tree residue; the `live_trees` set includes every live worktree, and no live tree's state is swept. |
| **C3-02** | write-guard attributes by payload cwd | direct | 3.2 write-guard | A write issued by a subagent in worktree B, delivered with B's payload cwd, is attributed to B's tree (not the hook's process cwd); the guard does not deny a legitimate B write while the main thread is active, and denies a write whose payload cwd names a *different* tree than the target path. |
| **C3-03** | a wrong tree identity is refused, not trusted | direct | 3.2 / 3.5 identity | When the identity signal is made to name a plausible-but-wrong checkout (a well-shaped cwd resolving to a different real checkout), a per-tree writer refuses or writes to the *named* tree — it never silently writes B's state under A's key. Fails if a wrong identity passes as right. (The cluster-D "wrong, not merely absent" guard.) |
| **C3-04** | main-anchored ledgers resolve to main from a worktree | direct | 3.9 ledgers | A SPEC/plan ledger write issued from inside worktree B lands in the main checkout's single ledger, not a forked per-tree copy; the resolver, not `$PWD`, supplies the path. |
| **C3-05** | the project id is one value per clone | direct | 3 consumer conv. | Reading `.project-id` from worktree B yields the main checkout's id, not a second id minted from the worktree's own root path. |

### Tranche 4 — KEYS (the contamination tranche; armed as required CI at step 4)

Two worktrees off the same base, concurrent audits and merges, nothing leaks. This is
the claim the program exists to make verifiable.

| id | scenario | exec | owning task | frozen assertion |
|---|---|---|---|---|
| **C4-01** | findings sidecar isolated across worktrees | direct | 4.1 findings | Two worktrees off one main tip each run an audit that writes a findings sidecar; keyed by base-sha **plus branch**, tree A's findings never overwrite, and never appear in, tree B's sidecar. (Today's base-sha-only key collides — the live-harm defect.) |
| **C4-02** | rerun ledger isolated across worktrees | direct | 4.1 rerun | The rerun ledger written by concurrent audits off one base is partitioned by base-sha plus branch, so one tree's rerun record does not overwrite the other's. |
| **C4-03** | PR-artifact capture is per branch | simulated | 4.2 gh-artifact | With the GitHub PR/merge round-trip stood in by fixtures, the PR-artifact capture is keyed per branch, so tree A's captured artifact is never posted into tree B's PR. Marked simulated: the PR side is GitHub-side and not run live in CI. |
| **C4-04** | worthiness ledger is per tree | direct | 4.3 worthiness | Tree A's worthiness observation is addressed under A's tree key and is neither read nor overwritten by tree B; the ledger is per-tree, matching its RED sibling, not shared under `audit/`. |
| **C4-05** | SPEC/plan locks serialize across worktrees | direct | 4.4 locks | Two worktrees each acquiring the SPEC (or plan) ledger lock, anchored to main, serialize: concurrent number allocations do not both mint the same id, and the second waits rather than racing. |
| **C4-06** | per-tree state survives the cutover *(regression guard, green now)* | direct | 4 cutover | The RED ledger — correctly per-tree today — stays isolated after the single-symlink flip: tree A's RED observation never resolves into main's one path and never blocks tree B's commit. Guards the cutover risk that a not-yet-re-keyed per-tree writer bleeds into main. |

### Tranche 5 — SURFACE (green when a channel fires correctly or refuses out loud)

Classify each channel three ways from inside a worktree: fires correctly, refuses out
loud, or **silently dead**. A machine-scoped nudge firing from every worktree is a
fourth outcome, mis-scoped, and counts as a defect. Pass is 0 silently dead and 0
mis-scoped.

| id | scenario | exec | owning task | frozen assertion |
|---|---|---|---|---|
| **C5-01** | statusline renders the worktree's own segment | direct | 5.1 statusline | Run from worktree B (with B's `workspace.current_dir`), the statusline renders B's per-tree segment and is not blanket-suppressed; the right side is not dark, and no segment shows main's or another tree's state. |
| **C5-02** | wiki hooks are live in a worktree | direct | 5.2 wiki hooks | Each of the four `[ -d .git ]` wiki hooks, fired from inside a worktree, either fires correctly or refuses out loud — none is silently dead (the `[ -d .git ]` guard no longer reads a linked worktree as "no repo"). |
| **C5-03** | main-only flows refuse out loud from a worktree | proxy | 5.3 loud-refusal | A main-only flow (release / audit / wiki) triggered from a worktree refuses out loud with a named reason, rather than running against the wrong tree or dying silently. A correct loud refusal is a pass. **Proxy:** the release/audit/wiki flows are network + `gh` + multi-agent and impractical to drive in a fixture, so this asserts the deciding fact — that a main-only entry point actually consults the resolver's worktree predicate to refuse on — via a static call-site check. Red today (no entry point consults it); flips when task 5.3 adds the refusal. |
| **C5-04** | a machine-scoped nudge is not mis-scoped | direct | 5.3 / 5.4 nudges | A machine-scoped nudge fires once for the machine, not once per worktree; firing from every worktree is the mis-scoped defect and fails the scenario. |

### Tranche 6 — LIFECYCLE (green at harness-native creation + session-start provisioning)

| id | scenario | exec | owning task | frozen assertion |
|---|---|---|---|---|
| **C6-01** | a name collision deletes no peer | direct | 6.1 creation | Creating two worktrees whose names would collide deletes neither peer's worktree; the collision is refused or disambiguated, never resolved by removing an existing tree. The trial that must be answered by trying it, not assumed. |
| **C6-02** | provisioning self-heals on re-entry | direct | 6.2 provisioning | A worktree whose shared-state symlinks are deliberately broken repairs them on the next session start, idempotently, without manual intervention. |
| **C6-03** | generated types are present in a fresh worktree | direct | 6.2 provisioning | A freshly created worktree has its generated build types present and current before first use, not missing or stale. |

### Step-7 carve-out candidates (the hard three)

In the denominator today. Each must end fixed, or refusing out loud, or with its §1
clause written out of the goal — the last of which, and only that, subtracts it from the
target, recorded here when it happens.

| id | scenario | exec | owning task | frozen assertion |
|---|---|---|---|---|
| **C7-01** | Serena answers the acting tree or refuses | simulated | 7.1 Serena | A symbol query issued from worktree B is answered against B's own index, or refuses out loud; it never silently returns a symbol resolved against a different tree. Simulated: the single MCP process is stood in by a fixture. |
| **C7-02** | tests use the acting tree's dependencies | direct | 7.2 node_modules | A test run inside worktree B resolves its dependencies from B's own tree (or a correctly keyed shared store), never silently against main's `node_modules` when they differ. |
| **C7-03** | the wiki state value is not cross-clobbered | direct | 7.3 wiki state | Two worktrees on different branches do not clobber each other's `wiki/.state.json` value; the single-valued sha is keyed, merge-driven, or the store is untracked — never a last-writer-wins race across trees. |

---

## Green at freeze

These six pass today. Each drives real code (or a disclosed stand-in) and asserts a real
property — none is vacuous — but none is a fix this program landed, so the honest starting
reading is `6 / 21`. A green-at-freeze scenario going *red* later is a regression signal,
exactly as a red one going green is progress; its owning phase must **preserve** it.

| id | why it is green at freeze |
|---|---|
| **C4-06** | The designated cutover guard: the RED ledger is genuinely per-tree today (never symlinked), so it is already isolated. It must *stay* isolated across the single-symlink flip. |
| **C5-04** | The debt-count refresher already dedupes across worktrees through its shared, TTL-gated cache, so this machine-scoped nudge is not mis-scoped today. Task 5.3/5.4 must not introduce mis-scoping. |
| **C6-01** | Today's creation refuses to delete a peer it did not create. The Phase-6 move to harness-native creation must preserve that — the trial answered by trying it, not assumed. |
| **C6-02** | The linker already self-heals a broken shared-state symlink on re-run. Phase-6.2 SessionStart provisioning must keep that self-heal. |
| **C6-03** | Creation already invokes typegen for a fresh worktree (driven here through a stand-in CLI at the borrowed binary path). Phase 6.2 must keep generated types present. |
| **C7-03** | On the tracked-file path, git's own three-way merge conflicts on the single scalar rather than silently clobbering. Task 7.3's resolution (keying, merge-driver, or untrack) must not introduce a silent last-writer-wins. |

## Why it is red, and how it goes green

Every scenario drives the **real** GAIA code (or a disclosed `simulated`/`proxy` stand-in
for a side that cannot run in a fixture) and asserts the **target** isolation property, so
it fails today because the defect is live — not because it is stubbed. A scenario must fail
by a clean assertion with a named reason, never by a harness crash — a crash is noise, not
a reading. `skip` is banned in this suite: it reports green, the opposite of red-by-design.

Most `direct` scenarios flip green on their own as their owning task lands its fix, with no
edit here. The **contamination tranche** and the `simulated` scenarios are the exception,
and it is disclosed rather than hidden: they demonstrate the collision against *today's*
on-disk convention (they hand-construct the current key, or stand in the un-runnable side),
because the real fixed writer does not exist yet. **The step that arms this suite as a
required check — step 4 for the `C4-*` tranche — also re-points those scenarios at the
real, fixed writers**, so a green then reflects the writer's new keying, not a hand-built
path. That is a mechanism update, published visibly. The **frozen assertion** (tree A reads
its own state; nothing of tree B's appears) is what may never be weakened to move a number.

## Files

- `README.md` — this file. The frozen meter: scenarios, assertions, tranches, target,
  execution models, the arming step, and the second (deletion) number.
- `concurrency.bats` — the suite. One `@test` per scenario id above; each fails today.
- `lib/concurrency-harness.sh` — the fixture builder: a main checkout plus N linked
  worktrees off one base, seeded `.gaia/local` state, real hooks/scripts/libs copied in
  at their repo-relative paths, and a run-in-tree helper. Sourced by the suite.

## Model

Grounded in the worktree audit's verdict inventory and the three decide-phase artifacts
(the tree-identity rule, the `.gaia/local` state model, and the main-checkout resolver).
The scenario set is the audit's top-ranked cross-contamination failures, one per real
defect, each bound to the phase task that owns its cause.
