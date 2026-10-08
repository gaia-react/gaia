---
description: Promote a consolidated SPEC or plan summary into the GAIA wiki, pre-merge, as a wiki-only commit on the open PR's branch.
---

# Wiki Promote

The orchestrator runs this step after consolidation, once the audit has cleared and the human confirmed ready to merge, on the open PR's branch. It takes a `SPEC-NNN` id for the spec arm (`.gaia/local/specs/SPEC-NNN/SUMMARY.md`) or a `PLAN-NNN` id for the plan arm (`.gaia/local/plans/PLAN-NNN/SUMMARY.md`), both resolved through the main checkout. It reads the consolidated `SUMMARY.md`, writes pages into `wiki/` in the working tree, and returns the page list and one Choice token for the orchestrator to record and commit.

Contents: Step 1 - Resolve the source; Step 2 - Read promotion gate; Step 3 - Resolve the open PR; Step 4 - Route to wiki destinations; Step 5 - Render and write pages; Step 5b - Page body rendering; Step 6 - Return the page list; Step 7 - Report.

## Step 1 - Resolve the source

The orchestrator passes the `SPEC-NNN` or `PLAN-NNN` id as the invocation argument. Resolve the source path by id shape, anchored at the main checkout (`main_root="$(bash .gaia/scripts/main-root-lib.sh)"`), because the gitignored `.gaia/local/` tree lives there and not in an isolation worktree:

- `SPEC-NNN` → `$main_root/.gaia/local/specs/SPEC-NNN/SUMMARY.md`
- `PLAN-NNN` → `$main_root/.gaia/local/plans/PLAN-NNN/SUMMARY.md`

Read the consolidated `SUMMARY.md` frontmatter. Required fields: `wiki_promote_default`, `wiki_promote_targets` (may be an empty list).

**Legacy fallback (pre-consolidation SPECs):** if `SUMMARY.md` is absent but a legacy `SPEC.md` still exists in the same folder, fall back to reading `SPEC.md`'s frontmatter and body instead; downstream steps (title, body, routing) source from whichever file resolved here.

If neither `SUMMARY.md` nor a legacy `SPEC.md` exists, return Choice `no`, `Pages: none`, `Reason: no consolidated SUMMARY.md or SPEC artifact found; nothing to promote`.

## Step 2 - Read promotion gate

This step is the one place that states the promotion gate semantics. The orchestrator's wiki-promotion block and `lifecycle.md` point here and do not restate them.

First normalize `wiki_promote_default`: a legacy `true` is `yes` and a legacy `false` is `no` (an old-template consolidation may have copied a boolean, and `summary-verify.sh` accepts both as aliases). Then branch, returning exactly one Choice token per branch, with the `Reason:` line the orchestrator records:

| `wiki_promote_default` | Condition | Choice | Pages | `Reason:` |
|---|---|---|---|---|
| `yes` | `wiki_promote_targets` non-empty | continue to Step 3; ends `promoted` | the pages written | omitted |
| `yes` | `wiki_promote_targets` empty or absent | `no` | `none` | `yes with no wiki_promote_targets; nothing to promote` |
| `ask` | human present | ask once with `AskUserQuestion` (`Promote <id> to the wiki?`, options `Promote` / `Skip`); `Promote` continues to Step 3 and ends `promoted`; `Skip` returns `declined` | none on `declined` | `declined`: the human chose to skip |
| `ask` | no human present (unattended or auto) | `skipped-unattended`, without asking | `none` | `ask with no human present` |
| `no` | any | `no` | `none` | `wiki_promote_default is no` |
| any other value | any | `no` | `none` | names the value: `unrecognized wiki_promote_default '<value>'` |

An empty or absent `wiki_promote_targets` with `yes` is a recorded no-op and never falls back to a default target. Consolidation always stamps a non-empty list, so this arises only for a legacy SUMMARY. `skipped-verify-failed` is a consolidation outcome (the verify failed before promotion ran); this step never returns it.

## Step 3 - Resolve the open PR

Promotion runs pre-merge, so the implementing PR is open. Take its number and URL from the current branch:

```bash
gh pr view --json number,url
```

Capture `pr_number` and `pr_url` for downstream steps. If `gh` is unavailable, unauthenticated or finds no PR for the branch, return Choice `no`, `Pages: none`, `Reason: no open pull request found for this branch; nothing promoted`; the orchestrator does not guess a PR.

## Step 4 - Route to wiki destinations

Read `wiki_promote_targets` from the resolved source's frontmatter (`SUMMARY.md`, or the legacy `SPEC.md` under the Step 1 fallback). Step 2 guarantees it is non-empty here.

Allowed subdomain values:

```
{decisions, concepts, modules, flows, components, dependencies}
```

Validate the list:

