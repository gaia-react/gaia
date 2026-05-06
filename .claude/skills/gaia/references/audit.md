# /gaia audit

## Execution model — READ FIRST

**Do not execute the playbook yourself in the current conversation.** Dispatch subagents via the `Agent` tool. Each subagent runs in isolated context.

Calling `/gaia audit` is the intent to apply. The default chains research and apply: Stage 1 produces a report, Stage 2 executes it. The two-stage split exists for technical reasons (different reasoning loads, drift-check between stages), not as a user-confirmation gate.

### Path resolution (portable — no hardcoding)

This command ships in a template and runs in many clones across many machines. Neither this file nor the subagent prompts may hardcode a project root or a user-scoped memory path. The subagent resolves both at the start of its run:

```bash
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
MEMORY_DIR="$HOME/.claude/projects/$(echo "$PROJECT_ROOT" | sed 's|/|-|g')/memory"
AGENT_MEMORY_DIR="$HOME/.claude/agent-memory"
```

Every path below referenced as `$PROJECT_ROOT/...`, `$MEMORY_DIR/...`, or `$AGENT_MEMORY_DIR/...` is resolved by the subagent, not by this file.

### Branch on `$ARGUMENTS`

**Default (`/gaia audit`)** → Stage 1, then Stage 2.

1. Spawn the Stage 1 (Research) subagent below. Wait for it to return.
2. If Stage 1 succeeded (a report path was printed), spawn the Stage 2 (Apply) subagent below. Stage 2 finds the newest report by mtime — no path argument needed.
3. Relay both summaries verbatim, in order.
4. If Stage 1 failed, do not spawn Stage 2. Surface the error.

**`/gaia audit --apply`** → Stage 2 only.

Skip Stage 1. Spawn the Stage 2 (Apply) subagent below directly. Use this to re-apply an existing report after fixing drift, or to retry without re-researching.

### Stage 1 subagent (Research)

- `subagent_type`: `"general-purpose"`
- `model`: `"sonnet"`
- `description`: `"Knowledge audit (research)"`
- `prompt`: the string below (literal, no paraphrasing):

  > `You are Stage 1 of a two-stage knowledge audit. Your job is to PRODUCE A REPORT ONLY — do not mutate any files outside .gaia/local/audit/. The Stage 2 agent will execute the actions immediately after you return.`
  >
  > `Before doing anything else, resolve these variables and use them for every path in the playbook:`
  >
  > ```bash
  > PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  > MEMORY_DIR="$HOME/.claude/projects/$(echo "$PROJECT_ROOT" | sed 's|/|-|g')/memory"
  > AGENT_MEMORY_DIR="$HOME/.claude/agent-memory"
  > ```
  >
  > `Record the resolved values at the top of the report (both frontmatter and a visible line) so Stage 2 uses the same bindings.`
  >
  > `Read $PROJECT_ROOT/.claude/skills/gaia/references/audit.md and execute the "Research procedure" section (Steps 1–6). Write the report to $PROJECT_ROOT/.gaia/local/audit/KNOWLEDGE-{YYYY-MM-DD-HHMM}.md using the exact "Report template" schema. Every action you propose must be mechanical — include every detail a literal-minded executor needs: absolute paths, line ranges, expected current content (verbatim snippet), replacement content (verbatim), and drift-check signals. No handwaving like "merge these" or "consolidate that".`

### Stage 2 subagent (Apply)

- `subagent_type`: `"general-purpose"`
- `model`: `"sonnet"`
- `description`: `"Knowledge audit (apply)"`
- `prompt`: the string below (literal):

  > `You are Stage 2 of a two-stage knowledge audit. Stage 1 produced a report. Your job is to execute the unchecked actions MECHANICALLY — do not reason about whether an action is correct, do not expand scope, do not merge or split actions.`
  >
  > `Before doing anything else, resolve these variables and use them for every path in the playbook:`
  >
  > ```bash
  > PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  > MEMORY_DIR="$HOME/.claude/projects/$(echo "$PROJECT_ROOT" | sed 's|/|-|g')/memory"
  > AGENT_MEMORY_DIR="$HOME/.claude/agent-memory"
  > ```
  >
  > `Compare these to the "project_root" / "memory_dir" fields recorded in the report's frontmatter. If they differ, STOP and print a clear error — do not improvise.`
  >
  > `Read $PROJECT_ROOT/.claude/skills/gaia/references/audit.md and execute the "Apply procedure" section (Step 7). For every action: verify the expected-current-content drift signal matches; if it does, apply the change verbatim; if it does not, SKIP and note it in the final summary. Never improvise. Never invent replacements. If anything is ambiguous, skip.`

### After the subagent(s) return

