# GAIA Health Audit Taxonomy

Living document. Maintainer-only. Excluded from adopter distribution via `.gaia/release-exclude` category 10.

## Purpose

Six independent audits of the Claude integration optimization (PR #97) found different things each pass. Trajectory: B+ → A− → A → A → A+ → A → A+. Each audit caught at least one class previous audits missed. Without a shared baseline, fresh audit agents re-discover settled questions and burn tokens on re-litigation.

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

**UAT / SPEC refs in body prose or source comments.** Working-document IDs that get superseded; meaningless to a reader querying current behavior.
- Detection: `grep -rEn "UAT-[0-9]+|SPEC-[0-9]+" wiki/ --include="*.md" --exclude="log.md" --exclude="hot.md" --exclude-dir="meta"` and same for `app/` source comments
- Codified in: `.claude/rules/wiki-style.md` Audit section
- Exempt scopes: `.claude/`, `.specify/` instruction files (SPEC machinery)

**Stale wiki frontmatter `updated` dates.** Body advances; `updated` field doesn't bump.
- Detection: spot-check `updated` against most recent body change (no automated grep)
- Prior: `wiki/hot.md` frontmatter stale relative to body (8730d15)

**Wiki documentation surface drift.** Decision/concept pages enumerating CLI primitives or features fall behind the actual surface as new primitives land.
- Detection: cross-reference enumerated lists in `wiki/decisions/` and `wiki/concepts/` against `.gaia/cli/src/*/index.ts` HELP_TEXT for that domain
- Prior: `wiki/decisions/Wiki Management.md` listed 7 of 10 wiki primitives (e665b40)

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

**Stale comments referencing primitive count or phase context.** Comments say "this router only ships the seven primitives" or "Phase N of the Claude Integration Optimization plan extracts…" after the count or phase is no longer current. Wiki-style.md scopes to `app/**`, but the same hygiene applies inside `.gaia/cli/src/` — comments describe what the file is, not how it got there.
- Detection: `grep -rEn "the (seven|eight|nine|ten|N) primitives|Phase [0-9]+ of" .gaia/cli/src/`
- Prior: 5 sibling files (`init`, `update`, `update/merge`, `wiki`, `release` `index.ts`) carried `Phase N of the Claude Integration Optimization plan` headers; `wiki/index.ts:7` additionally said "the seven primitives" (ten ship). Surfaced and fixed in the 8th audit.

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

**Maintainer paths referenced in adopter-shipped files.** Distributed workflows, wiki pages, instruction files (skills, commands, agents, rules), or hook script comments mention `.gaia/cli/src/`, `.specify/extensions/gaia/test/`, `.claude-tests/`, `release-exclude`, etc. — paths that don't exist on adopter clones.
- Detection: build excluded-path set from `release-exclude`; grep manifest entries for each path literal and unique filename literal. For `.claude/skills/`, `.claude/commands/`, `.claude/agents/`, `.claude/rules/`, and `.claude/hooks/`: every path mention should be a path that ships.
- Allowlist: `wiki/concepts/Release Workflow.md` Distribution Boundary section legitimately describes the maintainer surface.
- Prior: `tests.yml` body comment cited `.gaia/`, `.specify/`, `.claude/`, `cli-tests.yml` (98f7a62); `.claude/skills/update-gaia/SKILL.md` cited `.gaia/cli/src/update/merge.ts` (8th audit fix); `.claude/hooks/telemetry-task-postuse.sh` cited `.gaia/cli/src/telemetry/parse-stdin.ts` (8th audit fix).

**Maintainer-monorepo path prefix in adopter-shipped files.** A path in a distributed `.claude/` file uses the maintainer's monorepo layout (`gaia/`, `studio/`, `website/` are siblings of the maintainer's clone). Adopter clones are single-repo; the prefix dangles.
- Detection: `grep -rEn "\bgaia/\." .claude/` (catches `gaia/.gaia/...`, `gaia/.claude/...`); also `grep -rEn "(studio|website)/" .claude/`
- Codified in: `.claude/rules/instruction-files.md` ("All paths in template-distributed Claude files must be repo-relative"). The rule's own audit grep targets `/Users/`/`/home/` literals; the `gaia/` flavor is a sibling pattern that grep misses. Promote: `instruction-files.md` Audit section should add the monorepo-prefix grep above.
- Prior: `.claude/skills/update-gaia/SKILL.md:155` cited `gaia/.gaia/cli/src/update/merge.ts` (8th audit fix)

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

## How to extend

When an audit surfaces a class not in this taxonomy:

1. **Real bug**: fix in code, then add a section under "Issue classes" with pattern + detection + the commit SHA that fixed it.
2. **Settled question audits keep raising**: add a section under "Decided / not findings" with the claim and why it's not a finding.

Taxonomy edits should reference the audit run that surfaced the class in the commit message.
