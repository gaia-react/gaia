---
type: concept
title: Release Workflow
status: active
created: 2026-04-22
updated: 2026-05-07
tags: [release, claude, maintainer, versioning]
---

# Release Workflow

How GAIA cuts a public release. Two surfaces — the template repo (`gaia-react/gaia`) and the bootstrapper (`gaia-react/create-gaia`) — ship on independent cadences.

> [!note] Audience
> The `/gaia-release` command is **maintainer-only** and stripped from distribution tarballs by `.gaia/release-exclude`. Adopters never see it. This page documents the flow so adopters understand what each GAIA release contains and why `/update-gaia` behaves the way it does.

## Primitives

| File                                  | Role                                                                                                          |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `.gaia/VERSION`                       | Plain `X.Y.Z`. Single source of truth for the installed version. Survives `/gaia-init`.                       |
| `.gaia/manifest.json`                 | Maps every GAIA-shipped file to a class (`owned` / `shared` / `wiki-owned`). Consumed by [[Update Workflow]]. |
| `.gaia/release-exclude`               | Tar-exclude format. Paths listed here are stripped from the release tarball.                                  |
| `gaia release manifest` (CLI)         | Maintainer-only. Walks `git ls-files` + classifier globs; writes `.gaia/manifest.json`.                       |
| `CHANGELOG.md`                        | Keep-a-Changelog format. `## [Unreleased]` at top; `/gaia-release` graduates it to a versioned section.       |
| `.github/workflows/release.yml`       | Tag-triggered (`v*.*.*`). Builds scrubbed tarball, creates GitHub Release with CHANGELOG excerpt.             |

## Versioning (SemVer)

- **Major** — breaking changes to skill/command API, Node bump, framework major upgrade, removed/renamed `.claude/` paths.
- **Minor** — new skills, commands, wiki concept pages; opt-in features.
- **Patch** — bugfixes, docs, in-range dependency bumps.

## Cutting a release

Run `/gaia-release` on a clean `main`. The command is a 13-step orchestrator:

1. Verify clean working tree + on `main`.
2. Verify `wiki/.state.json` is current — either `last_evaluated_sha == HEAD`, or the only drift commits are wiki-sync squash artifacts (subjects starting with `wiki:`). Substantive non-wiki drift STOPs the release; the wiki is stale and would ship out-of-date adopter docs. Maintainer runs `/wiki-sync` first. The `wiki:`-prefix bypass exists because PR squash-merging always rewrites the SHA, so the standard flow (`/wiki-sync` → merge → `/gaia-release`) leaves the state pointer one squash-commit behind even when content is current; without the bypass the gate is unsatisfiable. See [[Wiki Sync]].
3. Auto-determine bump by analyzing commits since last tag. `patch`/`minor` proceed automatically; `major` stops and asks.
4. Run the [[Quality Gate]]. Stop on failure.
5. Create `release/vX.Y.Z` branch.
6. Bump `package.json` + `.gaia/VERSION`.
7. Auto-draft CHANGELOG from `git log` since last release; present for approval; graduate to `## [vX.Y.Z] — YYYY-MM-DD` and seed a new empty `## [Unreleased]`.
8. Overwrite `wiki/hot.md` with release-baseline content (so adopters clone a fresh slate).
9. Overwrite `wiki/log.md` with a single release-milestone entry (dev history lives in git).
10. Regenerate `.gaia/manifest.json` via `gaia release manifest`.
11. Commit on the release branch: `chore(release): vX.Y.Z`. The pre-commit dance updates `wiki/.state.json`'s `last_evaluated_sha` to the new commit's own SHA via amend, so adopters' state files match their release commit on first scaffold.
12. Push branch, open PR via `gh`, merge inline via `gh pr merge --merge`. Release branches have no required checks, so the merge is immediate.
13. Pull `main`, tag the merge commit (`v<NEW_VERSION>`), push the tag.

The tag push triggers [`release.yml`](../../.github/workflows/release.yml), which produces the scrubbed tarball.

## Tarball scrubbing

`release.yml` builds the tarball from `git ls-files` (not a raw `tar .`) and then subtracts `.gaia/release-exclude` patterns. Two-layer filter: `git ls-files` already ignores anything in `.gitignore` (no `.DS_Store`, `node_modules`, build output, `.idea/`); `.gaia/release-exclude` additionally strips tracked-but-maintainer-only content. The same exclusion list drives `gaia release manifest`, so the manifest never references files an adopter cannot have. The categories are spelled out in the next section.

The scrubbed `wiki/hot.md` + `wiki/log.md` contain only the release marker — none of GAIA's internal session cache.

## Distribution Boundary

The exclusion categories below are authoritative. `.gaia/release-exclude` is the executable copy; this section is the human-readable narrative. Anything **not** listed here ships in the adopter tarball and is classified in `.gaia/manifest.json`. Future audits that flag any of the listed paths as "missing from manifest" should consult this page first — the absence is intentional, not a bug.

