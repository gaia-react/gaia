---
name: wiki-lint
description: Health check the GAIA wiki — runs the upstream claude-obsidian wiki-lint, then appends GAIA-specific checks (drift between wiki/.state.json and HEAD).
---

## Execution model — READ FIRST

**Do not execute the playbook yourself in the current conversation.** Dispatch a Haiku subagent via the `Agent` tool. The work is mechanical (rule-based orphan/dead-link/frontmatter checks plus a deterministic drift severity table) — Haiku is sufficient, and a fresh context avoids dragging the upstream skill's large wiki-page reads into the parent. This protects the user even if they're on Opus or forgot to `/clear` before invoking.

Spawn:

- `subagent_type`: `"general-purpose"`
- `model`: `"haiku"`
- `description`: `"Wiki lint"`
- `prompt`: the string below (literal, no paraphrasing):

  > `You are running the GAIA /wiki-lint workflow in a fresh context. Read .claude/commands/wiki-lint.md from the project root and execute the "Playbook" section (Steps 1–4) verbatim. Your working directory is the project root. Return only the report path and the one-line summary required by Step 4 — no recap of the report contents.`

When the subagent returns, relay its summary verbatim. If the drift severity is **`high`**, prefix the surfaced line with `WIKI DRIFT:` per Step 4. If the subagent returns a `WIKI DEAD-PATHS:` line, surface it too.

---

## Playbook

GAIA-local wrapper around the upstream `claude-obsidian:wiki-lint` skill. Runs the upstream lint flow first, then appends GAIA-specific checks **#11: Wiki drift check** and **#12: Dead repo-relative paths** to the report.

Do **not** modify the upstream skill (`~/.claude/plugins/marketplaces/claude-obsidian-marketplace/skills/wiki-lint/SKILL.md`) — it is read-only territory. Extensions live here.

## Step 1: Run upstream wiki-lint

Invoke the `claude-obsidian:wiki-lint` skill following its documented pattern (see `~/.claude/plugins/marketplaces/claude-obsidian-marketplace/skills/wiki-lint/SKILL.md`). The upstream skill writes the report to:

```
wiki/meta/lint-report-YYYY-MM-DD.md
```

Capture the report path it produced — every appended GAIA check writes into that same file.

Do **not** restructure the upstream report format. Append GAIA sections at the bottom only.

## Step 2: GAIA check #11 — Wiki drift

After the upstream lint finishes, run `gaia wiki state --json` and append a `## #11: Wiki drift check` section to the report file based on its output.

### 2a. Run the primitive

```bash
gaia wiki state --json
```

The CLI returns a JSON object with `drift_severity` (`none` | `low` | `medium` | `high`), `head_short`, `state_sha`, `commits_ahead`, `reachable`, and `recent_commits`. If the command exits non-zero with `state_missing` (or equivalent reason), append:

```markdown
## #11: Wiki drift check

⚠ `wiki/.state.json` missing — system has never run `/wiki-sync`. Run `/wiki-sync` to initialize.
```

Then stop the drift check.

If `reachable === false`, append:

```markdown
## #11: Wiki drift check

⚠ `wiki/.state.json` `last_evaluated_sha` (`<state_sha>`) is not reachable from HEAD (history rewritten or shallow clone). Run `/wiki-sync` to re-anchor.
```

Then stop.

### 2b. Classify and append

Map the CLI's `drift_severity` and `commits_ahead` to the report section:

| `drift_severity` | Section to append                                                                                                       |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `none`           | `✓ Wiki in sync with HEAD ({head_short}).`                                                                              |
| `low`            | `ℹ {commits_ahead} commits behind HEAD. Run /wiki-sync at next opportunity.`                                            |
| `medium`         | `⚠ {commits_ahead} commits behind HEAD. Run /wiki-sync soon.` + recent commits list                                     |
| `high`           | `✗ {commits_ahead} commits behind HEAD. Wiki is significantly out of date. Run /wiki-sync now.` + recent commits list   |

For **medium** and **high**, list up to 5 of the `recent_commits` from the CLI output as `  - <sha> <subject>`.

Example WARN (`medium`) section:

```markdown
## #11: Wiki drift check

⚠ 7 commits behind HEAD. Run `/wiki-sync` soon. Recent unsynced commits:

- a1b2c3d feat: add new module
- d4e5f6g fix: edge case in router
- h7i8j9k chore: bump deps
```

Example ERROR (`high`) section:

```markdown
## #11: Wiki drift check

✗ 14 commits behind HEAD. Wiki is significantly out of date. Run `/wiki-sync` now. Recent unsynced commits:

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

## Step 4: Surface to the user

Print to the user:

1. The report path (e.g. `wiki/meta/lint-report-2026-05-03.md`).
2. A one-line summary that includes the drift severity and count, plus dead-path count if non-zero.

If `drift_severity` is **`high`**, surface it prominently (separate line, prefixed with `WIKI DRIFT:`).
If `dead.length > 0`, surface as a separate line prefixed with `WIKI DEAD-PATHS:` followed by the count.

## Notes

- Hooks (drift-check, commit-nudge, session-stop) are read-only consumers of `wiki/.state.json`. Only `/wiki-sync` writes to it. This command also does not write `wiki/.state.json`.
- Drift count semantics: missing state file or unreachable SHA are surfaced as advisories, not silent zeroes. See [[Wiki Sync]] for the full design.
- Severity table thresholds are the canonical thresholds for this plan; if changing, update both this command and any sibling tooling that classifies drift.
