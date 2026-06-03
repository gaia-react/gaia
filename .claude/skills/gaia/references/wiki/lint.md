# wiki-lint playbook

Dispatched by the `/gaia-wiki` router (`references/wiki.md` → "Lint"). Runs in a Haiku subagent context.

## Playbook

Standalone GAIA-native wiki lint. Builds its own report shell, then writes GAIA-specific checks: **#11: Wiki drift check**, **#12: Dead repo-relative paths**, **#13: UAT/SPEC narrative-ref drift**, **#14: Orphan pages**, **#15: Frontmatter gaps**, and **#16: Empty sections**. Every check re-derives from a live `.gaia/cli/gaia wiki` CLI primitive on each run; the report is plain markdown that GAIA owns end to end.

## Step 1: Create the report shell

Compute today's date from the shell clock first: no LLM has a clock, so the model's notion of "today" is unreliable.

```bash
DATE=$(date +%F)
```

**Regenerate the report from scratch every run.** A lint report is a point-in-time snapshot; a stale report from an earlier run must never be reused or renamed into today's slot. Remove any same-day report before writing the shell so a stale one cannot be picked up and patched in place:

```bash
rm -f wiki/meta/lint-report-$DATE.md
```

Then create the report file with the standard frontmatter and H1 heading:

```bash
cat > wiki/meta/lint-report-$DATE.md <<EOF
---
type: meta
title: 'Lint Report $DATE'
created: $DATE
updated: $DATE
tags: [meta, lint]
status: developing
---

# Lint Report: $DATE
EOF
```

Use `wiki/meta/lint-report-$DATE.md` as the canonical report path for every subsequent step and the Step 8 summary. The GAIA checks below write into this same file: each **replaces** its own `## #NN` section if one already exists, otherwise appends it at the bottom. Never trust or carry over a pre-existing GAIA section: every check re-derives from its live CLI primitive on each run.

## Step 2: GAIA check #11: Wiki drift

Always run `.gaia/cli/gaia wiki state --json` fresh and write the `## #11: Wiki drift check` section from its output, replacing any existing `## #11` section in the report. Never carry over a `#11` section from a reused report: drift state is the most time-sensitive check, and a stale `#11` is exactly how a wiki that was just synced or recovered gets mis-reported as drifting.

### 2a. Run the primitive

```bash
.gaia/cli/gaia wiki state --json
```

The CLI returns a JSON object with `drift_severity` (`none` | `low` | `medium` | `high`), `head_short`, `state_sha`, `commits_ahead`, `reachable`, `recent_commits`, and `suggested_base`. If the command exits non-zero with `state_missing` (or equivalent reason), append:

```markdown
## #11: Wiki drift check

⚠ `wiki/.state.json` missing: system has never run sync. Run `/gaia-wiki sync` to initialize.
```

Then stop the drift check.

If `reachable === false`, the recorded SHA was orphaned (the squash-merge flow replaces the evaluated branch SHA on every merge). Append, and surface `suggested_base` when the CLI resolved a recovery baseline so the reader knows the window is recoverable, not lost:

```markdown
## #11: Wiki drift check

⚠ `wiki/.state.json` `last_evaluated_sha` (`<state_sha>`) is not reachable from HEAD (squashed/rewritten history). Run `/gaia-wiki sync`: it resolves a recovery baseline (`<suggested_base>`) and evaluates the un-evaluated window.
```

When `suggested_base` is empty (no recoverable baseline), drop the parenthetical and say `it re-anchors to HEAD.` instead. Then stop.

### 2b. Classify and append

Map the CLI's `drift_severity` and `commits_ahead` to the report section:

| `drift_severity` | Section to append                                                                                                          |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `none`           | `✓ Wiki in sync with HEAD ({head_short}).`                                                                                 |
| `low`            | `ℹ {commits_ahead} commits behind HEAD. Run /gaia-wiki sync at next opportunity.`                                          |
| `medium`         | `⚠ {commits_ahead} commits behind HEAD. Run /gaia-wiki sync soon.` + recent commits list                                   |
| `high`           | `✗ {commits_ahead} commits behind HEAD. Wiki is significantly out of date. Run /gaia-wiki sync now.` + recent commits list |

For **medium** and **high**, list up to 5 of the `recent_commits` from the CLI output as `  - <sha> <subject>`.

Example WARN (`medium`) section:

```markdown
## #11: Wiki drift check

⚠ 7 commits behind HEAD. Run `/gaia-wiki sync` soon. Recent unsynced commits:

- a1b2c3d feat: add new module
- d4e5f6g fix: edge case in router
- h7i8j9k chore: bump deps
```