### 1. Maintainer-only Claude commands

- `.claude/commands/gaia-release.md` — cuts releases of the GAIA template itself.

The other `/gaia-*` commands (`plan`, `handoff`, `pickup`, `audit`) are adopter-useful and DO ship.

### 2. Maintainer-only wiki content

- `wiki/entities/` — team and people pages specific to the GAIA project.
- `wiki/meta/` — lint and consolidate audit reports; references specific commits and dates.
- `wiki/.obsidian/workspace.json` — per-machine Obsidian layout state.
- `wiki/concepts/Release Workflow.md` — this page; documents GAIA administration, not adopter workflow.

Other wiki pages under `wiki/concepts/`, `wiki/decisions/`, `wiki/dependencies/`, `wiki/modules/`, `wiki/components/`, `wiki/flows/`, `wiki/sources/` ship as `wiki-owned` and are intended for adopter projects to extend.

### 3. Test harnesses and audit harnesses

- `.claude-tests/` — bats / smoke harness invoked by maintainer CI.
- `.claude/rules/_internal/` — rules consumed only by the smoke harness; their `@`-imports would dangle on adopter installs.
- `.specify/extensions/gaia/test/` — GAIA SPEC UAT runbooks.

### 4. CLI maintainer source

Adopters receive only the bundled binary at `.gaia/cli/gaia` plus the runtime templates at `.gaia/cli/templates/`. Everything under `.gaia/cli/` else stays in the template repo:

- `.gaia/cli/src/`, `.gaia/cli/test-fixtures/`, `.gaia/cli/__tests__/`
- `.gaia/cli/package.json`, `pnpm-lock.yaml`, `tsconfig.json`, `vitest.config.ts`, `.gitignore`
- `.gaia/cli/node_modules/`, `.gaia/cli/dist/` (also gitignored, defense-in-depth)

Excluding the source prevents adopters from accidentally rebuilding the binary out from under themselves with a different toolchain.

### 5. Release-time maintainer tooling

- `.gaia/release-exclude` — this exclusion file itself.
- `.gaia/scripts/` — legacy scripts (`generate-manifest.mjs` was superseded by `gaia release manifest`; the directory is kept for reference).

### 6. Maintainer dev-tool configs

- `.serena/` — Serena MCP project config. Initialized per-machine by `setup-gaia` on the adopter's side; the template's copy isn't portable. Not in manifest so `/update-gaia` never tries to merge it.

### 7. Scratch and transient

- `.raw/` — scratchpad ingestion drop zone.
- `.gaia/cache/`, `.gaia/local/` — CLI build cache, per-machine state, telemetry analytics.
- `.gaia-backup/`, `.gaia-merge/` — `/gaia-init` backup and `/update-gaia` stage areas.

### 8. Per-machine Claude state

- `.claude/handoff/`, `.claude/worktrees/`, `.claude/agent-memory/`, `.claude/audit/` — generated at runtime under the user's clone; not template content.

### Adopter-owned sentinels

These ARE distributed but excluded from `.gaia/manifest.json` by the classifier (not by `.gaia/release-exclude`) because adopters take ownership at first install and `/update-gaia` must never touch them:

- `wiki/hot.md`, `wiki/log.md` — adopter's session cache and change ledger.
- `CHANGELOG.md` — adopter's project changelog.
- `.gaia/VERSION`, `.gaia/manifest.json` — bumped only by `/update-gaia`.

The classifier is in `.gaia/cli/src/release/manifest.ts` — `ADOPTER_OWNED_SENTINELS` constant.

## create-gaia bootstrapper

Separate repo, separate npm package (`create-gaia`). Zero runtime deps. When an adopter runs `npx create-gaia@latest my-app`:

1. Resolves the target version (flag, or latest GitHub release).
2. Downloads the release tarball from `github.com/gaia-react/gaia/releases/download/vX.Y.Z/gaia-vX.Y.Z.tar.gz`.
3. Extracts into `my-app/`.
4. `git init` + initial commit (unless `--no-git`).
5. `pnpm install` (after `corepack enable pnpm`), unless `--no-install`. The scaffolded project pins pnpm via `packageManager` in `package.json`; corepack provisions the matching version transparently.
6. Prints welcome pointing at `/gaia-init`.

The CLI is deliberately thin — heavy lifting (i18n, branding strip, plugin install) happens inside Claude Code via `/gaia-init`. See the `create-gaia` repo for the implementation.

## See also

- [[Update Workflow]] — how adopters pull later releases into an initialized project without clobbering drift.
- [[Quality Gate]] — must pass before `/gaia-release` will let you tag.
- [[Wiki Sync]] — drift gate at Step 2; release is blocked until `wiki/.state.json` matches HEAD.
- [[Git Workflow]] — destructive-on-main hook that `/gaia-release` coexists with (the final push is gated behind explicit user confirmation).