- Any value not in the allowed set → emit warning `wiki-promote: unrecognized target '<value>' in wiki_promote_targets; skipped.` and drop that value.
- All values invalid after filtering → write nothing and return Choice `no`, `Pages: none`, `Reason: no valid wiki_promote_targets after filtering`.

Compute `<slug>` once for this run:

1. Read the resolved source's H1 heading (the first `# ` line in the body).
2. Lowercase it, strip non-ASCII, replace any run of non-alphanumeric characters with a single hyphen, trim leading/trailing hyphens.
3. If no H1 is found or the slug ends up empty, fall back to the id itself (e.g. `SPEC-NNN` or `PLAN-NNN`).


For each valid target subdomain:

1. Compute target path: `wiki/<subdomain>/<slug>.md`.
2. Check if the file already exists on disk (`test -f wiki/<subdomain>/<slug>.md`).
3. If it exists, read its frontmatter and check whether `promoted_from` equals the current id.
4. Build the routing plan tuple:

   ```yaml
   - subdomain: <decisions|concepts|modules|flows|components|dependencies>
     slug: <slug>
     target_path: wiki/<subdomain>/<slug>.md
     exists_already: <bool>
     promoted_from_match: <bool>
   ```


The routing plan is the input to Step 5 (page rendering). The `wiki/index.md` update runs in Step 5 (one batch per subdomain).

## Step 5 - Render and write pages

For each tuple in the routing plan from Step 4, classify the page status, render markdown, and write to disk. Track three lists for the Step 7 report:

- `pages_written`: newly created files.
- `pages_updated`: existing promoted pages re-rendered in place.
- `pages_skipped`: entries that hit a hand-edit collision, a foreign-collision, or any other guard.

### Page status classification

For each tuple:

1. **New page** (`exists_already: false`) → status `new`.
2. **Existing page, our promotion** (`exists_already: true` AND `promoted_from_match: true`) → run hand-edit detection with a content hash, which survives a squash merge (a commit subject does not):
   1. Read the page's frontmatter `promoted_hash` (`sha256:<hex>`, written at render time).
   2. Hash the page's current body, everything below the closing `---` of the frontmatter, and compare.
   3. Hashes equal → status `our-update`. Hashes differ → status `hand-edited`.
   4. No `promoted_hash` field (the page was promoted before the field existed) → status `hand-edited`. This fails safe: a page whose provenance cannot be proven is never overwritten.
3. **Existing page, NOT our promotion** (`exists_already: true` AND `promoted_from_match: false`) → status `foreign-collision`.

### Action per status

| Status              | Action |
| ------------------- | ------ |
| `new`               | Render frontmatter + body (per Step 5b). Write file. Append to `pages_written`. |
| `our-update`        | Read existing frontmatter, preserve `created`. Render fresh frontmatter (advancing `updated`, `promoted_at` and `promoted_hash`) + body. Write file. Append to `pages_updated`. |
| `hand-edited`       | Do NOT write. Emit warning to stdout: `wiki-promote: skipped wiki/<subdomain>/<slug>.md (hand-edited since last promotion).`. Append a log line `WARN: skipped wiki/<subdomain>/<slug>.md (hand-edited since last promotion)`. Append the path to `pages_skipped`. |
| `foreign-collision` | Do NOT write. Emit warning to stdout: `wiki-promote: target wiki/<subdomain>/<slug>.md exists with no promoted_from match; skipped to avoid clobbering hand-authored content.`. Append a log line `WARN: skipped wiki/<subdomain>/<slug>.md (foreign-collision; no promoted_from match)`. Append the path to `pages_skipped`. |

### Frontmatter rendering

Emit YAML frontmatter at the top of the file matching the contract. Map `subdomain` to `type`:

| subdomain      | type         |
| -------------- | ------------ |
| `decisions`    | `decision`   |
| `concepts`     | `concept`    |
| `modules`      | `module`     |
| `flows`        | `flow`       |
| `components`   | `component`  |
| `dependencies` | `dependency` |


Fields:

- `type`: from the table above.
- `status`: `active` (always).
- `created`: for `new`, today's ISO date (`YYYY-MM-DD`). For `our-update`, preserve the value from the existing file's frontmatter.
- `updated`: today's ISO date.
- `promoted_from`: the folder id (`SPEC-NNN` for the spec arm, `PLAN-NNN` for the plan arm).
- `promoted_at`: current ISO 8601 UTC timestamp.
- `promoted_hash`: `sha256:<hex of the body below the frontmatter>`, computed over the final rendered body (Step 5b) after it is complete. Render the body first, hash it, then write the frontmatter.
- `pr_number`: from Step 3.
- `pr_url`: from Step 3.
- `tags`: copied from the resolved source's frontmatter `tags` if present and non-empty; otherwise `[promoted, <subdomain>]`.

### `wiki/log.md` append

