---
type: concept
status: active
created: 2026-07-23
updated: 2026-07-25
tags: [concept, worktree, claude, hooks, state]
---

# Worktrees

A git worktree is a second (third, fourth) working directory for one repository, each on its own branch, all sharing one `.git` underneath. Instead of stashing to switch branches, you keep several folders open and move between them. In GAIA a worktree is the default unit of work: you run several at once, as a matter of routine, and **GAIA behaves identically in every one.**

"Behaves identically" is the whole claim. Creating a worktree is one command and it works immediately, with no repair step and no knowledge of where GAIA keeps its files. Nothing done in one folder can corrupt, block, silently satisfy, or be misattributed to another. Every notification, status indicator, and maintenance flow works the same inside one. The main folder holds no privileged working state, only what is genuinely global.

Two facts make that hard, and everything below exists to handle them: GAIA must know **which tree an action belongs to**, and it must know **where the main checkout is** — and both answers have to be the same everywhere, in every checkout shape.

## For a feature author: the one rule

You almost never compute any of this yourself. If you are about to write "find the repo root" or "the list of shared `.gaia/local` folders," stop — those are the two mistakes this model exists to prevent, and each has one shared answer:

- **Never derive the main checkout by hand.** Do not write `dirname "$(git rev-parse --git-common-dir)"` or any cousin of it. Source the resolver and call it. It is correct in checkout shapes the hand-rolled idiom gets wrong.
- **Never hardcode what lives in `.gaia/local/`.** Do not restate the list of shared entries, or which folders are per-tree. Read the state registry. Every entry is declared once, with its scope and its key; the registry is the only list, and a child it does not know is reported rather than silently absorbed.

<!-- gaia:maintainer-only:start -->
GAIA maintainers: both rules are backed by CI in this repo. A second shell definition of the resolver fails the build, and a live registry entry with no source reference fails the build; a companion report lists the `.gaia/local/` literals in shipped source that no entry maps to. Those checks run only from the release-excluded suites, so they guard maintainer changes rather than adopter ones.
<!-- gaia:maintainer-only:end -->

Get those two right and your feature is worktree-correct for free. Get either wrong by hand and you have re-created the defect this model removed. The rest of this page is why those two things are enough.

## Which tree am I in?

A hook or script often needs to attribute an action to the tree it happened in — to write that tree's state, render that tree's status, or decide whether a guard should fire. The harness hands several candidate signals on each event, and all but one are traps:

- `session_id` is **shared** from a parent to its subagents, so it cannot tell them apart.
- `agent_id` is present for a worktree subagent but **absent on the main thread**, so it is not a tree key either (it answers a different question — *which agent*, not *which tree*).
- A worktree-creation event carries a working directory, but one that names the **dispatching** tree, not the tree being created.

Only the working directory the harness reports for the acting agent is reliably per-agent: each agent's own event carries its own tree's directory (on a tool call, the payload `cwd`; on the statusline event, `workspace.current_dir`). That is the source of truth for tree identity.

### The rule

1. Read the acting event's working-directory field.
2. If it is **absolute and resolves to a checkout**, the tree identity is that checkout's resolved root. It is authoritative on its own — no comparison against the process's own directory, no consulting `session_id` or `agent_id` to confirm it. Identity is the resolved, symlink-canonicalized root, so a tree reached through a symlink and through its real path are one identity, never two.
3. If the field is **unusable** (absent, relative, or absolute but not a checkout), fall back to the hook's own process directory, resolved the same way. The pair a guard compares (main's root and the acting tree's root) is always read from one source, never mixed across the two.
4. If neither resolves to a checkout, identity is **undeterminable**: the rule never invents a tree by defaulting to main or to any worktree, and each site takes its class's failure direction below.

Two properties are load-bearing and no consumer may relax them. **Absolute is required**, not merely preferred: the value flows into a bare shell `cd`, which option-parses a leading dash and could otherwise land in the home directory and pass a same-repo check spuriously. **Resolving to a checkout is required** beyond the leading slash: an absolute path that is not a checkout (say `/tmp`) is unusable and routes to the fallback.

### What "refuse, do not guess" means, per site

Undeterminable identity is one rule with a direction chosen per site, not a single blanket default. Every GAIA site that reasons about "which tree" is exactly one of these classes:

| Site class | Example | On undeterminable identity |
|---|---|---|
| Non-destructive path guard | the worktree write-guard | **fail open** — allow the action (blocking a legitimate edit on an identity it could not confirm is the worse, cheap-to-notice failure, and the guard is defense-in-depth) |
| Per-tree writer / reaper | the session-start janitor, the RED ledger, the worthiness ledger | **refuse to act** — no-op rather than writing or deleting one tree's state as another's, which is the worse failure (`GAIA_TREE_KEY_UNRESOLVABLE` is the diagnostic where one is emitted) |
| Destructive removal guard | the `rm -rf` guard | **fail cautious** — a wrong destructive action is unrecoverable, so an unreadable registry loses the scratch carve-outs and the target falls to the absolute-path deny. It derives no tree identity; it is one of several guards that do not fail open. |
| Main-anchored surface or state (exempt) | the statusline, the SPEC and plan ledgers, the token tally, the PR-artifact capture | does not derive tree identity — anchors to main by design. The statusline renders in full inside a linked worktree, with no worktree gate: every segment it shows reads shared state under the main checkout, and a resolution failure degrades to its own checkout rather than going dark. |
| Content-keyed shared state (exempt) | the audit content-digest clearance markers | does not derive tree identity — keyed by content, one shared store |

The exempt classes are named so their absence reads as deliberate, not an oversight. The deriving classes never choose their own default; the direction above is the rule.

### The signal is measured, not promised

The harness documents the working-directory field only as "the directory at invocation" — it never promises the per-agent scoping the rule depends on. So the day the harness changes that unpromised behavior, every site that reads it would break silently and at once.

The defense today is the fallback and the per-site failure directions above: a dropped, relative, or non-resolvable working directory routes to the hook's own process directory and the site keeps guarding. The *per-agent* property (that two concurrent agents each see their own tree) is exercised by the N-worktree concurrency harness. A dedicated single-event contract test — one that pins the assumed shape and fails loudly naming the field as the broken contract, turning a silent repo-wide regression into one attributable failure — is specified and not yet built.

## Where is the main checkout?

Almost everything GAIA does needs one path: the root of the project's main working tree. Worktree creation puts new trees under it; the linker points shared state at it; the cost ledger records into it; the janitor sweeps inside it; the statusline reads from it. There is **one resolver per language**, and everything calls its own — bash sites source `main-root-lib.sh`, instruction prose invokes it as a script, the Node CLI calls its TypeScript counterpart rather than paying a subprocess on a hot path. Two implementations, one per language, is the deliberate position; a third copy in either is not. The shell resolver is the one that answers correctly in every shape below.

<!-- gaia:maintainer-only:start -->
GAIA maintainers: a CI check counts resolver definitions per language and fails the build on a second copy in either. It runs from the release-excluded suites, so it guards maintainer changes.
<!-- gaia:maintainer-only:end -->

The naive idiom — "the main checkout is the parent of git's common directory" — is wrong outside an ordinary clone. In a submodule, git's directory lives in the superproject, so the idiom hands back a path inside `.git`. In a `--separate-git-dir` checkout it does the same. Nothing errors, because the paths are guarded by silent presence checks, so the wrongness is invisible until GAIA writes a ledger or links shared state into git's own storage. The resolver answers correctly in every shape git can describe:

1. **Am I in a linked worktree?** Compare the absolute git directory against the absolute common directory (both physically resolved). They differ only inside a linked worktree. Correct in every shape, including submodules — unlike the `dirname(common) != toplevel` test, which reads a plain submodule checkout as a worktree.
2. **Not in one** → the working tree that owns the target directory (correct for ordinary clone, submodule, and separate-git-dir alike).
3. **In one** → the main working tree git records: `core.worktree` resolved against the common directory (the submodule case), otherwise the common directory's parent (the ordinary case).
4. **Neither recorded, or the candidate does not validate** → the shape is **underivable**: exit non-zero, print nothing on stdout, write one named reason to stderr identifying the shape and the git directory it saw.

A candidate is accepted only after it **validates**: it is a real directory, the toplevel git reports for it equals the candidate itself (physically resolved), and the common directory git reports for it is the one the resolution started from. Validation is what separates "fails loudly" from "silently returns a path inside somebody's git storage," so an ambient work-tree override cannot stand in for the repository's own layout.

