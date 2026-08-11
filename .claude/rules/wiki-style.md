---
paths:
  - 'wiki/**/*.md'
  - 'app/**/*.{ts,tsx,js,jsx,css}'
  - '.gaia/**/*.ts'
  - '.gaia/**/*.sh'
  - '.claude/instructions/**/*.md'
  - '.claude/skills/**/*.md'
  - '.claude/commands/**/*.md'
  - '.claude/agents/**/*.md'
  - '.claude/rules/**/*.md'
  - '.claude/hooks/**/*.sh'
  - '.specify/extensions/gaia/README.md'
  - '.specify/extensions/gaia/commands/**/*.md'
  - '.specify/extensions/gaia/lib/**/*.sh'
  - '.specify/extensions/gaia/rules/**/*.md'
  - '.specify/extensions/gaia/templates/**/*.md'
---

# Wiki & Comment Style

Body prose and code comments describe **what is** in present tense. The historical record lives in git (`git log`, `git blame`), `wiki/log.md`, and `CHANGELOG.md`, body prose is not the place for it.

## Rules

- **Present tense only.** Do not write "was changed from X to Y", "previously did A, now does B", "moved from a to b". State the current behavior directly.
- **No UAT or SPEC references in prose or comments.** `UAT-NNN` identifies entries inside SPECs; `SPEC-NNN` identifies the SPECs themselves. Both are working documents, they get superseded, renumbered, or deleted. A reader querying the wiki about a feature gets no value from "implements UAT-012" or "from SPEC-005". Drop the reference; describe what the feature does and why.
- **No inline PR / commit / date-of-change references in body prose.** Don't write "added in PR #97", "commit abc123 introduced …", "as of 2026-05-07 …". The git log answers those questions and stays accurate when prose drifts.
- **No unreleased or speculative roadmap as current behavior.** Body prose describes what ships today. Do not document a planned, deferred, or not-yet-built feature as if it already exists, a reader cannot tell aspiration from shipped fact. State current behavior; keep forward-looking notes out of the page, or label them plainly as deferred and not yet built.
  <!-- gaia:maintainer-only:start -->
  GAIA maintainers: two kinds of content go inside the HTML-comment maintainer-only markers, the same pair wrapping this note. First, roadmap or forward-looking content that must live in the source repo but not reach adopter scaffolds. Second, any statement specific to the maintainer repo itself, how `gaia-react/gaia` is configured or operated (its branch-protection / ruleset setup, per-author audit mode, secrets, in-tree-only workflows): on an adopter clone that reads as a claim about the reader's own repo and is false there, so wrap it. Keep the general behavior in the visible body and confine the maintainer-repo specifics to the wrapped block. The bundle-time scrub strips marker-delimited blocks from markdown under `wiki/`, `.claude/`, and `.specify/extensions/gaia/` before tar, so the source repo stays a superset of the adopter bundle; unbalanced markers fail the release build. See [[Bundle-time Scrub]].
  The `.gaia/**/*.sh` activation glob above reaches shell files under `.gaia/tests/` as well, but that directory's content stays exempt under the `.gaia/tests/` bullet in Exceptions regardless of what activates this rule.
  <!-- gaia:maintainer-only:end -->

## Why

Wiki readers (maintainers, adopters) need to understand the system as it is now. References to _how it got here_ are noise unless explicitly load-bearing, and even then, `wiki/log.md` and `CHANGELOG.md` are the right home, not body prose. Comments and pages explaining _what changed when_ rot the moment another change lands.

## Exceptions

