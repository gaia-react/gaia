---
type: concept
status: active
created: 2026-08-20
updated: 2026-08-20
tags: [concept, github, labels, workflow]
---

# GitHub Labels

`.gaia/labels.json` is the single machine-readable source of truth for every GitHub label GAIA creates, syncs, and documents. Each entry carries its color, its description, the axis it classifies on, whether it belongs to an adopter repository or only to the GAIA maintainer repository, and which feature has to be enabled before the label is owed at all. `.gaia/labels.schema.json` is the editor-facing copy of the shape, and the `gaia labels` commands validate the registry themselves before acting on it.

The middle of this page is generated from that registry. A hand edit between the two `gaia:labels:generated` markers is reverted by the next regeneration, so a label's color or description changes in `.gaia/labels.json` and reaches the page from there. Everything above the start marker and below the end marker is hand-maintained, and the generator never touches a byte of it.

The appendix at the bottom is yours. A project that adds labels of its own documents them there, outside the generated span, where no regeneration can reach them.

The registry documents each label's shape; it does not document how one is used day to day. For `in-progress`, see [[Issue Claim]] for the claim and release workflow.

## Commands

- `.gaia/cli/gaia labels sync` reconciles this repository's labels against the registry.
- `.gaia/cli/gaia labels docs` regenerates the span below from the registry.
- `.gaia/cli/gaia labels check` fails when a label literal in the tree is absent from the registry.

Sync is conservative by design. It renames rather than deleting and recreating, because a delete strips the label from every issue and pull request carrying it. It reports an unknown live label instead of touching it. Color is operator wins and description is GAIA wins, so a deliberate recolor survives an update while a stale description does not. A rename is the one exception: it carries the registry's color with it, under no flag. Sync cannot tell a registry recolor from an operator's own, so a renamed entry's leftover color would sit unreconciled indefinitely; the rename resolves that in the registry's favour, at the cost of an operator's recolor of the old name not surviving the rename. Nothing is deleted without `--prune-deprecated` or `--enforce-blocked`, and `--enforce-blocked` counts a label's carriers on both surfaces, issues and pull requests, before reading it as uncarried; a label it cannot count on either surface is never deleted. A token without label-write scope produces a list of manual `gh` commands and a zero exit rather than a failed setup. That list means two different things, so the degraded output and the `--json` `degradedAt` field name which refusal happened: after a refused write it is the mutations still owed, while after a refused read the plan was computed against an assumed-empty repository and the list is the whole registry.
<!-- gaia:maintainer-only:start -->

The `audience` axis answers two questions at two layers, under one name. A registry entry's `audience` field decides which clones receive the label; an `audience:*` label records which side can observe the defect it is filed against. So the two `audience:*` entries carry `"audience": "maintainer"` themselves: only this repository files against the split, while `audience:adopter` still means an adopter can observe the defect. The Code Audit Team roster's `audience:` field in `.gaia/audit-ci.yml` uses the same two values for the same split.
<!-- gaia:maintainer-only:end -->

<!-- gaia:labels:generated-start -->

## GAIA labels

### Type

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `tech-debt` | `ededed` | Out-of-scope review finding, tracked for a later drain | tech-debt |
| `bug` | `d73a4a` | Existing behavior is broken or wrong | always |
| `enhancement` | `a2eeef` | New feature or request | always |
| `documentation` | `0075ca` | Improvements or additions to documentation | always |
| `security` | `a1121b` | Security defect or dependency CVE | gaia-ci |

### Urgency

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `severity:critical` | `b60205` | Breaks a documented promise or loses work; drain first | tech-debt, gaia-ci |
| `severity:important` | `fbca04` | Degrades a documented behavior; drain before suggestions | tech-debt, gaia-ci |
| `severity:suggestion` | `c5def5` | Improvement with no broken behavior behind it | tech-debt |
| `severity:investigate` | `1d76db` | Severity not yet determined; research required before it can be graded | tech-debt |

### Effort

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `difficulty:easy` | `bfe3df` | Fix is determined by the issue text and the cited code | tech-debt |
| `difficulty:medium` | `4c9c8f` | Fix has a design decision the surrounding code settles | tech-debt |
| `difficulty:hard` | `1b6b5f` | Fix has a design decision the surrounding code does not settle | tech-debt |

### Reach of fix

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `footprint:narrow` | `d4c5f9` | Fix is one logical unit in one file, no contract change | tech-debt |
| `footprint:wide` | `8957e5` | Fix spans files, changes a contract, or is structural | tech-debt |
| `footprint:spec` | `4c2889` | Fix must start with a design SPEC; drains via /gaia-spec | tech-debt |

