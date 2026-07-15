---
type: decision
status: active
priority: 1
date: 2026-07-09
created: 2026-07-09
updated: 2026-07-15
tags: [decision, claude, audit, ci]
---

# Code Audit Team

The pre-merge gate is a **config-driven roster of auditor members**, not a single agent. `.gaia/audit-ci.yml`'s `auditors:` block maps file globs to specialized auditor members; a diff can dispatch more than one member, and the shared `GAIA-Audit` gate requires every dispatched member's own clearance before a merge unblocks. [[Code Review Audit Agent]] (`code-audit-frontend`) is the roster's default, adopter-facing member; this page covers the roster mechanism itself and the maintainer-only members layered on top of it.

## Roster shape

Each `auditors:` entry carries a `name`, a `globs` list, a `scope` (`adopter` or `maintainer-only`), a `push_fixes` flag, and, on exactly one entry, `default: true`. The default member owns every file inside the CI `has_source` surface (`app/`, `test/`, `.storybook/`, `.github/workflows/`, and root-level build/lint/test config) that no specialized member's globs claim. `scope: maintainer-only` entries sit inside `# gaia:maintainer-only` marker comments; the release scrub strips them from the shipped config, so an adopter clone's built-in fallback roster carries the default (frontend) member only.

| Member | Globs | Scope | `push_fixes` |
| --- | --- | --- | --- |
| `code-audit-frontend` | `app/**`, `test/**`, `.storybook/**` | adopter | `true` |

## Ownership classifier

Roster parsing and per-path ownership live in one shared, sourced module, `.claude/hooks/lib/audit-scope.sh`, that every dispatch resolver and the merge gate itself consult, rather than each parsing the roster on its own. It parses the roster (`.gaia/audit-ci.yml`'s `auditors:` block when present and non-empty, else the same built-in default roster, itself marker-wrapped for the maintainer-only entries) exactly once per run, and answers four separately-named questions that are never interchangeable: which paths are the default member's implicit domain, which paths the merge gate's out-of-scope allowlist covers, an ordered three-way classification for the `/update-gaia` self-mod bypass (out-of-scope / the audit workflow itself / in-scope), and which member, if any, owns a given path by precedence (a specialized member's glob wins first, then the default member's implicit domain, then ownerless). Conflating any two of those questions is a merge-gate bypass, which is why they stay four distinct predicates in the one module instead of one generalized check.

A sibling module, `.claude/hooks/lib/audit-machinery.sh`, holds the one list of **audit-machinery paths**: every file whose bytes can change what a member reviews, who reviews it, where a clearance lands, or whether a clearance is believed (the roster, the classifier and machinery modules themselves, the clearance writer and reader, the merge gate, the CI workflow and its bundled templates, the agent definitions, among others). A `.bats` suite is deliberately excluded, its bytes decide none of those four things; the suites are covered instead by the roster's own `.bats` globs (see below), which dispatch a real member to review them. The machinery list matters most to [[PR Merge Workflow#Carry-forward|carry-forward]]: a change to any machinery path refuses every member's carry, since a machinery edit can change the rules a stale anchor was cleared under.

## Dispatch resolver

`.gaia/scripts/resolve-audit-members.sh` turns the current branch's diff into the **dispatched member set**: the deduped, lexically-sorted list of member names owning at least one changed file. It resolves each changed path's owner through the shared ownership classifier above and collects the unique, non-empty owners; empty stdout means the whole diff is out of audit scope. It is generic over the roster: a new member is a config entry plus an agent file, no resolver edit.

## Spawning: the same set, resolved ahead of the gate

The gates are reactive: they deny, they never spawn. `.gaia/scripts/resolve-audit-spawn.sh` is the spawn-side reader of the same dispatch, so the pre-merge procedure resolves the member set and spawns exactly those members instead of guessing one.

The spawn set equals the dispatched member set, with one addition: on a zero-match dispatch it names the default member whenever any changed path is in scope but owned by nobody, mirroring the merge gate's legacy fallback (which still requires the default member's clearance there). That makes the spawn set a superset of what the gate can require, so no diff exists where the gate demands a marker nothing was spawned to produce.