- **`wiki/log.md`**: append-only change ledger, exempt by design.
- **`wiki/hot.md`**: auto-loaded recent-context cache. Body is by design a recap of recent commits / threads; historical phrasing is the point. The cache is overwritten by `/gaia-wiki sync`, not edited by hand.
- **`wiki/meta/`**: audit artifacts (lint reports, consolidate reports). Their purpose is referencing specific commits / SHAs / dates, so the no-inline-refs rule does not apply.
- **Frontmatter (`created`, `updated`, `status`, etc.)**: metadata, not prose.
- **Structural UAT/SPEC references in `.claude/`, `.specify/extensions/gaia/`**: narrowly exempt: template format examples (`> - UAT-NNN, Given … when … then …` showing the SPEC artifact shape), fixture data (CLI args like `--uat-id UAT-007`, JS/Python/YAML literals like `uat_id: 'UAT-099'`, regex targets that match SPEC YAML structure), filename literals (`uat-001.spec.ts`), and identifier fragments inside variable names (`uat_id`, `uats_block`, `seen_uat_files`). Narrative references, section-header parentheticals (`#### 5b. Discuss-this escape (UAT-004)`), inline narrative parentheticals, comments naming specific working-doc IDs, and pass/fail label prefixes, are NOT exempt and must be scrubbed.
<!-- gaia:maintainer-only:start -->
- **`.gaia/tests/` is out of scope entirely.** It is release-excluded maintainer-only test infrastructure that never reaches an adopter, so a UAT/SPEC reference there is never shipped-surface drift. Its suites use `UAT-NNN` / `SEC-N` / `TST-NN` test-name prefixes, header comments, and section headers as deliberate SPEC-conformance traceability; those stay. Both audit greps below omit `.gaia/tests/` for this reason, matching the release boundary. Do not re-add `.gaia/tests/` to either grep.
<!-- gaia:maintainer-only:end -->
- **Concrete maintainer SPEC IDs.** Adopter-shipped surfaces must not reference specific maintainer SPECs by ID (`SPEC-001`, `SPEC-003`, etc.) as if they were system-wide constants. On adopter clones those IDs identify whatever the adopter authored first, not the maintainer artifact. Rephrase to generic placeholders (`the SPEC's <field>`, `## Composition with` heading prefix match) or drop the reference. Generic placeholder forms (`SPEC-NNN`, `SPEC-NNN.md`, illustrative `(e.g. SPEC-002)` examples in usage docs) are fine.
- **Targeted archival labels**: e.g. the `## Historical context (from <older-title>)` heading `/gaia-wiki consolidate` writes when merging a superseded page is a deliberate label that identifies lifted content; not the prose pattern this rule bans.

## Comment worthiness

The rules above apply to wiki prose and code comments alike. This section applies to code comments only, and asks a different question: does the comment earn its place at all?

> **A comment must be about something the file does not contain.**

That is a test of subject, not of length. A thirty-line comment about a platform quirk earns every one of its lines; a three-line docblock naming the symbol imported below it earns none. So this standard compresses a comment toward its subject, it never suppresses one: cutting a comment until it is cryptic, or dropping a fact that deserves to survive because the block looked long, fails the standard rather than satisfying it.

### What earns its place

- **The reason a tested value has the value it has.** The test pins the value; nothing pins the reason. Applies to timeouts, retry counts, thresholds, cache TTLs, debounce intervals, page sizes.
- **A why-not.** An obvious simpler approach, and the specific way it fails here.
- **The contract with the _other_ file.** Which event fires this code, what shape of input arrives, what a return value or exit code means to the caller. Narrowly: a file's own usage and its output shape are recoverable by reading it and do not qualify, only the cross-file half earns.
- **A platform or version quirk.** A shell version difference, a BSD-vs-GNU tool difference, a language-spec fact, a side effect of a third-party SDK.
- **An honest limit of a check.** What a guard does _not_ catch, and why that direction is the safe one to fail in.

### What does not

- Duplication at paragraph scale: a header re-narrating what the implementation sites below already say, then the same paragraphs repeated verbatim at each site.
- A banner restating the single item beneath it. A banner heading a group of items is navigation and stays.
- A label restating output the code already renders.
- ASCII section rules (`// ─── Types ───`).
- A comment restating what a check already enforces. The check is the durable form, the comment is a copy of it that decays.
- Historical narration, already banned above.
- The ceremonial docblock opener: a first line assembled from the filename's own tokens and saying nothing else. `` `foo bar <baz>` handler. `` above `foo/bar.ts`, or `Tests for Widget.` above the import of `Widget`.
- Source-to-test essay duplication: a prose proof in the source that restates the suite already proving it. The test is the durable proof.
- Unverified numbers used as a safety justification. A block asserting a per-character cost, a worst-case payload duration, a spawn count, and a claimed margin of safety, none of them reproducible from anything in the repo, gating a live timeout decision. A number in a comment that cannot be reproduced from something in the repo justifies nothing.

