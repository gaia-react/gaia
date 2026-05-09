---
type: concept
title: Release Workflow
status: active
created: 2026-04-22
updated: 2026-05-08
tags: [release, claude, maintainer, versioning]
---

# Release Workflow

How GAIA cuts a public release. Two surfaces — the template repo (`gaia-react/gaia`) and the bootstrapper (`gaia-react/create-gaia`) — ship on independent cadences.

> [!note] Audience
> Maintainer-only. This page is excluded from adopter distribution by `.gaia/release-exclude`. Adopter-facing background on what each release contains and how `/update-gaia` consumes it lives in [[Update Workflow]].

## Primitives

| File                                  | Role                                                                                                          |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `.gaia/VERSION`                       | Plain `X.Y.Z`. Single source of truth for the installed version. Survives `/gaia-init`.                       |
| `.gaia/manifest.json`                 | Maps every GAIA-shipped file to a class (`owned` / `shared` / `wiki-owned`). Consumed by [[Update Workflow]]. |
| `.gaia/release-exclude`               | Tar-exclude format. Paths listed here are stripped from the release tarball.                                  |
| `gaia-maintainer release manifest` (CLI)         | Maintainer-only. Walks `git ls-files` + classifier globs; writes `.gaia/manifest.json`.                       |
| `CHANGELOG.md`                        | Keep-a-Changelog format. `## [Unreleased]` at top; `/gaia-release` graduates it to a versioned section.       |
| `.github/workflows/release.yml`       | Tag-triggered (`v*.*.*`). Builds scrubbed tarball, creates GitHub Release with CHANGELOG excerpt.             |

## Versioning (SemVer)

- **Major** — breaking changes to skill/command API, Node bump, framework major upgrade, removed/renamed `.claude/` paths.
- **Minor** — new skills, commands, wiki concept pages; opt-in features.
- **Patch** — bugfixes, docs, in-range dependency bumps.

## Cutting a release

Run `/gaia-release` on a clean `main`. The command is a 13-step orchestrator:

1. Verify clean working tree + on `main`.
2. Verify `wiki/.state.json` is current — either `last_evaluated_sha == HEAD`, or the only drift commits are wiki-sync squash artifacts (subjects starting with `wiki:`). Substantive non-wiki drift STOPs the release; the wiki is stale and would ship out-of-date adopter docs. Maintainer runs `/gaia wiki sync` first. The `wiki:`-prefix bypass exists because PR squash-merging always rewrites the SHA, so the standard flow (`/gaia wiki sync` → merge → `/gaia-release`) leaves the state pointer one squash-commit behind even when content is current; without the bypass the gate is unsatisfiable. See [[Wiki Sync]].
3. Auto-determine bump by analyzing commits since last tag. `patch`/`minor` proceed automatically; `major` stops and asks.
4. Run the [[Quality Gate]]. Stop on failure.
5. Create `release/vX.Y.Z` branch.
6. Bump `package.json` + `.gaia/VERSION`.
7. Auto-draft CHANGELOG from `git log` since last release; present for approval; graduate to `## [vX.Y.Z] — YYYY-MM-DD` and seed a new empty `## [Unreleased]`.
8. Overwrite `wiki/hot.md` with release-baseline content (so adopters clone a fresh slate).
9. Overwrite `wiki/log.md` with a single release-milestone entry (dev history lives in git).
10. Regenerate `.gaia/manifest.json` via `gaia-maintainer release manifest`.
11. Commit on the release branch: `chore(release): vX.Y.Z`. The pre-commit dance updates `wiki/.state.json`'s `last_evaluated_sha` to the new commit's own SHA via amend, so adopters' state files match their release commit on first scaffold.
12. Push branch, open PR via `gh`, merge inline via `gh pr merge --merge`. Release branches have no required checks, so the merge is immediate.
13. Pull `main`, tag the merge commit (`v<NEW_VERSION>`), push the tag.

The tag push triggers [`release.yml`](../../.github/workflows/release.yml), which produces the scrubbed tarball.

## Tarball scrubbing

`release.yml` builds the tarball in five phases:

1. **Stage** — drive the file set from `git ls-files` (not a raw `tar .`) and subtract `.gaia/release-exclude` patterns. `git ls-files` already ignores anything in `.gitignore` (no `.DS_Store`, `node_modules`, build output, `.idea/`); `.gaia/release-exclude` strips the tracked-but-maintainer-only content. `rsync` materializes the include list into `/tmp/gaia-vX.Y.Z/`.
2. **Bundle-time scrub** — `gaia-maintainer release scrub /tmp/gaia-vX.Y.Z` applies the transforms in `.gaia/release-scrub.yml`: marker-delimited section strips and a leak-check pass that mirrors the `wiki-style.md` audit greps. Build fails closed on any leak. See [[Bundle-time Scrub]] for rationale.
3. **Runtime-deps verification** — `gaia-maintainer release runtime-deps --staging /tmp/gaia-vX.Y.Z` walks shipped shell scripts and verifies every explicit path constant resolves to a shipped path, an adopter-owned sentinel, or a runtime-allocated location. Catches the leak class scrubbing cannot see — runtime references survive lexical strip.
4. **Distribution test gate** — `bash .gaia/tests/distribution/run-all.sh` runs Layers 0+1+2 against an independently-staged tree (`build-staging.sh` re-runs the same `git ls-files` + scrub + runtime-deps phases above). Layer 0 confirms an adopter scaffold typechecks, lints, tests, and builds; Layer 1 confirms the bootstrap path survives in a PATH-stripped subshell; Layer 2 builds a Claude-in-Docker image and probes OAuth auth. The gate's `CLAUDE_CODE_OAUTH_TOKEN` comes from GAIA's GitHub organization secrets; per-run cost is $0 on the maintainer's Claude Max subscription. If any scenario fails the release halts — the tarball is never built and `gh release create` never runs, so a broken release cannot publish.
5. **Tar** — `tar -czf gaia-vX.Y.Z.tar.gz -C /tmp gaia-vX.Y.Z`. The same release-exclude list drives `gaia-maintainer release manifest`, so the manifest never references files an adopter cannot have. The categories are spelled out in the next section.

The scrubbed `wiki/hot.md` + `wiki/log.md` contain only the release marker — none of GAIA's internal session cache.

### Bundle-time enforcement

Marker-delimited maintainer-only blocks let the source repo carry content useful to maintainers (entity pages, internal cross-references, audit-decision rationale) without leaking into adopter scaffolds. Wrap a block in `<!-- gaia:maintainer-only:start -->` / `<!-- gaia:maintainer-only:end -->`; `gaia-maintainer release scrub` strips the block before tar.

The leak-check pass is the convergence mechanism the post-#97 audit trajectory predicted: free-form audits found roughly one novel issue class per round; codified detection patterns running against the staging tree close the loop. New leak patterns become explicit `.gaia/release-scrub.yml` entries — visible, reviewable, deterministic.

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
- `wiki/decisions/Bundle-time Scrub.md` — ADR for the bundle-time enforcement primitives; describes maintainer release machinery.

Other wiki pages under `wiki/concepts/`, `wiki/decisions/`, `wiki/dependencies/`, `wiki/modules/`, `wiki/components/`, `wiki/flows/`, `wiki/sources/` ship as `wiki-owned` and are intended for adopter projects to extend.

### 3. Test harnesses and audit harnesses

- `.gaia/tests/` — bats / smoke harness invoked by maintainer CI.
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
- `.gaia/release-scrub.yml` — bundle-time scrub config consumed by `gaia-maintainer release scrub`. Adopters never run releases.

`.gaia/scripts/` ships to adopters: `check-updates.sh` is the background refresher the statusline invokes to populate `Run /sharpen` and `Run /update-gaia` indicators.

### 6. Maintainer dev-tool configs

- `.serena/` — Serena MCP project config. Initialized per-machine by `setup-gaia` on the adopter's side; the template's copy isn't portable. Not in manifest so `/update-gaia` never tries to merge it.

### 7. Scratch and transient

