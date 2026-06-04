---
type: decision
status: active
priority: 1
date: 2026-05-08
created: 2026-05-08
updated: 2026-05-08
tags: [decision, release, maintainer, distribution-boundary]
---

# Bundle-time Scrub

> [!note] Audience
> Maintainer-only. This page is excluded from adopter distribution by `.gaia/release-exclude`. Adopter-facing release detail lives in [[Update Workflow]]; the maintainer release flow is in [[Release Workflow]].

The release tarball passes through two enforcement primitives between staging and tar: a marker-delimited section strip and a leak-check pass against the staged tree, plus a runtime-deps verification of shipped scripts.

## Why

The pre-#97 process was free-form audits of the distribution boundary. Across thirteen independent audit rounds the trajectory averaged roughly one novel issue class per round: UAT/SPEC narrative leaks, dead wikilinks to release-excluded targets, monorepo-prefix paths in adopter-shipped files, runtime references to release-excluded scripts. Each class had a codifiable detection pattern after the fact, but free-form audits do not converge: the next round always finds something.

Build-time enforcement closes the loop. The patterns the audit rounds surfaced become entries in `.gaia/release-scrub.yml`. Future leaks become deterministic build failures with structured reports rather than human-eyeball findings.

## What runs

Two primitives, sequenced inside `release.yml` between rsync-staging and tar:

### `gaia-maintainer release scrub <staging-dir>`

Reads `.gaia/release-scrub.yml`. Two transform types:

**marker-strip.** Removes content between `<!-- gaia:maintainer-only:start -->` and `<!-- gaia:maintainer-only:end -->` markers in markdown files under `wiki/`, `.claude/`, and `.specify/extensions/gaia/`. Source becomes superset; bundle is subset. The maintainer can carry useful context (entity pages, internal cross-references, audit rationale) in the source repo without leaking into adopter scaffolds. Unbalanced markers are a build failure.

**leak-check.** For each codified check (UAT-NNN narrative, concrete maintainer SPEC IDs, release-excluded path mentions, sibling-monorepo prefixes, absolute filesystem literals), runs the pattern over the post-strip staging tree. Each check has a scope (path globs that determine which files to scan), an optional path-allowlist (files exempt from this check by design, e.g. `wiki-style.md` itself names patterns to teach the rule), and an optional line-allowlist (regexes that exempt structural matches like filename literals or identifier fragments).

Non-empty match in any check fails the build with a structured leak report.

### `gaia-maintainer release runtime-deps --staging <dir>`

Walks `.gaia/statusline/**/*.sh` and `.claude/hooks/**/*.sh` inside the staging tree, extracts repo-relative path constants, and verifies each is a shipped path (in `.gaia/manifest.json`), an adopter-owned sentinel (`wiki/hot.md`, `wiki/log.md`, `.gaia/VERSION`, `.gaia/manifest.json`), or a runtime-allocated path on adopter machines (`.gaia/local/`, `.gaia/cache/`, `.claude/handoff/`, `.claude/worktrees/`, `.claude/agent-memory/`, `.claude/audit/`, plus the per-session marker files).

Anything else is a runtime-dependency leak, a shipped caller pointing at a release-excluded callee. Lexical scrubbing cannot see this class because the reference survives prose-style transforms.

## Marker discipline

Single-developer marker discipline is acceptable for now. The maintainer wraps maintainer-only blocks; the maintainer wraps consistently. If the project grows multiple maintainers, the cost is an additional convention to enforce in review, flagged as a future revisit, not a present blocker.

The markers are HTML comments to keep them invisible in rendered Markdown (Obsidian, GitHub previews) while remaining trivially line-grep-able.

## What it does NOT catch

The scrub is lexical. It does not understand semantics. Things outside its reach:

- **Runtime dependency chains**: caught by `runtime-deps`, not scrub.
- **Novel wikilink targets to release-excluded pages.** The `wikilink-to-excluded` check enumerates the known release-excluded slugs (`Release Workflow`, `Bundle-time Scrub`, `GAIA`, `Steven Sacks`, `dashboard`, `Entities`, `Meta`) and flags any unwrapped `[[…]]` in shipped wiki pages. A new release-excluded page added without updating the check's pattern would still slip through. `gaia wiki dead-paths` covers backticked filesystem paths; the wikilink check covers the named slugs.
- **Behaviorally maintainer-only logic**: code that calls a release-excluded source path through dynamic require / variable string concatenation. The bundle architecture (esbuild bundles `.gaia/cli/src/` into the shipped binary; nothing else imports from `src/`) makes this unlikely in practice but is not prevented by the scrub.

## How to extend

When a new leak class is identified:

1. Add a codified detection pattern to `.gaia/release-scrub.yml` (for lexical patterns) or `runtime-deps` (for runtime references).
2. Add prior occurrences to `.gaia/cli/health/taxonomy.md` so future free-form audits prime off the baseline.
3. If the new check requires structural exceptions, expand the line-allowlist or path-allowlist with explicit regexes; never accept a generic "skip this file" without rationale.

## See also

- [[Release Workflow]]: full release sequence; this ADR covers only the bundle-time enforcement step.
- [[Update Workflow]]: adopter-side consumption of the bundle.
