# wiki-lint playbook

Dispatched by the `/gaia-wiki` router (`references/wiki.md` → "Lint"). Runs in a Haiku subagent context.

## Playbook

GAIA-local wrapper around the upstream `claude-obsidian:wiki-lint` skill. Runs the upstream lint flow first, then appends GAIA-specific checks **#11: Wiki drift check**, **#12: Dead repo-relative paths**, and **#13: UAT/SPEC narrative-ref drift** to the report.

Do **not** modify the upstream `claude-obsidian:wiki-lint` skill — it ships from a marketplace plugin and is read-only territory. Extensions live here.

## Step 1: Run upstream wiki-lint

Invoke the `claude-obsidian:wiki-lint` skill following its documented pattern. The runtime resolves the plugin and dispatches the upstream playbook; do not attempt to read the plugin's SKILL.md from a hardcoded path. The upstream skill writes the report to:

```
wiki/meta/lint-report-YYYY-MM-DD.md
```

Capture the report path it produced — every appended GAIA check writes into that same file.

Do **not** restructure the upstream report format. Append GAIA sections at the bottom only.

### Normalize the report date

The upstream skill names the report from the model's notion of "today", which is unreliable (no LLM has a clock). Reconcile it against the shell clock before appending anything:

```bash
DATE=$(date +%F)
```

If the captured report path's date differs from `$DATE`, rename it and fix the in-file references:

```bash
git mv wiki/meta/lint-report-<upstream-date>.md wiki/meta/lint-report-$DATE.md
```

Then set the report's frontmatter (`title`, `created`, `updated`) and H1 heading to `$DATE`. Use the renamed path as the canonical report path for every subsequent step and the Step 5 summary.

## Step 2: GAIA check #11 — Wiki drift

After the upstream lint finishes, run `gaia wiki state --json` and append a `## #11: Wiki drift check` section to the report file based on its output.

### 2a. Run the primitive

```bash
gaia wiki state --json
```

The CLI returns a JSON object with `drift_severity` (`none` | `low` | `medium` | `high`), `head_short`, `state_sha`, `commits_ahead`, `reachable`, `recent_commits`, and `suggested_base`. If the command exits non-zero with `state_missing` (or equivalent reason), append:

```markdown
## #11: Wiki drift check

⚠ `wiki/.state.json` missing — system has never run sync. Run `/gaia-wiki sync` to initialize.
```

Then stop the drift check.

If `reachable === false`, the recorded SHA was orphaned (the squash-merge flow replaces the evaluated branch SHA on every merge). Append — and surface `suggested_base` when the CLI resolved a recovery baseline so the reader knows the window is recoverable, not lost:

```markdown
## #11: Wiki drift check

⚠ `wiki/.state.json` `last_evaluated_sha` (`<state_sha>`) is not reachable from HEAD (squashed/rewritten history). Run `/gaia-wiki sync` — it resolves a recovery baseline (`<suggested_base>`) and evaluates the un-evaluated window.
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

## Step 3: GAIA check #12 — Dead repo-relative paths

Run the dead-paths primitive and append a `## #12: Dead repo-relative paths` section. Detects backticked paths in wiki body prose that reference files no longer present on disk (e.g. a hook removed in a refactor still cited in a concept page).

### 3a. Run the primitive

```bash
gaia wiki dead-paths --json
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

⚠ {dead.length} dead path reference(s) in wiki/ — files no longer exist on disk:

- `wiki/concepts/Foo.md:23` → `.claude/hooks/old-hook.sh`
- `wiki/concepts/Bar.md:45` → `.claude/hooks/missing-helper.sh`
```

List every dead reference (one per line). Do not truncate — the count is small enough to be actionable.

## Step 4: GAIA check #13 — UAT/SPEC narrative-ref drift

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

- **Skip (structural — not findings):** template format examples (`> - UAT-NNN — Given …`), CLI argument values (`--uat-id UAT-007`), JS/Python/YAML literals (`uat_id: 'UAT-099'`), regex targets that match SPEC YAML structure, filename literals (`uat-001.spec.ts`), illustrative `(e.g. SPEC-002)` examples in usage docs, generic placeholders (`SPEC-NNN`, `SPEC-NNN.md`), variable-name fragments (`uat_id`, `uats_block`).
- **Flag (narrative — findings):** section-header parentheticals (`#### 5b. Discuss-this escape (UAT-004)`), inline narrative parentheticals (`(UAT-022, UAT-027)`), comments naming specific working-doc IDs, pass/fail label prefixes (`pass "UAT-001 …"`), prose using a maintainer SPEC ID as a system-wide constant (`operate under SPEC-001's scope_boundaries`).

If both scans produce zero narrative findings (all matches are structural):

```markdown
## #13: UAT/SPEC narrative-ref drift

✓ No narrative `UAT-NNN` or concrete maintainer `SPEC-NNN` references detected outside the structural exemptions in `.claude/rules/wiki-style.md`.
```

Otherwise:

```markdown
## #13: UAT/SPEC narrative-ref drift

⚠ {N} narrative ref(s) found in instruction files / shipped extension surfaces:

- `.claude/skills/foo/SKILL.md:42` — `(UAT-012)` parenthetical in section header
- `.specify/extensions/gaia/commands/bar.md:88` — `operate under SPEC-001's scope_boundaries` prose
```

List every narrative finding (one per line). Structural matches are not listed — they are the regex's false positives by design.

## Step 5: Surface to the user

Print to the user:

1. The report path (e.g. `wiki/meta/lint-report-2026-05-03.md`).
2. A one-line summary that includes the drift severity and count, plus dead-path count if non-zero, plus narrative-ref count if non-zero.

If `drift_severity` is **`high`**, surface it prominently (separate line, prefixed with `WIKI DRIFT:`).
If `dead.length > 0`, surface as a separate line prefixed with `WIKI DEAD-PATHS:` followed by the count.
If narrative-ref findings > 0, surface as a separate line prefixed with `UAT-SPEC DRIFT:` followed by the count.

## Notes

- Hooks (drift-check, commit-nudge, session-stop) are read-only consumers of `wiki/.state.json`. Only sync writes to it. This workflow also does not write `wiki/.state.json`.
- Drift count semantics: missing state file or unreachable SHA are surfaced as advisories, not silent zeroes. See [[Wiki Sync]] for the full design.
- Severity table thresholds are the canonical thresholds for this plan; if changing, update both this file and any sibling tooling that classifies drift.
