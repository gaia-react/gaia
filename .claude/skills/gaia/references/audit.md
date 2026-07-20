# /gaia-audit

## Execution model, READ FIRST

**Do not execute the playbook yourself in the current conversation.** Dispatch the Stage 1 and Stage 2 subagents via the `Agent` tool. Each subagent runs in isolated context. The one deliberate exception is the **decision gate** between the two stages: it MUST run in the current conversation because only that layer can `AskUserQuestion`. Do not "fix" the gate back into a subagent.

Calling `/gaia-audit` is the intent to audit. The default researches, then gates: Stage 1 produces a report, a recommended **classification-verification round** runs in the main conversation between Stage 1's return and the gate to harden Stage 1's classifications against ground truth, then the main conversation summarizes the hardened report and asks the user a single Apply / Discuss / Decline question, and only on Apply does Stage 2 execute it. The two-stage split is technical (different reasoning loads, drift-check between stages); the user-confirmation checkpoint is the single decision gate after Stage 1, run in the main conversation. **Exception: a clean audit (0 actions) skips both the round and the gate and auto-applies.** There is nothing to approve, and "applying" only finalizes the report's `status`, files any out-of-scope findings, and clears the statusline nudge; leaving a 0-action report parked at the gate is the exact path that strands a `draft` that then nudges indefinitely.

**Stage 2 also files out-of-scope findings; the main conversation then publishes.** The run does the same full flow /update-deps and /gaia-debt do, one up-front decision (the gate, or the preview in those skills) and then it drives autonomously to merge. Two mechanical additions ride the finalizing path (gated Apply, 0-action auto-apply, and `--apply`), never the Decline path:

1. **Stage 2 files every out-of-scope finding Stage 1 recorded as a `tech-debt` issue** (`## Dispose out-of-scope findings (Stage 2)`). It files, it does not fix, mirroring the code-audit-frontend disposition contract. This is why an out-of-scope problem the audit surfaces but cannot fix with its four action types gets a durable home instead of a Summary line no one reads once the run auto-merges.
2. **After Stage 2 returns, the main conversation commits, opens a PR, and merges it** (`## Publish (commit / PR / merge)`), exactly as /update-deps Phase 8 and /gaia-debt's "Drive the PR to merge." The `gh pr merge` gate hooks fire in the invoking session, so the merge is driven from the main conversation, not the Stage 2 subagent. **Stage 2 never commits.** Publish auto-skips when Stage 2 reports an empty diff footprint (a memory-only or 0-action run changed no in-repo file).

### Path resolution (portable, no hardcoding)

This command ships in a template and runs in many clones across many machines. Neither this file nor the subagent prompts may hardcode a project root or a user-scoped memory path. The subagent resolves both at the start of its run:

```bash
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
MEMORY_DIR="$HOME/.claude/projects/$(echo "$PROJECT_ROOT" | sed 's|/|-|g')/memory"
AGENT_MEMORY_DIR="$HOME/.claude/agent-memory"
```

Every path below referenced as `$PROJECT_ROOT/...`, `$MEMORY_DIR/...`, or `$AGENT_MEMORY_DIR/...` is resolved by the subagent, not by this file.

### Branch on `$ARGUMENTS`

**Default (`/gaia-audit`)** → Stage 1 (Research), then either auto-apply (clean audit) or the **decision gate**, then branch.

