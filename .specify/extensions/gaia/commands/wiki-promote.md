---
name: speckit-gaia-wiki-promote
description: Promote merged SPEC content into the GAIA wiki.
---

# Wiki Promote, `after_implement` hook

Fires automatically on `/speckit-implement` completion. Reads the SPEC artifact, detects whether the implementing PR has merged, and either promotes content into `gaia/wiki/` or persists a defer flag.

## Step 1 - Resolve the SPEC

The hook fires on `/speckit-implement` completion. The agent has the SPEC ID in conversation context (the implementer agent referenced it).

Identify the SPEC ID from the running conversation. If ambiguous, fall back to the most-recently-modified `.gaia/local/specs/SPEC-*/SPEC.md` (deriving the SPEC ID from the parent folder name; excluding `-revised-contracts` and `-refit-decision` suffixes).

Read the SPEC frontmatter. Required fields: `spec_id`, `wiki_promote_default`, `wiki_promote_targets` (default `[]`).

If the SPEC file is missing, exit with: `wiki-promote: SPEC artifact not found; nothing to promote.`

## Step 2 - Read promotion gate

Branch on `wiki_promote_default`:

- `no` → exit silently with: `wiki-promote: SPEC-NNN skipped per frontmatter (wiki_promote_default: no).`
- `ask` → surface `AskUserQuestion`:
  - Question: `Promote SPEC-NNN to wiki? (default yes)`
  - Options: `Yes, promote now` / `No, skip silently` / `Preview pages without writing`
  - On `Yes` → continue to Step 3.
  - On `No` → exit silently with the skip report.
  - On `Preview` → render the candidate pages (call Step 4 + Step 5 in dry-run mode), print to stdout, exit without writing. Mark this branch with `--preview` for downstream tasks.
- `yes` → continue to Step 3.
- Any other value → emit warning `wiki-promote: unrecognized wiki_promote_default '<value>'; treating as 'no'.` and exit silently.

## Step 3 - Detect merged PR

Determine the current branch using the Bash tool:

```bash
current_branch=$(git rev-parse --abbrev-ref HEAD)
```

Probe for a merged PR matching the branch using the Bash tool:

```bash
pr_json=$(gh pr list --head "$current_branch" --state merged --json number,mergedAt,url,body --limit 1 2>/dev/null || echo '[]')
```

If `$pr_json` is `[]` (no merged PR for this branch):

1. Write defer flag to `.gaia/local/cache/wiki-promote/SPEC-NNN.json`:

   ```json
   {
     "spec_id": "SPEC-NNN",
     "branch": "<current_branch>",
     "deferred_at": "<now ISO 8601 UTC>",
     "status": "awaiting-merge"
   }
   ```

   (Cache directory creation: `mkdir -p .gaia/local/cache/wiki-promote/`. The `.gaia/local/` line in `.gitignore` covers this path.)

2. Exit with: `wiki-promote: SPEC-NNN deferred, awaiting PR merge for branch <current_branch>. Drain via /gaia-spec close SPEC-NNN after merge.`

If `$pr_json` contains a merged PR:

1. Capture `pr_number`, `pr_url`, `pr_body`, `merged_at` for downstream steps.
2. Continue to Step 4 (routing, Phase 3).
3. If a defer flag exists at `.gaia/local/cache/wiki-promote/SPEC-NNN.json`, delete it (the wait is over).

If `gh` is not installed or not authenticated, treat as "no merged PR", write the defer flag with an additional field `gh_unavailable: true` and exit. This handles GAIA's framework-neutrality (offline, GitLab, Bitbucket users).

## Step 4 - Route to wiki destinations

Read `wiki_promote_targets` from the SPEC frontmatter.

If empty or absent: default to `[decisions]`.

Allowed subdomain values:

```
{decisions, concepts, modules, flows, components, dependencies}
```

Validate the list:

- Empty list `[]` (or field absent) → fall back to `[decisions]`.
- Any value not in the allowed set → emit warning `wiki-promote: unrecognized target '<value>' in wiki_promote_targets; skipped.` and drop that value.
- All values invalid after filtering → fall back to `[decisions]`.

Compute `<spec-slug>` once for this run:

1. Read the SPEC's H1 heading (the first `# ` line in the SPEC body).
2. Lowercase it, strip non-ASCII, replace any run of non-alphanumeric characters with a single hyphen, trim leading/trailing hyphens.
3. If no H1 is found or the slug ends up empty, fall back to the SPEC ID itself (e.g. `SPEC-004`).