### Lifecycle

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `in-progress` | `ffd33d` | Someone is actively working this issue right now; do not pick it up | always |
| `debt:spec-pending` | `a6e3b8` | Handed to /gaia-spec; parked until the SPEC pipeline starts | tech-debt |
| `debt:spec-active` | `3b9b58` | SPEC is underway for this issue, or holds it open on a recorded trigger | tech-debt |

### Modifier

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `fold:required` | `fbb6ce` | Repair should ride a change that already pays its fixed cost | tech-debt |

### Disposition

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `wontfix` | `e5e5e5` | Deliberately declined; do not re-file | always |

### Origin and trigger

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `gaia-ci` | `d4d4d4` | Opened by a GAIA CI maintenance job | gaia-ci |
| `run-audit` | `a78bfa` | Forces the Code Audit Team to run on this pull request | always |

### Attention gate

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `needs-human` | `d93f0b` | A machine stopped here; maintainer review required | always |

### Third-party

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `dependencies` | `e1e4e8` | Dependabot: updates a dependency file | documented only |
| `github_actions` | `c9c9c9` | Dependabot: updates GitHub Actions code | documented only |

## Palette rule

Warm families (red, orange, amber) are reserved for attention: urgency, defect type, the gates that require a human, and the active-work claim, whose yellow marks an issue as in flight. Every other entry takes a cool or neutral family instead, high-frequency structural labels stay near grey so they recede, no two entries share a hex value, and every hex value is lowercase.

<!-- gaia:maintainer-only:start -->

## Maintainer-only labels

These labels serve the GAIA maintainer repository. Sync never creates them on an adopter repository, and the bundle-time scrub removes this section from the page an adopter receives.

### Disposition

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `non-issue` | `cccccc` | Not a bug: user config, missing prerequisite, or duplicate | forensics |

### Origin and trigger

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `gaia-forensics` | `5319e7` | End-user bug report routed via /gaia-forensics | forensics |
| `gaia-triaged` | `7d4cdb` | Forensics triage has processed this issue; re-firing is a no-op | forensics |

### Attention gate

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `auto-fixable` | `f2a93b` | Quality Gate passed on the autofix branch; draft PR ready | forensics |

### Audience

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `audience:adopter` | `d9a86c` | Defect an adopter can observe in something GAIA ships | tech-debt |
| `audience:maintainer` | `8a5a2b` | Defect observable only in the GAIA maintainer repository | tech-debt |

<!-- gaia:maintainer-only:end -->
## Deliberately absent

| Label | Reason |
| --- | --- |
| `good first issue` | Solicits drive-by contributions from people with no context for the work. GitHub recreates it on every new repository, so it needs an explicit block rather than a one-time delete. |
| `help wanted` | Same solicitation problem as good first issue. Both are GitHub defaults, recreated on every new repository, so a one-time delete does not hold. |

<!-- gaia:labels:generated-end -->

<!-- gaia:maintainer-only:start -->
## Label and key rename contract

The wrapped `gaia-debt-key` format (step 1 of `.claude/skills/file-tech-debt/SKILL.md`) and the label spellings (step 6 of that file) are not just prose there, they are a contract shared with several consumers and their tests. That file's step 2 dedup **matching basis** is `path=`+`line=` (ignoring `class=`), but that only changes which issue the recipe treats as a match, it does not change the wrapped key format (step 1) or any label spelling (step 6), so none of the consumers below need a change on account of it.

**Key format.** The wrapped comment format is a contract shared with every reader that parses it, and the authoritative reader set is found by searching rather than read from a list here, because a reader can assert the contract in a docblock while carrying no key literal at all: `git grep -n 'gaia-debt-key'`, paired with a search for the terminator the key parser currently uses for the `path=` field, taken from a reader the first prong just returned rather than named here, and a search for prose describing the `path` field. Search for the grammar you are moving away from, never one a past migration already moved away from: a spent spelling greps clean and reads as done. Naming today's spelling in this sentence would make it spent on the next move, which is why it describes the shape instead. Change the key format only once that search is clean against the change.

**Label spellings.** A rename is complete when the old spelling reaches no consumer, and that half is **checked rather than enumerated**. Record the previous name in `.gaia/labels.json`'s `renamedFrom` as part of the rename itself: that entry is what `gaia labels sync` reads to issue `gh label edit <old> --name <new>`, and it is also the term a scan of the tracked tree searches for. So rename registry-first, then `git grep` the old spelling, and each namespace prefix the rename retires, until the tree is clean of both.