A member with nothing to audit is never spawned, and if a stale caller spawns it anyway, it self-skips (each member's agent file carries the skip clause).

## AND-aggregation at the merge gate

The local merge deny-hook (`.claude/hooks/pr-merge-audit-check.sh`) resolves the dispatched member set and requires **every** dispatched member cleared, earned or carried, before allowing `gh pr merge`:

- `code-audit-frontend` clears via any of its existing signals (local `.ok`/`.carried` marker, `GAIA-Audit` commit trailer, GitHub CI status, `chore(deps)` bypass, or the self-mod-only GAIA-update bypass).
- A specialized member clears via its own marker, `.gaia/local/audit/<tree-sha>.<member>.ok` (earned) or `.gaia/local/audit/<tree-sha>.<member>.carried` (carried forward), the sole clearance signal for maintainer members (local/advisory-only, no CI or trailer equivalent). Markers key to HEAD's tree, so members can run in any order and `code-audit-frontend`'s trailer stamp (an empty commit) never orphans a sibling's marker. See [[PR Merge Workflow]], Marker key.

Before demanding a fresh spawn, the gate is itself the **sole minting authority** for a carried clearance: for any member not already cleared, it tries to carry that member's own earlier earned clearance forward to HEAD's tree, and only asks for a real re-audit when the carry-forward predicate refuses (a path the member owns, an audit-machinery path, an ownerless in-scope path for the default member, or the member's own live refusal of this exact tree). `resolve-audit-spawn.sh` consults the identical predicate to decide who not to spawn ahead of time; it mints nothing itself, so a stale spawn-side skip never substitutes for the gate's own check at merge time. See [[PR Merge Workflow#Carry-forward]] for the full contract, including the refusal artifact and the disposition-carry rules.

A zero-match dispatch (the resolver finds nothing, or is absent/unusable) falls through to the **legacy single-signal gate**, evaluated for `code-audit-frontend` alone, unchanged from before the roster existed. This is a fail-closed fallback, not an auto-allow: the legacy gate's own out-of-scope bypass still denies an ownerless-but-in-scope file (e.g. a root `Dockerfile`) with no marker.

`.claude/hooks/post-audit-status.sh`, the hook a member's agent calls after writing its own marker to POST the `GAIA-Audit` commit status, mirrors the same aggregation: it posts success only once every dispatched member is cleared, declining with `members pending <list>` otherwise. Because the check runs from whichever member's agent finishes last, the POST is order-independent, no member has to run first or last for the status to land correctly. When any dispatched member's clearance is carried rather than earned, the posted description gains a third field (`<version> <tree> carried`); the merge gate and the local out-of-scope check still accept it as cleared, but CI's own incremental-base resolver never anchors a future audit's review base on it.

<!-- gaia:maintainer-only:start -->
## Maintainer-only members

| Member | Globs | Scope | `push_fixes` |
| --- | --- | --- | --- |
| `code-audit-maintainer-shell` | `.gaia/**/*.sh`, `.gaia/**/*.bats`, `.claude/hooks/**/*.sh`, `.specify/extensions/gaia/lib/*.sh`, `.github/**/*.sh`, `.github/**/*.bats`, `.gaia/audit-ci.yml`, `.gaia/VERSION`, `.claude/agents/code-audit-*.md`, `.claude/rules/**`, `.gaia/cli/templates/workflows/code-review-audit.yml.tmpl` | maintainer-only | `false` |
| `code-audit-maintainer-node` | `.gaia/cli/src/**` | maintainer-only | `false` |

`code-audit-maintainer-shell` and `code-audit-maintainer-node` review framework source the frontend auditor never scoped: `code-audit-maintainer-shell` covers the framework bash GAIA ships and runs (`.gaia/**/*.sh`, `.claude/hooks/**/*.sh`, `.specify/extensions/gaia/lib/*.sh`, `.github/**/*.sh`) plus the bats suites guarding it (`.gaia/**/*.bats`, `.github/**/*.bats`, see below), with a hook-contract lens, a bats-suite lens, `shellcheck` as a deterministic oracle, and bash 3.2 / BSD-vs-GNU portability review; `code-audit-maintainer-node` covers `.gaia/cli/src/**` (the CLI's own TypeScript), with correctness, error handling, filesystem/IO safety, Zod schema fitness, and shell/`gh` injection-safety review. Both are advisory-only, no self-heal: a maintainer member never pushes a fix commit, it reviews and reports. Both are release-excluded (their agent files, roster entries, and glob references are marker-wrapped and stripped from the adopter bundle), so an adopter clone's Code Audit Team never dispatches them.

### The bats suites are owned, deliberately

`code-audit-maintainer-shell` also owns the `.bats` suites guarding that bash (`.gaia/**/*.bats`, `.github/**/*.bats`), which together cover every bats tree in the repo: `.gaia/scripts/tests/`, `.gaia/tests/{forensics,hooks,lib,sandbox,statusline}/`, `.github/audit/tests/`, and `.github/forensics/tests/`.

Ownership is the deliberate choice because a `.bats` file is not a `.sh` file: without a bats glob, a diff touching only test suites matches no member's globs, dispatches an empty member set, and rides the merge gate's out-of-scope bypass. Those suites are the only enforcement standing behind the framework's shell, so a commit that weakens, skips, or deletes one is simultaneously the change least affordable to merge unreviewed and the one that most easily escapes review. The shell member is the natural owner: bats suites are bash, `shellcheck` parses them as bash and reports genuine defects in them, and the reviewer who knows the script knows what its suite is supposed to prove. The agent carries a bats-specific lens for the failure modes a suite's own green run cannot catch: assertions that structurally cannot fail (per `.claude/rules/bats-assertions.md`), a silently loosened or deleted assertion, and a `skip` that retires coverage.

A bats-only diff therefore dispatches `code-audit-maintainer-shell` and requires its clearance, the same as any other change to the framework's shell.

### The declarative half of the machinery is owned too

`code-audit-maintainer-shell` also owns the roster itself (`.gaia/audit-ci.yml`), the version literal the clearance writer stamps into every marker (`.gaia/VERSION`), the rules directory (`.claude/rules/**`), the three `code-audit-*` agent definitions that produce clearances, and the bundled audit-workflow template. Every one of those is an audit-machinery path (see [[#Ownership classifier]] above): a commit that rewrites the roster, an agent definition, or the version literal changes what a member reviews, who reviews it, or whether a clearance is believed, exactly the surface this member already gates, so without these globs such a commit matched no member and merged unaudited. The application-scope default member has no remit over shell or roster config, and the CLI-TypeScript member's remit stays `.gaia/cli/src/**`, so the shell member is the fit. This fills the last unowned corner of the machinery set: every path the ownership classifier's generating rule names now resolves to a real member.
<!-- gaia:maintainer-only:end -->

## Ruleset-aware required-check confirmation

`read-audit-ci-config.sh`'s `required_check_confirmed` helper (used by the per-author local/CI resolution) now confirms the `GAIA-Audit` required check under either branch-protection model: classic branch protection (`required_status_checks` context, tried first, the only path an adopter repo with classic protection ever needs) or a repository ruleset (`GET repos/{owner}/{repo}/rules/branches/<branch>`, maintainer-only and marker-wrapped so it never ships). A repo protected by a ruleset rather than classic protection previously 404d on the classic-only check and fell to the fail-closed `ci` default; the ruleset read closes that gap for ruleset-protected repos that also want the `local` audit mode to confirm correctly.

## Pairs with

- [[Code Review Audit Agent]]: the `code-audit-frontend` member's own review dimensions, proof gate, and disposition contract.
- [[Code Review Audit CI]]: the CI workflow the frontend member runs under, the adopter-tunable knobs, and the trailer/status skip logic the legacy gate's signals 1-4 read.
- [[PR Merge Workflow]]: the local merge-gate handshake this page's AND-aggregator extends from a single marker to a member-aware set.
