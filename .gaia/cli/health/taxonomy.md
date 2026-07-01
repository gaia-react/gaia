# GAIA Health Audit Taxonomy

Living document. Maintainer-only. Excluded from adopter distribution via `.gaia/release-exclude` category 10.

## Purpose

The audit baseline. An audit reads it first, then walks the distribution boundary. Items in **Issue classes** must be verified absent (regressions matter). Items in **Decided / not findings** are not raised. Anything else; known class still present, or a genuinely new pattern; is the audit's output.

Without a shared baseline, fresh audit agents re-discover settled questions and burn tokens on re-litigation.

**Cross-class process gate (load-bearing).** When fixing any class, rerun the class's detection across the entire scoped corpus before reporting closure; not just the file the original finding lived in. Spot-fixes leak across siblings. The maintainer-path and monorepo-prefix scrubs are the canonical examples; the rule applies to every class with a corpus-walking detection (UAT/SPEC scrubs, maintainer-path scrubs, monorepo-prefix scrubs, etc.). The wikilink-to-excluded class is the exception that proves the rule: its build-time check derives the excluded-slug set and walks the full shipped-wiki corpus every run, so closure is already corpus-wide without a manual rerun.

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
- Prior: `wiki/index.md` carried `## Entities` and `## Meta` sections plus a `[[Release Workflow]]` bullet, all resolving to release-excluded pages (audit #11 fix). `[[Release Workflow]]` wikilinks in `Update Workflow.md`, `Wiki Sync.md`, `Telemetry.md`, `Update Merge.md` and a `[[GAIA]]` wikilink in `GAIA Philosophy.md` were missed by audit #11's spot-fix and caught by audit #12. Audit #13 verified the class clean across all shipped wiki domains end-to-end.

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

- Detection: run `gaia-maintainer release manifest` and `git diff .gaia/manifest.json` should be empty
- Prior: 370 → 426 entry rebuild (ed94f49); 426 → 425 after `release.yml` excluded (98f7a62)

**Maintainer-only files mis-classified as `shared` in manifest.** Files that don't ship should be in `release-exclude`, not in the manifest at all.

- Detection: cross-reference `release-exclude` paths against manifest entries; should be zero overlap
- Prior: `release.yml` was `shared` in manifest until 98f7a62 moved it to category 9

**Classifier sets contain release-excluded paths (dead code).** `ADOPTER_OWNED_SENTINELS`, `SHARED`, `WIKI_OWNED_EXACT` in `.gaia/cli/src/release/manifest.ts` enumerate paths whose classification is overridden by `.gaia/release-exclude` running first in `buildManifest`. Such entries are dead; the classifier never sees them; and rot the contract that the classifier expresses.

- Detection: cross-reference each string in `ADOPTER_OWNED_SENTINELS|SHARED|WIKI_OWNED_EXACT` against `.gaia/release-exclude` patterns; expect zero overlap.
- Prior: `CHANGELOG.md` in `ADOPTER_OWNED_SENTINELS` and `README.md` in `SHARED` were dead after release-exclude category 11 added root governance files (audit #11 fix).

**Maintainer paths referenced in adopter-shipped files.** Distributed workflows, wiki pages, instruction files (skills, commands, agents, rules), `.claude/hooks/`, `.gaia/statusline/`, root-level files (CLAUDE.md, etc.), shipped `.specify/extensions/gaia/` instruction surfaces, or hook script comments mention `.gaia/cli/src/`, `.specify/extensions/gaia/test/`, `.specify/specs/`, `.gaia/tests/`, `.gaia/scripts/tests/`, `.github/audit/tests/`, `release-exclude`, etc.; paths that don't exist on adopter clones. Concrete maintainer SPEC IDs (`SPEC-001`, `SPEC-003`, etc.) used as if they were system-wide constants count too: on adopter machines those IDs refer to whatever the adopter happened to author first, not the maintainer artifact.

- Detection (broad): `grep -rEn "\.gaia/cli/src/|\.gaia/cli/test-fixtures/|\.gaia/cli/__tests__/|\.gaia/cli/health/|\.specify/extensions/gaia/test/|\.specify/specs/|\.gaia/tests/|\.gaia/scripts/tests/|\.github/audit/tests/|\.claude/rules/_internal/" CLAUDE.md .claude/ wiki/ .gaia/statusline/ .specify/extensions/gaia/{README.md,commands,lib,rules,templates} --include="*.md" --include="*.sh" --include="*.yml"` (run from repo root). Every match outside the allowlist is a leak. Note the scope: must include root `CLAUDE.md`, `.gaia/statusline/`, shipped hooks under `.claude/hooks/`, AND `.specify/extensions/gaia/` non-test surfaces; pre-9th-audit greps were `.claude/`-scoped and missed root + statusline; pre-13th-audit greps additionally missed shipped extension instruction files.
- Detection, concrete maintainer SPEC IDs: `grep -rEn "\bSPEC-00[1-9]\b" CLAUDE.md .claude/ wiki/ .gaia/statusline/ .specify/extensions/gaia/{README.md,commands,lib,rules,templates}` excluding the allowlist below. Generic placeholders (`SPEC-NNN`, `SPEC-NNN.md`) are fine; instantiated IDs in narrative prose are the leak.
- Allowlist:
  - `wiki/concepts/Release Workflow.md` Distribution Boundary section legitimately describes the maintainer surface.
  - `wiki/concepts/Telemetry.md` body after the "Maintainer source lives at `.gaia/cli/src/`" framing line; that section documents the maintainer architecture by design and the framing line caveats it.
  - `.claude/rules/instruction-files.md` counter-example prose.
  - `.claude/commands/gaia-release.md`; itself maintainer-only (release-exclude category 1); not adopter-shipped, so internal references are fine.
  - `wiki/log.md`; append-only change ledger, exempt by design (per `wiki-style.md` Exceptions list); historical SHAs and paths are the point.
  - `wiki/hot.md`; auto-loaded recent-context cache, exempt by design (per `wiki-style.md` Exceptions list); overwritten with release-baseline content by `/gaia-release` Step 8, so maintainer-only path mentions in working content do not survive into adopter scaffolds.
- Per-class: for `.claude/skills/`, `.claude/commands/`, `.claude/agents/`, `.claude/rules/`, `.claude/hooks/`, and `.specify/extensions/gaia/{README.md, commands, lib, rules, templates}`: every path mention should be a path that ships.
- Codified in: `.gaia/release-scrub.yml` `maintainer-paths` check. Scope includes `.github/workflows/**` so adopter-shipped workflow files (`tests.yml`, `chromatic.yml`) are covered; the prior `tests.yml` body-comment regression (98f7a62) would now fail the build.
- Prior: `tests.yml` body comment cited `.gaia/`, `.specify/`, `.claude/`, `cli-tests.yml` (98f7a62); `.claude/skills/update-gaia/SKILL.md` cited `.gaia/cli/src/update/merge.ts` (ac7c019); `.claude/hooks/telemetry-task-postuse.sh` cited `.gaia/cli/src/telemetry/parse-stdin.ts` (ac7c019); `wiki/concepts/Telemetry.md:82` cited `.gaia/tests/smoke/telemetry-v1/run.sh` (23d0ed7); `wiki/decisions/spec-kit Extension Strategy.md:69` cited `.specify/extensions/gaia/test/v2-validation.md` (23d0ed7); `.claude/commands/wiki-lint.md:140` synthetic example used `.gaia/cli/src/removed/index.ts` (23d0ed7); `.claude/hooks/wiki-session-start.sh:16-25` named the obscurity rule + protected memory path + `_internal-assert-display-rule` CLI subcommand (10th audit fix; CLI subcommand renamed to `_internal-assert-memory-rules`); `.specify/extensions/gaia/README.md:3,12-13` cited `.gaia/local/specs/SPEC-001.md` plus a non-existent `hooks/` directory and `lib/hook-payload.md` (audit #13 fix); `.specify/extensions/gaia/lib/uat-write.sh:31` cited `SPEC-003` and `.specify/specs/` (audit #13 fix); `.specify/extensions/gaia/templates/{system-prompt.md:54, clarify-prompts.md:6}` operated under `SPEC-001`'s `scope_boundaries` by hardcoded ID (audit #13 fix); `.specify/extensions/gaia/commands/wiki-promote.md:194` looked up `## Composition with SPEC-001 architecture` as a literal heading (audit #13 fix); `.claude/skills/gaia/references/spec.md` carried ten narrative `UAT-NNN` parentheticals plus an `out of SPEC-001 scope` clause (audit #13 fix; the `wiki-style.md` exemption for `.claude/`/`.specify/` instruction files holds for SPEC-machinery template format, not for narrative refs to specific maintainer UAT/SPEC IDs).

**Release-excluded runtime dependencies of shipped surfaces.** A shipped script, hook, statusline, or CLI binary calls into a path that is itself in `.gaia/release-exclude`. Adopters get the caller but not the callee; the surface silently degrades. Distinct from the prose-mention class above: this one has _runtime-behavior_ consequences, not just documentation consequences. The bundle-time-scrub plan (post-#97) catches lexical leaks but does NOT catch this class; runtime references survive scrubbing.

- Detection: enumerate every shell-callee path in shipped scripts (`bash <path>`, `source <path>`, `exec <path>`, explicit script-path constants) and cross-reference each against `.gaia/release-exclude`. A simpler heuristic: `grep -rEn '\.gaia/scripts/|\.gaia/cli/src/|\.specify/extensions/gaia/test/|\.gaia/tests/' .gaia/statusline/ .claude/hooks/ .gaia/cli/templates/` for path constants in shipped runtime surfaces. Every match where the cited path is release-excluded is a runtime leak.
- Codified in: `gaia-maintainer release runtime-deps` (`.gaia/cli/src/release/runtime-deps.ts`) reads every shipped `.sh`/`.ts` for explicit path constants and verifies each is either in the manifest or a runtime-allocated path (`.gaia/local/`, `.gaia/cache/`). Wired into `.github/workflows/release.yml` between staging and tarball creation, alongside the manifest and scrub steps.
- Prior: `.gaia/statusline/gaia-statusline.sh:26,108-110` invoked `.gaia/scripts/check-updates.sh` while the entire `.gaia/scripts/` directory was release-excluded (category 5, "legacy"); on adopter clones the statusline never refreshed its cache, so `Run /update-deps` and `Run /update-gaia` indicators never lit. Audit #13 fix: removed `.gaia/scripts` from release-exclude, updated `wiki/concepts/Release Workflow.md` framing (the directory is not legacy; `check-updates.sh` is actively shipped), regenerated manifest (420 → 421 entries, 322 → 323 owned).

**Maintainer-monorepo path prefix in adopter-shipped files.** A path in a distributed file uses the maintainer's monorepo layout (`gaia/`, `studio/`, `website/` are siblings of the maintainer's clone). Adopter clones are single-repo; the prefix dangles.

- Detection (broad; covers root + nested + wiki + .claude): `grep -rEn "(studio|website)/|\bgaia/\." .claude/ wiki/ CLAUDE.md` (run from repo root). Note: scope must include the project-root `CLAUDE.md` and `wiki/`, not just `.claude/`. The 8th audit found regressions in `CLAUDE.md`, `wiki/concepts/Agentic Design.md`, and `.claude/commands/gaia-init.md` because earlier greps were `.claude/`-scoped only.
- Tooling: `gaia wiki dead-paths` flags any `studio/` or `website/` path in `wiki/**` (sibling-repo pattern always-dead in single-repo clones).
- Codified in: `.claude/rules/instruction-files.md` ("All paths in template-distributed Claude files must be repo-relative"). The rule's own audit grep targets `/Users/`/`/home/` literals only; the monorepo-prefix flavor needs the broader grep above.
- Prior: `.claude/skills/update-gaia/SKILL.md:155` cited `gaia/.gaia/cli/src/update/merge.ts` (ac7c019); `.claude/commands/gaia-init.md:242` cited `studio/decisions/...` (8th audit fix); `wiki/concepts/Agentic Design.md:121,142` cited `../../../studio/strategy/research/AGENTIC_DESIGN.md` (8th audit fix); `CLAUDE.md:29` cited `.gaia/cli/src/mentorship/display-rule.ts` (8th audit fix).

**Obscurity-rule leakage in shared / adopter-shipped surfaces.** The mentorship-display rule and similar privacy contracts are projected into per-machine user memory precisely so Claude is told _what not to do_ without being told _where the obscured artifacts live_. Documenting the rule's existence; OR naming the file path it protects; in any file Claude reads at session start (CLAUDE.md), in slash-command bodies, in distributed wiki pages, in shipped shell hooks, or in CLI subcommand names defeats the obscurity by signposting either the contract or the artifact location.

- Detection, rule name: `grep -rn "mentorship.*display\|raw mentorship\|mentorship event file\|Claude must not display" CLAUDE.md .claude/ wiki/ .gaia/statusline/ --include="*.md" --include="*.sh"`
- Detection, protected path: `grep -rEn "telemetry/mentorship/events|events-.*\.jsonl|~/\.claude/projects/[^[:space:]]+/(gaia/)?telemetry/mentorship|feedback_mentorship_display\.md" CLAUDE.md .claude/ wiki/ .gaia/statusline/ --include="*.md" --include="*.sh"`
- Detection, CLI subcommand name leak: `grep -rEn "_internal-assert-display-rule" .claude/ .gaia/cli/gaia` (binary contains help/source strings even when subcommand is `_internal-*`).
- All three greps must be empty outside the allowlist below. Pre-10th-audit detection scoped only to `--include="*.md"` and missed the shipped `wiki-session-start.sh` hook leak.
- Principle: per-machine user memory is the _only_ surface that should describe the rule or name the protected path. Shared CLAUDE.md, slash commands, and wiki should not mention the rule, name the files it protects, or describe paths that might draw Claude's attention to those files. Implementing the rule (writing `.gaia/cli/src/mentorship/display-rule.ts` etc.) is fine because that source is release-excluded; describing it on adopter-shipped surfaces is the leak. Path-leaks are subtler than name-leaks; the 9th audit caught a streams-table row that tabulated the protected path even after the rule's _name_ had been scrubbed.
- Prior: `CLAUDE.md:29` rule bullet (f3b4bc8); `.claude/commands/setup-gaia.md:196` parenthetical (f3b4bc8); `.claude/commands/gaia-init.md:242` full description (f3b4bc8); `wiki/concepts/Telemetry.md:24` "Claude must not display" sentence (f3b4bc8); `wiki/concepts/Telemetry.md:20` streams-table row tabulating `~/.claude/projects/<slug>/gaia/telemetry/mentorship/events-*.jsonl` (9th audit fix).
- Allowlist: `.gaia/tests/smoke/telemetry-v1/` and `.specify/extensions/gaia/test/smoke-telemetry-v1.md` legitimately describe what the smoke test verifies; both are release-excluded so adopters never see them. Source comments inside `.gaia/cli/src/mentorship/` are also fine (release-excluded). The constraint is shared / adopter-shipped surfaces only.
- Codified in: `.gaia/release-scrub.yml` checks `obscurity-rule-name`, `obscurity-protected-path`, `obscurity-cli-subcommand`. The `obscurity-rule-name` regex is tightened relative to the taxonomy reference grep above (`mentorship[- ]display rule|raw mentorship|mentorship events?\s+(file|path)|Claude must not display`) to avoid the known false positive on the "displayable aggregates" phrasing in `wiki/concepts/Telemetry.md`. The `gaia` binary is exempt by the "Decided / not findings" entry; it ships the rule's source strings verbatim by construction; the audit class targets adopter-shipped instruction surfaces, not bundled binary blobs.

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

**Bundled binary contains obscurity-rule prose verbatim.** `strings .gaia/cli/gaia` returns the rule name, the protected path, and "Claude must not display…" prose. By construction; `display-rule-memory.ts` writes the rule into per-machine user memory, and esbuild inlines the writer source into the shipped binary. The binary is not part of Claude's session-start reading surface; the obscurity threat model targets auto-loaded markdown / instruction files (CLAUDE.md, slash commands, wiki pages, hooks). Running `strings` on the binary is a different surface that the rule never claimed to defend.

**Pre-existing uncommitted working-tree edits at audit start.** The auditor's job is read-only against HEAD; staged edits the user made before invoking the audit are out of scope. Note them informationally and continue; do not act on them.

## How to extend

When an audit surfaces a class not in this taxonomy:

1. **Real bug**: fix in code, then add a section under "Issue classes" with pattern + detection + the commit SHA that fixed it.
2. **Settled question audits keep raising**: add a section under "Decided / not findings" with the claim and why it's not a finding.

Taxonomy edits should reference the audit run that surfaced the class in the commit message.