`.gaia/scripts/lint-retired-label-spellings.sh` runs that scan deterministically, gated in CI by `audit-ci-tests.yml`, so a rename that leaves a carrier behind reds before the merge instead of surfacing later as a degraded count. It needs no roster: it takes its search terms from `renamedFrom` and reads every tracked file outside the historical, generated and test surfaces its own `EXCLUDED_PATHSPECS` array names, with the reasons written beside it. Its one blind spot is a rename that never records `renamedFrom`, which `gaia labels sync` already punishes by creating a second label instead of renaming the first.

The list below is **annotation, not the contract**. It makes no completeness claim and nothing depends on it making one; its parentheticals say how each consumer behaves when a rename misses it, loudly or silently, which is what decides the order to migrate in and what to distrust while a rename is in flight. The paragraphs after it own the per-consumer detail and this list does not restate any of it.

- `.gaia/statusline/gaia-statusline.sh` (carries no spelling; it renders debt-derived UI, so it is checked defensively)
- `.gaia/scripts/debt-count-refresh.sh` (silent)
- `.claude/hooks/debt-session-reconcile.sh` (silent)
- `.claude/skills/gaia/references/debt.md` (silent: instructions keep reading as correct while naming a label nothing applies)
- `.gaia/scripts/check-debt-issue-metadata.sh` (loud, and first)
- `.claude/rules/issue-claim.md` (silent, for the same reason `debt.md` is)
- `.claude/hooks/issue-claim-release.sh` (silent)
- `.claude/hooks/lib/audit-dispositions.sh` (loud but misdirected: the query returns empty rather than erroring, which reads as every filed entry missing)
- `.github/actions/gaia-ci-merge-and-watch/action.yml` (`severity:important`, `severity:critical`; loud, but only on the revert path, so it can sit unfired for a long time)
- `.gaia/labels.json` (neither loud nor silent: it is the rename itself rather than a carrier of it)
- `.gaia/cli/src/labels/registry.ts` (every governed namespace prefix; silent, and held as bare prefixes, which no search for a full spelling reaches)
- `.gaia/cli/health/comprehensive/runbook.md` (silent: a pasted command fails in a human's terminal rather than in CI)
- Tests: `.gaia/tests/hooks/debt-sentinel-touch.bats`, `.gaia/tests/hooks/debt-session-reconcile.bats`, `.gaia/scripts/tests/debt-count-refresh.bats`, `.gaia/tests/statusline/audit-nudge-drift-suppression.bats`, `.gaia/scripts/tests/check-debt-issue-metadata.bats`, `.gaia/tests/hooks/issue-claim-release.bats`

One carve-out, so the per-namespace paragraphs below do not each have to restate it: `.gaia/cli/src/labels/registry.ts`'s `NAMESPACE_PREFIXES` array hardcodes **every** governed prefix, so it is an edit for every namespace rename without exception. The consumer counts those paragraphs give ("one of them reads it", "two of them read it") are counts over the reader set each paragraph describes, and they do not include this one.

`.gaia/labels.json` is the registry where every spelling this section governs is defined, rather than a consumer of them. Rename there by changing the entry's `name` and appending the old spelling to its `renamedFrom`, then regenerate the wiki page with `.gaia/cli/gaia labels docs`. `labels sync` takes its label definitions from that file and nowhere else, so a rename that works every consumer in the list above and skips the registry leaves sync creating the old label forever and the new one never.

`check-debt-issue-metadata.sh` is the only consumer that gates on a label spelling rather than merely tolerating one. It hardcodes the permitted value set for every namespace steps 6 and 7 of `.claude/skills/file-tech-debt/SKILL.md` define, and the key's line shape, so it is the consumer a spelling change breaks first and loudest, which is the intended direction: a rename that forgets this file fails a filing immediately instead of degrading a count silently.

`severity:investigate` is the one value in the `severity:` namespace with a consumer outside the vocabulary set. `.gaia/scripts/check-debt-issue-metadata.sh` matches the bare spelling outside its vocabulary set, to decide whether the research block is required and whether the cap check reads the network at all, and `.claude/skills/gaia/references/debt.md` matches it wherever it ranks, excludes, or annotates an investigate issue. Every one of those matches fails **open** on a forgotten rename, the same direction the claim label does: the block stops being demanded, the cap stops being counted, and such an issue re-enters `/gaia-debt`'s fix candidate pool, by direct number and in the recommendation offer alike, all on a grade that still files. So the rename moves every occurrence in both files, not the ones a reader happens to recall; grep each file for the value rather than working from a list here. The body marker `<!-- gaia-investigate: v1 -->` is a second contract of its own, shared between the gate's patterns and step 5's schema, and it moves under the key-format rules above rather than these.

The governed set also includes the `in-progress` claim label, which has more consumers than any other spelling here because it is not tech-debt-specific. `.claude/skills/gaia/references/debt.md` creates and applies it as the `/gaia-debt` claim and `.claude/rules/issue-claim.md` applies it to every other issue type; `.claude/hooks/issue-claim-release.sh` removes it on a confirmed merge; `.gaia/scripts/debt-count-refresh.sh` consumes it, excluding any issue that carries it from the open count; and `.gaia/scripts/check-debt-issue-metadata.sh` hardcodes the bare spelling in its pre-file guard, outside the namespace vocabulary sets, so for this one spelling a forgotten rename fails **open**: the guard matches a label nothing applies any more, and a filing carrying the renamed claim stops being rejected. The release hook's own removal is best-effort and silent, so a rename that forgets it degrades quietly rather than failing: every claim it was meant to release stays set. The same holds for the two park labels, `debt:spec-pending` and `debt:spec-active`: `debt.md` creates and applies `debt:spec-pending` as the `/gaia-debt` design-first handoff park label and directs the pasted spec session to swap it for `debt:spec-active` once the pipeline starts, `.gaia/scripts/debt-count-refresh.sh` consumes both, excluding any issue that carries either from the open count too, and that same pre-file guard names both in the same regex, so each carries the same fail-open direction on a forgotten rename. Rename them together: they are one axis with two values, and a rename that reaches only the spelling it was looking for leaves the other consumer set half-migrated. `.claude/skills/file-tech-debt/SKILL.md` creates or applies none of these labels itself.

`.gaia/scripts/debt-count-refresh.sh`, `.claude/hooks/audit-disposition-check.sh`, `.gaia/statusline/gaia-statusline.sh`, and `.claude/hooks/debt-session-reconcile.sh` are untouched by every **namespace** rename in the namespace paragraphs below, so they are named once here rather than per paragraph, as the **count/statusline/hook four**: `.gaia/scripts/debt-count-refresh.sh` excludes exactly three label names (`in-progress`, `debt:spec-pending`, and `debt:spec-active`) and ignores the rest, `.claude/hooks/audit-disposition-check.sh` matches the dedup key in the body and parses no labels, `.gaia/statusline/gaia-statusline.sh` parses no labels, and `.claude/hooks/debt-session-reconcile.sh` only reconciles the count downward. `.claude/hooks/audit-disposition-check.sh` is found by the key-format search above rather than enumerated in the label-spellings list, because it reads the key rather than a spelling, so that search already reaches it. Parsing no labels is not the criterion: `.gaia/statusline/gaia-statusline.sh` parses none either and stays on the list. It is named here because the count/statusline/hook four is a group about namespace renames, not a subset of that list.

The scope is those paragraphs and not this whole section: the `in-progress`, `debt:spec-pending`, and `debt:spec-active` labels above are in the governed set too, and `.gaia/scripts/debt-count-refresh.sh` and `.gaia/scripts/check-debt-issue-metadata.sh` hardcode all three spellings, but only the two `debt:` park labels still carry a namespace to rename, so a namespace rename reaches just those two labels. `.claude/rules/issue-claim.md` and `.claude/hooks/issue-claim-release.sh` are untouched by a namespace rename for that same reason, since `in-progress` is the only spelling either one carries. They are deliberately not counted into the count/statusline/hook four, which is a group defined by parsing a namespace and finding nothing to change, not by being unaffected.

Each paragraph below names only what varies from that: which consumers read its namespace, and what `.claude/skills/gaia/references/debt.md` does with it. A per-paragraph restatement is what lets copies of one inventory drift apart, leaving each reader whichever version sits nearest their namespace.

The `audience:` namespace (step 6 of `.claude/skills/file-tech-debt/SKILL.md`) is a label spelling and within this contract's scope. Verified against every consumer named above: one of them reads it and the rest do not. `.gaia/scripts/check-debt-issue-metadata.sh` is where the requirement is enforced rather than merely stated. The count/statusline/hook four are untouched, and `.claude/skills/gaia/references/debt.md` neither sorts, clusters, nor gates on it. The filing routes that map an `audience` field onto the label sit outside that list, because they write filed issues rather than read them; the leak check's pattern below is what finds them.

This namespace carries a **second** edit set the others do not, and a rename that stops at the reader and filing routes above breaks it silently. The axis is maintainer-only, so the spelling is also a scrub token: `.gaia/release-scrub.yml`'s `audience-label-vocabulary` leak check matches on it, and a rename leaves that check green while guarding a spelling nothing writes any more, which is the adopter leak it exists to catch. Renaming the namespace therefore means editing step 6 of that file, the registry entries, that consumer, the leak check's pattern, and every site and fixture the pattern reaches, found by running the pattern as a `git grep` over the tree. `CHANGELOG.md` matches too and is deliberately left alone, because it records what shipped and a rename never rewrites it.

The `footprint:` namespace (step 6 of `.claude/skills/file-tech-debt/SKILL.md`) is a label spelling and within this contract's scope. Re-verified against every consumer named above: two of them read it and the rest do not. `.gaia/scripts/check-debt-issue-metadata.sh` hardcodes the three permitted values, so a rename that forgets it fails a filing immediately. `.claude/skills/gaia/references/debt.md` resolves the class out of the `labels` projection its ordering query already builds and reads it in three places (the offer-time spec read, the Fix-time spec screen, and `list`/`why`'s annotations), so a rename must reach the one `startswith("footprint:")` selector there. The count/statusline/hook four are untouched.

