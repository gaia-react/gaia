---
type: decision
status: active
priority: 1
date: 2026-05-08
created: 2026-05-08
updated: 2026-07-03
tags: [decision, release, maintainer, distribution-boundary]
---

# Bundle-time Scrub

> [!note] Audience
> Maintainer-only. This page is excluded from adopter distribution by `.gaia/release-exclude`. Adopter-facing release detail lives in [[Update Workflow]]; the maintainer release flow is in [[Release Workflow]].

The release tarball passes through two enforcement primitives between staging and tar: a transform-and-leak-check pass against the staged tree (marker-delimited section strip, JSON key strip, JSON array-element strip, and codified leak patterns) and a runtime-deps verification of shipped scripts.

## Why

The pre-#97 process was free-form audits of the distribution boundary. Across thirteen independent audit rounds the trajectory averaged roughly one novel issue class per round: UAT/SPEC narrative leaks, dead wikilinks to release-excluded targets, monorepo-prefix paths in adopter-shipped files, runtime references to release-excluded scripts. Each class had a codifiable detection pattern after the fact, but free-form audits do not converge: the next round always finds something.

Build-time enforcement closes the loop. The patterns the audit rounds surfaced become entries in `.gaia/release-scrub.yml`. Future leaks become deterministic build failures with structured reports rather than human-eyeball findings.

## What runs

Two primitives, sequenced inside `release.yml` between rsync-staging and tar:

### `gaia-maintainer release scrub <staging-dir>`

Reads `.gaia/release-scrub.yml`. Three transform types, applied in order:

**marker-strip.** Removes content between `<!-- gaia:maintainer-only:start -->` and `<!-- gaia:maintainer-only:end -->` markers in markdown files under `wiki/`, `.claude/`, and `.specify/extensions/gaia/`. Source becomes superset; bundle is subset. The maintainer can carry useful context (entity pages, internal cross-references, audit rationale) in the source repo without leaking into adopter scaffolds. Unbalanced markers are a build failure. A second marker-strip covers `.prettierignore` (which carries maintainer-only globs for byte-sensitive `.gaia/tests/` fixtures) using `#`-comment markers (`# gaia:maintainer-only:start` / `# gaia:maintainer-only:end`), because `.prettierignore` is not markdown and HTML-comment markers would read as literal ignore globs there.