There is **one output form** everywhere: a single line, one trailing newline, an absolute path with symlinks resolved, no trailing slash, no `..` — byte-identical to git's toplevel from that root. Consumers string-compare the answer (the write-guard denies on exact equality; the statusline compares two roots), so the form is load-bearing.

A resolution failure does not decide the caller's behavior — the caller does. A fail-open guard keeps allowing; a silent reader or linker stands down and exits 0; a hard-requirement script propagates the named reason and aborts. The resolver keeps its reason off stdout so a fail-open caller can read the exit status alone without leaking a diagnostic on every guarded tool call. The worktree-detection **predicate** ("am I in a linked worktree") ships as a second entry point on the same implementation, so a site that needs a boolean does not resolve a root to get one.

## What lives in `.gaia/local/`, and how worktrees share it

`.gaia/local/` holds GAIA's per-machine working state — audit results, cost tracking, specs, plans, caches, ledgers. It is gitignored in full and ships nothing to adopters. It stays at that path in every checkout, because a developer must be able to browse to their own specs and plans without knowing where GAIA hides things.

A linked worktree's `.gaia/local` is a **single symlink to the main checkout's** `.gaia/local`, not a real directory holding a hand-maintained set of individually-symlinked entries. One consequence is that there is no shared-entry list to keep in sync, and no per-path guard exemptions — the whole directory is main's, so those collapse to one fact. The other consequence is the load-bearing one: state that must stay **per-tree** does not get its isolation from having its own physical directory. Under one symlink, a bare `red-ledger/` resolves to one shared path for every tree. So per-tree state is isolated by an **explicit tree-identity key** instead of by the filesystem, and the classification below is what says which entries need it.

### The four scopes

Every entry is exactly one of these. The scope answers where it lives and who owns it once the whole directory resolves to main:

- **shared** — a durable store multiple trees co-write, whose entries must coexist. Correct only with a content or identity partition key, a cross-tree lock, or (for a singleton) an idempotent overwrite. *Examples:* the audit clearance markers (keyed by content digest); the findings and rerun sidecars (keyed by base-sha **plus branch**, so two trees off one main tip do not overwrite each other); the telemetry cost ledger (a cross-tree file lock plus self-identifying rows); the debt count cache (idempotent overwrite of a repo-global fact); the harden decline ledger (one copy per clone, keyed internally by finding class, because one copy is the only scope at which a decline can suppress what it declined).
- **per-tree** — durable state belonging to exactly one tree that must not bleed across trees. Addressed at a sub-path carrying the resolved-checkout-root tree key the identity rule defines; the resolver supplies the key, the registry declares which entries need it. *Examples:* the RED ledger; the worthiness ledger (the same kind of per-tree fact as a RED observation); the forensics and handoff drop zones.
- **main-only** — a single canonical value owned by the main checkout, or a transient main-anchored coordination store holding no durable per-tree data. A worktree reads it or writes into main's one copy; it does not co-write a partitioned dataset. A coordination store may still carry a key (a spec-chain sentinel by session) — that partitions coordination records, it does not make the store a co-written dataset. *Examples:* the SPEC and plan ledgers; the PR-artifact capture; the project id; the update-preference file.
- **ephemeral** — transient scratch, regenerable or discardable, reaped by the janitor. Keyed by session, spec id, or a uuid, or an idempotent-overwrite cache whose concurrent write is harmless. Needs no tree key and no preservation. *Examples:* in-flight SPEC drafts and gate caches; react-perf run output; the daily version-check lock.

The one genuinely-close pair is **shared vs main-only**, since both resolve to main. The distinguishing test is whether the store holds *durable co-written data from multiple trees that must coexist* (shared) or *a single value or transient coordination* (main-only). The line between **per-tree and ephemeral** is durability: per-tree must persist for its tree and be addressable by tree; ephemeral is thrown away.

### The registry, and what it does with the unknown

There is **one file** declaring every `.gaia/local/` entry — its scope, a plain-language reason, and, for a shared entry, its key. Everything that needs that information reads this registry; nothing keeps its own copy. That is the whole product: the registry is the only list, so "someone forgot to update one of the hand-written lists" has nowhere left to happen, and drift from the registry is reported rather than silently absorbed.

A check that runs at session start, against real on-disk state, compares the directory to the registry. It **reports, never deletes or blocks**, an entry it does not recognize.

