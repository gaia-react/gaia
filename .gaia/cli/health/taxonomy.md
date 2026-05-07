# GAIA Health Audit Taxonomy

Living document. Maintainer-only. Excluded from adopter distribution via `.gaia/release-exclude` category 10.

## Purpose

Eleven independent audits of the Claude integration optimization (PR #97) found different things each pass. Trajectory: B+ → A− → A → A → A+ → A → A+ → A → A → A → A. Each audit caught at least one class previous audits missed. Without a shared baseline, fresh audit agents re-discover settled questions and burn tokens on re-litigation.

This file is the baseline. An audit reads it first, then walks the integration. Items in **Issue classes** must be verified absent (regressions matter). Items in **Decided / not findings** are not raised. Anything else — known class still present, or a genuinely new pattern — is the audit's output.

## How to prime an audit

Pass this file (or its path) to the audit agent's context with:

> Read this taxonomy first. Skip re-litigating items in "Decided / not findings". Verify items in "Issue classes" are absent in the current code. Flag anything novel.

## Issue classes

Each entry: pattern, codified detection where one exists, prior occurrences (commit SHA that fixed each).

### Wiki & documentation

**Dead path references in body prose.** Backticked repo paths in `wiki/` pointing at files that don't exist (renamed, deleted, merged).
- Detection: `gaia wiki dead-paths`
- Prior: dead refs in `wiki/concepts/Telemetry.md` (111c21b); zombie `wiki-stop-safety-net.sh` references after Phase 1 hook merge (6a39be4)

**H1 / slug collisions in `page-index.ts` walker.** Two pages with identical H1s collide via `byKey` last-write-wins, masking inbound links and over-reporting orphans.
- Detection: read `wiki/**/*.md` H1s, group, flag duplicates
- Prior: `# Storybook` H1 in both `wiki/modules/Storybook Stories.md` and `wiki/dependencies/Storybook.md` (4bd9c26)

**Orphan over-reporting from root pages.** `wiki/index.md`, `wiki/overview.md`, `wiki/hot.md` are catalogs/caches; their wikilinks should contribute to inbound counts but the pages themselves should stay out of `orphans` output.
- Detection: `gaia wiki orphans` (now empty)
- Codified in: `.gaia/cli/src/wiki/page-index.ts` `ROOT_LINK_SOURCES` constant
- Prior: orphan count was 9 from over-reporting, dropped to 0 (ed94f49)

**Historical-style phrasing in body prose.** "previously did X", "was changed from", "as of YYYY", "in PR #N", "in commit abc123".
- Detection: `grep -rEn "\bchanged from|was changed|previously (did|was|stated|had|used|set)|as of [0-9]{4}|in PR #?[0-9]+|in commit [a-f0-9]{6,}" wiki/ --include="*.md" --exclude="log.md" --exclude="hot.md" --exclude-dir="meta"`
- Codified in: `.claude/rules/wiki-style.md` Audit section
- Exempt scopes: `wiki/log.md`, `wiki/hot.md`, `wiki/meta/`, frontmatter, `## Historical context (from <older-title>)` consolidation labels
- Prior: bare `previously` and bare `changed from` produced false positives; tightened in 4bd9c26

**UAT / SPEC refs in body prose, source comments, or shipped scripts.** Working-document IDs that get superseded; meaningless to a reader querying current behavior.
- Detection: `grep -rEn "UAT-[0-9]+|SPEC-[0-9]+" wiki/ app/ .claude/hooks/ .gaia/statusline/ --include="*.md" --include="*.sh" --include="*.ts" --include="*.tsx" --exclude="log.md" --exclude="hot.md" --exclude-dir="meta"`
- Codified in: `.claude/rules/wiki-style.md` Audit section (currently scoped to `wiki/` + `app/`; needs broadening to include shipped `.sh` hooks and `.gaia/statusline/`).
- Exempt scopes: `.claude/`, `.specify/` instruction files (SPEC machinery); `.claude-tests/` and `.specify/extensions/gaia/test/` (release-excluded smoke harnesses).
- Prior: `.gaia/statusline/gaia-statusline.sh:89` carried `# 🧭 mentorship-active indicator (UAT-037/038)` and `.claude/hooks/wiki-session-start.sh:11` carried `# Clear telemetry coaching-active cache at session start (SPEC-001 UAT-038).` — both fixed in 10th audit.

**Stale wiki frontmatter `updated` dates.** Body advances; `updated` field doesn't bump.
- Detection: spot-check `updated` against most recent body change (no automated grep)
- Prior: `wiki/hot.md` frontmatter stale relative to body (8730d15)

**Wiki documentation surface drift.** Decision/concept pages enumerating CLI primitives or features fall behind the actual surface as new primitives land.
- Detection: cross-reference enumerated lists in `wiki/decisions/` and `wiki/concepts/` against `.gaia/cli/src/*/index.ts` HELP_TEXT for that domain
- Prior: `wiki/decisions/Wiki Management.md` listed 7 of 10 wiki primitives (e665b40)

**Shipped wiki pages link to release-excluded targets via wikilinks.** A `[[X]]` wikilink in an adopter-shipped wiki page resolves to a page under `wiki/entities/`, `wiki/meta/`, `wiki/_archived/`, or any other release-excluded location. Adopter sees a dangling reference, and the link itself signposts maintainer-only content even when the destination is excluded. `gaia wiki dead-paths` only catches backticked filesystem paths, not wikilinks; `gaia wiki orphans` is the inverse direction (pages with no inbound links).
- Detection (manual until automated): `grep -rEn '\[\[' wiki/index.md wiki/README.md wiki/overview.md wiki/concepts/ wiki/decisions/ wiki/modules/ wiki/components/ wiki/flows/ wiki/dependencies/` and cross-check each target slug against pages whose path matches a `.gaia/release-exclude` pattern or lives under `wiki/entities/|wiki/meta/|wiki/_archived/`.
- Suggested codification: extend `gaia wiki dead-paths` (or add a sibling primitive) to walk wikilinks via `gaia wiki page-index --json` and flag any link resolving to a release-excluded target.
- Prior: `wiki/index.md` carried `## Entities` and `## Meta` sections plus a `[[Release Workflow]]` bullet, all resolving to release-excluded pages (audit #11 fix).

### Claude integration surfaces

**`@`-import anti-pattern in `.claude/rules/`.** Rules use `@path/to/file` to import other files. Always-loaded rules transitively preloading skills bloat every session.
- Detection: `grep -rEn "^@" .claude/rules/`
- Prior: `coding-guidelines.md` transitively preloaded the TDD skill (8730d15)

**Absolute filesystem literals in distributed instruction files.** `/Users/...`, `/home/...` paths leak the maintainer's machine.
- Detection: `grep -rEn "/Users/|/home/" .claude/` excluding the documented counter-example in `instruction-files.md`
- Codified in: `.claude/rules/instruction-files.md` Audit section
- Prior: skill reference contained `/Users/...` literal (111c21b)

**Path-scoping mismatch — content vs. glob.** Rule scoped to a path glob but content is universal advice (or vice versa).
- Detection: read each rule's frontmatter `globs` and check whether content actually depends on those paths
- Prior: `coding-guidelines.md` was path-scoped to `app/test/**` despite being universal (8730d15)

**Dead clauses citing non-existent files.** Instruction prose says "start with `wiki/<domain>/_index.md`" but no `_index.md` files exist.
- Detection: `grep -rEn "_index\.md" .claude/ CLAUDE.md gaia/CLAUDE.md` then verify each cited path exists
- Prior: `gaia/CLAUDE.md` referenced non-existent `_index.md` files (8730d15)

**Per-session marker files missing from `.gitignore`.** Hooks write `.claude/foo-checked` markers that should not commit.
- Detection: cross-reference hook write paths with `.gitignore`
- Prior: `.claude/i18n-strings-checked` missing from `.gitignore` (8730d15)

**Redundant per-tool permission entries shadowed by globs.** `settings.local.json` has entries whose pattern is a strict subset of another entry's glob.
- Detection: read `.claude/settings.local.json` permissions; check for shadowed entries
- Prior: 14 git-shaped entries shadowed by `Bash(git *)` collapsed (8730d15)

**Hook references to deleted or merged files.** Hooks merged or renamed; settings.json or test fixtures still cite old name.
- Detection: cross-reference `.claude/settings.json` hook command paths against `.claude/hooks/*.sh` files; grep `.claude-tests/` for hook filenames
- Prior: `wiki-stop-safety-net.sh` cited from `CONTRIBUTING.md`, `.claude-tests/hooks/stop-safety-net.bats`, smoke fixtures (6a39be4)

### CLI surface

**Top-level `--help` text drift.** `.gaia/cli/src/index.ts` HELP_TEXT lists subcommands by hand; new subcommands added to a domain router don't propagate.
- Detection: cross-reference each domain router's HELP_TEXT against the top-level HELP_TEXT line for that domain
- Prior: `wiki` line listed 7 of 10 primitives (e665b40)

**Stale comments referencing primitive count or phase context.** Comments say "this router only ships the seven primitives" or "Phase N of the Claude Integration Optimization plan extracts…" or "Phase N task-adaptation-inject…" after the count or phase is no longer current. Wiki-style.md scopes to `app/**`, but the same hygiene applies inside any shipped or maintainer source — comments describe what the file is, not how it got there.
- Detection: `grep -rEn "the (seven|eight|nine|ten|N) primitives|Phase [0-9]+ (of|task-adaptation|adaptation-inject)" .gaia/cli/src/ .claude/hooks/ .gaia/statusline/`
- Prior: 5 sibling files (`init`, `update`, `update/merge`, `wiki`, `release` `index.ts`) carried `Phase N of the Claude Integration Optimization plan` headers; `wiki/index.ts:7` additionally said "the seven primitives" (ten ship) — fixed in `ac7c019`. `.claude/hooks/wiki-session-start.sh:12` said "Phase 5 task-adaptation-inject writes …" — fixed in 10th audit.

**Test scripts with baked-in CLI flags.** `package.json scripts.test = "vitest --run"` overrides project-wide PreToolUse hooks that block bare `test`.
- Detection: read `.gaia/cli/package.json scripts.test`; verify no `--run` baked in
- Prior: `--run` baked in caused command failure (ed94f49)

**Bundled binary out of sync with source.** `.gaia/cli/src/index.ts` HELP_TEXT (or any user-facing string) edited but `.gaia/cli/gaia` not rebundled. Adopters run the binary.
- Detection: rebundle (`pnpm -C .gaia/cli bundle`) and check `git diff .gaia/cli/gaia` is empty
- Prior: implicit pre-rebundle drift after each src edit; rebundle is now part of every src-touching commit

### Distribution boundary

**Manifest stale relative to distributed file set.** Files added to the template don't auto-classify; manifest count diverges from `git ls-files | grep -v -f release-exclude`.
- Detection: run `gaia release manifest` and `git diff .gaia/manifest.json` should be empty
- Prior: 370 → 426 entry rebuild (ed94f49); 426 → 425 after `release.yml` excluded (98f7a62)

**Maintainer-only files mis-classified as `shared` in manifest.** Files that don't ship should be in `release-exclude`, not in the manifest at all.
- Detection: cross-reference `release-exclude` paths against manifest entries; should be zero overlap
- Prior: `release.yml` was `shared` in manifest until 98f7a62 moved it to category 9

**Classifier sets contain release-excluded paths (dead code).** `ADOPTER_OWNED_SENTINELS`, `SHARED`, `WIKI_OWNED_EXACT` in `.gaia/cli/src/release/manifest.ts` enumerate paths whose classification is overridden by `.gaia/release-exclude` running first in `buildManifest`. Such entries are dead — the classifier never sees them — and rot the contract that the classifier expresses.
- Detection: cross-reference each string in `ADOPTER_OWNED_SENTINELS|SHARED|WIKI_OWNED_EXACT` against `.gaia/release-exclude` patterns; expect zero overlap.
- Prior: `CHANGELOG.md` in `ADOPTER_OWNED_SENTINELS` and `README.md` in `SHARED` were dead after release-exclude category 11 added root governance files (audit #11 fix).

**Maintainer paths referenced in adopter-shipped files.** Distributed workflows, wiki pages, instruction files (skills, commands, agents, rules), `.claude/hooks/`, `.gaia/statusline/`, root-level files (CLAUDE.md, etc.), or hook script comments mention `.gaia/cli/src/`, `.specify/extensions/gaia/test/`, `.claude-tests/`, `release-exclude`, etc. — paths that don't exist on adopter clones.
- Detection (broad): `grep -rEn "\.gaia/cli/src/|\.gaia/cli/test-fixtures/|\.gaia/cli/__tests__/|\.gaia/cli/health/|\.specify/extensions/gaia/test/|\.claude-tests/|\.claude/rules/_internal/" CLAUDE.md .claude/ wiki/ .gaia/statusline/ --include="*.md" --include="*.sh" --include="*.yml"` (run from repo root). Every match outside the allowlist is a leak. Note the scope: must include root `CLAUDE.md`, `.gaia/statusline/`, and shipped hooks under `.claude/hooks/` — pre-9th-audit greps were `.claude/`-scoped and missed root + statusline.
- Allowlist:
  - `wiki/concepts/Release Workflow.md` Distribution Boundary section legitimately describes the maintainer surface.
  - `wiki/concepts/Telemetry.md` body after the "Maintainer source lives at `.gaia/cli/src/`" framing line — that section documents the maintainer architecture by design and the framing line caveats it.
  - `.claude/rules/instruction-files.md` counter-example prose.
  - `.claude/commands/gaia-release.md` — itself maintainer-only (release-exclude category 1); not adopter-shipped, so internal references are fine.
  - `wiki/log.md` — append-only change ledger, exempt by design (per `wiki-style.md` Exceptions list); historical SHAs and paths are the point.
  - `wiki/hot.md` — auto-loaded recent-context cache, exempt by design (per `wiki-style.md` Exceptions list); overwritten with release-baseline content by `/gaia-release` Step 8, so maintainer-only path mentions in working content do not survive into adopter scaffolds.
- Per-class: for `.claude/skills/`, `.claude/commands/`, `.claude/agents/`, `.claude/rules/`, and `.claude/hooks/`: every path mention should be a path that ships.
- Prior: `tests.yml` body comment cited `.gaia/`, `.specify/`, `.claude/`, `cli-tests.yml` (98f7a62); `.claude/skills/update-gaia/SKILL.md` cited `.gaia/cli/src/update/merge.ts` (ac7c019); `.claude/hooks/telemetry-task-postuse.sh` cited `.gaia/cli/src/telemetry/parse-stdin.ts` (ac7c019); `wiki/concepts/Telemetry.md:82` cited `.claude-tests/smoke/telemetry-v1/run.sh` (23d0ed7); `wiki/decisions/spec-kit Extension Strategy.md:69` cited `.specify/extensions/gaia/test/v2-validation.md` (23d0ed7); `.claude/commands/wiki-lint.md:140` synthetic example used `.gaia/cli/src/removed/index.ts` (23d0ed7); `.claude/hooks/wiki-session-start.sh:16-25` named the obscurity rule + protected memory path + `_internal-assert-display-rule` CLI subcommand (10th audit fix; CLI subcommand renamed to `_internal-assert-memory-rules`).

**Maintainer-monorepo path prefix in adopter-shipped files.** A path in a distributed file uses the maintainer's monorepo layout (`gaia/`, `studio/`, `website/` are siblings of the maintainer's clone). Adopter clones are single-repo; the prefix dangles.
- Detection (broad — covers root + nested + wiki + .claude): `grep -rEn "(studio|website)/|\bgaia/\." .claude/ wiki/ CLAUDE.md` (run from repo root). Note: scope must include the project-root `CLAUDE.md` and `wiki/`, not just `.claude/`. The 8th audit found regressions in `CLAUDE.md`, `wiki/concepts/Agentic Design.md`, and `.claude/commands/gaia-init.md` because earlier greps were `.claude/`-scoped only.
- Tooling: `gaia wiki dead-paths` flags any `studio/` or `website/` path in `wiki/**` (sibling-repo pattern always-dead in single-repo clones).
- Codified in: `.claude/rules/instruction-files.md` ("All paths in template-distributed Claude files must be repo-relative"). The rule's own audit grep targets `/Users/`/`/home/` literals only; the monorepo-prefix flavor needs the broader grep above.
- Prior: `.claude/skills/update-gaia/SKILL.md:155` cited `gaia/.gaia/cli/src/update/merge.ts` (ac7c019); `.claude/commands/gaia-init.md:242` cited `studio/decisions/...` (8th audit fix); `wiki/concepts/Agentic Design.md:121,142` cited `../../../studio/strategy/research/AGENTIC_DESIGN.md` (8th audit fix); `CLAUDE.md:29` cited `.gaia/cli/src/mentorship/display-rule.ts` (8th audit fix).

**Obscurity-rule leakage in shared / adopter-shipped surfaces.** The mentorship-display rule and similar privacy contracts are projected into per-machine user memory precisely so Claude is told *what not to do* without being told *where the obscured artifacts live*. Documenting the rule's existence — OR naming the file path it protects — in any file Claude reads at session start (CLAUDE.md), in slash-command bodies, in distributed wiki pages, in shipped shell hooks, or in CLI subcommand names defeats the obscurity by signposting either the contract or the artifact location.
- Detection — rule name: `grep -rn "mentorship.*display\|raw mentorship\|mentorship event file\|Claude must not display" CLAUDE.md .claude/ wiki/ .gaia/statusline/ --include="*.md" --include="*.sh"`
- Detection — protected path: `grep -rEn "telemetry/mentorship/events|events-.*\.jsonl|~/\.claude/projects/[^[:space:]]+/(gaia/)?telemetry/mentorship|feedback_mentorship_display\.md" CLAUDE.md .claude/ wiki/ .gaia/statusline/ --include="*.md" --include="*.sh"`
- Detection — CLI subcommand name leak: `grep -rEn "_internal-assert-display-rule" .claude/ .gaia/cli/gaia` (binary contains help/source strings even when subcommand is `_internal-*`).
- All three greps must be empty outside the allowlist below. Pre-10th-audit detection scoped only to `--include="*.md"` and missed the shipped `wiki-session-start.sh` hook leak.
- Principle: per-machine user memory is the *only* surface that should describe the rule or name the protected path. Shared CLAUDE.md, slash commands, and wiki should not mention the rule, name the files it protects, or describe paths that might draw Claude's attention to those files. Implementing the rule (writing `.gaia/cli/src/mentorship/display-rule.ts` etc.) is fine because that source is release-excluded; describing it on adopter-shipped surfaces is the leak. Path-leaks are subtler than name-leaks — the 9th audit caught a streams-table row that tabulated the protected path even after the rule's *name* had been scrubbed.
- Prior: `CLAUDE.md:29` rule bullet (f3b4bc8); `.claude/commands/setup-gaia.md:196` parenthetical (f3b4bc8); `.claude/commands/gaia-init.md:242` full description (f3b4bc8); `wiki/concepts/Telemetry.md:24` "Claude must not display" sentence (f3b4bc8); `wiki/concepts/Telemetry.md:20` streams-table row tabulating `~/.claude/projects/<slug>/gaia/telemetry/mentorship/events-*.jsonl` (9th audit fix).
- Allowlist: `.claude-tests/smoke/telemetry-v1/` and `.specify/extensions/gaia/test/smoke-telemetry-v1.md` legitimately describe what the smoke test verifies; both are release-excluded so adopters never see them. Source comments inside `.gaia/cli/src/mentorship/` are also fine (release-excluded). The constraint is shared / adopter-shipped surfaces only.

**Maintainer-specific governance files shipping to adopters.** Adopters use GAIA as a template via `npx create-gaia` to scaffold an independent project. Maintainers clone or fork the GAIA repo itself. Shipping GAIA-the-template's `CONTRIBUTING.md`, `CHANGELOG.md`, `LICENSE`, `CODE_OF_CONDUCT.md`, `SUPPORTERS.md`, or root `README.md` makes adopter projects inherit GAIA's governance — wrong by default. Each adopter project chooses its own license, contribution policy, code of conduct, and changelog cadence.
- Detection: any of `{CHANGELOG, CODE_OF_CONDUCT, CONTRIBUTING, LICENSE, README, SUPPORTERS}` at repo root present in the manifest (`grep -E '"(CHANGELOG|CODE_OF_CONDUCT|CONTRIBUTING|LICENSE|README|SUPPORTERS)\.md?"' .gaia/manifest.json`). Expect zero matches at the root level — they belong only in `.gaia/release-exclude` category 11.
- Allowlist: `.gaia/templates/README.md` (DOES ship — `/gaia-init` strip-branding consumes it as the source for the regenerated root `README.md`). `wiki/README.md` (wiki-owned). 
- Prior: all six root governance files were classified `owned`/`shared` and shipped as adopter-tarball content (10th audit fix; moved to release-exclude category 11).

**Denylist filters rotting silently.** `paths-filter` denylists (`!**/*.md`, `!wiki/**`, `!.claude/**`) miss new top-level paths added to the repo. Allowlists fail loud (skip when expected to run); denylists fail quiet (run when expected to skip).
- Detection: read all `.github/workflows/*.yml` `paths-ignore` and inverted `paths` patterns; flag any using denylist syntax
- Prior: `chromatic.yml` and `tests.yml` denylists missed `.gaia/`, `.specify/`, `studio/` (a8a4b75, c6eeecc)

### CI workflows

**Required-check workflows that block when they shouldn't run.** Workflow gated to a path subset but wired as a required check; PRs outside that path can't merge unless the gate is implemented inside-job.
- Detection: read each workflow's `paths-filter` step + the required-check list; required workflows must use the gate-steps-inside-job pattern (`if: steps.filter.outputs.code == 'true'` on every step), not job-level `if`
- Prior: `cli-tests.yml` design (c6eeecc)

**Adopter-shipped workflows referencing maintainer-only paths in body or comments.** Workflow ships to adopters but its YAML mentions paths that don't exist on adopter clones.
- Detection: cross-reference shipped workflow files (`tests.yml`, `chromatic.yml`) against `release-exclude` path literals
- Prior: `tests.yml` comment scrubbed (98f7a62)

### Tests & harnesses

**Bats / smoke fixtures referencing renamed or deleted hook filenames.** `cp` lines in fixtures, embedded `settings.json` Stop hook entries, fixture filenames themselves.
- Detection: `grep -rEn "\.sh\b" .claude-tests/` and verify each filename exists at `.claude/hooks/`
- Prior: 5 smoke fixtures + 1 bats test cited `wiki-stop-safety-net.sh` (6a39be4)

## Decided / not findings

Things audits keep re-discovering. None of these are findings.

**Slash commands appear under "skills" in Claude Code's surface listing.** `/command` files in `.claude/commands/` register through Claude Code's plugin/skill discovery system. The skills list mixes them with actual skills under `.claude/skills/`. This is a Claude Code surface artifact, not a GAIA finding. Audits sometimes flag it then self-correct — skip the round-trip.

**`wiki/.state.json` lagging HEAD.** Normal pre-release state. The user runs `/wiki-sync` before cutting a release. The session-start hook reports drift; the report is informational, not a finding.

**`dorny/paths-filter@v3` self-validation behavior.** For both `pull_request` and `push`, the action defaults to comparing HEAD against the repo's default branch. On a feature branch with workflow edits, both adopter-shipped workflows fire because the branch's diff vs main includes the workflows themselves (they appear in their own allowlists for self-validation). After merge to main, future PRs without workflow edits skip correctly. Intended.

**Two `wiki-stop-safety-net.sh` references in `.gaia/cli/src/wiki/dead-paths.{ts,test.ts}`.** Intentional. They are the canonical example of what `dead-paths` was built to catch (a renamed/merged hook still cited in code). Removing them would defeat the test.

**`.gaia/local/plans/...` historical archive content.** Per-machine plan + handoff state under `.gaia/local/` is excluded from distribution (category 7). Plan-time references to retired files are the historical record by design. Not a finding.

**`CHANGELOG.md` historical entries with old filenames.** `wiki-style.md` scopes to `wiki/**` body prose and `app/**` source comments. The changelog is by design a historical record of past releases; old filenames in old release notes are correct.

**The `## Historical context (from <older-title>)` heading.** `/wiki-consolidate` writes this when merging a superseded page. Deliberate label that identifies lifted content. Not the prose pattern `wiki-style.md` bans; explicitly exempted.

**`tests.yml` and `chromatic.yml` ship to adopters.** Their explicit allowlists are written to stay meaningful on an adopter clone. Excluding them from distribution would leave adopters without CI on type/lint/test/storybook. Don't propose moving them to `release-exclude`.

**`.gaia/cli/templates/` ships to adopters; `.gaia/cli/src/` does not.** The bundled binary is built from `src/`; adopters get the binary plus the runtime templates the binary references at scaffold time. Not an asymmetry — it's the bundle architecture.

**Pre-existing low-stakes near-collisions in `gaia wiki near-collisions` output.** Domains containing pages with short slugs produce Levenshtein-2 collisions that are semantically distinct. The `--max-distance` flag exists for tuning. Not a finding unless titles are actually duplicates.

**The taxonomy itself is exempt from `wiki-style.md`.** `.claude/rules/wiki-style.md` scopes to `wiki/**` body prose and `app/**` source comments. This file lives at `.gaia/cli/health/taxonomy.md` — outside both scopes. Historical phrasing here ("Prior: …", "fixed in commit abc") is the point.

**Bundled binary contains obscurity-rule prose verbatim.** `strings .gaia/cli/gaia` returns the rule name, the protected path, and "Claude must not display…" prose. By construction — `display-rule-memory.ts` writes the rule into per-machine user memory, and esbuild inlines the writer source into the shipped binary. The binary is not part of Claude's session-start reading surface; the obscurity threat model targets auto-loaded markdown / instruction files (CLAUDE.md, slash commands, wiki pages, hooks). Running `strings` on the binary is a different surface that the rule never claimed to defend.

## How to extend

When an audit surfaces a class not in this taxonomy:

1. **Real bug**: fix in code, then add a section under "Issue classes" with pattern + detection + the commit SHA that fixed it.
2. **Settled question audits keep raising**: add a section under "Decided / not findings" with the claim and why it's not a finding.

Taxonomy edits should reference the audit run that surfaced the class in the commit message.