The `fold:` namespace (step 6 of `.claude/skills/file-tech-debt/SKILL.md`) is a label spelling and within this contract's scope. Verified against every consumer named above: two of them read it and the rest do not. `.gaia/scripts/check-debt-issue-metadata.sh` hardcodes the one permitted value, so a rename that forgets it fails a filing immediately. `.claude/skills/gaia/references/debt.md` resolves it out of the `labels` projection its ordering query already builds and surfaces it in three display sites (`list`'s annotation, `why`'s report, and the recommendation prompt's option description), so a rename must reach the one `startswith("fold:")` selector there. No consumer gates on it, which is the point of the label rather than an accident of its youth: the count/statusline/hook four are untouched.

The `difficulty:` namespace (step 7 of `.claude/skills/file-tech-debt/SKILL.md`) is a label spelling, so it is within this lockstep contract's scope. No consumer **outside `check-debt-issue-metadata.sh`** gates on it, verified against every consumer named above: the count/statusline/hook four are untouched, and `.claude/skills/gaia/references/debt.md` surfaces it in output only, never to gate a path (`debt.md`'s own Guardrails: "Difficulty grading never gates anything"). Renaming the namespace therefore requires zero gating changes to any of them, and two literal edits in `check-debt-issue-metadata.sh`: the `'difficulty:'` prefix it passes to its count check and to its vocabulary check. The registry's own three entries are a third edit, as they are for every namespace here, and regenerating the wiki page follows from them. `DIFFICULTY_VALUES` is not one of them, since it holds the grades and a prefix rename does not touch them. Nor does forgetting the prefix fail a filing the way it would for a mandatory namespace: this one is optional, so the count check passes on zero and the vocabulary check returns before reading anything, which leaves the renamed label validated by nothing.