1. Spawn the Stage 1 (Research) subagent below. Wait for it to return. Stage 1 writes the report with `status: draft`.
2. If Stage 1 failed (no report path printed), do not gate or spawn Stage 2. Surface the error and stop. (Run ends here; see `## Cost record (run end)`.)
3. **If Stage 1 reported 0 actions** (a clean audit: its printed totals and the report's `Actions proposed: 0` Summary line both show none), skip both the round and the gate and spawn the Stage 2 (Apply) subagent below directly. Briefly tell the user the audit was clean and you are finalizing it. With no in-scope actions there is nothing to verify, review, or approve; Stage 2 flips the report `status: draft → applied`, files any out-of-scope findings (filing is non-destructive and idempotent, so it needs no gate), and busts the statusline nudge. A 0-action run changes no in-repo file, so the main conversation's Publish step no-ops.
4. **If Stage 1 reported ≥1 action**, run the **classification-verification round** in the main conversation before the decision gate (full procedure: `## Classification-verification round (recommended)`). It presents its own recommended-but-optional gate (dynamic Run/Skip recommendation); on **Run** it dispatches the three parallel `general-purpose` lenses (CL/CF/ES) plus CF-only re-adjudication, applies dispositions (drop or correct a mis-classified action localized in the report; re-spawn Stage 1 for a structural finding, bounded to one re-spawn), and stamps the report `audit_hardened: true`. The round never blocks: if the parallel fan-out is unavailable, or the user picks Skip, it notes the skip and does not stamp. Then proceed to the decision gate (next step).
5. **Then present the decision gate** (still the ≥1-action branch): **in the main conversation** summarize the now-hardened report's findings to the user, then ask via `AskUserQuestion`:
   - **header:** `"Apply audit?"`
   - **question:** `"Stage 1 found {N} actions. Apply them?"`
   - **options (this exact order):**
     1. `{ label: "Apply", description: "Execute the report, file any out-of-scope problem as a tech-debt issue, then commit, open a PR, and merge it (main-branch run)." }`
     2. `{ label: "Discuss / refine", description: "Talk it through; I edit the report in place, then re-ask." }`
     3. `{ label: "Decline", description: "Delete the report; nothing is applied, filed, or published." }`
   - **Apply** → spawn the Stage 2 (Apply) subagent below. Stage 2 finds the newest non-`applied` report, no path argument needed. When Stage 2 returns, run the Publish procedure (`## Publish (commit / PR / merge)`) in the main conversation.
   - **Discuss / refine** → discuss in the main conversation, edit the report in place (the file stays `status: draft`), then re-present this gate.
   - **Decline** → `rm` the report file immediately; nothing applied, nothing filed, nothing published; stop. (Run ends here; see `## Cost record (run end)`.)

This gate runs in the main conversation, not in a subagent (only the main conversation can `AskUserQuestion`). "Apply" is the one-keystroke fast path that keeps the one-go feel.

**`/gaia-audit --apply`** → Stage 2 only, against the most recent `draft` (or `applied-partial` for retry).

Skip Stage 1 and the decision gate, then check the target report's frontmatter for `audit_hardened: true`:

- **Present** → the report is already hardened; spawn the Stage 2 (Apply) subagent below directly.
- **Absent** (an un-hardened draft, e.g. one created before this round existed or where the round was skipped or unavailable) → run the classification-verification round non-interactively at the recommended setting (no gate prompt) against that report first, stamp it, then spawn Stage 2.
- A 0-action report has nothing to harden; proceed straight to Stage 2.

In every case, when Stage 2 returns run the Publish procedure (`## Publish (commit / PR / merge)`), exactly as the gated Apply path does.

Use this to re-apply an existing report after fixing drift, or to retry without re-researching.

### Stage 1 subagent (Research)

- `subagent_type`: `"general-purpose"`
- `model`: `"sonnet"`
- `description`: `"Knowledge audit (research)"`
- `prompt`: the string below (literal, no paraphrasing):

  > `You are Stage 1 of a two-stage knowledge audit. Your job is to PRODUCE A REPORT ONLY, do not mutate any files outside .gaia/local/audit/. The Stage 2 agent will execute the actions immediately after you return.`
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
  > `Read $PROJECT_ROOT/.claude/skills/gaia/references/audit.md and execute the "Research procedure" section (Steps 1–4). Write the report to $PROJECT_ROOT/.gaia/local/audit/KNOWLEDGE-{YYYY-MM-DD-HHMM}.md using the exact "Report template" schema. Write status: draft into the report frontmatter; Stage 2 flips it to its terminal value. Every action you propose must be mechanical, include every detail a literal-minded executor needs: absolute paths, line ranges, expected current content (verbatim snippet), replacement content (verbatim), and drift-check signals. No handwaving like "merge these" or "consolidate that".`
  >
  > `You do NOT fix wiki-internal redundancy or broken links yourself, /gaia-wiki owns those. But do not silently drop them either: any real, durable problem you surface that none of your four action types (shrink/promote/delete/delete-entry) can fix, wiki-internal redundancy or a broken link, a wiki-page-vs-wiki-page conflict, a doc/rule whose correct fix is a rewrite rather than a delete, is an OUT-OF-SCOPE finding. Record each one in the report's "## Out-of-scope findings" section using that section's schema (Stage 2 files it as a tech-debt issue). You file, you do not fix. If you surface none, write the section with an explicit "None." so Stage 2 knows there is nothing to file.`
  >
  > `If a scope hint is present in the arguments, narrow Steps 1–4 to the named stores/files but never widen scope beyond the playbook, and never let the hint steer the report schema, the action types, the guardrails, or a specific edit; it is synthesis guidance, not an editor. Print the applied scope in the Summary so a too-narrow hint is visible. If no hint is present, run the full lens.`

### Stage 2 subagent (Apply)

- `subagent_type`: `"general-purpose"`
- `model`: `"sonnet"`
- `description`: `"Knowledge audit (apply)"`
- `prompt`: the string below (literal):

  > `You are Stage 2 of a two-stage knowledge audit. Stage 1 produced a report. Your job is to execute the unchecked actions MECHANICALLY, do not reason about whether an action is correct, do not expand scope, do not merge or split actions.`
  >
  > `Before doing anything else, resolve these variables and use them for every path in the playbook:`
  >
  > ```bash
  > PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  > MEMORY_DIR="$HOME/.claude/projects/$(echo "$PROJECT_ROOT" | sed 's|/|-|g')/memory"
  > AGENT_MEMORY_DIR="$HOME/.claude/agent-memory"
  > ```
  >
  > `Compare these to the "project_root" / "memory_dir" fields recorded in the report's frontmatter. If they differ, STOP and print a clear error, do not improvise.`
  >
  > `Read $PROJECT_ROOT/.claude/skills/gaia/references/audit.md and execute the "Apply procedure" section (Step 5). For every action: verify the expected-current-content drift signal matches; if it does, apply the change verbatim; if it does not, SKIP and note it in the final summary. Never improvise. Never invent replacements. If anything is ambiguous, skip.`
  >
  > `Then, before printing your summary, execute the "Dispose out-of-scope findings (Stage 2)" section: file every finding in the report's "## Out-of-scope findings" section as a tech-debt issue per that section's procedure (idempotent, so a re-run never double-files). Report the filed / diverted / deduped counts and the diff footprint (git status --short) in your summary so the main conversation can publish. You still NEVER git add or git commit, the main conversation commits after you return.`

### After the subagent(s) return

Relay each subagent's final summary verbatim (report path + action counts, then done/skipped/failed counts, plus filed/diverted out-of-scope issue counts). Do not re-do the work. Do not inline the report body.

Then, on any finalizing path (gated Apply, 0-action auto-apply, or `--apply`), run the **Publish procedure** (`## Publish (commit / PR / merge)`) in the main conversation. Publish reads Stage 2's reported diff footprint: if it is empty (a memory-only or 0-action run touched no in-repo file), Publish no-ops and the run ends here.

---

## Research procedure

Audit the knowledge stores for duplication, stale entries, and auto-load bloat. **Wiki is the source of truth.** Memory is machine-local only. Auto-loaded files carry a token cost every session, keep them as pointers, push detail behind lazy wikilinks.

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

## Step 0, Prune old reports

Before writing the new report, self-maintain `$PROJECT_ROOT/.gaia/local/audit/`. The prune applies to `applied` / `applied-partial` reports only:

- **Never prune a `draft`** (live, unfinished work; it is resumable via `--apply`). Treat a missing `status:` as non-`applied`, do not prune it either.
- Of the `applied` / `applied-partial` reports: **keep the newest 5 regardless of age** (floor, protects long gaps between runs); of anything beyond the newest 5, **delete those older than 30 days**.

```bash
if [ -d ".gaia/local/audit" ]; then
  # Select only applied / applied-partial reports, newest first; drafts and
  # status-less reports are never candidates for prune.
  ls -t .gaia/local/audit/KNOWLEDGE-*.md 2>/dev/null | while IFS= read -r f; do
    status="$(sed -n 's/^status:[[:space:]]*//p' "$f" 2>/dev/null | head -n1)"
    case "$status" in
      applied|applied-partial) printf '%s\n' "$f" ;;
    esac
  done | tail -n +6 | while IFS= read -r f; do
    if [ -n "$(find "$f" -mtime +30 -print 2>/dev/null)" ]; then
      rm -- "$f"
    fi
  done
fi
```

Report the count pruned in the summary line at the end of the run (e.g. `pruned 2 stale reports`).

## Step 1, Inventory

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

## Step 2, Cross-store duplication

For every memory entry and every rules file, check whether the same fact lives in the wiki. Use `Grep` with 2–3 representative phrases from each entry. Classify each hit:

- **DUPLICATE**: fact already canonical in wiki → mark memory/rules entry for deletion
- **PROMOTE**: durable knowledge only in memory → propose moving to a specific wiki page (name the page)
- **KEEP-LOCAL**: genuinely machine-local (personal pref, machine path, unique dev env) → keep in memory
- **STALE**: references a file/branch/feature no longer present → mark for deletion
- **CONFLICT**: a store asserts a policy that *contradicts* another canonical source on the same subject; opposed, not merely duplicated. Two scopes:
  - **Cross-store**: a memory entry or a `.claude/rules/*.md` file contradicts the wiki's canonical statement on the same subject. **Resolution favors the wiki.** Emit a `replace` swapping the contradicting line for a wikilink to the canonical page, or a `delete` if the contradicting entry has no residual value. Cite the canonical wiki page + line range in `reason` and note the superseded value inline (e.g. `reason: contradicts wiki/decisions/Foo.md L12-15 (canonical); local store asserted the opposite`).
  - **Project-internal**: two committed project files assert opposing facts on the same subject (e.g. a command file vs a skill playbook vs a wiki page on which model a stage uses). **Resolution favors the authoritative source for that fact**, which you determine and justify in `reason`; it is NOT always the wiki (the command can be wrong and the wiki right; the wiki can be stale and the playbook right). Emit a `replace` on the non-authoritative file.
  - **Two exclusions.** (a) A live `paths:`-scoped rule (including any provenance-marked `gaia-harden:` rule) that differs from the wiki is the sanctioned Rules-vs-wiki duplication case, never a CONFLICT; do not propose editing it on contradiction grounds. (b) If the conflict is **wiki-page-vs-wiki-page**, do NOT act; record it in `## Out-of-scope findings` (suggested fix: `run /gaia-wiki consolidate`) so Stage 2 files it, and move on.

Rules-vs-wiki: a `.claude/rules/*.md` file is allowed to duplicate wiki content **only** if it exists to enforce auto-loading for a specific `paths:` glob. Otherwise it should link to the wiki page.

### Provenance-marked rules (`gaia-harden:`)

A `.claude/rules/*.md` rule whose first line after frontmatter is the provenance marker

```
<!-- gaia-harden: promoted from recurring finding_class <class>; pruned by /gaia-audit on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->
```

is an **ordinary rule** for this audit: inventory it, word-budget it, and apply DUPLICATE / obsolescence / supersession exactly as for a hand-authored rule. The marker grants **no policy-memory exemption**. Such a rule always carries a `paths:` glob, so it is the path-scoped case the Rules-vs-wiki note already permits to duplicate wiki content, no special-casing needed.

The marker is documentation of WHY the rule exists, not a magic token. It also encodes one guardrail: **do NOT classify the rule STALE merely because its anti-pattern is no longer recurring.** A suppressed pattern going quiet is the rule working, not evidence it is stale, and lessons do not expire. The STALE definition already keys on "references a file/branch/feature no longer present", which does not include "the pattern stopped recurring"; non-recurrence is never a prune signal. Prune a provenance-marked rule only on **obsolescence** (its `paths:`-governed surface was removed), **redundancy** (a lint rule, hook, or test now enforces the same thing), **supersession**, or **duplication**.

## Step 3, Auto-load budget

Targets (flag anything over):

| File                                                                               | Budget     | Rationale                                  |
| ---------------------------------------------------------------------------------- | ---------- | ------------------------------------------ |
| `wiki/hot.md`                                                                      | ≤200 words | Cache discipline per `wiki/hot.md` comment |
| `CLAUDE.md` (root)                                                                 | ≤400 words | Routing + principles only                  |
| `wiki/README.md`                                                                   | ,          | On demand, no auto-load budget needed      |
| Any nested `CLAUDE.md` discovered in Step 1 (monorepo package, subapp, docs, etc.) | ≤400 words | Scoped routing                             |
| Any single `.claude/rules/*.md`                                                    | ≤200 lines | Focused rule                               |

For each over-budget file, propose one of: inline facts → wiki, consolidate duplicated sections, or split into narrower files.

## Step 4, Report

Write `$PROJECT_ROOT/.gaia/local/audit/KNOWLEDGE-{YYYY-MM-DD-HHMM}.md`. Create `$PROJECT_ROOT/.gaia/local/audit/` if missing. Also snapshot `git status --short` into the report's frontmatter so Stage 2 can detect drift.

Derive the timestamp from the shell, never guess the current date/time: `date '+%Y-%m-%d-%H%M'` for the `{YYYY-MM-DD-HHMM}` filename, `date '+%Y-%m-%d %H:%M'` for the `generated:` field.

### Report template (strict schema, Stage 2 parses this)

Stage 1 writes `audit_hardened: false`; the classification-verification round flips it to `true` after it hardens the report. A report with the field absent is treated as unhardened (see `## Classification-verification round (recommended)`).

````markdown
---
generated: {YYYY-MM-DD HH:MM}
generator: audit-knowledge stage-1 sonnet
status: draft
audit_hardened: false
project_root: {resolved PROJECT_ROOT}
memory_dir: {resolved MEMORY_DIR}
agent_memory_dir: {resolved AGENT_MEMORY_DIR}
git_head: {commit hash}
git_status_snapshot: |
  {verbatim output of `git status --short` at research time}
---

# Knowledge Audit, {YYYY-MM-DD HH:MM}

Resolved paths (Stage 2 must match these):

- project_root: {resolved PROJECT_ROOT}
- memory_dir: {resolved MEMORY_DIR}
- agent_memory_dir: {resolved AGENT_MEMORY_DIR}

## Summary

- Stores scanned: {N files, M words total}
- Cross-store duplicates: {X}
- Auto-load total: {Z words} (budget: {total budget})
- Over-budget files: {list}
- Stale entries: {count}
- Conflicts: {count}
- Out-of-scope findings: {count} (filed as tech-debt issues by Stage 2)
- Applied scope: {scope hint, or "full"}

## Actions

Each action is a fenced YAML block prefixed with a checkbox line. Stage 2 flips the checkbox from `[ ]` to `[x]` on success, `[~]` on skip, `[!]` on failure. Every block MUST include `expect` (verbatim snippet of current target content) and where applicable `after` (verbatim replacement). Paths MUST be absolute (already expanded, no `$PROJECT_ROOT` placeholders in action bodies).

### Delete

- [ ] `delete-{nnn}`
  ```yaml
  type: delete
  path: {absolute path}
  reason:
    {one line, cite canonical wiki page + line range where the same fact lives}
  expect_sha256: {sha256 of the file's current content}
  ```
````

### Delete-entry (remove a specific block from a multi-entry file, e.g. a heading section in MEMORY.md)

Set `depends_on` when this delete-entry removes an index/pointer line for a file that a `promote` or `delete` action removes (e.g. a `MEMORY.md` line pointing at a promoted or deleted memory file). It names that action's id; Stage 2 removes the pointer only if the referenced action landed (`[x]`), so a `promote`/`delete` that skips on drift never strands the source file with its index line already gone. Omit `depends_on` for a standalone delete-entry that removes content in its own right (nothing else removes a file the entry points at).

- [ ] `delete-entry-{nnn}`
  ```yaml
  type: delete-entry
  path: {absolute path}
  expect: |
    {verbatim block to remove, including heading, must match exactly}
  depends_on: {action id this removal is contingent on, e.g. promote-001 or delete-001; omit the key entirely if standalone}
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
  target_heading: {e.g. "## Bar", only if insert_after_heading}
  target_expect: |
    {verbatim snippet at insertion point, omit for create_new}
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
    {verbatim current block, must match byte-for-byte}
  after: |
    {verbatim replacement, typically a wikilink line}
  reason: {…}
  ```

## Out-of-scope findings

Real, durable problems Stage 1 surfaced that **none** of the four action types above can fix. Stage 2 **files** each as a `tech-debt` issue (`## Dispose out-of-scope findings (Stage 2)`); it never edits the working tree for one. Not actions, so no checkbox and no `## Ordering` entry. Write `None.` when there are none, so Stage 2 knows there is nothing to file.

One fenced YAML block per finding:

- `oos-{nnn}`
  ```yaml
  finding_class: {seeded code-audit-frontend finding_class, or holistic/unclassified when it maps to none (the usual case for a knowledge/doc finding)}
  path: {repo-relative POSIX path of the offending file}
  line: {integer line the finding anchors to}
  severity: {critical | important | suggestion, using the code-audit-frontend tier meaning; most knowledge-hygiene findings are suggestion, a genuine cross-page contradiction is important}
  failure_mode: {one line, concrete: what is wrong and the bad outcome}
  suggested_fix: {one line, e.g. "run /gaia-wiki consolidate" for wiki-internal redundancy or a page-vs-page conflict, "run /gaia-wiki lint" for a broken link, or a specific rewrite}
  handler: {prompt | plan, prompt when the fix is a single logical unit confined to one file with no cross-module ripple, else plan}
  difficulty: {easy | medium | hard, graded against the rubric in .claude/skills/file-tech-debt/SKILL.md, assigned at filing time, not by a later pass}
  security_sensitive: {true only if the finding's CONTENT reads as a security concern or is secret-shaped, else false; see the divergence note in "## Dispose out-of-scope findings"}
  ```

## Ordering

Stage 2 must apply actions in this order: `shrink` → `promote` → `delete` → `delete-entry`. Rationale: shrinks never reference content that later gets touched; promotes run before the deletes that remove their sources; and index-pointer removals (`delete-entry`) come last so a `delete-entry` carrying `depends_on` is gated on its referenced `promote`/`delete` having already landed. Removing a pointer only after its target is confirmed gone means a `promote`/`delete` that skips on drift never strands a source file with its index line already deleted (the orphaning hazard the old `delete-entry`-before-`promote` order carried).

Wiki-internal redundancy and broken-link repair are handled by `/gaia-wiki consolidate` and `/gaia-wiki lint` respectively, `merge` and `fix-link` action types are not part of this workflow. The audit does not fix them, but it no longer drops them: it records each in `## Out-of-scope findings` so Stage 2 files a `tech-debt` issue whose suggested fix names the right `/gaia-wiki` command.

## To re-apply

Apply runs immediately after this report (or at the decision gate). To re-apply later (e.g., after fixing drift): `/gaia-audit --apply` within 72h.

End the research run by printing: report path and total actions per category. (Stage 2 runs next automatically.)

## Classification-verification round (recommended)

An adversarial verification round that hardens Stage 1's classifications against ground truth in the MAIN CONVERSATION, between Stage 1 returning its draft report and the Apply / Discuss / Decline decision gate. Stage 1's DUPLICATE / STALE / CONFLICT / PROMOTE / shrink classifications are single-pass semantic judgments that nothing else verifies before they drive edits, and for memory entries those edits are IRREVERSIBLE (machine-local under `$HOME/.claude`, no git undo). The round verifies the checkable claim behind each action against the actual stores, wiki, and repo, then drops, corrects, or re-spawns to harden the report before any human approval or any apply path consumes it.

It runs only when Stage 1 reported ≥1 action; a 0-action report has nothing to verify and skips both the round and the decision gate (the existing 0-action auto-apply path is unchanged). The round dispatches the skill's own parallel `general-purpose` Agent fan-out (the same primitive Stage 1 and Stage 2 use), so it is available in every context including headless and `--apply` runs.

**Deliberate divergences from the canonical adversarial pattern (`.claude/skills/gaia/references/spec.md` step 7, `plan.md` step 4.6). Do not "fix" these back to the spec shape:**

- **Asymmetric disposition, biased toward DROPPING flagged deletes.** Wrongly keeping an entry is trivial clutter; wrongly executing a memory delete is permanent. So when a lens flags a `delete` / `shrink` as mis-classified, the safe disposition is to DROP or correct that action, not to keep it. There is deliberately NO spec-style refuter that defaults to "refuted" and pushes surviving findings back toward executing the action: the spec round refutes findings to keep the SPEC as-authored, here the conservative default is the opposite.
- **Refutation is CF-only and deep-tier.** Only judgment-heavy CONFLICT (CF) findings get a second-adjudication pass. CL and ES findings are checkable and binary (the cited fact resolves or it does not; the load-bearing content survives or it does not), so they route to disposition directly with no refuter, like the plan audit.
- **Skip is a legitimate recommendation, and the round is a choice at all.** The canonical spec/plan rounds run automatically with no prompt and no Skip option; this round keeps an interactive gate whose recommendation is dynamic (Run vs. Skip-eligible per the gate section below).

**The round is a choice, presented once.** When the round is reached (≥1 action) in an interactive context, gauge the report, then ask via `AskUserQuestion` exactly once whether to run it. The recommendation is dynamic:

- **Recommend Run** when the report contains any memory `delete` / `delete-entry`, or any CONFLICT-driven `replace` — those actions are irreversible or carry contradiction risk.
- **Skip is eligible** (a legitimate recommendation) when the actions are only git-reversible `shrink` / `replace` on in-repo (non-memory) files; the decision gate plus git undo already cover that case.

Present the recommended option FIRST, carrying the `(Recommended)` tag:

- question: `"Run the classification-verification round before the decision gate? It verifies Stage 1's classifications against ground truth and drops or corrects any action that would drive a wrong or destructive edit."`
- header: `"Verify"`
- options (recommended first):
  - `{ label: "Run the round (Recommended)", description: "Three parallel lenses verify the classifications against ground truth; a mis-classified delete is dropped, others corrected. A few agents, a couple of minutes." }`
  - `{ label: "Skip the round", description: "Proceed straight to the decision gate with the report as Stage 1 wrote it. Best when the actions are only git-reversible shrinks on in-repo files." }`

On **Skip**, do not stamp `audit_hardened`; proceed to the decision gate. On **Run**, execute the sub-steps below, stamp `audit_hardened: true`, then proceed to the decision gate.

**Non-interactive paths run the round WITHOUT prompting** at the recommended setting: `--apply` against an unhardened report, headless runs, and any context with no user to prompt. They never present the gate; they run the round, stamp, and continue.

**Fallback (never block).** If the parallel `general-purpose` Agent fan-out is unavailable (a restricted context that cannot spawn subagents), do NOT block: note the skip (`classification-verification unavailable, relying on the decision gate`), do NOT stamp `audit_hardened`, and proceed straight to the decision gate. The human Apply / Discuss / Decline gate is the safety net.

### Dispatch the three lenses (parallel fan-out)

Announce once, naming each lens in full with its id code in parentheses (e.g. `classification grounding (CL)`), never the bare code:

> Dispatching the three lenses in parallel against ground truth: classification grounding (CL), conflict adjudication (CF), edit safety / blast-radius (ES).

Dispatch **one `general-purpose` Agent per lens, all in parallel** (one message, one Agent tool call per lens), each handed the shared preamble plus its lens line. Each agent reads the Stage 1 report at `<REPORT_PATH>` (resolved under `.gaia/local/audit/`), the cited stores, the wiki, and `node_modules` if relevant, and returns only the findings JSON below, no narrative.

Shared preamble (interpolate `<REPORT_PATH>` = the Stage 1 report path the main conversation just received, `<repo_root>` = `$PWD`, `<MEMORY_DIR>` = the resolved memory dir from the report frontmatter):

> You are an ADVERSARIAL verifier of a GAIA knowledge-audit report at `<REPORT_PATH>`. Repo root is `<repo_root>`; you may read any file under it. Read the report's actions first. Your job is to find MIS-CLASSIFICATIONS that would drive a wrong or destructive edit, not to praise the report.
>
> - Verify every checkable claim against ground truth; when an action cites a wiki page or a fact, open it and confirm.
> - Cite evidence as `file:line`.
> - Severity: `blocker` = the action will execute a wrong or destructive edit (e.g. a memory delete whose cited fact does not resolve in the wiki); `high` = the classification is likely wrong and the action needs dropping or correcting before apply; `medium` = should fix; `low` = nit.
> - Give each finding a stable id prefixed with your lens code.
> - Be concrete and falsifiable. A finding a verifier can confirm by reading one file is a good finding; vague "could be clearer" is not.
> - Bias note: a wrongly-dropped delete is harmless (the entry stays); a wrongly-executed delete on a memory entry is PERMANENT (machine-local, no git undo), so when you cannot confirm a delete's basis from ground truth, flag it for dropping.

The three lenses (build each agent's prompt from the shared preamble plus its `LENS:` line):

- **CL, classification grounding (id prefix `CL`).** For each DUPLICATE-driven or STALE-driven `delete` / `shrink`, open the cited wiki `page:line` and confirm the fact TRULY lives there with the same nuance, not a superficially-similar sentence that drops a caveat the memory entry carries. For each STALE action, re-grep the repo with DIFFERENT search terms than Stage 1 used, to catch rename-not-removal (the file or feature still exists under a new name, so the entry is current, not stale). A delete whose cited fact does not resolve, or whose STALE basis is actually a rename, is a finding.
- **CF, conflict adjudication (id prefix `CF`).** For each CONFLICT-driven action, INDEPENDENTLY re-pick the authoritative source and confirm a GENUINE contradiction exists, rather than: (a) sanctioned path-scoped-rule duplication (a live `paths:`-scoped `.claude/rules/*.md` rule, including a `gaia-harden:` provenance-marked rule, is allowed to duplicate wiki content and is never a CONFLICT); (b) a maintainer-only block; or (c) an out-of-scope wiki-page-vs-wiki-page case (those route to `/gaia-wiki consolidate`, not here). A CONFLICT that is actually one of these, or that picks the wrong authoritative source, is a finding.
- **ES, edit safety / blast-radius (id prefix `ES`).** For each `promote` and `shrink` / `replace`, confirm the action PRESERVES all load-bearing content (a shrink-to-wikilink does not drop a nuance the inline text carried that the target page lacks; a promote carries the full content, not a truncation). For each memory `delete` / `delete-entry`, confirm the action's `reason` cites a canonical location that actually RESOLVES, the guardrail "never delete a memory entry unless the reason cites a canonical wiki location" is only as good as the citation resolving. A promote/shrink that loses content, or a delete whose reason citation does not resolve, is a finding.

Findings schema (each agent returns exactly this object; `location` is the offending action id, e.g. `delete-003`, or the classification; `evidence` is the wiki `page:line` or memory `file` actually opened):

    {
      "dimension": "<lens name>",
      "findings": [
        {
          "id": "<lens-prefix>-NNN",
          "severity": "blocker" | "high" | "medium" | "low",
          "title": "<short>",
          "location": "<action id or classification>",
          "issue": "<one sentence: what is wrong>",
          "evidence": "<file:line or quote actually checked>",
          "recommendation": "<one sentence: the fix>"
        }
      ]
    }

### CF-only refutation / second adjudication (deep-tier)

Collect the CF findings ONLY. CL and ES findings are checkable and binary, so they route to disposition directly with no refuter. For each CF finding, dispatch ONE additional `general-purpose` Agent that independently re-adjudicates the conflict: re-pick the authoritative source from ground truth and decide whether a genuine contradiction exists.

This is NOT the spec round's "default to refuted" refuter; it is a second opinion whose DISPOSITION is conservative in the safe direction:

- A CONFLICT-driven `replace` / `delete` action **survives** only if the CF lens AND its re-adjudicator agree the conflict is genuine AND agree on the same authoritative source.
- On any disagreement (the re-adjudicator finds the conflict spurious, or picks a different authoritative source), **drop or downgrade** the action: do not execute a `replace` / `delete` that could clobber a legitimately-distinct local statement when two adjudicators cannot agree it is wrong.

This default (disagreement → drop the action) is the deliberate INVERSION of spec.md 7b's "disagreement → keep the finding refuted → SPEC unchanged", driven by the irreversibility asymmetry: there, keeping the SPEC as-authored is safe; here, the safe direction is to not execute the destructive edit.

### Disposition routing and the stamp (mirror plan.md 4.6b)

Route each surviving finding by scope:

- **Localized finding** (one mis-classified action): drop or correct that action block directly in the report file. The main conversation edits the report; it lives under `.gaia/local/audit/`, which the main conversation may write. "Drop" removes the action block; "correct" fixes the cited target or `reason` when the lens supplies a correct one. Because the disposition is asymmetric, a `delete` / `shrink` a lens cannot confirm is DROPPED, not kept (the spec round keeps unrefuted findings to preserve the artifact; here the conservative default is to not execute the unconfirmed destructive edit).
- **Structural finding** (a whole Stage-1 lens is miscalibrated, e.g. every STALE classification used the same flawed grep and they are all rename-not-removal): re-spawn the Stage 1 (Research) subagent (mirror plan.md 4.6b's re-spawn-the-planner) with the surviving findings appended as a correction directive. The re-spawn reuses the existing Stage 1 subagent definition, goes through the same report path, and overwrites the flawed report. Bound this to ONE re-spawn: after re-spawning, re-run the round once against the regenerated report, then proceed (do not loop indefinitely).

**The stamp.** After the round completes (findings dispositioned, report edited), stamp the report frontmatter `audit_hardened: true`. This is the idempotency and inheritance signal:

- The decision gate reads the now-hardened report.
- The `--apply` re-run path checks the stamp: `audit_hardened: true` present → `--apply` trusts the hardened report and does NOT re-run the round; absent (an un-hardened draft, e.g. one created before this round existed or where it was skipped or unavailable) → `--apply` runs the round itself non-interactively at the recommended setting before applying.

## Step 5, Apply procedure (Stage 2, Sonnet)

You are executing, not reasoning. Follow this loop exactly.

### Pre-flight

1. Find the most recent non-`applied` report under `$PROJECT_ROOT/.gaia/local/audit/`: the newest `KNOWLEDGE-*.md` whose frontmatter `status:` is `draft` or `applied-partial` (an `applied` report has already been executed and must not be re-applied; skip it). If none, stop and print `no fresh report, run /gaia-audit first`. Otherwise check its mtime:
   - mtime ≤ 24h → proceed normally.
   - 24h < mtime ≤ 72h → print `WARNING: draft is {age}h old; drift checks will catch any staleness` and continue.
   - mtime > 72h → stop and print `draft too old (>72h), re-run /gaia-audit`.
2. Parse the report's frontmatter. Verify `project_root`, `memory_dir`, and `agent_memory_dir` match the values you resolved at startup. If any differ, stop and print a clear error, the report was generated on a different machine or in a different clone.
3. Run `git rev-parse HEAD`, if it differs from `git_head` in the report, print a warning but continue. Run `git status --short`, any file that is currently dirty AND appears as a target in the report is marked `SKIP (dirty)` before any action runs.
4. Read the `## Ordering` section. Process actions in that order.

### Per-action loop

For each unchecked action block:

1. Dependency gate (`delete-entry` carrying `depends_on` only; every other action skips this step): look up the `depends_on` action id's checkbox in the report. If it is anything other than `[x]` (skipped `[~]`, failed `[!]`, still unchecked `[ ]`, or the id is not found), mark this delete-entry `[~]` skipped, record reason `paired action {id} not applied`, and move on WITHOUT removing anything. The `## Ordering` guarantees the referenced `promote`/`delete` is already processed by the time this runs, so its checkbox is authoritative.
2. Verify drift signal:
   - If the action specifies `expect_sha256`: compute sha256 of the target file. If mismatch → mark `[~]` skipped, record reason `sha drift`, move on.
   - If the action specifies `before:` or `expect:` snippet: read the file and confirm the snippet appears verbatim. If missing → `[~]` skipped, `snippet drift`.
3. Apply the change using the exact operation:
   - `type: delete` → remove the file
   - `type: delete-entry` → read file, locate the `expect` block, remove it, write back
   - `type: promote` → perform the `target_action` (use Edit or Write as appropriate), then prepend `log_entry` to `wiki/log.md`, then append `index_entry` to the right section of `wiki/index.md`, then delete `source_path` if `delete_source_after: true`
   - `type: replace` → Edit with `old_string: before`, `new_string: after`. If `before` is not unique, prepend additional context from the file until unique.
4. Flip the checkbox: `[ ]` → `[x]` on success, `[~]` on skip, `[!]` on error. Record the reason inline on the checkbox line.

### Post-apply verification (mechanical, no judgment)

Before printing the summary, verify each flipped action actually landed. This is mechanical, no judgment, no re-deciding whether an action was correct:

1. **Every `promote` flipped `[x]`:**
   - If the action's `target_action: create_new`: confirm `target_page` exists and is non-empty (the `body` *is* the new page).
   - Otherwise (`append_section` / `insert_after_heading`): confirm the inserted `body` snippet appears in `target_page`.
   - Then, if `delete_source_after: true`, confirm `source_path` is gone.
   - On **any** failure, downgrade the checkbox `[x]` → `[!]`, note `promote unverified` on the checkbox line, and the report's terminal `status` is `applied-partial`.
2. **Every `delete` / `delete-entry` flipped `[x]`:** confirm the path (delete) or the `expect` block (delete-entry) is gone. On failure, downgrade to `[!]`, note `delete unverified`, terminal `status` = `applied-partial`.
3. **If a `shrink`/`replace` ran on `wiki/hot.md` or root `CLAUDE.md`:** recompute `wc -w`; if still over budget, note `still over budget` (informational only, does NOT downgrade the checkbox or change status).

This verification is the single authority for the report's terminal `status`: after running it, `status` is `applied` only if every action is `[x]`, and `applied-partial` if any action ended `[~]` skipped or `[!]` failed (including a `promote`/`delete` downgraded to `[!]` here).

### Dispose out-of-scope findings (file, do not fix)

After applying the in-scope actions, file every finding in the report's `## Out-of-scope findings` section as a `tech-debt` issue. This is the audit's equivalent of the code-audit-frontend disposition contract: **you file, you never fix**, and never edit the working tree for one. If that report section reads `None.`, skip this step entirely.

Follow `.claude/agents/code-audit-frontend.md` section **C** (backend probe: definitive-absent → file nothing, note it, continue; transient → note and continue) for the backend probe. Follow the **file-tech-debt** skill (`.claude/skills/file-tech-debt/SKILL.md`) for building the dedup key, the dedup query, creating with `--body-file`, the idempotent labels, and the `file:line` + failure-mode + suggested-fix + `Handler:` body, and for touching the debt-count sentinel (`mkdir -p .gaia/local/debt && : > .gaia/local/debt/refresh-requested`). Reuse that procedure verbatim, do not re-derive it. **Skip E.7** (the disposition-ledger sidecar record, which stays in the agent), the audit writes no sidecar, see the third rule below.

Three audit-specific rules override the agent's defaults; do NOT "fix" them back to the agent's shape:

- **Screen on `security_sensitive`, never on the class.** A finding is security-class **only** when its block's `security_sensitive: true` (its content reads as a security concern or is secret-shaped), never merely because it carries `holistic/unclassified`, which is the expected class for an audit finding (knowledge/doc hygiene maps to no seeded class by construction). This is the agent's own rule rather than an audit-specific carve-out: `.claude/agents/code-audit-frontend.md` section B screens on content and severity and excludes the fallback class as a trigger, precisely because a class-keyed screen would divert every finding and file nothing on a public repo. Screen on the flag, then apply the agent's **section D** visibility gate (PUBLIC/INTERNAL → divert, never a public issue; confirmed PRIVATE → file through E).
- **Build the dedup key from the block's own fields:** `<!-- gaia-debt-key: v1 class=<finding_class> path=<path> line=<line> -->` from the block's `finding_class` (or `holistic/unclassified`), `path`, and `line`. Dedup per the file-tech-debt skill's dedup procedure (open + declined-closed + keyless `path:line` fallback) so a repeated audit never re-files a standing wiki-internal problem. Map `severity` → the `severity:<tier>` label, map `difficulty` → the `difficulty:<grade>` label, and carry the block's `handler` as the `Handler:` line.
- **Do NOT write a `<HEAD>.dispositions.json` sidecar.** That sidecar gates the code-audit-frontend marker; the audit's own PR clears the merge gate through the out-of-scope bypass whenever the oracle finds nothing owed for its diff (see `## Publish`). Writing one would make `audit-disposition-check.sh` gate the audit's own merge on a filing it never needed. File the issues; write no sidecar.

Record the filed / diverted / deduped counts for the final summary. A backend-absent or transient `gh` failure is never fatal: file what you can, note the rest, and let the main conversation publish regardless.

### Post-flight

Set the report frontmatter `status:` to the terminal value the verification step above decided: `applied` if every action is `[x]`, otherwise `applied-partial`. `applied-partial` is kept so `--apply` can retry the remainder. That verification checklist is the authority for this value, do not re-derive it here.

Then bust the statusline cache so the audit nudge clears and a fresh check is triggered on the next render (mirrors the `/update-deps` post-run cache-bust). This runs on every Stage 2 completion: the gated Apply path, the `--apply` path, and the 0-action auto-apply path.

```bash
CACHE="$PROJECT_ROOT/.gaia/local/cache/shared/update-check.json"
if [ -f "$CACHE" ]; then
  if command -v jq >/dev/null 2>&1; then
    tmp="$(mktemp)"
    jq '.auditNudge = false | .auditNudgeReason = "" | .checkedAt = 0' "$CACHE" > "$tmp" && mv "$tmp" "$CACHE"
  else
    rm -f "$CACHE"
  fi
fi
```

`auditNudge = false` / `auditNudgeReason = ""` clear the displayed nudge immediately; `checkedAt = 0` forces `check-updates.sh` past its TTL gate on the next statusline render (which fires it in the background), recomputing every signal (including any over-budget condition a partial apply left unresolved) from the source of truth. All other cached fields (`outdatedCount`, `gaia*`) are preserved, so no other indicator flickers. If the cache file is absent, skip.

Then print a final summary to stdout:

```

applied: {n} shrink · {n} delete-entry · {n} promote · {n} delete | skipped: {n} | failed: {n}
out-of-scope: filed {n} · diverted {n} · deduped {n} (tech-debt issues)
diff footprint:
{git status --short}
handoff: changes are uncommitted; the main conversation runs Publish next (branch → commit → PR → merge on a main-branch run, commit → push on any other branch). An empty diff footprint means Publish no-ops.

```

## Guardrails

- Never delete a memory entry unless the action's `reason` cites a canonical wiki location. (Stage 1 must supply this; Stage 2 doesn't judge.)
- Never edit `wiki/log.md` anywhere except prepending a new line at the top.
- **Stage 2** never `git add` or `git commit`; it leaves the applied changes in the working tree and returns. The main conversation's Publish procedure commits after Stage 2 returns.
- Never improvise: if drift-check fails, skip and report. Do not search for the "right" target.
- Never merge two actions: each block is atomic.
- If an action targets a path that doesn't exist, mark `[!]` with `target missing` and continue.
- File out-of-scope findings, never fix them: no working-tree edit for an out-of-scope finding, and no `<HEAD>.dispositions.json` sidecar (the audit produces no marker).

## Publish (commit / PR / merge)

Runs in the **main conversation** after Stage 2 returns, on any finalizing path (gated Apply, 0-action auto-apply, `--apply`). It does for the audit's in-repo edits what `/update-deps` Phase 8 does for a dep bump and `/gaia-debt`'s "Drive the PR to merge" does for a fix. It never runs on Decline.

**If Stage 2's diff footprint is empty, skip this entire section.** A memory-only or 0-action run touched no in-repo file, memory edits live under `$HOME/.claude`, outside the repo, and are never committed. Tell the user the audit is finalized and stop. (Run ends here; see `## Cost record (run end)`.)

Otherwise the working tree carries the applied `wiki/` / `.claude/` / `CLAUDE.md` edits. Branch on where the run started, mirroring `/update-deps` Phase 8:

### On `main`/`master` and not in CI (interactive main-branch run)

1. **Cut a branch** (the uncommitted applied changes carry over):

   ```bash
   git checkout -b chore/knowledge-audit-$(date +%Y-%m-%d-%H-%M)
   ```

2. **Commit.** `.gaia/local/` is gitignored, so `git add -A` never sweeps in the report; memory edits are outside the repo. Route the message through a file, never `-m`, so package/keyword text can't trip a shell hook:

   ```bash
   git add -A
   git commit -F <commit-message-file>
   ```

   Subject: `chore(audit): <concise summary of what was pruned / shrunk / promoted>`. The diff is expected to touch only out-of-scope surfaces (`wiki/`, `.claude/`, root `CLAUDE.md`), in which case the PR clears the merge gate through the PR Merge Workflow's **out-of-scope bypass** with no `code-audit-frontend` marker. Do not assume it. Before `gh pr merge`, run

   ```bash
   bash .gaia/scripts/resolve-audit-spawn.sh
   ```

   Empty output confirms the bypass applies and no marker is owed (this also covers the rare case of an audit edit to a nested `CLAUDE.md` under an in-scope path such as `app/`, which would otherwise silently defeat the bypass). If it names any member, spawn each member it names and complete the marker handshake in `wiki/concepts/PR Merge Workflow.md` like any in-scope PR. Run the Quality Gate first **only** if the applied diff touched a gate-affecting file (`.ts|tsx|js|jsx|mjs|cjs|css` or gate config); a docs-only audit diff has nothing for it to check.
   <!-- gaia:maintainer-only:start -->

   Then clear the **CHANGELOG gate** per `wiki/concepts/PR Merge Workflow.md`: decide whether the change warrants a `## [Unreleased]` entry (pure pruning / consolidation is usually an internal, no-entry change; a rule or concept-page behavior change is worthy) and, if so, land it on the branch before merging (HEAD moves, so any bypass/marker must still cover the new HEAD). Scrubbed from adopter bundles.
   <!-- gaia:maintainer-only:end -->

3. **Open the PR and drive it to merge** through `wiki/concepts/PR Merge Workflow.md` (read it, don't merge from memory), exactly as `/gaia-debt`:

   ```bash
   git push -u origin <branch-name>
   gh pr create --title "<commit subject>" --body-file <report-summary-file>
   gh pr merge <N> --squash --delete-branch --auto
   ```

   `--auto` queues the merge behind required checks (the oracle check before `gh pr create` already confirmed whether a marker is owed). Verify the terminal state before any local cleanup:

   ```bash
   for i in 1 2 3 4 5; do
     state=$(gh pr view <N> --json state -q .state)
     [ "$state" = "MERGED" ] && break
     sleep 30
   done
   ```

   - **`MERGED`** → clean up locally, then print the merged PR URL:

     ```bash
     git checkout main && git pull origin main
     git branch -D <branch-name>
     git fetch --prune origin
     ```

     (Run ends here; see `## Cost record (run end)`.)

   - **still queued** → print the PR URL, note auto-merge is queued and lands when checks pass, and **do not** delete the local branch or switch off it. (Run ends here; see `## Cost record (run end)`.)

### On any other branch, or in CI (no new branch)

```bash
git add -A
git commit -F <commit-message-file>
git push
```

Do not open a PR and do not merge; the branch owner (the user, or the CI workflow) drives it from here. (Run ends here; see `## Cost record (run end)`.)

If any `git push`, `gh pr create`, or `gh pr merge` above exits non-zero, print the command's error and STOP. Do not retry, force-push, or amend, a rejected push or blocked merge is the user's call to resolve. (Run ends here; see `## Cost record (run end)`, passing `--github-*` only if `gh pr create` already succeeded before the failure.)

## Cost record (run end)

Every path that ends a `/gaia-audit` run appends exactly one cost record, the run-ending paths above:

- Stage 1 failure (no report path).
- The decision gate's Decline.
- Publish's empty-diff-footprint no-op.
- Publish's merge outcomes on a main-branch run, `MERGED` or still-queued.
- Publish's no-PR path on any other branch or in CI.
- Publish's non-zero-exit STOP on `git push` / `gh pr create` / `gh pr merge`.

Standalone final step, one call:

```bash
bash .gaia/scripts/token-tally.sh --action command --command gaia-audit
```

**Artifact pass-through.** When this run opened a pull request and the URL `gh pr create` printed appeared in this run's own Bash tool result, append:

```bash
  --github-type pr --github-number <N> --github-repo '<owner>/<name>'
```

Never look the number up (`gh pr list`, `gh pr view`), never reuse a number from an earlier run, a different branch, or a `gh` command run outside this workflow, and never guess. If this run did not itself print a creation URL, pass no `--github-*` flags at all; the record correctly carries no artifact, and that is not an error.

**Report the line verbatim.** The tally prints exactly one line on stdout, e.g. `Cost: ~5.2M tokens, $4.12, 6m39s`. Relay it as the last line of the run's report; do not reassemble, reformat, or re-derive it.

The tally never blocks, never fails, and never turns a failed run into a successful one: it runs as a bare call with no exit-status ceremony around it. On a path that ends in an error (a rejected push, a blocked merge), record the cost, then report the failure exactly as before; recording the cost never implies success.