**json-strip.** Deletes maintainer-only keys from structured JSON files. From `package.json` it removes `bin` (registers the `gaia` CLI binary, meaningful only for published packages, not adopter apps) and `scripts.test:forensics` (runs GAIA's internal BATS suite against release-excluded `.gaia/tests/forensics/unit.bats`). Keys use dot-notation paths; dots are path separators, and a literal dot inside a key name is escaped as `\.`. Missing keys are silently skipped. Runs after marker-strip so leak-check sees already-clean JSON.

**json-strip-array-element.** Removes a single array element by predicate, the shape `json-strip` cannot express since it only deletes whole object keys. A selector's dot-notation `path` walks to the target array (a `[]` suffix marks the array to iterate); `match` is a non-empty key→value map, and an element is removed only when every entry matches the element's own value, so a stale selector matches nothing and is a silent no-op rather than a corruption of the shipped file. This lets a maintainer-only hook registration live in committed `.claude/settings.json` (rather than only in the maintainer's gitignored `settings.local.json`) and still be scrubbed out of the adopter bundle; an emptied `hooks[]` array stays `[]` rather than being collapsed or removed.

**leak-check.** For each codified check (UAT-NNN narrative, concrete maintainer SPEC IDs, release-excluded path mentions, sibling-monorepo prefixes, absolute filesystem literals), runs the pattern over the post-strip staging tree. Each check has a scope (path globs that determine which files to scan), an optional path-allowlist (files exempt from this check by design, e.g. `wiki-style.md` itself names patterns to teach the rule), and an optional line-allowlist (regexes that exempt structural matches like filename literals or identifier fragments).

Three checks derive their match set instead of carrying a literal pattern. `wikilink-to-excluded` reads `.gaia/release-exclude` at scan time (resolved against the source repo, which still holds the excluded pages the staging tree drops) and flags any `[[…]]` in a shipped wiki page that resolves to a release-excluded slug. Every `.md` exclude contributes its slug, and every bare-directory exclude walks for the entity pages and dated audit artifacts beneath it, so the excluded-slug set tracks the manifest automatically and a newly excluded page is caught without editing the check. `excluded-workflow-ref` covers the same class for `.github/workflows/`, a directory the literal `maintainer-paths` pattern cannot blanket because some workflows ship and some do not. It reads `.gaia/release-exclude` and flags references in shipped surfaces to any excluded `.github/workflows/*.yml` that has no render template under `.gaia/cli/templates/workflows/` (i.e. is never installable on an adopter, unlike a workflow `/setup-gaia` renders from a `.tmpl`). A newly excluded maintainer-only workflow is covered with no config edit.

`excluded-titles` catches a subtler leak: bare prose, not a link. It fails the build when a shipped `wiki/**` page names a release-excluded page's title as a bare Title-Case mention rather than a `[[wikilink]]`, a backticked path, or text inside a fenced code block or a stripped maintainer-only block, which would otherwise reach an adopter as a dangling pointer to a page their clone never received. Its title set derives at scan time from the `.md` page basenames named in `.gaia/release-exclude` (case-preserving, page-basenames only), minus a config-declared opt-out for known generic titles, and it matches case-sensitively and whole-token while skipping wikilink, backtick, and fenced spans. Fenced-code-block state is derived from delimiter *pairs*, not a per-line toggle: an odd (unbalanced) fence-delimiter count in a page closes nothing, so a trailing lone delimiter and every line after it stay scannable rather than being silently swallowed as "still inside a fence" through end of file.

Non-empty match in any check fails the build with a structured leak report.

### `gaia-maintainer release runtime-deps --staging <dir>`

Walks `.gaia/statusline/**/*.sh`, `.gaia/cli/templates/**/*.sh`, `.gaia/scripts/**/*.sh`, `.claude/hooks/**/*.sh`, `.github/actions/**/*.sh`, `.github/audit/**/*.sh`, and `.specify/extensions/gaia/lib/**/*.sh` inside the staging tree, extracts repo-relative path constants, and verifies each is a shipped path (in `.gaia/manifest.json`), an adopter-owned sentinel (`wiki/hot.md`, `wiki/log.md`, `.gaia/VERSION`, `.gaia/manifest.json`), a directory with at least one shipped file beneath it (the shape a scan-glob directory decays to when a script globs it, e.g. `.claude/hooks/*.sh`), or a runtime-allocated path on adopter machines (`.gaia/local/`, which covers its `cache/` subtree, `.claude/handoff/`, `.claude/worktrees/`, `.claude/agent-memory/`, `.claude/audit/`, plus the per-session marker files).

Extraction stops at the first character that cannot appear in a path, so a reference carrying a glob, a brace expansion, or a variable yields whatever precedes the pattern. Where the pattern opens at a directory boundary that remainder is already the directory token above. Where it opens mid-basename (`.claude/agents/code-audit-*.md`) the remainder is a fragment of a family of names rather than a path, so it is reduced to the directory holding the family and checked as that same directory token. Both shapes therefore ask one question: does the directory this family lives in ship? A script may name a file family by pattern without the scan reading the fragment as a dependency, while a family sourced from a release-excluded directory is still a leak.

Anything else is a runtime-dependency leak, a shipped caller pointing at a release-excluded callee. Lexical scrubbing cannot see this class because the reference survives prose-style transforms.

## Marker discipline

Single-developer marker discipline is acceptable for now. The maintainer wraps maintainer-only blocks; the maintainer wraps consistently. If the project grows multiple maintainers, the cost is an additional convention to enforce in review, flagged as a future revisit, not a present blocker.

The markers are HTML comments to keep them invisible in rendered Markdown (Obsidian, GitHub previews) while remaining trivially line-grep-able.

## What it does NOT catch

The scrub is lexical. It does not understand semantics. Things outside its reach:

- **Runtime dependency chains**: caught by `runtime-deps`, not scrub.
- **Behaviorally maintainer-only logic**: code that calls a release-excluded source path through dynamic require / variable string concatenation. The bundle architecture (esbuild bundles `.gaia/cli/src/` into the shipped binary; nothing else imports from `src/`) makes this unlikely in practice but is not prevented by the scrub.

## How to extend

When a new leak class is identified:

1. Add a codified detection pattern to `.gaia/release-scrub.yml` (for lexical patterns) or `runtime-deps` (for runtime references).
2. Add prior occurrences to `.gaia/cli/health/taxonomy.md` so future free-form audits prime off the baseline.
3. If the new check requires structural exceptions, expand the line-allowlist or path-allowlist with explicit regexes; never accept a generic "skip this file" without rationale.

## See also

- [[Release Workflow]]: full release sequence; this ADR covers only the bundle-time enforcement step.
- [[Update Workflow]]: adopter-side consumption of the bundle.