<!-- gaia:maintainer-only:start -->
GAIA maintainers: because the directory is gitignored and empty on a fresh CI checkout, the rest of the enforcement is split by where each half can see something real. One CI check requires that a single canonical resolver definition exists per language. A second checks the registry against shipped source in both directions: a live registry entry naming no real source reference fails the build, while the reverse direction — `.gaia/local/` literals in shipped source that map to no entry — is a report rather than a gate. Both run only from the release-excluded suites, so they guard maintainer changes; the session-start sweep is the half an adopter gets.
<!-- gaia:maintainer-only:end --> Three reasons: the directory is deliberately discoverable, so a human or an adopter may keep their own folder there; a machine on one GAIA version may carry a folder a different version owns; and enumerating an allowlist to police what may exist is the hardcoded-list reflex this whole model removes. Reporting surfaces drift without asserting an authority the registry does not have — in both directions of version skew.

### Keys, guards, and the janitor

Two couplings follow from the single symlink and are worth an author's attention:

- **The write-guard does not see per-tree stale writes.** A checkout-boundary guard catches a stale pre-switch path writing one tree's state into another's only while per-tree entries are non-exempt. Once the whole directory legitimately resolves to main, the guard cannot tell a correct per-tree write from a stale one. The per-tree isolation boundary sits inside `.gaia/local`, at the tree key, where a checkout-boundary guard structurally cannot reach. Under this model **the key is the isolation.**
- **The janitor consults the registry.** The session-start janitor's outlier sweep puts every `.gaia/local` child to the registry and keeps what it recognizes. It reports what it does not recognize and deletes nothing on that basis, so the report-not-delete rule is a real system property and not a claim the next sweep falsifies. It still owns reaping genuine ephemeral scratch once provably stale, and reclaiming orphaned worktrees whose branches are provably dead. The per-tree ledger directories sit outside every zone it walks.

The checkout-root `.env` / `.env.*` secret files are symlinked into each worktree separately; they sit outside `.gaia/local` and are not part of this model, but the linking survives it.

## What is permanent

The registry is the only list, and the session-start sweep reports every `.gaia/local/` child it does not recognize — so drift surfaces rather than vanishing. That is the defense an adopter clone carries.

<!-- gaia:maintainer-only:start -->
GAIA maintainers: three enforcement mechanisms persist in this repo and are the entire defense against re-creating the problem in the next cross-cutting feature.

1. A second copy of the main-checkout derivation, in either language, fails the build.
2. A live registry entry with no source reference fails the build; an unregistered `.gaia/local/` child is reported, by the CI companion report over source literals and by the session-start sweep over real on-disk state.
3. The N-worktree concurrency meter runs in CI: two trees off the same base drive audit, PR, and merge cycles concurrently — some scenarios directly, some simulated or proxied — and nothing from one leaks into the other.

All three run from release-excluded suites, so they guard maintainer changes. If they exist and are enforced, the next feature cannot recreate this. If they do not, it will.
<!-- gaia:maintainer-only:end -->

## Adding state or a hook correctly (the checklist)

- **New piece of `.gaia/local/` state?** Decide its scope from the four above (durable-co-written → shared with a key; durable-one-tree → per-tree; one-canonical or coordination → main-only; throwaway → ephemeral). Add its registry entry — scope, reason, and a key if shared — in the same change. Do not add it to any hand-written list; there are none to add it to.
- **Need the main checkout root?** Source the resolver and call it. Do not derive it. Keep your caller's failure disposition: a guard fails open, a reader stands down, a hard script aborts with the named reason.
- **Need to know which tree an event is for?** Read the acting event's working-directory field through the identity rule; pick your class's failure direction for undeterminable identity. Never key on `session_id` or `agent_id` for a tree.
- **Writing a hook that touches per-tree state?** Address it under the tree key, not a bare relative path. A bare `.gaia/local/<thing>` resolves to main's one copy for every tree.

## Cross-references

- [[Local Working State]] — the entry-by-entry catalogue of `.gaia/local/` and the session-start janitor.
- [[Claude Hooks]] — the hook surface and the per-agent working-directory measurement the identity rule rests on.
- [[PR Merge Workflow]] — the audit → PR → merge cycle the concurrency test drives, and the content-digest clearance markers.