Relay each subagent's final summary verbatim (report path + action counts, then done/skipped/failed counts). Do not re-do the work. Do not inline the report body.

---

## Research procedure

Audit the knowledge stores for duplication, stale entries, and auto-load bloat. **Wiki is the source of truth.** Memory is machine-local only. Auto-loaded files carry a token cost every session — keep them as pointers, push detail behind lazy wikilinks.

The report you produce is a **contract** to a Sonnet-level executor. Assume it can read, edit, and run bash, but will not reason about intent. Every action needs a literal before/after.

## Stores & load behavior

| Store                                          | Path                                            | Auto-loaded?                                                |
| ---------------------------------------------- | ----------------------------------------------- | ----------------------------------------------------------- |
| Machine-local project memory                   | `$MEMORY_DIR/`                                  | `MEMORY.md` (first 200 lines), individual entries on demand |
| Machine-local agent memory                     | `$AGENT_MEMORY_DIR/`                            | Per-agent, on demand                                        |
| Project agent memory                           | `$PROJECT_ROOT/.claude/agent-memory/`           | Per-agent, on demand                                        |
| Project CLAUDE.md (root)                       | `$PROJECT_ROOT/CLAUDE.md`                       | Auto at session start                                       |
| Wiki README                                    | `$PROJECT_ROOT/wiki/README.md`                  | On demand only                                              |
| Project rules                                  | `$PROJECT_ROOT/.claude/rules/*.md`              | Auto by `paths:` frontmatter match                          |
| Project commands                               | `$PROJECT_ROOT/.claude/commands/*.md`           | On invocation only                                          |
| Wiki hot cache                                 | `$PROJECT_ROOT/wiki/hot.md`                     | Auto at session start                                       |
| Wiki index                                     | `$PROJECT_ROOT/wiki/index.md`                   | On demand                                                   |
| Wiki domain pages                              | `$PROJECT_ROOT/wiki/<domain>/`                  | On demand                                                   |
| Nested `CLAUDE.md` files (any monorepo layout) | any `$PROJECT_ROOT/**/CLAUDE.md` below the root | Auto when cwd matches                                       |

## Step 0 — Prune old reports

Before writing the new report, self-maintain `$PROJECT_ROOT/.gaia/local/audit/`:

- **Keep the newest 5 reports regardless of age** (floor — protects long gaps between runs).
- Of anything beyond the newest 5, **delete reports older than 30 days**.

```bash
if [ -d "$PROJECT_ROOT/.gaia/local/audit" ]; then
  ls -t "$PROJECT_ROOT"/.gaia/local/audit/KNOWLEDGE-*.md 2>/dev/null | tail -n +6 | while IFS= read -r f; do
    if [ -n "$(find "$f" -mtime +30 -print 2>/dev/null)" ]; then
      rm -- "$f"
    fi
  done
fi
```

Report the count pruned in the summary line at the end of the run (e.g. `pruned 2 stale reports`).

## Step 1 — Inventory

Run in parallel:

```bash
# Machine-local memory (resolved dynamically)
find "$MEMORY_DIR" -type f -name "*.md" 2>/dev/null
find "$AGENT_MEMORY_DIR" -type f -name "*.md" 2>/dev/null

# Project-local
find "$PROJECT_ROOT/.claude/agent-memory" -type f -name "*.md" 2>/dev/null
find "$PROJECT_ROOT/.claude/rules" -type f -name "*.md"

# Wiki
find "$PROJECT_ROOT/wiki" -type f -name "*.md"

# Auto-loaded CLAUDE.md set (covers root, wiki, and any downstream app subdirs)
find "$PROJECT_ROOT" -maxdepth 3 -name CLAUDE.md -not -path '*/node_modules/*'

# Word counts for auto-loaded files
wc -w "$PROJECT_ROOT"/CLAUDE.md "$PROJECT_ROOT"/wiki/hot.md "$PROJECT_ROOT"/.claude/rules/*.md 2>/dev/null
```

Record per file: path, word count, last-modified. Compute totals per store.

## Step 2 — Cross-store duplication

For every memory entry and every rules file, check whether the same fact lives in the wiki. Use `Grep` with 2–3 representative phrases from each entry. Classify each hit:

- **DUPLICATE** — fact already canonical in wiki → mark memory/rules entry for deletion
- **PROMOTE** — durable knowledge only in memory → propose moving to a specific wiki page (name the page)
- **KEEP-LOCAL** — genuinely machine-local (personal pref, machine path, unique dev env) → keep in memory
- **STALE** — references a file/branch/feature no longer present → mark for deletion

Rules-vs-wiki: a `.claude/rules/*.md` file is allowed to duplicate wiki content **only** if it exists to enforce auto-loading for a specific `paths:` glob. Otherwise it should link to the wiki page.