After all pages have been processed (and at least one was written or updated), prepend a new entry to `wiki/log.md` under the `## [Unreleased]` section (newest entries on top, match the existing convention).

Line format:

```
- <YYYY-MM-DD> PROMOTED: <id> → <comma-separated paths>
```

- `<YYYY-MM-DD>`: today.
- `<comma-separated paths>`: union of `pages_written` and `pages_updated`, in the order they were processed. If the union is empty (everything skipped), do NOT append a `PROMOTED:` line, instead append `WARN: <id> promotion produced no writes; see warnings above.`.

If `wiki/log.md` does not contain a `## [Unreleased]` section, prepend the section header above the existing first `## ` heading. (Defensive, the file should already have one per the existing wiki convention.)

## Step 5b - Page body rendering

Render the body in the following sections, in order, immediately after the closing `---` of the frontmatter. No template engine, emit markdown directly.

1. **Title**, H1 line copied verbatim from the resolved source's H1 (the `SUMMARY.md` H1, or the legacy `SPEC.md`'s H1 under the Step 1 fallback).
2. **Lede**, first paragraph of the source body immediately after the H1. **Legacy `SPEC.md` fallback only:** first paragraph of the SPEC's `## One-line summary` section if present; else the first paragraph of its `## Intent` section; if neither exists, fall back to a single-line lede `Promoted from <id>.`.
3. **Decisions / behaviors**, under an H2 `## Decisions` (for `type: decision`) or `## Behavior` (for all other types). For the consolidated `SUMMARY.md` source, render the body prose as-is, it is already present-tense final-state prose written by the consolidation producer, no voice adaptation needed. **Legacy `SPEC.md` fallback only:** include the SPEC's `## Intent` body and, if present, any H2 in the SPEC body whose heading begins with `## Composition with ` (the section that explains how the SPEC composes with prior architecture); adapt voice from future-tense ("will promote") to present-tense ("promotes") where the change is mechanical, leave wording alone where rewriting risks meaning drift.
4. **Divergence**, if the resolved source has a `## Divergence` section (consolidated `SUMMARY.md` only, an optional section the consolidation producer writes when shipped scope is materially narrower than the stated intent), render it verbatim under its own `## Divergence` heading. Omit entirely when absent.
5. **UAT references**, under an H2 `## UAT references`, render a bullet list. **Legacy `SPEC.md` fallback only** (the consolidated `SUMMARY.md` frontmatter carries no `uats:` list, so this section is omitted entirely on that path): for each entry in the SPEC's frontmatter `uats:` list, emit `- **<UAT-ID>**, <one-line summary>`. Source the one-line summary from the UAT entry's `summary` field if present; otherwise the first sentence of its `intent` field. If `uats:` is empty or absent, omit the entire `## UAT references` section.
6. **Related**, sibling wikilinks. Determine the set of sibling pages produced by the **current run**: every entry in the union of `pages_written` and `pages_updated` whose `target_path` is not the page being rendered. (Skipped pages, `hand-edited`, `foreign-collision`, are excluded; their files were not written and a wikilink would dangle.)
   - **Solo-page promotion** (no siblings): omit the entire `## Related` section. Do not emit the H2 at all.
   - **Has siblings**: emit:

     ```markdown
     ## Related

     Promoted from the same source:

     - [[<sibling-page-title>]]
     - [[<sibling-page-title>]]
     ```

     `<sibling-page-title>` is the H1 of the sibling page (same value used as the H1 in Step 5b §1, since all sibling pages share it). Sort sibling entries alphabetically by title. Use exact wikilink form `[[Title]]`, Obsidian resolves the link by page title across the vault, so no path is needed.

