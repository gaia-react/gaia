# wiki-lint fix playbook

Run by the `/gaia-wiki` router (`references/wiki.md` → "Lint", stage 2) in the parent, the agent reading this file in the live conversation, right after the lint subagent returns. It is never dispatched: it asks the user with `AskUserQuestion`, which is unavailable inside dispatched subagents.

Lint finds defects; this stage fixes them. A report that names a dead path or an empty section and leaves it standing records a known defect and changes nothing, so every finding ends this stage fixed, filed, or explicitly left by the user. Fix mechanically where one answer is right, and ask only where the fix needs judgment.

## Step 1: Collect the findings

Read each check's findings fresh from its primitive, not from the report prose:

```bash
.gaia/cli/gaia wiki dead-paths --json
.gaia/cli/gaia wiki orphans --json
.gaia/cli/gaia wiki frontmatter --json
.gaia/cli/gaia wiki empty-sections --json
.gaia/cli/gaia wiki broken-links --json
```

Read check #13's findings from the `## #13` section of the report the subagent wrote: the structural-versus-narrative triage that produced them has no primitive.

Check #11 (drift) has no fix here, because sync has just run in the same chain.

When every list is empty, there is nothing to fix: skip to Step 5.

## Step 2: Fix the mechanical findings

These have one right answer. Apply them without asking.

- **#15 Frontmatter gaps.** Add each missing field to the page's frontmatter block, leaving the fields already there untouched. `type` comes from the page's domain folder, in the singular form the folder's other pages use (`wiki/concepts/` → `concept`, `wiki/decisions/` → `decision`); read a sibling page when unsure. `status` is `active`.
- **#14 Orphan pages.** Add a wikilink entry for the page to `wiki/index.md`, in the section for its domain, matching the neighbouring entries' format and placing it where the section's ordering puts it. Read the page's opening lines for a short gloss when the neighbouring entries carry one.
  <!-- gaia:maintainer-only:start -->
  When the page matches a pattern in `.gaia/release-exclude`, place the entry inside one of that section's `gaia:maintainer-only` marker blocks, or wrap it in a new pair, so the scrubbed adopter index never links a page the adopter bundle does not ship.
  <!-- gaia:maintainer-only:end -->
- **#12 Dead paths with a rename successor.** Find the commit that removed the path, then look for a rename out of it:

  ```bash
  git log -1 --format=%h --diff-filter=D -- '<path>'
  git show -M --name-status --format= <sha>
  ```

  An `R` line whose source is exactly the dead path names its successor. When the successor exists on disk, replace the dead path with it at the cited line and re-read the sentence: a path that moved can leave the prose around it describing the old location. A dead path with no rename successor needs judgment (Step 3).
- **#17 Broken wikilinks with a rename successor.** The target is a page title or slug, not a path. Find a rename record whose source page's slug (basename without `.md`) or H1 title equals the target case-insensitively:

  ```bash
  git log -z -M --diff-filter=R --name-status --format=%h -- 'wiki/'
  git show "<sha>^:<source>"
  ```

  Match the slug against each rename's source path first; when no slug matches, read the source page's H1 with the second command. A rename whose destination is under `wiki/_archived/` is not a successor: never repoint into `wiki/_archived/`, and treat that link as having no successor (Step 3). When the successor exists on disk outside `wiki/_archived/`, repoint the link at the successor page's H1 title without asking, by the link-matching rule of `references/wiki/consolidate.md` (Step 4, apply item 6): keep any `|alias`, and drop a `#heading` anchor the successor has no matching heading for.

## Step 3: Ask about the judgment findings

Ask one question per finding, up to four per `AskUserQuestion` call, header `Lint fix`. Put the recommended option first, its label suffixed ` (Recommended)`, and always end with `Leave as is`, which records the finding as accepted. Apply each answer before moving on.

- **#12 Dead path, no successor.** Read the sentence at the cited line first.
  - `Remove the reference`: the file is gone and the sentence or clause citing it is stale. Delete it, or rewrite the sentence to what is true now. Recommended when the page describes the file as present behaviour.
  - `Reword`: the file is real but absent by design (generated on demand, opt-in, gitignored, or machine-local). Rewrite so the page names what creates the file rather than citing the path as if it were tracked. Recommended when the sentence already says the file is generated or optional.
- **#17 Broken wikilink, no successor** (including a rename whose destination is under `wiki/_archived/`). Read the sentence around the link first.
  - `Repoint to <page title>`: name the candidate live page. Recommended when one live page clearly covers the subject.
  - `Remove the link`: unlink the text, keeping the words when the sentence still reads. Recommended when no live page covers the subject.

  `Leave as is` records nothing durable, so the same link is asked about again on the next run, as consolidate's `Skip` is.
- **#16 Empty section.** Read the page around the heading.
  - `Remove the heading`: recommended unless the heading is one a tool writes and fills on its own (a promotion step's provenance heading, a template slot).
  - `Write the section`: draft the body from the page's subject and the code it describes, following `.claude/rules/wiki-style.md`.
- **#13 Narrative refs.** These are not asked about. They sit in instruction files outside `wiki/`, and the chain's branch carries `wiki/` only: `chain commit` refuses a working tree with non-wiki changes, and the wiki-only diff is what lets `chain finish` stamp the PR out of audit scope. Do not edit them here. File each as a `tech-debt` issue through the `file-tech-debt` skill, one per finding, citing its `path:line` and the narrative reference, so it is drained through `/gaia-debt` on a branch the audit gate covers. When the skill cannot file (no issues backend), list the findings in the Step 5 summary as unfiled.

## Step 4: Re-lint

Re-dispatch the lint subagent exactly as `references/wiki.md` → "Lint" stage 1 does. It regenerates the report from scratch, so the report that gets committed describes the fixed wiki rather than the one lint first saw.

Compare its findings, #17 included, with what Steps 2 and 3 resolved. A finding the user left as is, or that Step 3 filed, is expected to remain. Any other remaining finding is a fix that did not take: fix it once more and re-lint once more. A finding still present after that second pass is reported in Step 5 as unresolved, naming the check and the location; do not loop further.

## Step 5: Report

Print one line: `Lint fix: <fixed> fixed, <filed> filed as tech-debt, <left> left as is, <unresolved> unresolved.` Then one line per finding left as is, unfiled, or unresolved, as `<check>: <location>`.

Do not commit. The router commits the fixes and the final report together (`references/wiki.md` → "Full chain", step 5).