Example ERROR (`high`) section:

```markdown
## #11: Wiki drift check

✗ 14 commits behind HEAD. Wiki is significantly out of date. Run `/gaia-wiki sync` now. Recent unsynced commits:

- a1b2c3d feat: ...
- d4e5f6g fix: ...
- h7i8j9k chore: ...
- l0m1n2o docs: ...
- p3q4r5s refactor: ...
```

## Step 3: GAIA check #12: Dead repo-relative paths

Run the dead-paths primitive and append a `## #12: Dead repo-relative paths` section. Detects backticked paths in wiki body prose that reference files no longer present on disk (e.g. a hook removed in a refactor still cited in a concept page).

### 3a. Run the primitive

```bash
.gaia/cli/gaia wiki dead-paths --json
```

Returns `{ "dead": [{ "filePath": "...", "line": N, "path": "..." }, ...] }`. Empty array means clean.

### 3b. Append the section

If `dead.length === 0`:

```markdown
## #12: Dead repo-relative paths

✓ No dead repo-relative paths detected in wiki body prose.
```

Otherwise:

```markdown
## #12: Dead repo-relative paths

⚠ {dead.length} dead path reference(s) in wiki/, files no longer exist on disk:

- `wiki/concepts/Foo.md:23` → `.claude/hooks/old-hook.sh`
- `wiki/concepts/Bar.md:45` → `.claude/hooks/missing-helper.sh`
```

List every dead reference (one per line). Do not truncate: the count is small enough to be actionable.

## Step 4: GAIA check #13: UAT/SPEC narrative-ref drift

Detects narrative `UAT-NNN` and concrete maintainer `SPEC-NNN` references that crept into instruction files (`.claude/skills/`, `.claude/commands/`, `.claude/agents/`, `.claude/rules/`, `.claude/hooks/`) and shipped extension surfaces (`.specify/extensions/gaia/{README.md, commands, lib, rules, templates}`) plus the maintainer-only `.gaia/tests/` smoke harnesses. The rule rationale + structural-vs-narrative triage table lives in `.claude/rules/wiki-style.md` (Exceptions section).

### 4a. Run the greps

Two scans, run from the repo root:

```bash
# UAT-NNN narrative-ref candidates
grep -rEn "UAT-[0-9]{3}" \
  .claude/skills/ .claude/commands/ .claude/agents/ .claude/rules/ .claude/hooks/ \
  .specify/extensions/gaia/README.md .specify/extensions/gaia/commands/ \
  .specify/extensions/gaia/lib/ .specify/extensions/gaia/rules/ \
  .specify/extensions/gaia/templates/ \
  .gaia/tests/

# Concrete maintainer SPEC IDs
grep -rEn "\bSPEC-00[1-9]\b" \
  .claude/skills/ .claude/commands/ .claude/agents/ .claude/rules/ .claude/hooks/ \
  .specify/extensions/gaia/README.md .specify/extensions/gaia/commands/ \
  .specify/extensions/gaia/lib/ .specify/extensions/gaia/rules/ \
  .specify/extensions/gaia/templates/
```

### 4b. Triage and append

Both scans return raw match lines. Apply the structural-vs-narrative filter from `wiki-style.md`:

- **Skip (structural, not findings):** template format examples (`> - UAT-NNN → Given …`), CLI argument values (`--uat-id UAT-007`), JS/Python/YAML literals (`uat_id: 'UAT-099'`), regex targets that match SPEC YAML structure, filename literals (`uat-001.spec.ts`), illustrative `(e.g. SPEC-002)` examples in usage docs, generic placeholders (`SPEC-NNN`, `SPEC-NNN.md`), variable-name fragments (`uat_id`, `uats_block`).
- **Flag (narrative, findings):** section-header parentheticals (`#### 5b. Discuss-this escape (UAT-004)`), inline narrative parentheticals (`(UAT-022, UAT-027)`), comments naming specific working-doc IDs, pass/fail label prefixes (`pass "UAT-001 …"`), prose using a maintainer SPEC ID as a system-wide constant (`operate under SPEC-001's scope_boundaries`).

If both scans produce zero narrative findings (all matches are structural):

```markdown
## #13: UAT/SPEC narrative-ref drift

✓ No narrative `UAT-NNN` or concrete maintainer `SPEC-NNN` references detected outside the structural exemptions in `.claude/rules/wiki-style.md`.
```

Otherwise:

```markdown
## #13: UAT/SPEC narrative-ref drift

⚠ {N} narrative ref(s) found in instruction files / shipped extension surfaces:

- `.claude/skills/foo/SKILL.md:42` → `(UAT-012)` parenthetical in section header
- `.specify/extensions/gaia/commands/bar.md:88` → `operate under SPEC-001's scope_boundaries` prose
```

List every narrative finding (one per line). Structural matches are not listed: they are the regex's false positives by design.

## Step 5: GAIA check #14: Orphan pages

Run the orphans primitive and append a `## #14: Orphan pages` section, replacing any existing `## #14` section. Detects wiki pages that no other page links to with a wikilink.

### 5a. Run the primitive

```bash
.gaia/cli/gaia wiki orphans --json
```

Returns `{ "orphans": [{ "path": "...", "title": "...", "domain": "..." }, ...] }`. Empty array means clean.

Intentionally-unlinked maintainer-only pages are kept reachable via marker-wrapped links in `wiki/index.md`, so a page that shows up here is a genuine orphan: it signals a missing cross-reference, not a maintainer page.

### 5b. Append the section

If `orphans.length === 0`:

```markdown
## #14: Orphan pages

✓ No orphan pages (every page has at least one inbound wikilink).
```

Otherwise:

```markdown
## #14: Orphan pages

⚠ {orphans.length} orphan page(s), no inbound wikilinks:

- `wiki/concepts/Foo.md` (Foo Concept)
- `wiki/modules/Bar.md` (Bar Module)
```

List every orphan (one per line) as `` - `wiki/path.md` (title) ``.

## Step 6: GAIA check #15: Frontmatter gaps

Run the frontmatter primitive and append a `## #15: Frontmatter gaps` section, replacing any existing `## #15` section. The required floor is `type` and `status`.

### 6a. Run the primitive

```bash
.gaia/cli/gaia wiki frontmatter --json
```

Returns `{ "gaps": [{ "path": "...", "missing": ["type", "status"] }, ...] }`. Empty array means clean.

### 6b. Append the section

If `gaps.length === 0`:

```markdown
## #15: Frontmatter gaps

✓ All wiki pages carry the required frontmatter (type, status).
```

Otherwise:

```markdown
## #15: Frontmatter gaps

⚠ {gaps.length} page(s) missing required frontmatter:

- `wiki/concepts/Foo.md`: missing status
- `wiki/modules/Bar.md`: missing status, tags
```

List every gap (one per line) as `` - `wiki/path.md`: missing {comma-joined fields} ``.

## Step 7: GAIA check #16: Empty sections

Run the empty-sections primitive and append a `## #16: Empty sections` section, replacing any existing `## #16` section. Detects headings with no body content beneath them.

### 7a. Run the primitive

```bash
.gaia/cli/gaia wiki empty-sections --json
```

Returns `{ "empty": [{ "path": "...", "line": N, "heading": "..." }, ...] }`. Empty array means clean.

### 7b. Append the section

If `empty.length === 0`:

```markdown
## #16: Empty sections

✓ No empty sections detected.
```

Otherwise:

```markdown
## #16: Empty sections

⚠ {empty.length} empty section(s):

- `wiki/concepts/Foo.md:42` → `## Heading`
- `wiki/modules/Bar.md:88` → `### Subheading`
```

List every empty section (one per line) as `` - `wiki/path.md:42` → `## Heading` ``.

## Step 8: Surface to the user

Print to the user:

1. The report path (e.g. `wiki/meta/lint-report-2026-05-03.md`).
2. A one-line summary that includes the drift severity and count, plus dead-path count, orphan count, frontmatter-gap count, and empty-section count when any of those is non-zero, plus narrative-ref count if non-zero.

If `drift_severity` is **`high`**, surface it prominently (separate line, prefixed with `WIKI DRIFT:`).
If `dead.length > 0`, surface as a separate line prefixed with `WIKI DEAD-PATHS:` followed by the count.
If narrative-ref findings > 0, surface as a separate line prefixed with `UAT-SPEC DRIFT:` followed by the count.
If `orphans.length > 0`, surface as a separate line prefixed with `WIKI ORPHANS:` followed by the count.
If `gaps.length > 0`, surface as a separate line prefixed with `WIKI FRONTMATTER:` followed by the count.
If `empty.length > 0`, surface as a separate line prefixed with `WIKI EMPTY-SECTIONS:` followed by the count.

## Notes

- Hooks (drift-check, commit-nudge, session-stop) are read-only consumers of `wiki/.state.json`. Only sync writes to it. This workflow also does not write `wiki/.state.json`.
- Drift count semantics: missing state file or unreachable SHA are surfaced as advisories, not silent zeroes. See [[Wiki Sync]] for the full design.
- Severity table thresholds are the canonical thresholds for this plan; if changing, update both this file and any sibling tooling that classifies drift.