7. **References**, emit an H2 `## References` followed by a bullet list with the source backlink, the PR URL, and the promotion timestamp:

   ```markdown
   ## References

   - Source: [<id>](<relative-path>) (local artifact, gitignored, link does not resolve from GitHub web view; removed once the folder reaps, the PR link and `promoted_from` below are the durable provenance)
   - Implementing PR: [PR #NNN](<pr_url>)
   - Promoted at: <ISO 8601 UTC>
   ```

   Substitutions:
   - `<id>`, the `SPEC-NNN` or `PLAN-NNN` id from Step 1.
   - `<relative-path>`, the resolved source's repo-relative path with a `../../` prefix (promoted wiki pages live at `wiki/<subdomain>/<page>.md`, two segments deep from the repo root): `../../.gaia/local/specs/SPEC-NNN/SUMMARY.md`, `../../.gaia/local/plans/PLAN-NNN/SUMMARY.md`, or the legacy `../../.gaia/local/specs/SPEC-NNN/SPEC.md` under the Step 1 fallback.
   - `<owner>/<repo>`, resolved once per run by running, via the Bash tool:

     ```bash
     repo_slug=$(gh repo view --json owner,name -q '"\(.owner.login)/\(.name)"' 2>/dev/null)
     ```

     Fallback when `gh` is unavailable: parse `git remote get-url origin`. Handle both forms:
     - SSH: `git@github.com:<owner>/<repo>.git` → strip the `git@github.com:` prefix and the `.git` suffix.
     - HTTPS: `https://github.com/<owner>/<repo>.git` → strip the `https://github.com/` prefix and the `.git` suffix.

     If both methods fail (no `gh`, no `origin` remote), substitute the literal `<owner>/<repo>` placeholder and emit a warning `wiki-promote: could not resolve repo slug; PR URL placeholder left in references.`. Nothing downstream fixes the placeholder: Step 6 returns the warning with the page list so the orchestrator reports it to the human in its wiki-promotion record, and the human corrects the URL by hand.

   - `NNN` and `<pr_url>`, the open PR's `pr_number` and `pr_url` from Step 3.
   - `<ISO 8601 UTC>`, same value as `promoted_at` in the page frontmatter.

   The "(local artifact, gitignored, ...)" note appears on this first-occurrence line only. If the source backlink is referenced again later in the body, omit the parenthetical.

### `wiki/index.md` update

After all pages have been written and the body is rendered, update `wiki/index.md` to surface the new pages.

1. Read `wiki/index.md`. If missing, skip the index update entirely (emit warning `wiki-promote: wiki/index.md not found; skipped index update.`).
2. For each entry in `pages_written` (only, `pages_updated` already appear in the index from a prior run; do not re-add):
   1. Determine the section header by the page's subdomain:

      | subdomain      | section header                    |
      | -------------- | --------------------------------- |
      | `decisions`    | `## Decisions (ADRs)`             |
      | `concepts`     | `## Concepts`                     |
      | `modules`      | `## Modules (architecture)`       |
      | `flows`        | `## Flows`                        |
      | `components`   | `## Components (Form deep dives)` |
      | `dependencies` | `## Dependencies`                 |

   2. Compute the wikilink: `- [[<page-title>]]` where `<page-title>` is the H1 of the rendered page (same value used in `## Related`).
   3. Locate the section in the index. If the section header is absent, emit warning `wiki-promote: section '<header>' not found in wiki/index.md; skipped entry for <page-title>.` and continue with the next entry.
   4. Scan the section's existing bullets. If any bullet's wikilink target equals `<page-title>` (case-sensitive match on the text inside `[[…]]`, ignoring any `- description` suffix after the closing `]]`), skip, the entry already exists. (Idempotent: re-running the promotion does not duplicate.)
   5. Insert the new bullet in alphabetical order by `<page-title>` (case-insensitive comparison) within the section. The section ends at the next `## ` heading or end-of-file.

3. Write `wiki/index.md` back to disk.

If `--preview` mode (from Step 2) is active, render the proposed index diff to stdout and do NOT write.

The orchestrator stages the modified `wiki/index.md` together with the returned pages (Step 6); no separate staging is needed here.

Match the existing wiki voice: declarative, no preamble, concrete examples where useful. End the file with a single trailing newline.

## Step 6 - Return the page list

This command does NOT commit or push; the orchestrator does. Return a structured payload the orchestrator reads as conversation context:

```json
{
  "source": "wiki-promote",
  "id": "<SPEC-NNN or PLAN-NNN>",
  "choice": "promoted",
  "pr_number": <NNN>,
  "pr_url": "<full URL>",
  "pages_written": ["wiki/<subdomain>/<slug>.md", ...],
  "pages_updated": [...],
  "pages_skipped": [...],
  "log_line": "<YYYY-MM-DD> PROMOTED: <id> → <comma-separated paths>"
}
```

The orchestrator stages exactly the `pages_written` and `pages_updated` paths plus `wiki/index.md` and `wiki/log.md`, commits them with a `wiki:` Conventional Commits subject (`.gaia/conventional-commits.json` has a `wiki` type), and pushes. The commit must contain only `wiki/**` paths: `wiki/**` is outside every Code Audit Team member's scope, and that is what keeps the members' already-posted markers valid. A commit that touches any other path invalidates them.

When every page was skipped (the union of `pages_written` and `pages_updated` is empty), return Choice `no`, `Pages: none` and `Reason: every target page was skipped; see warnings`, and the orchestrator makes no commit.

## Step 7 - Report

Print a brief summary:

```
Wiki promote complete for <id>.

  PR:               <pr_url>
  Pages written:    <count> (<comma-separated paths>)
  Pages updated:    <count> (<comma-separated paths>)
  Pages skipped:    <count> (<comma-separated paths with reason>)
```

If any pages were skipped due to hand-edit detection, include a one-line note: `Skipped pages stay as they are; reconcile them manually in a follow-up.`