- `.raw/` — scratchpad ingestion drop zone.
- `.gaia/cache/`, `.gaia/local/` — CLI build cache, per-machine state, telemetry analytics.
- `.gaia-backup/`, `.gaia-merge/` — `/gaia-init` backup and `/update-gaia` stage areas.

### 8. Per-machine Claude state

- `.claude/handoff/`, `.claude/worktrees/`, `.claude/agent-memory/`, `.claude/audit/` — generated at runtime under the user's clone; not template content.

### 9. Maintainer-only CI workflows

- `.github/workflows/release.yml` — cuts releases of the GAIA template itself, triggered by `v*.*.*` tags against `.gaia/VERSION`. Adopters never release GAIA, so the workflow is at best a silent passenger and at worst a CI failure if they accidentally tag with `v*`.
- `.github/workflows/cli-tests.yml` — runs `.gaia/cli/` typecheck and vitest. Adopters receive only the bundled binary at `.gaia/cli/gaia`, so there is nothing for the workflow to test on their side.
- `.github/workflows/distribution.yml` — runs the `.gaia/tests/distribution/` harness on a GitHub runner. Manual trigger only (`workflow_dispatch`); the maintainer's `CLAUDE_CODE_OAUTH_TOKEN` org secret authenticates the in-container `claude` calls used by Layer 2 scenarios. Adopters never run distribution tests against their own scaffold, so the workflow is irrelevant on their side.

`tests.yml` and `chromatic.yml` DO ship; both are adopter-relevant. Their `paths-filter` allowlists are written without reference to maintainer-only paths so the filter stays meaningful on an adopter clone.

### 10. Maintainer-only health-audit infrastructure

- `.gaia/cli/health/` — health-audit taxonomy and per-cycle run state. Documents the issue classes prior independent audits found and the "decided / not findings" list so future audits don't re-litigate settled questions.
- `.gaia/cli/src/health/` — health-audit orchestrator + check primitives (added post-PR-#97 on a separate branch). Not imported by `.gaia/cli/src/index.ts`, so esbuild tree-shakes it out of the bundled `gaia` binary.

Adopters audit their own app via the standard `code-review-audit` agent under `.claude/agents/`; the GAIA-template-specific health audit is maintainer-only because its taxonomy and detections target the GAIA repo's surface, not an adopter project.

### 11. Maintainer-only project governance

Adopters use GAIA as a template via `npx create-gaia` to scaffold an independent project. Maintainers clone or fork the GAIA repo itself to contribute upstream. The GAIA template's governance documents describe GAIA, not the adopter's downstream project, and they ship empty consequences for adopters: a CONTRIBUTING file pointing at GAIA test harnesses, a CHANGELOG with GAIA's release history, a SUPPORTERS list of GAIA's supporters, an MIT LICENSE that pre-decides license choice, etc.

- `CHANGELOG.md` — GAIA's release history. Adopters write their own as they ship.
- `CODE_OF_CONDUCT.md` — GAIA's community standards. Adopters set their own (or none).
- `CONTRIBUTING.md` — how to contribute to GAIA. Adopter projects may not accept contributors at all.
- `LICENSE` — GAIA's MIT license. Adopters choose their own license.
- `README.md` — GAIA's marketing and architecture description. `/gaia-init` regenerates it from `.gaia/templates/README.md` (which DOES ship) substituting the project name.
- `SUPPORTERS.md` — list of GAIA's financial supporters. Adopters maintain their own if they want one.

The README template at `.gaia/templates/README.md` is the only governance-style file that ships, because `/gaia-init` consumes it as a strip-branding source.

### Adopter-owned sentinels

These ARE distributed but excluded from `.gaia/manifest.json` by the classifier (not by `.gaia/release-exclude`) because adopters take ownership at first install and `/update-gaia` must never touch them:

- `wiki/hot.md`, `wiki/log.md` — adopter's session cache and change ledger.
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
- [[Bundle-time Scrub]] — rationale for marker-strip + leak-check + runtime-deps; what the system catches, what it does not.
- [[Git Workflow]] — destructive-on-main hook that `/gaia-release` coexists with (the final push is gated behind explicit user confirmation).
