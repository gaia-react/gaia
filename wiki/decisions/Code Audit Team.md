---
type: decision
status: active
priority: 1
date: 2026-07-09
created: 2026-07-09
updated: 2026-07-18
tags: [decision, claude, audit, ci]
---

# Code Audit Team

The pre-merge gate is a **config-driven roster of auditor members**, not a single agent. `.gaia/audit-ci.yml`'s `auditors:` block maps file globs to specialized auditor members; a diff can dispatch more than one member, and the shared `GAIA-Audit` gate requires every dispatched member's own clearance before a merge unblocks. [[Code Review Audit Agent]] (`code-audit-frontend`) is the roster's default, adopter-facing member; this page covers the roster mechanism itself and the maintainer-only members layered on top of it.

## Roster shape

Each `auditors:` entry carries a `name`, a `globs` list, a `scope` (`adopter` or `maintainer-only`), a `push_fixes` flag, and, on exactly one entry, `default: true`. Every member, the default included, declares its own domain in `globs`; there is no implicit domain inferred from anywhere else. Ownership resolves in two precedence tiers: every **claimant** member's (a member without `default: true`) globs are matched first, first-match-wins over roster order, so roster order among claimants is load-bearing; only once every claimant has failed to match does the **default** member's own globs apply, as a catch-all second tier. `scope: maintainer-only` entries sit inside `# gaia:maintainer-only` marker comments; the release scrub strips them from the shipped config, so an adopter clone's built-in fallback roster carries only the adopter-scope members below.

