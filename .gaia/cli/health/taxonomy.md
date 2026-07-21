# GAIA Health Audit Taxonomy

Living document. Maintainer-only. Excluded from adopter distribution via `.gaia/release-exclude` category 10.

## Purpose

The audit baseline. An audit reads it first, then walks the distribution boundary. Items in **Issue classes** must be verified absent (regressions matter). Items in **Decided / not findings** are not raised. Anything else; known class still present, or a genuinely new pattern; is the audit's output.

Without a shared baseline, fresh audit agents re-discover settled questions and burn tokens on re-litigation.

**Cross-class process gate (load-bearing).** When fixing any class, rerun the class's detection across the entire scoped corpus before reporting closure; not just the file the original finding lived in. Spot-fixes leak across siblings. The maintainer-path and monorepo-prefix scrubs are the canonical examples; the rule applies to every class with a corpus-walking detection (UAT/SPEC scrubs, maintainer-path scrubs, monorepo-prefix scrubs, etc.). The wikilink-to-excluded and excluded-titles classes are the exception that proves the rule: each build-time check derives its own set and walks the full shipped-wiki corpus every run, so closure is already corpus-wide without a manual rerun.

## Composition

The shared Claude-integration check classes (hook integrity; skill/command/agent frontmatter; rule hygiene; `CLAUDE.md` hygiene; settings hygiene; GAIA-install fitness; wiki fitness) and the triage/heal orchestration protocol live in `wiki/decisions/Claude Integration Fitness.md`. This taxonomy retains only the maintainer distribution-boundary / CLI-surface / forensics / tests classes.

`/health-audit` runs the shared protocol over the seven fitness categories as its shared-fitness bucket (see runbook §Bucket E: Shared Claude-integration fitness). Cross-references are one-directional: this file and the runbook reference the wiki page; the wiki page never references `.gaia/cli/health/` paths.

## How to prime an audit

Pass this file (or its path) to the audit agent's context with:

> Read this taxonomy first. Skip re-litigating items in "Decided / not findings". Verify items in "Issue classes" are absent in the current code. Flag anything novel.

## Issue classes

Each entry: pattern, codified detection where one exists, prior occurrences (commit SHA that fixed each).

### Wiki & documentation

**Wiki documentation surface drift.** Decision/concept pages enumerating CLI primitives or features fall behind the actual surface as new primitives land.

- Detection: cross-reference enumerated lists in `wiki/decisions/` and `wiki/concepts/` against `.gaia/cli/src/*/index.ts` HELP_TEXT for that domain
- Prior: `wiki/decisions/Wiki Management.md` listed 7 of 10 wiki primitives (e665b40)

**Shipped wiki pages link to release-excluded targets via wikilinks.** A `[[X]]` wikilink in an adopter-shipped wiki page resolves to a page under `wiki/entities/`, `wiki/meta/`, `wiki/_archived/`, or any other release-excluded location. Adopter sees a dangling reference, and the link itself signposts maintainer-only content even when the destination is excluded. `gaia wiki dead-paths` only catches backticked filesystem paths, not wikilinks; `gaia wiki orphans` is the inverse direction (pages with no inbound links).

