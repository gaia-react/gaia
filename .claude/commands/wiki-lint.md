---
name: wiki-lint
description: Health check the GAIA wiki — runs the upstream claude-obsidian wiki-lint, then appends GAIA-specific checks (drift between wiki/.state.json and HEAD).
---

GAIA-local wrapper around the upstream `claude-obsidian:wiki-lint` skill. Runs the upstream lint flow first, then appends GAIA-specific check **#11: Wiki drift check** to the report.

Do **not** modify the upstream skill (`~/.claude/plugins/marketplaces/claude-obsidian-marketplace/skills/wiki-lint/SKILL.md`) — it is read-only territory. Extensions live here.

## Step 1: Run upstream wiki-lint

Invoke the `claude-obsidian:wiki-lint` skill following its documented pattern (see `~/.claude/plugins/marketplaces/claude-obsidian-marketplace/skills/wiki-lint/SKILL.md`). The upstream skill writes the report to:

```
wiki/meta/lint-report-YYYY-MM-DD.md
```

Capture the report path it produced — every appended GAIA check writes into that same file.

Do **not** restructure the upstream report format. Append GAIA sections at the bottom only.

## Step 2: GAIA check #11 — Wiki drift

After the upstream lint finishes, run the drift check below and append a `## #11: Wiki drift check` section to the report file.

### 2a. Read state file

```bash
test -f wiki/.state.json && cat wiki/.state.json | jq -r '.last_evaluated_sha' || echo MISSING
```

If the result is `MISSING` or `jq` returns null, append:

```markdown
## #11: Wiki drift check

⚠ `wiki/.state.json` missing — system has never run `/wiki-sync`. Run `/wiki-sync` to initialize.
```

Then stop the drift check (no further sub-steps).

### 2b. Verify SHA reachable from HEAD

```bash
STATE_SHA=$(jq -r '.last_evaluated_sha' wiki/.state.json)
git merge-base --is-ancestor "$STATE_SHA" HEAD 2>/dev/null
```

If the exit status is non-zero, the recorded SHA is not in HEAD's history (rebase, reset, or shallow clone). Append:

```markdown
## #11: Wiki drift check

⚠ `wiki/.state.json` `last_evaluated_sha` (`<short_sha>`) is not reachable from HEAD (history rewritten or shallow clone). Run `/wiki-sync` to re-anchor.
```

Then stop. `<short_sha>` is `git rev-parse --short "$STATE_SHA"` (fall back to the first 7 chars if the rev-parse fails).

### 2c. Compute drift count

```bash
DRIFT=$(git rev-list --count "$STATE_SHA"..HEAD)
HEAD_SHORT=$(git rev-parse --short HEAD)
```

### 2d. Classify and append

| Drift count | Severity | Section to append                                                                                       |
| ----------- | -------- | ------------------------------------------------------------------------------------------------------- |
| 0           | OK       | `✓ Wiki in sync with HEAD ({HEAD_SHORT}).`                                                              |
| 1–4         | INFO     | `ℹ {DRIFT} commits behind HEAD. Run /wiki-sync at next opportunity.`                                    |
| 5–9         | WARN     | `⚠ {DRIFT} commits behind HEAD. Run /wiki-sync soon.` + recent commits list                             |
| 10+         | ERROR    | `✗ {DRIFT} commits behind HEAD. Wiki is significantly out of date. Run /wiki-sync now.` + recent commits |

For **WARN** and **ERROR**, list up to 5 most recent unsynced commit subjects:

```bash
git log "$STATE_SHA"..HEAD --no-merges --reverse --format='  - %h %s' | tail -5
```

Example WARN section:

```markdown
## #11: Wiki drift check

⚠ 7 commits behind HEAD. Run `/wiki-sync` soon. Recent unsynced commits:

  - a1b2c3d feat: add new module
  - d4e5f6g fix: edge case in router
  - h7i8j9k chore: bump deps
```

Example ERROR section:

```markdown
## #11: Wiki drift check

✗ 14 commits behind HEAD. Wiki is significantly out of date. Run `/wiki-sync` now. Recent unsynced commits:

  - a1b2c3d feat: ...
  - d4e5f6g fix: ...
  - h7i8j9k chore: ...
  - l0m1n2o docs: ...
  - p3q4r5s refactor: ...
```

## Step 3: Surface to the user

Print to the user:

1. The report path (e.g. `wiki/meta/lint-report-2026-05-03.md`).
2. A one-line summary that includes the drift severity and count.

If drift is in **ERROR** severity, surface it prominently (separate line, prefixed with `WIKI DRIFT:`).

## Notes

- Hooks (drift-check, commit-nudge, stop-safety-net) are read-only consumers of `wiki/.state.json`. Only `/wiki-sync` writes to it. This command also does not write `wiki/.state.json`.
- Drift count semantics match the rules in `.claude/plans/wiki-sync-system/README.md` § 5: missing state file or unreachable SHA are surfaced as advisories, not silent zeroes.
- Severity table thresholds are the canonical thresholds for this plan; if changing, update both this command and any sibling tooling that classifies drift.