Nothing catches that omission, which is why it is called out. No test couples the script's prefix to the skill's spelling, and the check's own suite, `.gaia/scripts/tests/check-debt-issue-metadata.bats`, reds only once a prefix has been edited, so it catches a half-done rename rather than a skipped one. The script edit is unguarded and has to be made by hand.

Provenance (the `gaia-debt-origin` line, see "Provenance line" in `.claude/skills/file-tech-debt/SKILL.md`) is a separate line and joins none of that lockstep set. Adding, removing, or renaming a provenance field requires no change to any deterministic consumer of the dedup key. No consumer reads the issue body positionally, so a second HTML comment beside the dedup key is safe: `.claude/hooks/lib/audit-dispositions.sh` reconstructs the wrapped dedup key and tests it as a substring, and `.claude/skills/gaia/references/debt.md` captures on the literal `<!-- gaia-debt-key: ` prefix; neither reads past it. The keyless `<path>:<line>` fallback cannot false-match a provenance field either, since no provenance field yields a colon followed by digits. The helper deliberately inverts `audit-key-lib.sh`'s fail-closed rule, printing `unknown` in a slot it cannot resolve rather than refusing to print a partial line; that inversion is deliberate, not a bug to "fix" into agreement.
<!-- gaia:maintainer-only:end -->

## Project labels

This section is where a project documents the labels it adds for itself. `gaia labels docs` never rewrites it, and `gaia labels check` never demands that a label named here be present in the registry.

A project label that falls into one of the GAIA axes above can take that family's color, so the palette stays readable across both sets. `gaia labels sync` reports a label it does not recognize and suggests the family color when the name carries a known namespace prefix, but it never recolors one without `--adopt-palette`.

| Label | Color | Description |
| --- | --- | --- |
| | | |