## Step 3 — Intra-wiki duplication

Scan `$PROJECT_ROOT/wiki/` for pages covering the same topic. For each cluster:

- Pick the most-complete page as canonical
- Propose merging the others into it (or converting them to redirects: a one-line page with `→ see [[Canonical]]`)
- Flag pages in `wiki/sources/` that duplicate content already synthesized in a domain page — `sources/` is archival, domain pages are active

## Step 4 — Auto-load budget

Targets (flag anything over):

| File                                                                               | Budget     | Rationale                                  |
| ---------------------------------------------------------------------------------- | ---------- | ------------------------------------------ |
| `wiki/hot.md`                                                                      | ≤200 words | Cache discipline per `wiki/hot.md` comment |
| `CLAUDE.md` (root)                                                                 | ≤400 words | Routing + principles only                  |
| `wiki/README.md`                                                                   | —          | On demand — no auto-load budget needed     |
| Any nested `CLAUDE.md` discovered in Step 1 (monorepo package, subapp, docs, etc.) | ≤400 words | Scoped routing                             |
| Any single `.claude/rules/*.md`                                                    | ≤200 lines | Focused rule                               |

For each over-budget file, propose one of: inline facts → wiki, consolidate duplicated sections, or split into narrower files.

## Step 5 — Link-efficiency audit

In every auto-loaded file (CLAUDE.md hierarchy, `wiki/hot.md`, rules):

- **Describes instead of points** — flag passages that restate content already in a wiki page (e.g. inlining a facts table instead of linking to the canonical wiki page). Propose replacing with wikilink.
- **Broken wikilinks** — `Grep` every `[[Name]]` against `wiki/index.md`. Flag misses.
- **Dead paths** — verify every file path referenced in auto-loaded files still exists.
- **Inlined source excerpts** — flag wiki pages that inline raw text from `wiki/sources/` instead of linking.

## Step 6 — Report

Write `$PROJECT_ROOT/.gaia/local/audit/KNOWLEDGE-{YYYY-MM-DD-HHMM}.md`. Create `$PROJECT_ROOT/.gaia/local/audit/` if missing. Also snapshot `git status --short` into the report's frontmatter so Stage 2 can detect drift.

### Report template (strict schema — Stage 2 parses this)

````markdown
---
generated: {YYYY-MM-DD HH:MM}
generator: audit-knowledge stage-1 sonnet
project_root: {resolved PROJECT_ROOT}
memory_dir: {resolved MEMORY_DIR}
agent_memory_dir: {resolved AGENT_MEMORY_DIR}
git_head: {commit hash}
git_status_snapshot: |
  {verbatim output of `git status --short` at research time}
---

# Knowledge Audit — {YYYY-MM-DD HH:MM}

Resolved paths (Stage 2 must match these):

- project_root: {resolved PROJECT_ROOT}
- memory_dir: {resolved MEMORY_DIR}
- agent_memory_dir: {resolved AGENT_MEMORY_DIR}

## Summary

- Stores scanned: {N files, M words total}
- Cross-store duplicates: {X}
- Intra-wiki duplicates: {Y}
- Auto-load total: {Z words} (budget: {total budget})
- Over-budget files: {list}
- Stale entries: {count}
- Broken links: {count}

## Actions

Each action is a fenced YAML block prefixed with a checkbox line. Stage 2 flips the checkbox from `[ ]` to `[x]` on success, `[~]` on skip, `[!]` on failure. Every block MUST include `expect` (verbatim snippet of current target content) and where applicable `after` (verbatim replacement). Paths MUST be absolute (already expanded — no `$PROJECT_ROOT` placeholders in action bodies).

### Delete

- [ ] `delete-{nnn}`
  ```yaml
  type: delete
  path: {absolute path}
  reason:
    {one line — cite canonical wiki page + line range where the same fact lives}
  expect_sha256: {sha256 of the file's current content}
  ```
````

### Delete-entry (remove a specific block from a multi-entry file, e.g. a heading section in MEMORY.md)

- [ ] `delete-entry-{nnn}`
  ```yaml
  type: delete-entry
  path: {absolute path}
  expect: |
    {verbatim block to remove, including heading — must match exactly}
  reason: {…}
  ```

### Promote (memory → wiki)

- [ ] `promote-{nnn}`
  ```yaml
  type: promote
  source_path: {absolute path}
  source_expect_sha256: {sha256 of source content}
  target_page: {absolute wiki path}
  target_action: {append_section | insert_after_heading | create_new}
  target_heading: {e.g. "## Bar" — only if insert_after_heading}
  target_expect: |
    {verbatim snippet at insertion point — omit for create_new}
  body: |
    {verbatim content to insert, frontmatter-ready if target_action=create_new}
  index_entry: {one-line addition to wiki/index.md, or null}
  log_entry: {one-line to prepend to wiki/log.md}
  delete_source_after: true
  ```