For each valid target subdomain:

1. Compute target path: `wiki/<subdomain>/<spec-slug>.md`.
2. Check if the file already exists on disk (`test -f wiki/<subdomain>/<spec-slug>.md`).
3. If it exists, read its frontmatter and check whether `promoted_from` equals the current `SPEC-NNN`.
4. Build the routing plan tuple:

   ```yaml
   - subdomain: <decisions|concepts|modules|flows|components|dependencies>
     slug: <spec-slug>
     target_path: wiki/<subdomain>/<spec-slug>.md
     exists_already: <bool>
     promoted_from_match: <bool>
   ```

If no valid targets remain after validation (should not happen given the `[decisions]` fallback, but guard for it), emit warning and exit silently, do not write any pages. Append a log line `WARN: SPEC-NNN had no valid wiki_promote_targets; skipped.`.

The routing plan is the input to Step 5 (page rendering). The `wiki/index.md` and per-domain `_index.md` files are updated in Step 5 (one batch update per subdomain).

## Step 5 - Render and write pages

For each tuple in the routing plan from Step 4, classify the page status, render markdown, and write to disk. Track three lists for the Step 7 report:

- `pages_written`: newly created files.
- `pages_updated`: existing promoted pages re-rendered in place.
- `pages_skipped`: entries that hit a hand-edit collision, a foreign-collision, or any other guard.

### Page status classification

For each tuple:

1. **New page** (`exists_already: false`) → status `new`.
2. **Existing page, our promotion** (`exists_already: true` AND `promoted_from_match: true`) → run hand-edit detection:
   1. Read the current file's frontmatter to extract `promoted_at`.
   2. Run `git log --format='%H %s' -- wiki/<subdomain>/<spec-slug>.md` to list commits touching this file.
   3. For each commit whose author timestamp is later than `promoted_at`, inspect the commit subject. A commit is a "promotion commit" if its subject contains `wiki-promote` or `wiki-sync` (case-insensitive). Otherwise it is a hand-edit.
   4. If any hand-edit commit is found → status `hand-edited`.
   5. If no hand-edit commits are found → status `our-update`.
   6. If `git log` returns no commits at all (file is staged but never committed), treat as `our-update`, the existing file is from the current uncommitted run and a re-render is safe.
3. **Existing page, NOT our promotion** (`exists_already: true` AND `promoted_from_match: false`) → status `foreign-collision`.

### Action per status

| Status              | Action                                                                                                                                                                                                                                                                                                                                  |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `new`               | Render frontmatter + body (per Step 5b). Write file. Append to `pages_written`.                                                                                                                                                                                                                                                         |
| `our-update`        | Read existing frontmatter, preserve `created`. Render fresh frontmatter (advancing `updated` and `promoted_at` to today/now) + body. Write file. Append to `pages_updated`.                                                                                                                                                             |
| `hand-edited`       | Do NOT write. Emit warning to stdout: `wiki-promote: skipped wiki/<subdomain>/<spec-slug>.md (hand-edited since last promotion).`. Append a log line `WARN: skipped wiki/<subdomain>/<spec-slug>.md (hand-edited since last promotion)`. Append the path to `pages_skipped`.                                                            |
| `foreign-collision` | Do NOT write. Emit warning to stdout: `wiki-promote: target wiki/<subdomain>/<spec-slug>.md exists with no promoted_from match; skipped to avoid clobbering hand-authored content.`. Append a log line `WARN: skipped wiki/<subdomain>/<spec-slug>.md (foreign-collision; no promoted_from match)`. Append the path to `pages_skipped`. |

If `--preview` was set in Step 2, render but do NOT write. Print each rendered page (path + content) to stdout, classified by status. Skip the `wiki/log.md` append.

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
- `status`: `active` (always; `superseded` handling is out of scope for this task).
- `created`: for `new`, today's ISO date (`YYYY-MM-DD`). For `our-update`, preserve the value from the existing file's frontmatter.
- `updated`: today's ISO date.
- `promoted_from`: the SPEC ID (e.g. `SPEC-NNN`).
- `promoted_at`: current ISO 8601 UTC timestamp.
- `spec_artifact_path`: `.gaia/local/specs/SPEC-NNN/SPEC.md`.
- `pr_number`: from Step 3.
- `pr_url`: from Step 3.
- `tags`: copied from the SPEC's frontmatter `tags` if present and non-empty; otherwise `[promoted, <subdomain>]`.

### `wiki/log.md` append

