# The concurrency meter (INV-7)

This directory is the program's **first published progress number**: the count of
concurrency scenarios that pass. It is one test — two worktrees off the same base
running full audit → PR → merge cycles at the same time — written as a frozen list
of named scenarios and **expected to fail**. Every top-ranked failure the worktree
audit found would be caught here, and no other test in the repo catches any of them.

**It is red by design, and as of step 4 it gates CI anyway.** Those two are not in
tension, and reconciling them is the whole of the arming design: the already-required
`Audit CI Tests` check runs the **whole** suite through `meter-gate.sh`, which
adjudicates every scenario against `expected-status.txt` and fails the build on a
deviation **in either direction**. An expected-pass going red is a regression. An
expected-red going **green** fails too, deliberately, because an advance absorbed into
a silent green is an advance nobody recorded. So the scenarios that are red by design
gate nothing, while still counting in the reading, and no scenario is filtered out of
the suite to achieve that. See
[Armed as a required CI check](#armed-as-a-required-ci-check).

Run the gate the way CI runs it:

```bash
bash .gaia/tests/concurrency/meter-gate.sh
```

Or read the raw suite by hand, without the adjudication:

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
- **One number, always.** A scenario that goes green because its assertion was repaired
  counts as passing, exactly like one turned by a fix; there is no second "fixed" count
  running alongside. The distinction is not lost, it lives in
  [Published assertion changes](#published-assertion-changes), which is written at the
  moment an assertion moves and so is never reconstructed afterwards. That section is the
  whole safeguard on this number: a repair published nowhere is the one way the reading
  can mislead.

## The target, stated up front

**The isolation claim holds when all 22 scenarios pass.** That is the frozen target.

**The target rose from 21 to 22, by the maintainer's decision, and that is the only way it may
move upward.** A real cross-tree defect was found that no scenario could see (`C4-07`, the
commit gate's inverse harm), so the instrument grew to cover it rather than the defect being
left outside the number. Published here the way any added scenario is; the reasoning is in
[Published assertion changes](#published-assertion-changes). A target that never grows when
something is found is a target that rewards not looking.

- **Step-7 carve-out accounting.** The three hard-case scenarios (`C7-*`) are in the
  denominator today. Under the program's step-7 bar each must end **fixed, or refusing
  out loud, or removed from the §1 goal in writing** — the first two are passes, so they
  stay in the target. A scenario leaves the denominator (and the target drops by one)
  **only** if the maintainer writes the §1 clause it guards out of the goal, and that
  subtraction is recorded here visibly when it happens. **A silent wrong answer is never
  a carve-out.** No clause is carved, so the target is the full 22.
- **The contamination tranche is the central claim.** The `C4-*` scenarios are the ones the
  whole program exists to turn green; there are **seven**, the seventh added after the
  tranche was first read green. It passes too, so the reading was not disturbed and the
  tranche's claim now stands against a strictly larger set than the one it was first made
  against. **Step 4 (KEYS)** is where that tranche is
  expected green and where this suite becomes a **required CI check** — added to the
  `audit-ci-tests` bats manifest and kept required forever after (one of the three
  permanent defenses, alongside the resolver-singleton build check and the registry
  conformance check). **Done: it is armed.** See
  [Armed as a required CI check](#armed-as-a-required-ci-check).
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

## What this meter cannot see: the shell an agent actually uses

Every scenario here runs under bats, which runs under bash. Some of what GAIA ships is
not invoked that way: a hook registered in `.claude/settings.json` runs as
`bash <script>`, but a markdown block an agent executes through its shell tool runs
under that machine's login shell, which on a stock Mac is zsh. A green row therefore
says nothing about whether the same code works where an agent runs it.

This is not hypothetical. `C5-03` drove the real main-only refusal from a real worktree
and was green while all three of those flows failed to refuse at all under zsh, because
the helper they source used `BASH_SOURCE` and `declare -F`, which mean nothing and
something wrong there respectively. Milestone 5's own gate — a sweep that fires each
channel rather than running this suite — is what found it. Where a surface is invoked
through an agent's shell, its conformance suite carries the shell-specific case
(`.gaia/scripts/tests/main-only-lib.bats` does), because this meter structurally cannot.

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
| **C3-03** | tree identity is the payload cwd, and the target is judged against it | direct | 3.2 / 3.10 identity | The acting tree is the tree the payload cwd *names*, whenever that cwd is absolute and resolves to a checkout, and the write is adjudicated against **that** tree: a target inside the named tree is allowed, and a target in any other tree — including the one the hook process itself sits in — is denied. An unusable payload cwd (relative, or absolute but not a checkout) falls back to the process cwd and the guard stays live against it rather than going inert. An identity that cannot be determined at all allows the write, emitting no decision (fail-open, defense-in-depth), never blocks it. (Assertion rewritten — see [Published assertion changes](#published-assertion-changes).) |
| **C3-04** | main-anchored ledgers resolve to main from a worktree | direct | 3.9 ledgers | A SPEC/plan ledger write issued from inside worktree B lands in the main checkout's single ledger, not a forked per-tree copy; the resolver, not `$PWD`, supplies the path. |
| **C3-05** | the project id is one value per clone | direct | 3 consumer conv. | Reading `.project-id` from worktree B yields the main checkout's id, not a second id minted from the worktree's own root path. |

### Tranche 4 — KEYS (the contamination tranche; armed as required CI at step 4)

Two worktrees off the same base, concurrent audits and merges, nothing leaks. This is
the claim the program exists to make verifiable.

| id | scenario | exec | owning task | frozen assertion |
|---|---|---|---|---|
| **C4-01** | findings sidecar isolated across worktrees | direct | 4.1 findings | Two worktrees off one main tip each run an audit that writes a findings sidecar; keyed by base-sha **plus branch**, tree A's findings never overwrite, and never appear in, tree B's sidecar. (Today's base-sha-only key collides — the live-harm defect.) (Mechanism re-pointed at the shipped writer — see [Published assertion changes](#published-assertion-changes).) |
| **C4-02** | rerun ledger isolated across worktrees | direct | 4.1 rerun | The rerun ledger written by concurrent audits off one base is partitioned by base-sha plus branch, so one tree's rerun record does not overwrite the other's. (Mechanism re-pointed at the shipped writer — see [Published assertion changes](#published-assertion-changes).) |
| **C4-03** | PR-artifact capture is per branch | simulated | 4.2 gh-artifact | With the GitHub PR/merge round-trip stood in by fixtures, the PR-artifact capture is keyed per branch, so tree A's captured artifact is never posted into tree B's PR. Marked simulated: the PR side is GitHub-side and not run live in CI. |
| **C4-04** | worthiness ledger is per tree | direct | 4.3 worthiness | Tree A's worthiness observation is addressed under A's tree key and is neither read nor overwritten by tree B; the ledger is per-tree, matching its RED sibling, not shared under `audit/`. |
| **C4-05** | SPEC/plan locks serialize across worktrees | direct | 4.4 locks | Two worktrees each acquiring the SPEC (or plan) ledger lock, anchored to main, serialize: concurrent number allocations do not both mint the same id, and the second waits rather than racing. |
| **C4-06** | per-tree state survives the cutover *(regression guard, green now)* | direct | 4 cutover | The RED ledger — correctly per-tree today — stays isolated after the single-symlink flip: tree A's RED observation never resolves into main's one path and never blocks tree B's commit. Guards the cutover risk that a not-yet-re-keyed per-tree writer bleeds into main. (Mechanism made real, and one clause named as not measured; see [Published assertion changes](#published-assertion-changes).) |
| **C4-07** | one tree's RED never satisfies another tree's commit gate *(cutover guard, green now)* | direct | 4 cutover | Tree A's observed failing run for a test never satisfies tree B's TDD commit gate for that same test. With the identical new test staged in both trees, the real gate **allows** the commit in the tree that recorded the RED and **denies** it in the tree that did not; recording B's own RED then flips B to allow, so the deny is attributable to the missing per-tree observation and to nothing else. Guards the *inverse* of `C4-06`'s clause: the harm that wrongly **clears** a peer's gate, which an appending ledger writer makes invisible to any blocking-shaped assertion. (Added scenario — see [Published assertion changes](#published-assertion-changes).) |

### Tranche 5 — SURFACE (green when a channel fires correctly or refuses out loud)

Classify each channel three ways from inside a worktree: fires correctly, refuses out
loud, or **silently dead**. A machine-scoped nudge firing from every worktree is a
fourth outcome, mis-scoped, and counts as a defect. Pass is 0 silently dead and 0
mis-scoped.

| id | scenario | exec | owning task | frozen assertion |
|---|---|---|---|---|
| **C5-01** | the statusline renders in a worktree | direct | 5.1 statusline | Run from worktree B (with B's `workspace.current_dir`), the statusline renders B's per-tree segment and is not blanket-suppressed; the right side is not dark, and no segment shows main's or another tree's state. (Name changed and mechanism re-pointed at the shipped resolver — see [Published assertion changes](#published-assertion-changes).) |
| **C5-02** | wiki hooks are live in a worktree | direct | 5.2 wiki hooks | Each of the four `[ -d .git ]` wiki hooks, fired from inside a worktree, either fires correctly or refuses out loud — none is silently dead (the `[ -d .git ]` guard no longer reads a linked worktree as "no repo"). |
| **C5-03** | main-only flows refuse out loud from a worktree | proxy | 5.3 loud-refusal | A main-only flow triggered from a worktree refuses out loud with a named reason, rather than running against the wrong tree or dying silently. A correct loud refusal is a pass. The shipped refusal helper is **driven live** from a real linked worktree and must refuse non-zero while naming the tree it refused from, the main checkout to use instead, and the command to get there; a main-only entry point must also invoke it, so that refusal is reachable rather than orphaned. **Proxy:** only the calling flow is proxied, the release/audit/wiki flows are network + `gh` + multi-agent and impractical to drive in a fixture, never the refusal itself. (Assertion rewritten, see [Published assertion changes](#published-assertion-changes).) |
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

## Published assertion changes

The meter is frozen, so a changed assertion is published here the way an added
scenario would be, with what changed and what it did to the number. **The target
never moves for a repair** — a scenario is repaired, never subtracted. It moves
**upward** only for an added scenario, and only by the maintainer's word.

### C5-03: the assertion was measuring a symbol's name in prose, and is rewritten to drive the refusal

**The frozen assertion could not be satisfied by a correct implementation of the task it
gated.** It grepped three entry-point paths for the literal string `gaia_is_linked_worktree`.
Task 5.3's correct shape is **one shared refusal helper**, `gaia_refuse_if_worktree` in
`.gaia/scripts/main-only-lib.sh`, that every main-only flow calls instead of each one
open-coding the predicate. Under that design no entry point names the predicate: they name the
helper, and the helper names the predicate. So the only ways to turn the old assertion green
were to decline to share the helper, or to write a sentence of documentation containing the
symbol. **The second is what happened first, and it was caught here rather than shipped:** the
scenario was green, and rewording one prose sentence, touching no code and changing no
behavior, turned it red. An assertion a documentation edit can flip is measuring the
documentation.

**What it measures now, in two parts.** The shipped helper is **driven live** from a real
linked worktree, and must refuse non-zero while naming the tree it refused from, the main
checkout to use instead, and the `cd` to get there. Then a static check requires a main-only
entry point to actually *invoke* it, anchored to the start of a line, so a prose mention
cannot satisfy it and only a call can. Part 1 proves the refusal is real and loud; part 2
proves it is reachable rather than orphaned.

**The proxy shrank, which is the other reason this is a repair and not a rewrite.** The
scenario still cannot drive `/gaia-release` end to end, it is network + `gh` + multi-agent.
But the refusal is no longer proxied at all, only the flow that calls it. The old version
proxied the entire thing with a grep.

**Non-vacuity, proven by three independent mutations of the SHIPPED code**, each reverted and
each file verified byte-identical by checksum afterwards. Deleting only the call line from
`.claude/commands/gaia-release.md` **while leaving the prose mention of the helper's name in
place** reds it, the direct proof that the hole this repair closes is closed. Making the
helper omit the "Main checkout:" line reds it. Making the helper allow instead of refuse reds
it.

**The reading moves 19 / 22 → 20 / 22. The repair did not turn it; the code did.** Task 5.3
shipped in its own commit with this scenario left red, precisely so that a frozen fixture was
never edited by the change that turned it green. Both halves of the repaired assertion fail
against the pre-5.3 tree: there was no helper to drive and no entry point to find.

### C5-02: nothing about the scenario changed, only the code under it

**No assertion, no name, no fixture moved.** This entry exists for one reason: the reading
cannot move without being published, and `C5-02` is the first scenario in this suite to turn
on a code fix alone, with the instrument untouched. That is the case the meter was built for,
so it is worth naming as distinct from the four entries below it, each of which had to change
something about the scenario itself.

**What turned it.** Four wiki hooks each opened with `[ -d .git ] || exit 0`. In a linked
worktree `.git` is a file, not a directory, so all four exited before their first real
statement: no drift nudge, no end-of-session safety net, no autocommit squash, and no word
that any of it had stopped. Three now ask git the question directly, with
`git rev-parse --is-inside-work-tree`, the form three other hooks in this repo already use.
The fourth already had the answer: `wiki-session-stop.sh` resolves `git rev-parse --git-dir`
on the very next line, so its guard was deleted rather than converted, because two probes for
one question is the duplication this program removes. **Nothing was made to refuse**, and the
scope manifest is why: `.gaia/hook-scopes.json` declares all four `any` or `per-tree`, so
firing from a worktree is what they are for, and a refusal would have been a second defect
wearing the first one's fix.

**The frozen row still identifies them by the guard they carried at freeze**, and that is left
alone on purpose. Rewriting a frozen assertion so it tracks the fix that satisfied it is how an
assertion stops being frozen.

**The reading moves 18 / 22 → 19 / 22, and this is a fix, not a measurement.** Non-vacuity
proven by mutation, not argued: the old guard was restored in each of the four hooks in turn,
one hook at a time, and each time the scenario went red naming exactly the mutated hook. So all
four conversions are load-bearing, none rides on another, and none of the four checks is
vacuous. Every source was restored byte-identical (checksum-verified) after each mutation, and
the four sibling suites under `.gaia/tests/hooks/` that own these hooks stay green (27 of 27).
No other scenario moved.

### C5-01 — the name changed, the assertion did not, and the fixture now drives the real resolver

**The assertion text above is untouched.** What changed is the scenario's *name* and what
the fixture actually exercises.

**The name said something the delivered design contradicts.** "Statusline renders the
worktree's own segment" presumes a per-tree segment. There is none, and there should not
be: all three state files the statusline reads — the update-check cache, the debt count,
the setup marker — are registry scope `shared`, meaning one physical copy under main for
the whole clone. Every segment states a fact about the clone, so the honest claim is that
the statusline *renders in a worktree*, not that it renders something the worktree owns.
Leaving the old name would have left the meter advertising a mechanism GAIA does not have,
which is the defect `C3-03`'s repair removed rather than one to reintroduce.

**The second clause of the assertion is kept, and read as it must be to mean anything.**
"No segment shows main's or another tree's state" guards cross-tree contamination: a
segment true of one tree and false of the tree you are in. It cannot mean "never read a
file that physically sits under main", because every segment reads exactly such a file —
under that reading no code could satisfy the scenario at all while also leaving the right
side lit, which is the unwinnable shape `C3-03` was repaired out of. Shared state is the
clone's state, and reporting it from any tree is correct.

**The fixture was measuring the fallback, not the fix.** It copied in only the statusline
and seeded the state under worktree B, so the script found no resolver library, fell back
to its own install path, and read B's own files — green through the no-resolver path
rather than through the shipped one. It now copies `main-root-lib.sh` alongside the
statusline and seeds the state under **main**, where shared state actually lives, with B
left deliberately unprovisioned. The segment can therefore only render if the statusline
resolved main for itself. That is the standing rule that a conversion repairs the fixture
whose dependency set it changes, in the same change.

**The reading moves 17 / 22 → 18 / 22, and this one is a fix, not a measurement.**
Non-vacuity proven by mutation, not argued: restoring the blanket worktree gate turns it
red, and anchoring the state paths on the session tree instead of main turns it red as
well, so the green is attributable to the gate's removal *and* to main-anchoring, not to
either alone. The statusline source was restored byte-identical (checksum-verified) after
both. No other scenario moved; the four still red stayed red for their own reasons.

### C4-07 — an added scenario, and the first movement in the target

**The target goes 21 → 22, on the maintainer's decision.** `C4-06`'s repair found that one
clause of that scenario's frozen wording points the wrong way. It says one tree's RED must
never *block* the other tree's commit — which cannot happen, because the ledger writer
appends, so even one merged ledger still holds tree B's own record and B's commit is allowed.
The real harm is the inverse and it is quiet: if the ledgers merge, **tree A's observation
satisfies tree B's gate for a test B never ran**, so B commits a test nobody watched fail,
which is the single thing that gate exists to prevent.

**It could not be folded into `C4-06`.** That scenario reads green under exactly this failure,
so an added check there would have hidden the defect rather than caught it — a second false
green inside the scenario that had just been repaired for its first one. A distinct scenario
was therefore the only honest option, and adding one to a frozen target is not a repair's call
to make.

**The mechanism is the real gate, both halves of it.** The fixture drives the shipped capture
hook to *write* each RED (through the documented `RED_CAPTURE_JSON_OVERRIDE` seam the hooks'
own bats suite uses, because a live vitest run is impractical here) and the shipped check hook
to *read* it. The signal is not canned: each hook recomputes it from the staged file's real
on-disk body, so the cross-tree question is asked of a genuine identity handshake. Two
directories are symlinked from the real repo rather than copied — the signal extractor and the
determinism classifier — because both resolve `typescript` through
`createRequire(import.meta.url)` from their own on-disk location, and a copy into a fixture
resolves nothing. That is disclosed rather than hidden: it is the same install-state dependency
`C3-05` and `C4-04` carry, and the step that arms this suite in CI has to install dependencies
for all three.

**Three checks, and the third is the one that keeps it honest.** The tree that recorded the RED
must be *allowed* (so the fixture is known to be capable of producing an allow at all); the
tree that did not must be *denied*; and then, with its own RED recorded, that same tree must
flip to *allowed*. Without the third, the deny could have come from any fixture defect — a
wrong staged path, an unparseable body, a missing binary — and the scenario would have read
green vacuously, which is precisely the hole `C4-06` was repaired to close.

**The reading moves 16 / 21 → 17 / 22, and the numerator rising is a measurement, not a
fix.** The scenario passes on arrival because the RED ledger is genuinely per-tree today. It is
a cutover guard in the same role as `C4-06`: its owning phase must **preserve** it, and it is
not one of the fixes this program landed. Non-vacuity proven by mutation, not argued:
simulating the Phase-6 cutover (each tree's `.gaia/local` replaced by a single symlink to
main's) turns it red at the deny assertion, which is the exact condition it exists to catch. No
other scenario moved; the five red ones stayed red for their own reasons.

### C3-03 — the assertion demanded a mechanism the design forbids

**As frozen it could never pass, by any code.** It required the write-guard to
refuse a payload cwd that names a sibling worktree, which is the
payload-versus-process cross-check the tree-identity rule's binding `never` list
forecloses unconditionally. So every reading published while it stood carried an
unturnable scenario in its denominator. (The cross-check it asked for compared
*main-checkout* roots, which every worktree of one clone shares, so it could not
have caught this case even before it was removed — the scenario may always have
been describing a protection that never existed.)

It is re-pointed at what the shipped design does guarantee, in four parts: the
payload cwd is adopted as the acting tree; the target is adjudicated against that
tree, not against the hook's own process cwd; an unusable payload falls back to
the process cwd with the guard still live; an undeterminable identity fails open.

**The reading moves 11 → 12, and that is a measurement, not a repair artifact.**
The repair shipped no code. It is green because tasks 3.2 and 3.10 already landed
the behavior, which the old assertion could not see. Verified by mutating the real
hook twice and watching the scenario go red each time: restore the pre-3.10 deny
condition (`file_root == main_root`) and part 2 fails; take identity from the
process cwd instead of the payload and part 1 fails. It now stands as a regression
guard on the identity rule, in the same role as the [green-at-freeze](#green-at-freeze)
six.

### C4-01 / C4-02 — the mechanism moved to the real writer; the assertions did not move

**No assertion text changed here.** What changed is where the path under test comes
from. Both scenarios were written before the fixed writer existed, so each
hand-built today's colliding `<base-sha>`-only path inside the test. A scenario
that builds the very key it is judging can only ever measure the fixture.

Task 4.1 ships `gaia_audit_key` (`.gaia/scripts/audit-key-lib.sh`), the one function
every Code Audit Team member's definition now derives its findings-sidecar and
re-run-ledger paths through. Both fixtures now **ask that function, inside each
worktree, where to write** — the standing rule that a conversion repairs the fixture
whose dependency set it changes, in the same change.

Two consequences are named rather than left implicit. First, each scenario now also
reads back **tree B's** file, not only tree A's: the frozen assertion always said
"never overwrite, and never appear in, tree B's sidecar", and only the first half was
being measured. Second, a fixture that drives the shipped function can go green
vacuously, so the green is backed by mutation: breaking the shipped key (dropping the
branch component) turns both scenarios red, and the same fixtures stay red for the
old writer. What the fixtures still cannot prove is that the five agent definitions
*call* the function — that is a static check
(`.gaia/scripts/check-audit-key-callers.sh`), because prose drift would otherwise
leave a green meter over a broken writer.

### C4-04 — the target path moved; the assertion gained two positive controls and an old-location negative control

**No assertion text changed in the tranche-4 table.** What changed is where the
fixture looks, and how much it proves. Task 4.3 moves the ledger's flat file, which
sat directly under the `audit/` directory (shared in practice: `link-worktree.sh`
symlinks `audit/` wholesale into main because other registry entries under it are
`scope: "shared"`), to `worthiness-ledger/worthiness.jsonl`, a directory sibling to
`red-ledger/`. What protects it is the segment, not the label: `link-worktree.sh`
symlinks a top-level segment when *any* registry entry under it is `scope: "shared"`,
and `worthiness-ledger/` has no shared siblings, so nothing pulls it into main. The
entry was already `scope: "per-tree"` before this task and that did not save it, which
is the whole lesson of the defect — the scope was describing an intent the machinery
did not enforce. Re-pointing the scenario at the new path is what the frozen
assertion already demands ("not shared under `audit/`"), not a weakening of it.

The old fixture's single check read tree B's OLD shared path for tree A's
observation leaking in — a check that could pass even when the writer wrote
nothing at all there, since an empty or absent file also contains zero matches of
"a only test". The rewritten scenario proves four things instead of one: each
tree's own ledger exists and holds its own observation (the writer really wrote,
not a vacuous silence); neither ledger holds the other tree's observation (both
directions, not only the one originally checked); and the old shared location
receives nothing at all in either tree. The assertion is strictly stronger than
before.

### C4-06: the assertion did not move; the scenario went from asserting nothing to driving GAIA

**It ran no GAIA code at all.** It created two `red-ledger/` directories itself, in two
separate `git worktree add` checkouts, wrote one line into each, and asserted that each
lacked the other's line. All of that is true by construction of `git worktree add`,
whatever the registry and the linker do. Its own comment claimed `red-ledger/` "is never
symlinked", an affirmative claim about `link-worktree.sh` that the test never checked.
Because this is the **designated cutover guard**, that made it false safety on precisely
the class it exists to protect, and it was counted among the [green-at-freeze](#green-at-freeze)
six under a stated claim that none of them is vacuous.

**No assertion text changed.** What changed is that every step now asks GAIA. The fixture
copies in the real state registry, the real `link-worktree.sh`, the real main/tree
resolver and the RED ledger's own path lib, runs the real linker in both worktrees, and
then: asks the registry what scope `red-ledger/` carries; asks the linker's own shared-set
function whether it names `red-ledger`; and asks the shipped `red_ledger_path` where each
tree's ledger belongs, rather than hand-building the path.

**Two things were added that the filed repair did not name, both inside the frozen
assertion rather than beyond it.** First, a **positive control on the linker**:
`link-worktree.sh` always exits 0 by contract, so a run that linked nothing at all would
leave `red-ledger/` unlinked too and the isolation checks would pass for the wrong reason.
The control asserts that shared state really is shared: the first shared directory the
registry names resolves, from both trees, to main's one copy. It is stated as *resolution*
rather than as "is a symlink" so that it still holds after the single-symlink cutover, and
so Phase 6 is never pushed to weaken this scenario to land. Second, a **physical-path
comparison** of the two ledgers. Once `.gaia/local` is itself one symlink to main,
`red-ledger/` stays a plain directory while resolving inside main, so a symlink check
alone would have gone on reading green straight through the flip it was written to catch,
a repaired-but-shallow guard failing the same way the original did.

**The reading does not move: 16 / 21 before and after, with `C4-06` green both times.**
That is the honest outcome for a repair to a scenario that was already (falsely) green, and
it is not "no change": the same green is now backed by GAIA's code instead of by the
fixture's own `mkdir`. Non-vacuity is proven by three mutations, each red at the intended
assertion: replacing each worktree's `.gaia/local` with a single symlink to main (the
Phase-6 cutover, simulated) reds at the physical-path comparison; reclassifying
`red-ledger/` as `shared` in the registry reds at the scope check; and a linker that links
nothing reds at the positive control. Both mutated shipped files were restored and verified
byte-identical by checksum.

**One clause of the frozen assertion is deliberately not measured, and saying so is the
point.** "Never blocks tree B's commit" names the consequence, and driving the real commit
gate here would have *passed under the very bleed this scenario guards*: the ledger writer
appends, so a shared ledger still holds tree B's own RED and B's commit is allowed. It
would have added a second false green inside the repaired scenario. The genuine cross-tree
harm at that gate is the inverse (tree A's RED satisfying tree B's demand for a test B
never ran), which is a different scenario, and adding one to a frozen target of 21 is the
maintainer's call, not a repair's. **They made it: that scenario is `C4-07` and the target is
now 22.** The clause stays unmeasured here on the reasoning above; what measures the real harm
is the new scenario, not this one.

---

## Green at freeze

These six pass today. Each drives real code (or a disclosed stand-in) and asserts a real
property — none is vacuous — but none is a fix this program landed, so the honest starting
reading is `6 / 21`. A green-at-freeze scenario going *red* later is a regression signal,
exactly as a red one going green is progress; its owning phase must **preserve** it.

**`C4-07` belongs to this class but is deliberately not listed in it.** It was added after the
freeze, so it is not part of the `6 / 21` starting reading and adding it here would corrupt what
that number means. It carries the same obligation: green on arrival, guarding a change that has
not happened yet, and its owning phase must preserve it.

| id | why it is green at freeze |
|---|---|
| **C4-06** | The designated cutover guard: the RED ledger is genuinely per-tree today (never symlinked), so it is already isolated. It must *stay* isolated across the single-symlink flip. **This row's "none is vacuous" claim did not hold for this scenario until its mechanism was made real; see [Published assertion changes](#published-assertion-changes).** |
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
because the real fixed writer does not exist yet. **Step 4 re-pointed those scenarios at
the real, fixed writers**, so their greens now reflect the writer's new keying rather than
a hand-built path; each re-pointing is published under
[Published assertion changes](#published-assertion-changes). That is a mechanism update,
published visibly. The **frozen assertion** (tree A reads its own state; nothing of tree
B's appears) is what may never be weakened to move a number.

## Armed as a required CI check

Step 4's arming, and what it does not need. `meter-gate.sh` runs as the last step of the
`Audit CI Tests` job (`.github/workflows/audit-ci-tests.yml`), alongside the six bats
suites that job already runs.

**It needed no branch-protection change, and earlier drafts of this file were wrong to
imply one.** `Audit CI Tests` is *already* a declared-required context
(`.gaia/scripts/verify-required-checks.sh`, `REQUIRED_CONTEXTS`), so a step inside that job
inherits the requirement. Arming would have needed a ruleset edit only if it meant adding a
**new** job, creating a check context nobody requires yet — and it never had to mean that;
this file always described arming as "added to the `audit-ci-tests` bats manifest," which
is exactly a step inside the already-required job.

**One thing is still the maintainer's, and it is a confirmation, not a cutover:** that the
live GitHub ruleset really lists `Audit CI Tests`. `REQUIRED_CONTEXTS` is *intent*; the
live ruleset is a separate thing that can drift from it, which is why
`verify-required-checks.yml` exists as a drift detector. Reading the live ruleset leaves
the machine, so nothing local can confirm it.

**How the red-by-design scenarios avoid wedging `main`.** `expected-status.txt` records
what every scenario is expected to do today, and the gate fails on any deviation from it in
either direction — regression *and* unrecorded progress. It also fails when a scenario runs
that the manifest does not know, when a manifest entry reports no result, when the entry
count stops equalling the frozen `target`, or when any scenario reports `skip` (banned
here, and now enforced rather than only stated). The rejected alternative was a
`bats --filter` over the armed tranches, and it is worse three ways: it hides the red
scenarios, it makes a newly added scenario invisible by default, and it is the same quiet
caveat this program spent its week removing.

When a scenario turns, flip its row in `expected-status.txt` and move the reading in this
file **in the same change that turned it**. The gate's whole value is that neither can be
deferred.

**Two dependency installs precede the step, and both are load-bearing.** Three scenarios
drive real node code: `C4-04` and `C4-07` resolve `typescript` from the repo root, and
`C3-05` runs the CLI's own `tsx` out of `.gaia/cli/node_modules`. The runner box is lean
(the job apt-installs only `bats` and `python3-yaml`) and `.gaia/cli` is deliberately its
own isolated pnpm workspace, so a repo-root install does not reach it — hence
`pnpm install` **and** `pnpm -C .gaia/cli install`. Without both, three landed green
scenarios go red for want of an npm install, which would read as a regression in the
number rather than as the environment gap it is. **The five sibling suites under
`.gaia/tests/hooks/` guard this same dependency with `|| skip "typescript not installed"`,
and that hatch is unavailable here** — a skip reports green, which is the opposite of what
this suite means, so it has to actually have the dependency.

**The job's `dorny/paths-filter` gained this suite and the sources it reads.** Without the
entries, a PR touching only those sources would report `code=false`, skip every step, and
green the job having run the meter zero times. Most of what the fixtures copy in
(`.claude/hooks/**`, `.gaia/scripts/**`, `.gaia/statusline/**`,
`.specify/extensions/gaia/lib/**`) was already listed; the additions are this directory,
`.gaia/state-registry.json` and its schema, `.gaia/cli/src/**`,
`.claude/commands/gaia-release.md`, and both lockfiles — the last because a dependency bump
touches a lockfile without touching any source dir, and could otherwise red the meter with
the next unrelated PR the first to notice.

## Files

- `README.md` — this file. The frozen meter: scenarios, assertions, tranches, target,
  execution models, the arming, and the second (deletion) number.
- `concurrency.bats` — the suite. One `@test` per scenario id above. (This entry used to
  read "each fails today," which stopped being true as the tranches turned; the live
  per-scenario expectation is `expected-status.txt`, and no prose copy of it belongs here.)
- `expected-status.txt` — what each scenario is expected to do today, plus the frozen
  `target`. The gate's denominator and its adjudication list.
- `meter-gate.sh` — the CI gate: runs the whole suite, compares every scenario against
  `expected-status.txt`, prints the reading, and fails on any deviation in either
  direction. **Not** the same contract as `.gaia/tests/forensics/run-all.sh`, which fails
  when any test fails; this one exits zero with scenarios red.
- `lib/concurrency-harness.sh` — the fixture builder: a main checkout plus N linked
  worktrees off one base, seeded `.gaia/local` state, real hooks/scripts/libs copied in
  at their repo-relative paths, and a run-in-tree helper. Sourced by the suite.

## Model

Grounded in the worktree audit's verdict inventory and the three decide-phase artifacts
(the tree-identity rule, the `.gaia/local` state model, and the main-checkout resolver).
The scenario set is the audit's top-ranked cross-contamination failures, one per real
defect, each bound to the phase task that owns its cause.