### Name less, explain more

The sharpest edge of this section: be far harder on a comment that NAMES a thing than on one that EXPLAINS a thing. Explanations age well. Pointers do not, because the file, symbol, or ticket a comment names gets renamed or deleted while the comment stays behind still naming it. A name in a comment carries a maintenance obligation that the reasoning around it does not, so hold every name to whether a reader actually needs it.

Pointing at a rule is not the same as restating one. A pointer to a rule stays allowed, including inside a runtime message an operator reads at decision time; copying a rule's content into a comment stays banned, because the copy drifts from the rule.

### Doc comments

- Doc comments meet the same bar. A `/** */` restating the signature is worth no more than a `//` restating the line below it, the delimiter does not launder it.
- One addition, for **exported symbols only**: a single-line summary earns its place on an exported function, hook, type, or constant even when the implementation is self-evident, because it reaches callers who never open the file. One line, not a paragraph.
- No `@param` or `@returns` restating the signature. TypeScript types them, the editor shows them, and the tag rots independently of the parameter it names. Use a tag only for what the type cannot say: a unit, an ownership transfer, a mutation.
- A wrong doc comment on an exported symbol is displayed at every call site, so it misleads more readers than a wrong inline comment. Exported-symbol docs get the **highest** scrutiny, not an exemption from it.

### Comments that are not commentary

Some lines in comment syntax are read by a tool rather than by a person: linter and type-checker directives, test-environment and editor pragmas, generated-region and codegen markers, and version glosses a bot writes and a test parses. If anything in the repo parses it, it is data wearing comment syntax. Never judge it on worthiness and never reword it, editing or deleting one changes behavior.

## Audit

Before merging changes that touch any in-scope path, and before running `/gaia-wiki` (any sub-command):

```bash
# UAT / SPEC refs in wiki body prose (excluding log.md, hot.md, and meta/ audit reports)
grep -rEn "UAT-[0-9]+|SPEC-[0-9]+" wiki/ --include="*.md" --exclude="log.md" --exclude="hot.md" --exclude-dir="meta"

# UAT / SPEC refs in source comments
grep -rEn "// .*(UAT|SPEC)-[0-9]+|/\*.*(UAT|SPEC)-[0-9]+|\*.*(UAT|SPEC)-[0-9]+" app/

# UAT-NNN narrative refs in instruction files and shipped extension surfaces
# (functional fixture values are kept; the maintainer triages each match per
# the structural-vs-narrative distinction in the Exceptions section)
grep -rEn "UAT-[0-9]{3}" \
  .claude/skills/ .claude/commands/ .claude/agents/ .claude/rules/ .claude/hooks/ \
  .specify/extensions/gaia/README.md .specify/extensions/gaia/commands/ \
  .specify/extensions/gaia/lib/ .specify/extensions/gaia/rules/ \
  .specify/extensions/gaia/templates/

# Concrete maintainer SPEC IDs in instruction files and shipped extension surfaces
grep -rEn "\bSPEC-[0-9]{3,}\b" \
  .claude/skills/ .claude/commands/ .claude/agents/ .claude/rules/ .claude/hooks/ \
  .specify/extensions/gaia/README.md .specify/extensions/gaia/commands/ \
  .specify/extensions/gaia/lib/ .specify/extensions/gaia/rules/ \
  .specify/extensions/gaia/templates/

# Historical-style phrasing in wiki body prose
# `set` is matched by its own `previously set` alternative rather than from
# inside the group: the env-dump guard (.claude/hooks/block-env-read.sh) splits
# a command on |&;() and evaluates each fragment, so a lone `set` between pipes
# reads as a bare `set` command and the whole grep is denied.
grep -rEn "\bchanged from|was changed|previously (did|was|stated|had|used)|previously set|as of [0-9]{4}|in PR #?[0-9]+|in commit [a-f0-9]{6,}" wiki/ --include="*.md" --exclude="log.md" --exclude="hot.md" --exclude-dir="meta"
```

Any non-empty match outside this rule's prose is a candidate for rewrite. The narrative-vs-structural triage for the `.claude/` / `.specify/` greps is a human read, the regex flags candidates; the Exceptions section above codifies what stays.