After all pages have been processed (and at least one was written or updated), prepend a new entry to `wiki/log.md` under the `## [Unreleased]` section (newest entries on top, match the existing convention).

Line format:

```
- <YYYY-MM-DD> <pr_short_sha> - PROMOTED: SPEC-NNN → <comma-separated paths>
```

- `<YYYY-MM-DD>`: today.
- `<pr_short_sha>`: short SHA of the merge commit. Resolve via `gh pr view <pr_number> --json mergeCommit --jq '.mergeCommit.oid' | cut -c1-7`. If unavailable, fall back to `current` (a literal placeholder is acceptable for the deferred-then-drained path; the orchestrator covers this).
- `<comma-separated paths>`: union of `pages_written` and `pages_updated`, in the order they were processed. If the union is empty (everything skipped), do NOT append a `PROMOTED:` line, instead append `WARN: SPEC-NNN promotion produced no writes; see warnings above.`.

If `wiki/log.md` does not contain a `## [Unreleased]` section, prepend the section header above the existing first `## ` heading. (Defensive, the file should already have one per the existing wiki convention.)

## Step 5b - Page body rendering

Render the body in the following sections, in order, immediately after the closing `---` of the frontmatter. No template engine, emit markdown directly.

1. **Title**, H1 line copied verbatim from the SPEC's H1 (the first `# ` line in the SPEC body).
2. **Lede**, first paragraph of the SPEC's `## One-line summary` section if present; else the first paragraph of the SPEC's `## Intent` section. If neither exists, fall back to a single-line lede `Promoted from SPEC-NNN.`.
3. **Decisions / behaviors**, under an H2 `## Decisions` (for `type: decision`) or `## Behavior` (for all other types), include the SPEC's `## Intent` body and, if present, any H2 in the SPEC body whose heading begins with `## Composition with ` (the section that explains how the SPEC composes with prior architecture). Adapt voice from future-tense ("will promote") to present-tense ("promotes") where the change is mechanical; leave wording alone where rewriting risks meaning drift.
4. **UAT references**, under an H2 `## UAT references`, render a bullet list. For each entry in the SPEC's frontmatter `uats:` list, emit `- **<UAT-ID>**, <one-line summary>`. Source the one-line summary from the UAT entry's `summary` field if present; otherwise the first sentence of its `intent` field. If `uats:` is empty or absent, omit the entire `## UAT references` section.
5. **Related**, sibling wikilinks. Determine the set of sibling pages produced by the **current run**: every entry in the union of `pages_written` and `pages_updated` whose `target_path` is not the page being rendered. (Skipped pages, `hand-edited`, `foreign-collision`, are excluded; their files were not written and a wikilink would dangle.)
   - **Solo-page promotion** (no siblings): omit the entire `## Related` section. Do not emit the H2 at all.
   - **Has siblings**: emit:

     ```markdown
     ## Related

     Promoted from the same SPEC:

     - [[<sibling-page-title>]]
     - [[<sibling-page-title>]]
     ```

     `<sibling-page-title>` is the H1 of the sibling page (same value used as the H1 in Step 5b §1, the SPEC's H1 line, since all sibling pages share it). Sort sibling entries alphabetically by title. Use exact wikilink form `[[Title]]`, Obsidian resolves the link by page title across the vault, so no path is needed.

6. **References**, emit an H2 `## References` followed by a bullet list with the SPEC backlink, the PR URL, and the promotion timestamp:

   ```markdown
   ## References

   - Source SPEC: [SPEC-NNN](../../.gaia/local/specs/SPEC-NNN/SPEC.md) (local SPEC artifact, gitignored, link does not resolve from GitHub web view)
   - Implementing PR: [PR #NNN](https://github.com/<owner>/<repo>/pull/NNN)
   - Promoted at: <ISO 8601 UTC>
   ```

   Substitutions:
   - `SPEC-NNN`, the SPEC ID from Step 1.
   - The repo-relative path uses `../../` because promoted wiki pages live at `wiki/<subdomain>/<page>.md` (two segments deep from the repo root).
   - `<owner>/<repo>`, resolved once per run by running, via the Bash tool:

     ```bash
     repo_slug=$(gh repo view --json owner,name -q '"\(.owner.login)/\(.name)"' 2>/dev/null)
     ```

     Fallback when `gh` is unavailable: parse `git remote get-url origin`. Handle both forms:
     - SSH: `git@github.com:<owner>/<repo>.git` → strip the `git@github.com:` prefix and the `.git` suffix.
     - HTTPS: `https://github.com/<owner>/<repo>.git` → strip the `https://github.com/` prefix and the `.git` suffix.

     If both methods fail (no `gh`, no `origin` remote), substitute the literal `<owner>/<repo>` placeholder and emit a warning `wiki-promote: could not resolve repo slug; PR URL placeholder left in references.`. The wiki-sync handoff will surface this for manual fix.

   - `NNN`, `pr_number` from Step 3.
   - `<ISO 8601 UTC>`, same value as `promoted_at` in the page frontmatter.

   The "(local SPEC artifact, gitignored, link does not resolve from GitHub web view)" note appears on this first-occurrence line only. If the SPEC backlink is referenced again later in the body, omit the parenthetical.

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

The wiki-sync handoff (Step 6) will pick up the modified `wiki/index.md` along with the promoted pages, no separate staging is needed.

Match the existing wiki voice: declarative, no preamble, concrete examples where useful. End the file with a single trailing newline.

## Step 6 - Hand off to wiki-sync

The wiki-promote command does NOT commit or push. The existing `/gaia-wiki sync` skill handles branch-aware commits.

Emit a structured payload to stdout (the next agent reads it as conversation context):

```json
{
  "source": "wiki-promote",
  "spec_id": "SPEC-NNN",
  "pr_number": <NNN>,
  "pr_url": "<full URL>",
  "pages_written": ["wiki/<subdomain>/<slug>.md", ...],
  "pages_updated": [...],
  "pages_skipped": [...],
  "log_line": "<YYYY-MM-DD> <short_pr_sha> - PROMOTED: SPEC-NNN → <comma-separated paths>"
}
```

Then invoke `/gaia-wiki sync` by calling the Skill tool (skill `gaia-wiki`, args `sync`), do not merely print the line below; it states the intent, it is not the call:

> Invoking `/gaia-wiki sync` to handle the branch-aware commit step for these pages.

(`/gaia-wiki sync` will read the staged-but-uncommitted wiki changes from `git status`, write to `wiki/log.md` and `wiki/.state.json`, then commit per its branch-aware rules.)

If `/gaia-wiki sync` fails or refuses, exit with the warning `wiki-promote: pages staged but wiki-sync handoff failed. Run /gaia-wiki sync manually.` Do NOT attempt to commit from this command body.

## Step 7 - Report

Print a brief summary:

```
Wiki promote complete for SPEC-NNN.

  PR:               <pr_url>
  Pages written:    <count> (<comma-separated paths>)
  Pages updated:    <count> (<comma-separated paths>)
  Pages skipped:    <count> (<comma-separated paths with reason>)
  Wiki-sync:        invoked
```

If any pages were skipped due to hand-edit detection, include a one-line note:

`Hand-edited skips can be resolved by re-running /gaia-spec close SPEC-NNN --force (TBD; for now resolve manually).`

## Step 8 - Chain to spec-close (immediate-merge path only)

This step fires only when Step 3 found a merged PR and Steps 4–7 ran full. On the deferred path, Step 3 exits before reaching here. On the silent-skip path (`wiki_promote_default: no`) and the preview path (`--preview`), Step 2 exits before reaching here. So an unconditional invoke at this step is safe, the only way to land here is the immediate-merge full-run.

**Suppression guard.** If wiki-promote was re-fired from `/speckit-gaia-spec-close` Step 2's drain (deferred path), spec-close passes the literal flag `drained: true` in the invocation that triggered this run. Skip this step **only when** the invoking message contains the exact string `drained: true`, match the literal token; do not infer "drained" from the surrounding conversation or from the fact that a cache was cleared. When `drained: true` is present, spec-close is the parent and will handle disposition itself once wiki-promote returns; skip Step 8.

Otherwise, invoke `/speckit-gaia-spec-close` directly by calling the Skill tool to run that command with `<spec_id>` as its argument, the line below states the intent, it is not a substitute for the call:

> Invoking `/speckit-gaia-spec-close <spec_id>`. wiki-promote completed inline; the cache is already cleared. Spec-close will skip drain and go straight to the disposition prompt.

This presents the user with the archive / delete / keep prompt for the local SPEC artifact. The wiki content is already committed (Step 6's wiki-sync handoff); the disposition only affects `.gaia/local/specs/<spec_id>/`.

If `/speckit-gaia-spec-close` fails or refuses, exit with the warning `wiki-promote: pages staged and committed; spec-close chain failed. Run /gaia-spec close <spec_id> manually to dispose of the SPEC artifact.` Do NOT retry the chain, the wiki side is already settled.
