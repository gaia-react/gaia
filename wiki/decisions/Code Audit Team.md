---
type: decision
status: active
priority: 1
date: 2026-07-09
created: 2026-07-09
updated: 2026-07-09
tags: [decision, claude, audit, ci]
---

# Code Audit Team

The pre-merge gate is a **config-driven roster of auditor members**, not a single agent. `.gaia/audit-ci.yml`'s `auditors:` block maps file globs to specialized auditor members; a diff can dispatch more than one member, and the shared `GAIA-Audit` gate requires every dispatched member's own clearance before a merge unblocks. [[Code Review Audit Agent]] (`code-audit-frontend`) is the roster's default, adopter-facing member; this page covers the roster mechanism itself and the maintainer-only members layered on top of it.

## Roster shape

Each `auditors:` entry carries a `name`, a `globs` list, a `scope` (`adopter` or `maintainer-only`), a `push_fixes` flag, and, on exactly one entry, `default: true`. The default member owns every file inside the CI `has_source` surface (`app/`, `test/`, `.storybook/`, `.github/workflows/`, and root-level build/lint/test config) that no specialized member's globs claim. `scope: maintainer-only` entries sit inside `# gaia:maintainer-only` marker comments; the release scrub strips them from the shipped config, so an adopter clone's built-in fallback roster carries the default (frontend) member only.

| Member | Globs | Scope | `push_fixes` |
| --- | --- | --- | --- |
| `code-audit-frontend` | `app/**`, `test/**`, `.storybook/**` | adopter | `true` |

## Dispatch resolver

`.gaia/scripts/resolve-audit-members.sh` turns the current branch's diff into the **dispatched member set**: the deduped, lexically-sorted list of member names owning at least one changed file. Per changed file, a specialized (non-default) member whose globs match wins first; failing that, a file inside the default member's auditable-base set falls to the default member; anything else has no owner and is out of scope. Empty stdout means the whole diff is out of audit scope. The resolver reads the roster from `.gaia/audit-ci.yml` when present, else falls back to a hard-coded built-in roster (itself marker-wrapped for the maintainer-only entries), so it never depends on the config file existing. It is generic over the roster: a new member is a config entry plus an agent file, no resolver edit.

## AND-aggregation at the merge gate

The local merge deny-hook (`.claude/hooks/pr-merge-audit-check.sh`) resolves the dispatched member set and requires **every** dispatched member's own clearance signal before allowing `gh pr merge`:

- `code-audit-frontend` clears via any of its existing signals (local `.ok` marker, `GAIA-Audit` commit trailer, GitHub CI status, `chore(deps)` bypass, or the self-mod-only GAIA-update bypass).
- A specialized member clears via its own marker file, `.gaia/local/audit/<tree-sha>.<member>.ok`, the sole clearance signal for maintainer members (local/advisory-only, no CI or trailer equivalent). Markers key to HEAD's tree, so members can run in any order and `code-audit-frontend`'s trailer stamp (an empty commit) never orphans a sibling's marker. See [[PR Merge Workflow]], Marker key.

A zero-match dispatch (the resolver finds nothing, or is absent/unusable) falls through to the **legacy single-signal gate**, evaluated for `code-audit-frontend` alone, unchanged from before the roster existed. This is a fail-closed fallback, not an auto-allow: the legacy gate's own out-of-scope bypass still denies an ownerless-but-in-scope file (e.g. a root `Dockerfile`) with no marker.

`.claude/hooks/post-audit-status.sh`, the hook a member's agent calls after writing its own marker to POST the `GAIA-Audit` commit status, mirrors the same aggregation: it posts success only once every dispatched member's marker is present, declining with `members pending <list>` otherwise. Because the check runs from whichever member's agent finishes last, the POST is order-independent, no member has to run first or last for the status to land correctly.

<!-- gaia:maintainer-only:start -->
## Maintainer-only members

| Member | Globs | Scope | `push_fixes` |
| --- | --- | --- | --- |
| `code-audit-maintainer-shell` | `.gaia/**/*.sh`, `.claude/hooks/**/*.sh`, `.specify/extensions/gaia/lib/*.sh`, `.github/**/*.sh` | maintainer-only | `false` |
| `code-audit-maintainer-node` | `.gaia/cli/src/**` | maintainer-only | `false` |

`code-audit-maintainer-shell` and `code-audit-maintainer-node` review framework source the frontend auditor never scoped: `code-audit-maintainer-shell` covers the framework bash GAIA ships and runs (`.gaia/**/*.sh`, `.claude/hooks/**/*.sh`, `.specify/extensions/gaia/lib/*.sh`, `.github/**/*.sh`), with a hook-contract lens, `shellcheck` as a deterministic oracle, and bash 3.2 / BSD-vs-GNU portability review; `code-audit-maintainer-node` covers `.gaia/cli/src/**` (the CLI's own TypeScript), with correctness, error handling, filesystem/IO safety, Zod schema fitness, and shell/`gh` injection-safety review. Both are advisory-only, no self-heal: a maintainer member never pushes a fix commit, it reviews and reports. Both are release-excluded (their agent files, roster entries, and glob references are marker-wrapped and stripped from the adopter bundle), so an adopter clone's Code Audit Team never dispatches them.
<!-- gaia:maintainer-only:end -->

## Ruleset-aware required-check confirmation

`read-audit-ci-config.sh`'s `required_check_confirmed` helper (used by the per-author local/CI resolution) now confirms the `GAIA-Audit` required check under either branch-protection model: classic branch protection (`required_status_checks` context, tried first, the only path an adopter repo with classic protection ever needs) or a repository ruleset (`GET repos/{owner}/{repo}/rules/branches/<branch>`, maintainer-only and marker-wrapped so it never ships). A repo protected by a ruleset rather than classic protection previously 404d on the classic-only check and fell to the fail-closed `ci` default; the ruleset read closes that gap for ruleset-protected repos that also want the `local` audit mode to confirm correctly.

## Pairs with

- [[Code Review Audit Agent]]: the `code-audit-frontend` member's own review dimensions, proof gate, and disposition contract.
- [[Code Review Audit CI]]: the CI workflow the frontend member runs under, the adopter-tunable knobs, and the trailer/status skip logic the legacy gate's signals 1-4 read.
- [[PR Merge Workflow]]: the local merge-gate handshake this page's AND-aggregator extends from a single marker to a member-aware set.