### Shrink / Convert (replace inline content with a wikilink)

- [ ] `shrink-{nnn}`
  ```yaml
  type: replace
  path: {absolute path}
  before: |
    {verbatim current block — must match byte-for-byte}
  after: |
    {verbatim replacement, typically a wikilink line}
  reason: {…}
  ```

### Merge (intra-wiki consolidation)

- [ ] `merge-{nnn}`
  ```yaml
  type: merge
  canonical: {absolute wiki path}
  canonical_expect_sha256: {sha256}
  sources:
    - path: {absolute wiki path}
      expect_sha256: {sha256}
      append_as: |
        {verbatim content to add to canonical}
      redirect_body: |
        ---
        type: redirect
        ---
        → see [[Canonical Name]]
  index_updates:
    - {line to change in wiki/index.md}
  log_entry: {one-line to prepend to wiki/log.md}
  ```

### Fix-link

- [ ] `fixlink-{nnn}`
  ```yaml
  type: replace
  path: {absolute path}
  before: |
    {verbatim line containing the broken link}
  after: |
    {verbatim corrected line, or empty string to delete the line}
  reason: {broken target, correct target}
  ```

## Ordering

Stage 2 must apply actions in this order: `fix-link` → `shrink` → `delete-entry` → `merge` → `promote` → `delete`. Rationale: shrinks never reference content that later gets merged; deletes come last so earlier pointers don't go stale.

## To re-apply

Apply runs immediately after this report. To re-apply later (e.g., after fixing drift): `/gaia audit --apply` within 24h.

```

End the research run by printing: report path and total actions per category. (Stage 2 runs next automatically.)

## Step 7 — Apply procedure (Stage 2, Sonnet)

You are executing, not reasoning. Follow this loop exactly.

### Pre-flight

1. Find the newest `$PROJECT_ROOT/.gaia/local/audit/KNOWLEDGE-*.md`. If none, or mtime >24h, stop and print `no fresh report — run /gaia audit first`.
2. Parse the report's frontmatter. Verify `project_root`, `memory_dir`, and `agent_memory_dir` match the values you resolved at startup. If any differ, stop and print a clear error — the report was generated on a different machine or in a different clone.
3. Run `git rev-parse HEAD` — if it differs from `git_head` in the report, print a warning but continue. Run `git status --short` — any file that is currently dirty AND appears as a target in the report is marked `SKIP (dirty)` before any action runs.
4. Read the `## Ordering` section. Process actions in that order.

### Per-action loop

For each unchecked action block:

1. Verify drift signal:
   - If the action specifies `expect_sha256`: compute sha256 of the target file. If mismatch → mark `[~]` skipped, record reason `sha drift`, move on.
   - If the action specifies `before:` or `expect:` snippet: read the file and confirm the snippet appears verbatim. If missing → `[~]` skipped, `snippet drift`.
2. Apply the change using the exact operation:
   - `type: delete` → remove the file
   - `type: delete-entry` → read file, locate the `expect` block, remove it, write back
   - `type: promote` → perform the `target_action` (use Edit or Write as appropriate), then prepend `log_entry` to `wiki/log.md`, then append `index_entry` to the right section of `wiki/index.md`, then delete `source_path` if `delete_source_after: true`
   - `type: replace` → Edit with `old_string: before`, `new_string: after`. If `before` is not unique, prepend additional context from the file until unique.
   - `type: merge` → for each source: append `append_as` into canonical at its tail (or an explicit position if the action specifies one), then overwrite the source with `redirect_body`. Then prepend `log_entry` to `wiki/log.md`. Apply `index_updates` to `wiki/index.md`.
3. Flip the checkbox: `[ ]` → `[x]` on success, `[~]` on skip, `[!]` on error. Record the reason inline on the checkbox line.

### Post-flight

Print a final summary to stdout:

```

audit apply: {done}/{total} applied · {skipped} skipped · {failed} failed
diff footprint:
{git status --short}
next: review diff, commit if satisfied

```

## Guardrails

- Never delete a memory entry unless the action's `reason` cites a canonical wiki location. (Stage 1 must supply this; Stage 2 doesn't judge.)
- Never edit `wiki/log.md` anywhere except prepending a new line at the top.
- Never `git add` or `git commit` — leave changes in working tree for the human to review.
- Never improvise: if drift-check fails, skip and report. Do not search for the "right" target.
- Never merge two actions: each block is atomic.
- If an action targets a path that doesn't exist, mark `[!]` with `target missing` and continue.
```