| Member | Globs | Scope | `push_fixes` |
| --- | --- | --- | --- |
| `code-audit-frontend` (default) | `app/**`, `test/**`, `.storybook/**`, `.github/workflows/**`, `package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `tsconfig*.json`, `*.config.ts`, `*.config.mts`, `*.config.mjs`, `*.config.cjs`, `*.config.js` | adopter | `true` |
| `code-audit-github-workflows` | `.github/workflows/*.yml`, `.github/workflows/*.yaml`, `.github/actions/**/*.yml`, `.github/actions/**/*.yaml` | adopter | `false` |

The default's `.github/workflows/**` glob and the workflows member's `.github/workflows/*.yml`/`*.yaml` globs overlap textually, but the two-tier precedence resolves it: the workflows member is a claimant, so a `.yml`/`.yaml` workflow file matches it first; in practice every file under `.github/workflows/` is itself a `.yml`/`.yaml` workflow, so the more specific claimant glob always wins there. The default still declares the broader glob so its stated domain matches what it used to implicitly cover, even though the claimant's narrower glob wins in practice.

The twelve files under `.gaia/cli/templates/workflows/` are deliberately ownerless: a script pins them byte-identical to their source (the CLI's own bundling step), so a reviewer of the copy would decide nothing a reviewer of the source template has not already decided. Finding no owner for that directory is the designed state, not a gap to fix.

## Ownership classifier

Roster parsing and per-path ownership live in one shared, sourced module, `.claude/hooks/lib/audit-scope.sh`, that every dispatch resolver and the merge gate itself consult, rather than each parsing the roster on its own. It parses the roster (`.gaia/audit-ci.yml`'s `auditors:` block when present and non-empty, else the same built-in default roster, itself marker-wrapped for the maintainer-only entries) exactly once per run, and answers three separately-named questions that are never interchangeable: which paths the merge gate's out-of-scope allowlist covers, an ordered three-way classification for the `/update-gaia` self-mod bypass (out-of-scope / the audit workflow itself / in-scope), and which member, if any, owns a given path, resolved in the two precedence tiers above (every claimant's glob first, first-match-wins over roster order, then the default member's own declared globs, otherwise ownerless). Conflating any two of those questions is a merge-gate bypass, which is why they stay three distinct predicates in the one module instead of one generalized check.

A sibling module, `.claude/hooks/lib/audit-machinery.sh`, holds the one list of **audit-machinery paths**: every file whose bytes can change what a member reviews, who reviews it, where a clearance lands, or whether a clearance is believed (the roster, the classifier and machinery modules themselves, the clearance writer and reader, the merge gate, the CI workflow and its bundled templates, the agent definitions, among others). A `.bats` suite is deliberately excluded, its bytes decide none of those four things; the suites are covered instead by the roster's own `.bats` globs (see below), which dispatch a real member to review them.

Every member's clearance marker is keyed to a **content digest**, not the whole repository tree: a sha256 over exactly the files that member owns plus this machinery set (plus the in-scope-but-ownerless paths, for the default member; see [[PR Merge Workflow#Marker key]]). The machinery set is what makes a machinery edit rotate **every** member's digest, since it sits in every member's input set by construction, and because the classifier and machinery modules are themselves machinery, a classifier edit rotates every digest too. Machinery-list completeness is therefore load-bearing, not cosmetic: an unlisted gate-machinery file would rotate no member's key, a fail-open. `.gaia/scripts/audit-machinery-complete.sh` asserts every gate-machinery file (the trailer/status producers, the CI parsers, the dispatch resolvers, the noop detector, the disposition gate, among others) is matched by `audit_path_is_machinery`.

## Dispatch resolver

`.gaia/scripts/resolve-audit-members.sh` turns the current branch's diff into the **dispatched member set**: the deduped, lexically-sorted list of member names owning at least one changed file. It resolves each changed path's owner through the shared ownership classifier above and collects the unique, non-empty owners; empty stdout means the whole diff is out of audit scope. It is generic over the roster: a new member is a config entry plus an agent file, no resolver edit.

## Spawning: the same set, resolved ahead of the gate

The gates are reactive: they deny, they never spawn. `.gaia/scripts/resolve-audit-spawn.sh` is the spawn-side reader of the same dispatch, so the pre-merge procedure resolves the member set and spawns exactly those members instead of guessing one.

The spawn set equals the dispatched member set, filtered to drop a member whose valid current-digest marker is already present (the digest analog of the old carry-forward `cf_filter`, a simple presence check with no anchor selection), with one addition: on a zero-match dispatch it names the default member whenever any changed path is in scope but owned by nobody, mirroring the merge gate's legacy fallback (which still requires the default member's clearance there). That makes the spawn set a superset of what the gate can require, so no diff exists where the gate demands a marker nothing was spawned to produce. The oracle writes no clearance artifact on any path; it mints nothing.

A member with nothing to audit is never spawned, and if a stale caller spawns it anyway, it self-skips (each member's agent file carries the skip clause).

## AND-aggregation at the merge gate

The local merge deny-hook (`.claude/hooks/pr-merge-audit-check.sh`) resolves the dispatched member set, computes every roster member's own content digest in one walk, and requires **every** dispatched member cleared before allowing `gh pr merge`:

- `code-audit-frontend` clears via any of its existing signals (local `<digest>.ok` marker, `GAIA-Audit` commit trailer, GitHub CI status, `chore(deps)` bypass, or the self-mod-only GAIA-update bypass), each checked against its own current content digest.
- A specialized member clears via its own marker, `.gaia/local/audit/<digest>.<member>.ok` (local/advisory-only, no CI or trailer equivalent), or the same self-mod-only GAIA-update bypass `code-audit-frontend` uses. That bypass proves a property of the PR (the sole in-scope change is a verbatim re-render of the bundled audit-workflow template), not a property of one member, so it is resolved once per run and clears **any** dispatched member with no earned marker of its own. Markers key to each member's own content digest, not a shared tree, so members are naturally order-independent: an out-of-glob change rotates no digest, and `code-audit-frontend`'s trailer stamp (an empty commit, leaving every blob byte-identical) rotates no member's digest either. A live refusal for a member's current digest is checked first and stays absolute, overriding the bypass either way. See [[PR Merge Workflow]], Marker key.

A live **refusal** for a member's current digest (`.gaia/local/audit/<digest>[.<member>].refused`) is checked before that member's earned marker and is absolute: it denies the merge regardless of a same-digest earned marker. There is no minting step and no carry-forward clearance machinery, a member not already cleared for its own current digest simply has to be re-dispatched; the digest key is what shrinks how often that happens, since an unrelated or out-of-glob change never rotates it in the first place.

A zero-match dispatch (the resolver finds nothing, or is absent/unusable) falls through to the **legacy single-signal gate**, evaluated for `code-audit-frontend` alone. This is a fail-closed fallback, not an auto-allow: the legacy gate's own out-of-scope bypass still denies an ownerless-but-in-scope file (e.g. a root `Dockerfile`) with no marker, because such a path folds into the default member's own digest input set (see [[PR Merge Workflow#Marker key]]).

`.claude/hooks/post-audit-status.sh`, the hook a member's agent calls after writing its own marker to POST the `GAIA-Audit` commit status, mirrors the same aggregation: it posts success only once every dispatched member is cleared, declining with `members pending <list>` otherwise. Because the check runs from whichever member's agent finishes last, the POST is order-independent, no member has to run first or last for the status to land correctly. The posted description is always the fixed three-field `<version> <frontend-digest> <tree>` shape; there is no carried variant.

<!-- gaia:maintainer-only:start -->
## Maintainer-only members

| Member | Globs | Scope | `push_fixes` |
| --- | --- | --- | --- |
| `code-audit-maintainer-shell` | `.gaia/**/*.sh`, `.gaia/**/*.bats`, `.claude/hooks/**/*.sh`, `.specify/extensions/gaia/lib/*.sh`, `.github/**/*.sh`, `.github/**/*.bats`, `.gaia/audit-ci.yml`, `.gaia/VERSION`, `.claude/agents/code-audit-*.md`, `.claude/rules/**` | maintainer-only | `false` |
| `code-audit-maintainer-node` | `.gaia/cli/src/**/*.ts`, `.gaia/cli/src/**/*.tmpl`, `.gaia/cli/src/**/*.snap`, `.gaia/cli/src/**/.gitkeep` | maintainer-only | `false` |

`code-audit-maintainer-shell` and `code-audit-maintainer-node` review framework source the frontend and workflows auditors never scope: `code-audit-maintainer-shell` covers the framework bash GAIA ships and runs (`.gaia/**/*.sh`, `.claude/hooks/**/*.sh`, `.specify/extensions/gaia/lib/*.sh`, `.github/**/*.sh`) plus the bats suites guarding it (`.gaia/**/*.bats`, `.github/**/*.bats`, see below), with a hook-contract lens, a bats-suite lens, `shellcheck` as a deterministic oracle, and bash 3.2 / BSD-vs-GNU portability review; `code-audit-maintainer-node` covers `.gaia/cli/src/**`'s TypeScript sources, render templates, snapshots, and `.gitkeep` placeholders by extension, with correctness, error handling, filesystem/IO safety, Zod schema fitness, and shell/`gh` injection-safety review. The four-extension enumeration is narrower than a bare `.gaia/cli/src/**` glob would be, deliberately: a future file under an extension not in that list (e.g. a `.json`) reaches no member, a named, accepted cost. Both maintainer members are advisory-only, no self-heal: a maintainer member never pushes a fix commit, it reviews and reports. Both are release-excluded (their agent files, roster entries, and glob references are marker-wrapped and stripped from the adopter bundle), so an adopter clone's Code Audit Team never dispatches them.

### The bats suites are owned, deliberately

`code-audit-maintainer-shell` also owns the `.bats` suites guarding that bash (`.gaia/**/*.bats`, `.github/**/*.bats`), which together cover every bats tree in the repo: `.gaia/scripts/tests/`, `.gaia/tests/{forensics,hooks,lib,sandbox,statusline}/`, `.github/audit/tests/`, and `.github/forensics/tests/`.

Ownership is the deliberate choice because a `.bats` file is not a `.sh` file: without a bats glob, a diff touching only test suites matches no member's globs, dispatches an empty member set, and rides the merge gate's out-of-scope bypass. Those suites are the only enforcement standing behind the framework's shell, so a commit that weakens, skips, or deletes one is simultaneously the change least affordable to merge unreviewed and the one that most easily escapes review. The shell member is the natural owner: bats suites are bash, `shellcheck` parses them as bash and reports genuine defects in them, and the reviewer who knows the script knows what its suite is supposed to prove. The agent carries a bats-specific lens for the failure modes a suite's own green run cannot catch: assertions that structurally cannot fail (per `.claude/rules/bats-assertions.md`), a silently loosened or deleted assertion, and a `skip` that retires coverage.

A bats-only diff therefore dispatches `code-audit-maintainer-shell` and requires its clearance, the same as any other change to the framework's shell.

### The declarative half of the machinery is owned too

`code-audit-maintainer-shell` also owns the roster itself (`.gaia/audit-ci.yml`), the version literal the clearance writer stamps into every marker (`.gaia/VERSION`), the rules directory (`.claude/rules/**`), and the four `code-audit-*` agent definitions that produce clearances. Every one of those is an audit-machinery path (see [[#Ownership classifier]] above): a commit that rewrites the roster, an agent definition, or the version literal changes what a member reviews, who reviews it, or whether a clearance is believed, exactly the surface this member already gates, so without these globs such a commit matched no member and merged unaudited. The application-scope default member has no remit over shell or roster config, the workflows member's remit stays the live workflow and action YAML, and the CLI-TypeScript member's remit stays `.gaia/cli/src/**`'s enumerated extensions, so the shell member is the fit for the rest. This fills the unowned corner of the machinery set that is meant to have an owner, everything except the twelve pinned build-artifact templates under `.gaia/cli/templates/workflows/`, which stay deliberately ownerless (see Roster shape above).
<!-- gaia:maintainer-only:end -->

## Deterministic roster check

`.gaia/scripts/verify-audit-roster.sh` asserts four invariants over the roster and ships to every clone (it is `shared`, not maintainer-only: a roster change now reaches adopters through `/update-gaia`, so they need the check as much as the maintainer does):

1. **Pairwise claimant disjointness.** Every unordered pair of claimant members (a member without `default: true`) must have globs that are disjoint as glob languages, not merely against files that happen to exist today. An overlap fails, naming the pair and a witness path that matches both, synthesized from the two patterns. The default member is excluded from this comparison entirely: its tier is reached only after every claimant has failed to match, so it cannot collide with one.
2. **Undecidable pairs fail.** A glob pair the checker's bounded dialect cannot decide fails loudly, naming the pair, rather than passing silently.
3. **Machinery registration.** Every roster member's `.claude/agents/<name>.md` must exist, and its path must be literally present in both `AUDIT_MACHINERY_PATHS` (`.claude/hooks/lib/audit-machinery.sh`) and `GATE_MACHINERY_FILES` (`.gaia/scripts/audit-machinery-complete.sh`).
4. **Exactly one default.** Zero or more than one `default: true` member fails, naming the count found.

The checker's own glob dialect is a **bounded, decidable fragment**, not the full glob language: it accepts a glob whose `/`-separated segments are each either the whole segment `**`, or a non-empty pattern of literals and single `*`s, and it rejects as undecidable (invariant 2, never silently passed) an empty glob or segment, any of `? [ ] { } \`, a `**` inside a segment (e.g. `app/**.ts`), a run of three or more `*`, or embedded whitespace. Within the accepted fragment the procedure is total, there is no accepted-but-undecided case, so invariant 2 only ever fires on the rejected list above.

Named limits, not defects: the check verifies *disjointness*, never *coverage*, so a glob that reaches no member (see `code-audit-maintainer-node`'s narrowing above) is invisible to it. A roster with only one claimant, the adopter post-scrub shape (the default plus one claimant), has zero pairs to check, so an undecidable glob on a lone claimant goes unreported by invariant 1; invariant 4 still covers the count of defaults. The default member's own globs are never dialect-checked at all, excluded from the pairwise comparison by design. Nothing wires the script into CI or a hook automatically; running it is a deliberate, manual `bash .gaia/scripts/verify-audit-roster.sh`.

## Ruleset-aware required-check confirmation

`read-audit-ci-config.sh`'s `required_check_confirmed` helper (used by the per-author local/CI resolution) confirms the `GAIA-Audit` required check under either branch-protection model: classic branch protection (`required_status_checks` context, tried first, the only path an adopter repo with classic protection ever needs) or a repository ruleset (`GET repos/{owner}/{repo}/rules/branches/<branch>`). The ruleset read ships to every clone, adopter and maintainer alike, so a repository protected by a ruleset rather than classic branch protection confirms correctly too; a repo protected by classic branch protection alone never reaches the ruleset read. The confirmation is advisory only: whichever model confirms, or neither does, the resolved mode never changes.

## Pairs with

- [[Code Review Audit Agent]]: the `code-audit-frontend` member's own review dimensions, proof gate, and disposition contract.
- [[Code Review Audit CI]]: the CI workflow the frontend member runs under, the adopter-tunable knobs, and the trailer/status skip logic the legacy gate's signals 1-4 read.
- [[PR Merge Workflow]]: the local merge-gate handshake this page's AND-aggregator extends from a single marker to a member-aware set.