- Detection (manual cross-check; the build-time check below is authoritative): `grep -rEn '\[\[' wiki/index.md wiki/README.md wiki/overview.md wiki/concepts/ wiki/decisions/ wiki/modules/ wiki/components/ wiki/flows/ wiki/dependencies/` and cross-check each target slug against pages whose path matches a `.gaia/release-exclude` pattern or lives under `wiki/entities/|wiki/meta/|wiki/_archived/`.
- **Process gate (load-bearing):** the `wikilink-to-excluded` scrub check walks every shipped wiki domain on each run, so running it (not a per-file spot-check) is what confirms closure. The lesson that motivated this gate stands: audit #11 fixed only `wiki/index.md` and audit #12 found five regressions of the same class in other domains; a spot-fix never closes the class.
- Codified in: `.gaia/release-scrub.yml` `wikilink-to-excluded` check. It derives the excluded-slug set at scan time from `.gaia/release-exclude`, resolved against the source repo (that file excludes itself, so it never reaches the staging tree the other checks scan). Every `.md` exclude contributes its slug; every bare-directory exclude (`wiki/entities`, `wiki/meta`) contributes the directory slug plus the slug of each page beneath it, so entity pages and the dated audit artifacts under `wiki/meta/` (`consolidate-report-*`, `lint-report-*`, `staleness-audit-*`) are covered without enumeration. Matching is case-insensitive and alias/anchor-aware. A newly excluded page is caught with no edit to the check; the set cannot drift from `.gaia/release-exclude`.
- Prior: `wiki/index.md` carried `## Entities` and `## Meta` sections plus a `[[Release Workflow]]` bullet, all resolving to release-excluded pages (audit #11 fix). `[[Release Workflow]]` wikilinks in `Update Workflow.md`, `Wiki Sync.md`, `Update Merge.md` and a `[[GAIA]]` wikilink in `GAIA Philosophy.md` were missed by audit #11's spot-fix and caught by audit #12. Audit #13 verified the class clean across all shipped wiki domains end-to-end.

**Shipped wiki pages name a release-excluded page's title in bare prose.** A shipped `wiki/**` page mentions a release-excluded wiki page's TITLE as a Title-Case reference that is not a `[[wikilink]]`, not a backticked path, and not inside a fenced code block or a stripped `gaia:maintainer-only` marker block. Adopter sees a dangling pointer to a page their clone never received. The sibling `wikilink-to-excluded` matches only wikilinks, `maintainer-paths` matches path prefixes, and `gaia wiki dead-paths` matches backticked filesystem paths, so a bare title mention is invisible to all three.

- Detection (manual cross-check; the build-time check below is authoritative): grep each release-excluded page's Title-Case basename across `wiki/**/*.md`, then confirm every hit sits outside a `[[wikilink]]`, an inline-backtick span, a fenced code block, and a `gaia:maintainer-only` marker block. The build-time check walks the full shipped-wiki corpus every run, so running it, not a per-file spot-check, is what confirms closure.
- Codified in: `.gaia/release-scrub.yml` `excluded-titles` check. It derives the checked-title set at scan time from the `.md` page basenames named in `.gaia/release-exclude` (resolved against the source repo, which excludes itself): every `.md` exclude contributes its basename, case-preserved, and every `.md` page beneath a bare-directory exclude contributes its basename too, but the bare-directory basename itself is not included (a directory name is not a page title a reader follows). Matching is case-sensitive, whole-token, and skips `[[wikilink]]`, inline-backtick, and fenced spans; a config-declared `title-opt-out` (each entry `#`-justified) removes the known-generic titles (`GAIA`, `dashboard`, `Steven Sacks`, `Release Workflow`) whose bare-prose form is indistinguishable from ordinary text. The set cannot drift from `.gaia/release-exclude`; a newly excluded distinctive page is covered with no config edit. Mirrors `wikilink-to-excluded`.
- Prior: `wiki/decisions/Quality Gate.md` named the release-excluded page `Forensics Triage Workflow` in bare prose, but inside a `gaia:maintainer-only` marker block (stripped before this check reads the file); `wiki/index.md` and one other shipped page carried the same title only as `[[wikilinks]]` (the sibling `wikilink-to-excluded` class's territory). Both forms were neutralized before this check existed, so no active leak exists, but the class had no guard until now.

### CLI surface

**Top-level `--help` text drift.** `.gaia/cli/src/index.ts` HELP_TEXT lists subcommands by hand; new subcommands added to a domain router don't propagate.

- Detection: cross-reference each domain router's HELP_TEXT against the top-level HELP_TEXT line for that domain
- Prior: `wiki` line listed 7 of 10 primitives (e665b40)

**Stale comments referencing primitive count or phase context.** Comments say "this router only ships the seven primitives" or "Phase N of the Claude Integration Optimization plan extracts…" or "Phase N task-adaptation-inject…" after the count or phase is no longer current. Wiki-style.md scopes to `app/**`, but the same hygiene applies inside any shipped or maintainer source; comments describe what the file is, not how it got there.

- Detection: `grep -rEn "the (seven|eight|nine|ten|N) primitives|Phase [0-9]+ (of|task-adaptation|adaptation-inject)" .gaia/cli/src/ .claude/hooks/ .gaia/statusline/`
- Prior: 5 sibling files (`init`, `update`, `update/merge`, `wiki`, `release` `index.ts`) carried `Phase N of the Claude Integration Optimization plan` headers; `wiki/index.ts:7` additionally said "the seven primitives" (ten ship); fixed in `ac7c019`. `.claude/hooks/wiki-session-start.sh:12` said "Phase 5 task-adaptation-inject writes …"; fixed in 10th audit.

**Test scripts with baked-in `--run`.** `block-bare-test.sh` requires every `pnpm`/`npm test` invocation to carry `--run` (the watch-mode guard); it matches the command segment and never inspects `package.json`. A `scripts.test` value that also bakes `--run` doubles the flag on a `pnpm test --run` call (`vitest --run --run`) and errors. The script value stays the bare runner (`vitest …`); `--run` belongs on the caller's command line.

- Detection: read `.gaia/cli/package.json scripts.test`; verify no `--run` baked in
- Prior: `--run` baked in caused command failure (ed94f49)

**Bundled binary out of sync with source.** `.gaia/cli/src/index.ts` HELP_TEXT (or any user-facing string) edited but `.gaia/cli/gaia` not rebundled. Adopters run the binary.

- Detection: rebundle (`pnpm -C .gaia/cli bundle`) and check `git diff .gaia/cli/gaia` is empty
- Prior: implicit pre-rebundle drift after each src edit; rebundle is now part of every src-touching commit

### Distribution boundary

**Manifest stale relative to distributed file set.** Files added to the template don't auto-classify; manifest count diverges from `git ls-files | grep -v -f release-exclude`.

- Detection: run `gaia-maintainer release manifest --allow-undecided` and `git diff .gaia/manifest.json` should be empty
- Prior: 370 → 426 entry rebuild (ed94f49); 426 → 425 after `release.yml` excluded (98f7a62)

**Maintainer-only files mis-classified as `shared` in manifest.** Files that don't ship should be in `release-exclude`, not in the manifest at all.

- Detection: cross-reference `release-exclude` paths against manifest entries; should be zero overlap
- Prior: `release.yml` was `shared` in manifest until 98f7a62 moved it to category 9

**Classifier sets contain release-excluded paths (dead code).** `ADOPTER_OWNED_SENTINELS`, `SHARED`, `WIKI_OWNED_EXACT` in `.gaia/cli/src/release/manifest.ts` enumerate paths whose classification is overridden by `.gaia/release-exclude` running first in `buildManifest`. Such entries are dead; the classifier never sees them; and rot the contract that the classifier expresses.

- Detection: cross-reference each string in `ADOPTER_OWNED_SENTINELS|SHARED|WIKI_OWNED_EXACT` against `.gaia/release-exclude` patterns; expect zero overlap.
- Prior: `CHANGELOG.md` in `ADOPTER_OWNED_SENTINELS` and `README.md` in `SHARED` were dead after release-exclude category 11 added root governance files (audit #11 fix).

**Maintainer paths referenced in adopter-shipped files.** Distributed workflows, wiki pages, instruction files (skills, commands, agents, rules), `.claude/hooks/`, `.gaia/statusline/`, root-level files (CLAUDE.md, etc.), shipped `.specify/extensions/gaia/` instruction surfaces, or hook script comments mention `.gaia/cli/src/`, `.specify/extensions/gaia/test/`, `.specify/specs/`, `.gaia/tests/`, `.gaia/scripts/tests/`, `.github/audit/tests/`, `release-exclude`, etc.; paths that don't exist on adopter clones. Concrete maintainer SPEC IDs (`SPEC-001`, `SPEC-003`, etc.) used as if they were system-wide constants count too: on adopter machines those IDs refer to whatever the adopter happened to author first, not the maintainer artifact.

- Detection (broad): `grep -rEn "\.gaia/cli/src/|\.gaia/cli/test-fixtures/|\.gaia/cli/__tests__/|\.gaia/cli/health/|\.specify/extensions/gaia/test/|\.specify/specs/|\.gaia/tests/|\.gaia/scripts/tests/|\.github/audit/tests/|\.claude/rules/maintainers/" CLAUDE.md .claude/ wiki/ .gaia/statusline/ .specify/extensions/gaia/{README.md,commands,lib,rules,templates} --include="*.md" --include="*.sh" --include="*.yml"` (run from repo root). Every match outside the allowlist is a leak. Note the scope: must include root `CLAUDE.md`, `.gaia/statusline/`, shipped hooks under `.claude/hooks/`, AND `.specify/extensions/gaia/` non-test surfaces; pre-9th-audit greps were `.claude/`-scoped and missed root + statusline; pre-13th-audit greps additionally missed shipped extension instruction files.
- Detection, concrete maintainer SPEC IDs: `grep -rEn "\bSPEC-[0-9]{3,}\b" CLAUDE.md .claude/ wiki/ .gaia/statusline/ .specify/extensions/gaia/{README.md,commands,lib,rules,templates}` excluding the allowlist below. Generic placeholders (`SPEC-NNN`, `SPEC-NNN.md`) are fine; instantiated IDs in narrative prose are the leak.
- Allowlist:
  - `wiki/concepts/Release Workflow.md` Distribution Boundary section legitimately describes the maintainer surface.
  - `.claude/rules/instruction-files.md` counter-example prose.
  - `.claude/commands/gaia-release.md`; itself maintainer-only (release-exclude category 1); not adopter-shipped, so internal references are fine.
  - `wiki/log.md`; append-only change ledger, exempt by design (per `wiki-style.md` Exceptions list); historical SHAs and paths are the point.
  - `wiki/hot.md`; auto-loaded recent-context cache, exempt by design (per `wiki-style.md` Exceptions list); overwritten with release-baseline content by `/gaia-release` Step 8, so maintainer-only path mentions in working content do not survive into adopter scaffolds.
- Per-class: for `.claude/skills/`, `.claude/commands/`, `.claude/agents/`, `.claude/rules/`, `.claude/hooks/`, and `.specify/extensions/gaia/{README.md, commands, lib, rules, templates}`: every path mention should be a path that ships.
- Codified in: `.gaia/release-scrub.yml` `maintainer-paths` check. Scope includes `.github/workflows/**` so adopter-shipped workflow files (`tests.yml`, `chromatic.yml`) are covered; the prior `tests.yml` body-comment regression (98f7a62) would now fail the build. `maintainer-paths` is a curated path alternation, which structurally cannot blanket `.github/workflows/` (most workflows ship; a few are release-excluded) nor enumerate each excluded one without drifting. The `excluded-workflow-ref` derived check closes that sub-gap: it reads `.gaia/release-exclude` at scan time and flags references to any excluded `.github/workflows/*.yml` that has NO on-demand render template under `.gaia/cli/templates/workflows/`, i.e. is never installable on an adopter (unlike `code-review-audit.yml`, which `/setup-gaia` renders from its `.tmpl`). A newly excluded maintainer workflow is covered with no config edit; the set cannot drift from the exclude list. Mirrors `wikilink-to-excluded`.
- Prior: `tests.yml` body comment cited `.gaia/`, `.specify/`, `.claude/`, `cli-tests.yml` (98f7a62); `.claude/skills/update-gaia/SKILL.md` cited `.gaia/cli/src/update/merge.ts` (ac7c019); `wiki/decisions/spec-kit Extension Strategy.md:69` cited `.specify/extensions/gaia/test/v2-validation.md` (23d0ed7); `.claude/commands/wiki-lint.md:140` synthetic example used `.gaia/cli/src/removed/index.ts` (23d0ed7); `.specify/extensions/gaia/README.md:3,12-13` cited `.gaia/local/specs/SPEC-001.md` plus a non-existent `hooks/` directory and `lib/hook-payload.md` (audit #13 fix); `.specify/extensions/gaia/lib/uat-write.sh:31` cited `SPEC-003` and `.specify/specs/` (audit #13 fix); `.specify/extensions/gaia/templates/{system-prompt.md:54, clarify-prompts.md:6}` operated under `SPEC-001`'s `scope_boundaries` by hardcoded ID (audit #13 fix); `.specify/extensions/gaia/commands/wiki-promote.md:194` looked up `## Composition with SPEC-001 architecture` as a literal heading (audit #13 fix); `.claude/skills/gaia/references/spec.md` carried ten narrative `UAT-NNN` parentheticals plus an `out of SPEC-001 scope` clause (audit #13 fix; the `wiki-style.md` exemption for `.claude/`/`.specify/` instruction files holds for SPEC-machinery template format, not for narrative refs to specific maintainer UAT/SPEC IDs); `.gaia/cli/templates/workflows/code-review-audit.yml.tmpl:34` (and the byte-identical live `.github/workflows/code-review-audit.yml`) carried a `# Pinned action SHAs match .github/workflows/forensics-triage.yml` comment that renders onto adopters as a dangling pointer to a never-shipped maintainer workflow (health-audit false-clean challenger GH-01; `maintainer-paths` missed it because its curated alternation cannot cover the mixed-ship `.github/workflows/` directory; neutralized to a generic pinned-SHA note and the `excluded-workflow-ref` derived check added to close the class).

**Release-excluded runtime dependencies of shipped surfaces.** A shipped script, hook, statusline, or CLI binary calls into a path that is itself in `.gaia/release-exclude`. Adopters get the caller but not the callee; the surface silently degrades. Distinct from the prose-mention class above: this one has _runtime-behavior_ consequences, not just documentation consequences. The bundle-time-scrub plan (post-#97) catches lexical leaks but does NOT catch this class; runtime references survive scrubbing.

- Detection: enumerate every shell-callee path in shipped scripts (`bash <path>`, `source <path>`, `exec <path>`, explicit script-path constants) and cross-reference each against `.gaia/release-exclude`. A simpler heuristic: `grep -rEn '\.gaia/scripts/|\.gaia/cli/src/|\.specify/extensions/gaia/test/|\.gaia/tests/' .gaia/statusline/ .claude/hooks/ .gaia/cli/templates/` for path constants in shipped runtime surfaces. Every match where the cited path is release-excluded is a runtime leak.
- Codified in: `gaia-maintainer release runtime-deps` (`.gaia/cli/src/release/runtime-deps.ts`) reads every shipped `.sh` file for explicit path constants and verifies each is either in the manifest or a runtime-allocated path (`.gaia/local/`). Wired into `.github/workflows/release.yml` between staging and tarball creation, alongside the manifest and scrub steps. Scope is `*.sh` only, so `.tmpl` content under `.gaia/cli/templates/` is out of reach for this check by design; the scrub `maintainer-paths` check (`.gaia/release-scrub.yml`) is the enforcing primitive for template content, its scope includes `.gaia/cli/templates/**` and it content-scans regardless of extension. The two checks are complementary, not redundant: `runtime-deps` covers runtime-behavior leaks in shipped `.sh` scripts, `maintainer-paths` covers lexical leaks (any extension, including `.tmpl`) everywhere in its scope.
- Prior: `.gaia/statusline/gaia-statusline.sh:26,108-110` invoked `.gaia/scripts/check-updates.sh` while the entire `.gaia/scripts/` directory was release-excluded (category 5, "legacy"); on adopter clones the statusline never refreshed its cache, so `Run /update-deps` and `Run /update-gaia` indicators never lit. Audit #13 fix: removed `.gaia/scripts` from release-exclude, updated `wiki/concepts/Release Workflow.md` framing (the directory is not legacy; `check-updates.sh` is actively shipped), regenerated manifest (420 → 421 entries, 322 → 323 owned).

**Shipped `.sh`-bearing directories omitted from every leak-check scope simultaneously.** A directory of `owned` (shipped) shell scripts can fall completely outside both distribution-boundary enforcement primitives at once: the `maintainer-paths` scrub check's curated `scope:` list (`.gaia/release-scrub.yml`) and the `runtime-deps` `SCAN_GLOBS` array (`.gaia/cli/src/release/scan-globs.ts`). This differs from either single-check scope gap above: when the same tree is missing from both, running both checks still yields zero coverage for that tree, so neither the prose-leak detector nor the runtime-dependency detector catches a defect there.

- Detection: cross-reference every `owned`, non-release-excluded `.sh`-bearing directory in `.gaia/manifest.json` against BOTH `.gaia/release-scrub.yml`'s `maintainer-paths` `scope:` list AND `.gaia/cli/src/release/scan-globs.ts`'s `SCAN_GLOBS`; flag any directory missing from either.
- Codified in: `lintScanScopes()` (`.gaia/cli/src/release/manifest.ts`), wired into `release manifest --check` alongside `lintClassifierSets`. It derives owned `.sh`-bearing directories straight from the manifest at check time (so the set cannot drift from the shipped tree) and cross-checks each against `.gaia/release-scrub.yml`'s `maintainer-paths` scope and `scan-globs.ts`'s `SCAN_GLOBS`, reporting any directory missing from either.
- Prior: cycle 2 health audit (2026-07-09) found `.gaia/scripts/*.sh` (22 owned scripts) and `.github/audit/*.sh` (3 owned scripts) absent from both. The gap was live, not theoretical: `.gaia/scripts/lint-hook-array-guard.sh:7` and `.gaia/scripts/summary-verify.sh:24` carried unwrapped header-comment references to `.gaia/scripts/tests/*.bats` (release-excluded), which neither primitive caught. The directory's earlier move from excluded to shipped (to unbreak the statusline caller in the class above) added it as a manifest-owned tree without adding it as a scan target to either primitive; that fix covered the one file named in its finding, not the tree it un-excluded.

**Maintainer-monorepo path prefix in adopter-shipped files.** A path in a distributed file uses the maintainer's monorepo layout (`gaia/`, `studio/`, `website/` are siblings of the maintainer's clone). Adopter clones are single-repo; the prefix dangles.

- Detection (broad; covers root + nested + wiki + .claude): `grep -rEn "(studio|website)/|\bgaia/\." .claude/ wiki/ CLAUDE.md` (run from repo root). Note: scope must include the project-root `CLAUDE.md` and `wiki/`, not just `.claude/`. The 8th audit found regressions in `CLAUDE.md`, `wiki/concepts/Agentic Design.md`, and `.claude/commands/gaia-init.md` because earlier greps were `.claude/`-scoped only.
- Tooling: `gaia wiki dead-paths` flags any `studio/` or `website/` path in `wiki/**` (sibling-repo pattern always-dead in single-repo clones).
- Codified in: `.gaia/release-scrub.yml` `monorepo-prefix` check, wired into `release.yml`'s bundle-time scrub step (`gaia-maintainer release scrub`). Scope: `CLAUDE.md`, `.claude/**`, `wiki/**`, and the non-test `.specify/extensions/gaia/` surfaces (`README.md`, `commands/**`, `lib/**`, `rules/**`, `templates/**`); pattern flags any `studio/`/`website/` path segment, with `.claude/skills/release-notes/SKILL.md` (maintainer-only), `wiki/hot.md`, and `wiki/log.md` allowlisted. This is the actual build gate for the `studio/`/`website/` flavor. `.claude/rules/instruction-files.md` ("All paths in template-distributed Claude files must be repo-relative") is the prose counterpart, but the rule's own audit grep targets `/Users/`/`/home/` literals only; it does not cover monorepo siblings.
- Prior: `.claude/skills/update-gaia/SKILL.md:155` cited `gaia/.gaia/cli/src/update/merge.ts` (ac7c019); `.claude/commands/gaia-init.md:242` cited `studio/decisions/...` (8th audit fix); `wiki/concepts/Agentic Design.md:121,142` cited `../../../studio/strategy/research/AGENTIC_DESIGN.md` (8th audit fix).

**Maintainer-specific governance files shipping to adopters.** Adopters use GAIA as a template via `npx create-gaia` to scaffold an independent project. Maintainers clone or fork the GAIA repo itself. Shipping GAIA-the-template's `CONTRIBUTING.md`, `CHANGELOG.md`, `LICENSE`, `CODE_OF_CONDUCT.md`, `SUPPORTERS.md`, or root `README.md` makes adopter projects inherit GAIA's governance; wrong by default. Each adopter project chooses its own license, contribution policy, code of conduct, and changelog cadence.

- Detection: any of `{CHANGELOG, CODE_OF_CONDUCT, CONTRIBUTING, LICENSE, README, SUPPORTERS}` at repo root present in the manifest (`grep -E '"(CHANGELOG|CODE_OF_CONDUCT|CONTRIBUTING|LICENSE|README|SUPPORTERS)\.md?"' .gaia/manifest.json`). Expect zero matches at the root level; they belong only in `.gaia/release-exclude` category 11.
- Allowlist: `.gaia/templates/README.md` (DOES ship; `/gaia-init` strip-branding consumes it as the source for the regenerated root `README.md`). `wiki/README.md` (wiki-owned).
- Codified in: `.gaia/release-scrub.yml` `governance-files` check. Scope enumerates the six root filenames; pattern `.*` triggers on any line in any of them, so file presence at the staging root is the leak signal. A regression; accidentally removing the `release-exclude` category 11 entries; would fail the build.
- Prior: all six root governance files were classified `owned`/`shared` and shipped as adopter-tarball content (10th audit fix; moved to release-exclude category 11).

**Denylist filters rotting silently.** `paths-filter` denylists (`!**/*.md`, `!wiki/**`, `!.claude/**`) miss new top-level paths added to the repo. Allowlists fail loud (skip when expected to run); denylists fail quiet (run when expected to skip).

- Detection: read all `.github/workflows/*.yml` `paths-ignore` and inverted `paths` patterns; flag any using denylist syntax
- Codified in: `.gaia/release-scrub.yml` `workflow-denylist` check. Pattern matches `paths-ignore:` keys, block-list entries beginning with `!`, and the inline flow-array form (`paths: ["src/**", "!*.md"]`) across `.github/workflows/**`. The inline alternation is quote-anchored so a stray `[!` inside a run-step string does not false-positive. Line-based matching still cannot see an inverted entry split across the lines of a multi-line flow array (`paths: [\n  "!*.md"\n]`), a layout no workflow uses; the common single-line inline and block forms are both covered.
- Prior: `chromatic.yml` and `tests.yml` denylists missed `.gaia/`, `.specify/`, `studio/` (a8a4b75, c6eeecc)

### CI workflows

**Required-check workflows that block when they shouldn't run.** Workflow gated to a path subset but wired as a required check; PRs outside that path can't merge unless the gate is implemented inside-job.

- Detection: read each workflow's `paths-filter` step + the required-check list; required workflows must use the gate-steps-inside-job pattern (`if: steps.filter.outputs.code == 'true'` on every step), not job-level `if`
- Prior: `cli-tests.yml` design (c6eeecc)

**Adopter-shipped workflows referencing maintainer-only paths in body or comments.** Workflow ships to adopters but its YAML mentions paths that don't exist on adopter clones.

- Detection: cross-reference shipped workflow files (`tests.yml`, `chromatic.yml`) against `release-exclude` path literals
- Prior: `tests.yml` comment scrubbed (98f7a62)

### Forensics triage

Forward-looking signal patterns from the autonomous triage workflow at `.github/workflows/forensics-triage.yml`. These do not fail an audit on their own; they identify when the SPEC's immutable contract is worth reopening.

**Recurring `needs-human` rejections cite the same unenumerated path.** The workflow rejects auto-fix attempts on paths outside the canonical allowlist with reason-code `out-of-scope` (rendered into the `reason: \`out-of-scope\``line in the`needs-human` comment). When a single path appears in five or more distinct out-of-scope rejections, it is a candidate for allowlist expansion; which requires a SPEC reopen.

- Detection (signal scan; refine after first run once comment formatting is settled): `gh issue list --repo gaia-react/gaia --label needs-human --state all --search 'in:comments "reason: \`out-of-scope\`"' --json number,comments --limit 200 | jq -r '.[].comments[] | select(.body | test("reason: .out-of-scope.")) | .body' | grep -oE '\`[A-Za-z0-9._/-]+\`' | sort | uniq -c | sort -rn | awk '$1 >= 5'`
- Threshold: any path with count ≥ 5 across distinct issues warrants discussion of allowlist expansion.
- Codified in: `wiki/decisions/Forensics Triage Workflow.md` § Signals to revisit.

**Maintainer-corrected-outcome queue exceeds learning threshold.** The classifier runs on each issue independently; over time, manual corrections (re-labels, manual closures, rejected draft PRs) accumulate as a queue of human-corrected outcomes. When the queue exceeds fifty items across all classes, a follow-up SPEC for classifier priors / batched-triage queues / supervised retraining loops becomes worthwhile.

- Detection (proxy): `gh issue list --repo gaia-react/gaia --label gaia-triaged --state closed --json number,labels --limit 500 | jq '[.[] | select((.labels | map(.name) | contains(["non-issue"])) | not)] | length'` (count of triaged-and-closed issues that did not close as `non-issue`; a proxy for human-corrected outcomes).
- Threshold: queue length ≥ 50 warrants a follow-up SPEC discussion.
- Codified in: `wiki/decisions/Forensics Triage Workflow.md` § Signals to revisit.

### Tests & harnesses

**Bats / smoke fixtures referencing renamed or deleted hook filenames.** `cp` lines in fixtures, embedded `settings.json` Stop hook entries, fixture filenames themselves.

- Detection: `grep -rEn "\.sh\b" .gaia/tests/` and verify each filename exists at `.claude/hooks/`
- Prior: 5 smoke fixtures + 1 bats test cited `wiki-stop-safety-net.sh` (6a39be4)

## Decided / not findings

Things audits keep re-discovering. None of these are findings.

**Circuit breaker.** Editing this section; or the equivalent "Decided / not findings" section in `wiki/decisions/Claude Integration Fitness.md`; trips the circuit breaker: the Fixer dispatch pauses for human-confirm before writing (see runbook §Circuit breakers). Both sections are protected together because claiming a real class isn't real in either file undermines the audit baseline.

**Slash commands appear under "skills" in Claude Code's surface listing.** `/command` files in `.claude/commands/` register through Claude Code's plugin/skill discovery system. The skills list mixes them with actual skills under `.claude/skills/`. This is a Claude Code surface artifact, not a GAIA finding. Audits sometimes flag it then self-correct; skip the round-trip.

**`wiki/.state.json` lagging HEAD.** Normal pre-release state. The user runs `/gaia-wiki sync` before cutting a release. The session-start hook reports drift; the report is informational, not a finding.

**`dorny/paths-filter@v3` self-validation behavior.** For both `pull_request` and `push`, the action defaults to comparing HEAD against the repo's default branch. On a feature branch with workflow edits, both adopter-shipped workflows fire because the branch's diff vs main includes the workflows themselves (they appear in their own allowlists for self-validation). After merge to main, future PRs without workflow edits skip correctly. Intended.

**Two `wiki-stop-safety-net.sh` references in `.gaia/cli/src/wiki/dead-paths.{ts,test.ts}`.** Intentional. They are the canonical example of what `dead-paths` was built to catch (a renamed/merged hook still cited in code). Removing them would defeat the test.

**`.gaia/local/plans/...` historical archive content.** Per-machine plan + handoff state under `.gaia/local/` is excluded from distribution (category 7). Plan-time references to retired files are the historical record by design. Not a finding.

**`CHANGELOG.md` historical entries with old filenames.** `wiki-style.md` scopes to `wiki/**` body prose and `app/**` source comments. The changelog is by design a historical record of past releases; old filenames in old release notes are correct.

**The `## Historical context (from <older-title>)` heading.** `/gaia-wiki consolidate` writes this when merging a superseded page. Deliberate label that identifies lifted content. Not the prose pattern `wiki-style.md` bans; explicitly exempted.

**`tests.yml` and `chromatic.yml` ship to adopters.** Their explicit allowlists are written to stay meaningful on an adopter clone. Excluding them from distribution would leave adopters without CI on type/lint/test/storybook. Don't propose moving them to `release-exclude`.

**`.gaia/cli/templates/` ships to adopters; `.gaia/cli/src/` does not.** The bundled binary is built from `src/`; adopters get the binary plus the runtime templates the binary references at scaffold time. Not an asymmetry; it's the bundle architecture.

**Pre-existing low-stakes near-collisions in `gaia wiki near-collisions` output.** Domains containing pages with short slugs produce Levenshtein-2 collisions that are semantically distinct. The `--max-distance` flag exists for tuning. Not a finding unless titles are actually duplicates.

**The taxonomy itself is exempt from `wiki-style.md`.** `.claude/rules/wiki-style.md` scopes to `wiki/**` body prose and `app/**` source comments. This file lives at `.gaia/cli/health/taxonomy.md`; outside both scopes. Historical phrasing here ("Prior: …", "fixed in commit abc") is the point.

**Pre-existing uncommitted working-tree edits at audit start.** The auditor's job is read-only against HEAD; staged edits the user made before invoking the audit are out of scope. Note them informationally and continue; do not act on them.

**Marker-wrapped maintainer-path grep hits.** A marker-unaware `maintainer-paths` / `monorepo-prefix` grep hit (Bucket B, or any pre-strip grep) that resolves inside a *balanced* marker-strip block is not a leak. `.gaia/release-scrub.yml` defines three `marker-strip` transforms: `<!-- gaia:maintainer-only:start -->` / `<!-- gaia:maintainer-only:end -->` over `wiki/**/*.md`, `.claude/**/*.md`, `.specify/extensions/gaia/**/*.md`; `# gaia:maintainer-only:start` / `# gaia:maintainer-only:end` over `.prettierignore`; and the same `#`-comment pair over `.gaia/audit-ci.yml`, `**/*.sh`, `**/*.yml.tmpl`. A hit inside any of the three is not a leak. The bundle-time marker-strip removes the block from the staging tree before the real `release scrub` leak-check runs; Bucket C (the actual `gaia-maintainer release scrub`) is authoritative. Verify the marker pair is balanced (start before end, both present) before dismissing; a pair may be indented, so check containment as a substring/pattern match, not a `^`-anchored line match. An unbalanced pair does not strip and is a separate real finding.

**A harness-triage grep's pathspec omitting a shipped directory is not itself a release-blocking finding once the underlying scrub check's own scope covers that directory.** A health-audit Bucket B grep approximates, but does not replace, `gaia-maintainer release scrub`'s codified checks. Bucket C's bundle simulation runs the actual scrub against a staged tree end-to-end and is the authoritative distribution-boundary primitive; once a scrub check's own `scope:` covers a directory, Bucket C independently proves the strip regardless of whether Bucket B's grep pathspec also lists that directory. A gap in Bucket B's pathspec is a triage-tool blind spot (slower feedback within the audit loop), not an adopter-facing risk; file it as a Bucket B pathspec improvement, not a release-blocking finding.

## How to extend

When an audit surfaces a class not in this taxonomy:

1. **Real bug**: fix in code, then add a section under "Issue classes" with pattern + detection + the commit SHA that fixed it.
2. **Settled question audits keep raising**: add a section under "Decided / not findings" with the claim and why it's not a finding.

Taxonomy edits should reference the audit run that surfaced the class in the commit message.
