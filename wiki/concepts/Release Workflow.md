---
type: concept
title: Release Workflow
status: active
created: 2026-04-22
updated: 2026-10-03
tags: [release, claude, maintainer, versioning]
---

# Release Workflow

How GAIA cuts a public release. Two surfaces (the template repo (`gaia-react/gaia`) and the bootstrapper (`gaia-react/create-gaia`)) ship on independent cadences.

> [!note] Audience
> Maintainer-only. This page is excluded from adopter distribution by `.gaia/release-exclude`. Adopter-facing background on what each release contains and how `/update-gaia` consumes it lives in [[Update Workflow]].

## Primitives

| File                                     | Role                                                                                                          |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `.gaia/VERSION`                          | Plain `X.Y.Z`. Single source of truth for the installed version. Survives `/gaia-init`.                       |
| `.gaia/manifest.json`                    | Maps every GAIA-shipped file to a class (`owned` / `shared` / `wiki-owned`). Consumed by [[Update Workflow]]. |
| `.gaia/release-exclude`                  | Tar-exclude format. Paths listed here are stripped from the release tarball.                                  |
| `gaia-maintainer release manifest` (CLI) | Maintainer-only. Walks `git ls-files` + classifier globs; writes `.gaia/manifest.json` only once every newly-shipping file has an explicit ship-or-withhold answer, or when the caller passes `--allow-undecided`. |
| `CHANGELOG.md`                           | Keep-a-Changelog format. `## [Unreleased]` at top; `/gaia-release` graduates it to a versioned section.       |
| `.github/workflows/release.yml`          | Tag-triggered (`v*.*.*`). Builds scrubbed tarball, creates GitHub Release with CHANGELOG excerpt.             |

## Versioning (SemVer)

- **Major**: breaking changes to skill/command API, Node bump, framework major upgrade, removed/renamed `.claude/` paths.
- **Minor**: new skills, commands, wiki concept pages; opt-in features.
- **Patch**: bugfixes, docs, in-range dependency bumps.

## Cutting a release

Run `/gaia-release` on a clean `main`. The command is a 15-step orchestrator:

1. Verify clean working tree + on `main`.
2. Verify `wiki/.state.json` is current: either `last_evaluated_sha == HEAD`, or the only drift commits are wiki-sync squash artifacts (subjects starting with `wiki:`). Substantive non-wiki drift STOPs the release; the wiki is stale and would ship out-of-date adopter docs. Maintainer runs `/gaia-wiki` first (the full chain, landing through its own PR). The `wiki:`-prefix bypass exists because PR squash-merging always rewrites the SHA, so the standard flow (`/gaia-wiki` → merge → `/gaia-release`) leaves the state pointer one squash-commit behind even when content is current; without the bypass the gate is unsatisfiable. When a squash orphans `last_evaluated_sha` outright (`reachable:false`), `gaia wiki state` reports a hardcoded `commits_ahead:0`, a silent zero that would hide the un-evaluated window. Preflight catches this: it reads `drift_count` from `gaia wiki state`, counted from `suggested_base` (the recovery baseline) and excluding wiki bookkeeping commits, so an orphaned state still blocks on substantive drift instead of green-lighting on the zero. See [[Wiki Sync]].
3. Auto-determine bump by analyzing commits since last tag. `patch`/`minor` proceed automatically; `major` stops and asks.
4. Run the [[Quality Gate]]. Stop on failure.
5. Create `release/vX.Y.Z` branch.
6. Bump the root `package.json`, `frontend/package.json` (its `version` must equal the root's: `env.server.ts` reads it through `npm_package_version`, and a bats case fails on drift), and `.gaia/VERSION`.
7. Auto-draft a CHANGELOG block from `git log` since last release and present it for review; it is an aid, so fold anything the hand-written `## [Unreleased]` block is missing into that block by hand. Then graduate `## [Unreleased]` in place to `## [X.Y.Z] - YYYY-MM-DD` (no `v` prefix; `release.yml` extracts the section by the bare version), seeding a new empty `## [Unreleased]` above it. The hand-written entries are the released block; the drafted one is never written to the file, and an empty `## [Unreleased]` is refused rather than dated. The graduator also keeps the Keep-a-Changelog reference-link block current: it repoints the `[Unreleased]` compare link at the new version and inserts a `[X.Y.Z]` release-tag definition, deriving the repo base URL from the existing `[Unreleased]` link.
8. Overwrite `wiki/log.md` with a single release-milestone entry (dev history lives in git).
9. Regenerate `.gaia/manifest.json` via `gaia-maintainer release manifest --allow-undecided`. The release path takes the escape hatch deliberately: a release cut from a tree containing a new file must not start failing.
10. Commit on the release branch: `chore(release): vX.Y.Z`. The pre-commit dance updates `wiki/.state.json`'s `last_evaluated_sha` to the new commit's own SHA via amend, so adopters' state files match their release commit on first scaffold.
11. Push branch, open PR via `gh`. The release PR is subject to the same CI gate (`Vitest and Playwright`, `Run Chromatic`) and `code-review-audit` merge handshake as any other PR; see [[PR Merge Workflow]]. `gh pr merge --merge --auto` is the normal path: base-branch protection rejects a plain `--merge`, and `--auto` lets GitHub complete the merge once checks pass.
12. Once the PR shows `MERGED`, pull `main`, tag the merge commit (`v<NEW_VERSION>`), push the tag.
13. Lockstep `create-gaia` and the website. The website update includes bumping three version constants, invoking the `release-notes` skill to generate the public changelog entry (`<version>.ts`) for the site, and overwriting the GitHub release body with adopter-facing notes rendered from that file via `render-release-md.mjs` (so the GitHub release and the website changelog stay in sync). For a 2.x release that 1.x adopters can still see (the 2.0.0 cut), the release data carries a `preamble` (the routing line, the Proceed side-effects line, the sha256 line) that the renderer emits verbatim before the headline, so the rewritten body still starts with the routing line. The step ends with `gh release view <tag> --json body --jq .body | head -1`, which must equal `On GAIA 1.6.1? Choose Abort, then paste the prompt from https://gaiareact.com/migrate into a fresh session.`; any other first line means the rewrite dropped the preamble, so re-render before moving on.
14. Lockstep the docs site (`../docs` sibling checkout): update the sidebar version constant and commit directly to `main`.

The tag push triggers [`release.yml`](../../.github/workflows/release.yml), which produces the scrubbed tarball.

> [!note] Abbreviated SHAs are resolved before range queries
> `gaia wiki state --json` reports `state_sha` and `suggested_base` in short form. A caller that feeds either into a git range query (`<sha>..HEAD`) resolves it to a full SHA first via `git rev-parse --verify`; the `release preflight` subcommand does this before its wiki-sync drift scan (Step 2), for both the reachable `state_sha` range and the orphaned-recovery `suggested_base` range. Skipping the resolution makes the range query fail or silently return the wrong set on repos where the short SHA is ambiguous.

## Tarball scrubbing

`release.yml` builds the tarball in five phases:

1. **Stage**: drive the file set from `git ls-files` (not a raw `tar .`) and subtract `.gaia/release-exclude` patterns. `git ls-files` already ignores anything in `.gitignore` (no `.DS_Store`, `node_modules`, build output, `.idea/`); `.gaia/release-exclude` strips the tracked-but-maintainer-only content. The staging filter compiles `.gaia/release-exclude` into the anchored regexes it feeds to `grep -vE -f` by invoking `gaia-maintainer release exclude-regex`, the single compiler every release surface calls. `rsync` materializes the include list into `/tmp/gaia-vX.Y.Z/`. `.gaia/scripts/assert-no-release-leak.sh` then re-scans the materialized tree against the same exclude regex and fails closed: a leak exits 1, a scan that could not complete (an unreadable directory, a dead enumeration) exits 2, and either halts the release rather than shipping an unverified tree.
2. **Bundle-time scrub**: `gaia-maintainer release scrub /tmp/gaia-vX.Y.Z` applies the transforms in `.gaia/release-scrub.yml`: marker-delimited section strips and a leak-check pass that mirrors the `wiki-style.md` audit greps. Build fails closed on any leak. See [[Bundle-time Scrub]] for rationale.
3. **Runtime-deps verification**: `gaia-maintainer release runtime-deps --staging /tmp/gaia-vX.Y.Z` walks shipped shell scripts and verifies every explicit path constant resolves to a shipped path, an adopter-owned sentinel, or a runtime-allocated location. Catches the leak class scrubbing cannot see; runtime references survive lexical strip.
4. **Distribution test gate**: `bash .gaia/tests/distribution/run-all.sh` runs Layers 0+1 against an independently-staged tree (`build-staging.sh` re-runs the same `git ls-files` + scrub + runtime-deps phases above). Layer 0 confirms an adopter scaffold typechecks, lints, tests, and builds; Layer 1 confirms the bootstrap path survives in a PATH-stripped subshell. If any scenario fails the release halts; the tarball is never built and `gh release create` never runs, so a broken release cannot publish.
5. **Tar**: `tar -czf gaia-bundle-vX.Y.Z.tar.gz -C /tmp gaia-vX.Y.Z`, plus `gaia-bundle-vX.Y.Z.tar.gz.sha256` (`shasum -a 256`). The asset is `gaia-bundle-<tag>.tar.gz`, not `gaia-<tag>.tar.gz`, deliberately: v1.6.1's `/update-gaia` downloads with `--pattern "gaia-${tag}.tar.gz"`, and the 2.x manifest is keyed on `frontend/` paths a 1.6.1 merge would read as deletions of the adopter's app. Under the new name that download fails at its fetch step, before any write. `.gaia/scripts/compose-release-body.sh` then builds the release body, with the 1.6.1 routing line first (fail-closed for `v2.0.0`), the Proceed side effects (a `chore/update-gaia-*` branch is created and `.gaia-backup` and `.gaia/cache` tag dirs pruned before the expected `FETCH_FAILED`), and the sha256. `.gaia/tests/lib/release-asset-name.bats` pins the asset name against `release.yml` and the `/update-gaia` Step 5 pattern. The same release-exclude list drives `gaia-maintainer release manifest`, so the manifest never references files an adopter cannot have. What the list withholds, and why, is covered in the next section.

The scrubbed `wiki/log.md` contains only the release marker; none of GAIA's internal change history.

Three staleness gates run ahead of the tarball build so a stale committed artifact cannot ship silently: a binary rebuild-freshness check byte-compares the committed `.gaia/cli/gaia`/`gaia-maintainer` against a fresh bundle from source; a templates freshness check snapshots committed `.gaia/cli/templates/` before the bundle, regenerates from source, and `diff -rq`s the two, since template content resolves at runtime via `import.meta.url` and never enters the bundled binary, so the byte-compare alone cannot catch a stale committed template; and `gaia-maintainer release scrub-wiki --check` compares committed `wiki/log.md` against fresh-rendered release-clean output (dates normalized out of the comparison) and exits non-zero on drift without rendering anything, so a skipped scrub can no longer ship a stale wiki. Any gate failing halts the release before the tarball builds.

### Bundle-time enforcement

Marker-delimited maintainer-only blocks let the source repo carry content useful to maintainers (entity pages, internal cross-references, audit-decision rationale) without leaking into adopter scaffolds. Wrap a block in `<!-- gaia:maintainer-only:start -->` / `<!-- gaia:maintainer-only:end -->`; `gaia-maintainer release scrub` strips the block before tar.

New leak patterns become explicit `.gaia/release-scrub.yml` entries: visible, reviewable, deterministic.

## Distribution Boundary

GAIA is a template repository that also carries its own maintainers' tooling: release machinery, test and audit harnesses, CI that gates only GAIA's own pull requests, dev-tool configs, and project governance. None of that has a counterpart on an adopter's clone, so the release withholds it, and the source tree carries it on purpose.

`.gaia/release-exclude` is the single authoritative list of what is withheld. Its numbered categories each carry their rationale beside the paths they cover, and this page does not restate them. Everything git tracks that no line there masks ships in the adopter tarball and is classified in `.gaia/manifest.json`. An audit that flags a withheld path as "missing from manifest" should read that path's category in `.gaia/release-exclude` first: the absence is intentional, not a bug.

### Adopter-owned sentinels

These ARE distributed but excluded from `.gaia/manifest.json` by the classifier (not by `.gaia/release-exclude`) because adopters take ownership at first install and `/update-gaia` must never touch them:

- `wiki/log.md`: adopter's change ledger.
- `.gaia/VERSION`, `.gaia/manifest.json`: bumped only by `/update-gaia`.
- `.gaia/packages.json`: the package registry; an adopter adds a package by editing it.
- `<package>/.claude/settings.json` (`frontend/.claude/settings.json`): generated by `gaia packages sync-settings`, shipped so a scaffold starts drift-clean, and regenerated after every `/update-gaia` merge instead of merged. Any `.claude/settings.json` below the root is matched by the classifier's generated-settings rule.

The classifier is in `.gaia/cli/src/release/manifest.ts`, `ADOPTER_OWNED_SENTINELS` constant.

## create-gaia bootstrapper

Separate repo, separate npm package (`create-gaia`). Zero runtime deps. When an adopter runs `npx create-gaia@latest my-app`:

1. Resolves the target version (flag, or latest GitHub release).
2. Downloads the release tarball from `github.com/gaia-react/gaia/releases/download/vX.Y.Z/gaia-vX.Y.Z.tar.gz`. Releases from 2.0.0 on publish `gaia-bundle-vX.Y.Z.tar.gz` instead, so create-gaia has to switch to the new asset name before the 2.0.0 tag.
3. Extracts into `my-app/`.
4. `git init` + initial commit (unless `--no-git`).
5. `pnpm install` (after `corepack enable pnpm`), unless `--no-install`. The scaffolded project pins pnpm via `packageManager` in `package.json`; corepack provisions the matching version transparently.
6. Prints welcome pointing at `/gaia-init`.

The CLI is deliberately thin; heavy lifting (i18n, branding strip, plugin install) happens inside Claude Code via `/gaia-init`. See the `create-gaia` repo for the implementation.

## Distribution boundary vs. source tree presence

A file's presence in the GAIA source tree (`gaia/.claude/commands/`, etc.) does **not** mean it ships to end users. The release pipeline filters via `.gaia/release-exclude` (and related classifiers). Maintainer-only tools live in the source tree intentionally and are excluded at release time.

**How to apply:** Before recommending or executing the removal of any file from `gaia/`, check `.gaia/release-exclude` and the release pipeline first. If the file is already excluded from distribution, leave it alone; the boundary is working. Only act when the file is actually leaking through to end users.

**Note:** `gaia/.claude/commands/health-audit.md` is a working maintainer tool already excluded from distribution by `.gaia/release-exclude`. Its presence in the source tree is not grounds for deletion. Check the exclusion list before removing any file.

## See also

- [[Update Workflow]]: how adopters pull later releases into an initialized project without clobbering drift.
- [[PR Merge Workflow]]: the audit + marker handshake and `--auto` merge pattern the release PR follows like any other.
- [[Quality Gate]]: must pass before `/gaia-release` will let you tag.
- [[Wiki Sync]]: drift gate at Step 2; release is blocked until `wiki/.state.json` matches HEAD.
- [[Bundle-time Scrub]]: rationale for marker-strip + leak-check + runtime-deps; what the system catches, what it does not.
- [[Git Workflow]]: destructive-on-main hook that `/gaia-release` coexists with (the final push is gated behind explicit user confirmation).
- [[Worktrees]]: the per-tree state model behind `.claude/worktrees/`, generated at runtime and excluded from the release tarball.
