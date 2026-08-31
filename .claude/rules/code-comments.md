---
paths:
  - 'app/**/*.{ts,tsx,js,jsx,css}'
  - 'test/**/*.{ts,tsx}'
  - '.playwright/**/*.ts'
  - '.storybook/**/*.{ts,tsx}'
  - '.gaia/**/*.ts'
  - '.gaia/**/*.sh'
  - '.claude/hooks/**/*.sh'
  - '.github/**/*.sh'
  - '.specify/extensions/gaia/lib/**/*.sh'
  - '**/*.bats'
---

# Code Comments

Default to no comment. Write one only when it passes this test:

> **A comment must be about something the file does not make legible.**

A test of subject, not length. A thirty-line comment about a platform quirk earns every one of its lines; a three-line docblock naming the symbol below it earns none. So this rule compresses a comment toward its subject, it never suppresses one: cutting a comment until it is cryptic, or dropping a fact that deserves to survive because the block looked long, fails this rule rather than satisfying it.

## Earns its place

- **The reason a value has the value it has.** The code pins the value, nothing pins the reason. Timeouts, retry counts, thresholds, cache TTLs, debounce intervals, page sizes.
- **A why-not.** An obvious simpler approach, and the specific way it fails here.
- **The contract with the _other_ file.** What fires this code, what shape of input arrives, what a return value or exit code means to the caller. The cross-file half only: a file's own usage and output shape are recoverable by reading it.
- **A platform or version quirk.** A shell version difference, a BSD-vs-GNU tool difference, a language-spec fact, a third-party SDK side effect.
- **An honest limit of a check.** What a guard does not catch, and why that is the safe direction to fail in.
- **An invariant that spans the file.** An ordering or lifecycle rule no single site can state and no test proves.

## Earns nothing

- Restating the line, the signature, or the check below it. The code is the durable form; the copy decays.
- A header re-narrating the implementation sites below, or the same paragraph repeated at each site.
- A banner over a single item, and ASCII section rules (`// ─── Types ───`). A banner over a group is navigation and stays.
- The ceremonial opener: a first line assembled from the filename's own tokens and saying nothing else.
- Historical narration: "used to do X, now does Y", "added in PR #123", "as of <date>". Git carries this. A `#NNN` paired with the failure mode it names is a different subject; `## Issue and PR references` rules it.
- A number used as justification that nothing in the repo can reproduce.

## Name less, explain more

Be far harder on a comment that NAMES a thing than on one that EXPLAINS a thing. Explanations age well. Pointers do not, because the file, symbol, or ticket a comment names gets renamed or deleted while the comment stays behind still naming it. A name in a comment carries a maintenance obligation that the reasoning around it does not.

Pointing at a rule stays allowed. Copying a rule's content into a comment does not, because the copy drifts from the rule.

## Counts

<!-- gaia-harden: promoted from recurring finding_class holistic/stale-figure; pruned by /gaia-audit on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->

A bare count is a name for a set, and it decays the way a name does: the set grows, nothing recounts, and the number becomes a false claim a reader trusts precisely because it is specific. "Six subcommands", "the three exit codes", "all four members", in a docblock, a file header, or a bats `@test` name.

Prefer the set to its cardinality. The enumeration is almost always adjacent, so name the members or point at what holds them and let the reader count. A number earns its place only when it says something the enumeration beside it does not.

Where the number does carry the claim, it needs something that recounts it: a test asserting the cardinality against the live set, or a check that fails when the two disagree. That makes the number self-correcting. A count with neither is an assertion nobody is keeping, and correcting a stale one without adding the recount restarts the same decay from a fresher number.

<!-- gaia:maintainer-only:start -->
GAIA maintainers: part of this is gated rather than merely asserted. `.gaia/scripts/lint-stale-cardinals.sh` reds on a **definite** cardinal of at least three standing against a repository-artifact noun, in a full-line comment or a bats `@test` name, across every tracked `*.sh` and `*.bats`; `.gaia/tests/shell-lint.sh` folds it in, so it runs on every pull request. The script's own header owns what it reaches and what it does not, and it is the authority rather than this paragraph. What it deliberately leaves to a reader: a bare cardinal with no determiner, a possessive noun phrase, a noun outside its closed vocabulary, and Markdown, which in this repo is dominated by dated frozen records where a cardinal is a true statement about the tree as it was. A clean gate is therefore not a clean tree, and the rule above still governs the counts the gate cannot see.
<!-- gaia:maintainer-only:end -->


## Editing an existing comment

- **Never truncate a pointer to a bare unresolvable id.** Delete the line instead. A bare id keeps the maintenance obligation and discards the meaning, which is strictly worse than saying nothing.
- **Before deleting a name, grep the rest of the file for it.** A correct deletion can orphan a cross-reference elsewhere in the same file, and no test run, diff check, or type check detects it.

## Exported symbols

A single-line summary earns its place on an exported function, hook, type, or constant even when the implementation is self-evident, because it reaches callers who never open the file. One line, not a paragraph.

No `@param` or `@returns` restating the signature. Types say it, the editor shows it, and the tag rots independently of the parameter it names. Use a tag only for what the type cannot: a unit, an ownership transfer, a mutation.

A wrong doc comment on an exported symbol displays at every call site, so exported-symbol docs get the **highest** scrutiny, not an exemption from it.

## Comments that are not commentary

Linter and type-checker directives, test-environment and editor pragmas, generated-region and codegen markers, and version glosses a bot writes and a test parses. If anything in the repo parses it, it is data wearing comment syntax. Never judge it on worthiness and never reword it: editing or deleting one changes behavior.

## Issue and PR references

`#NNN` names an issue or a pull request out of one shared number space; the discriminator is the surrounding prose, never the number's kind. Judge any one of them by striking the number:

1. Remove the `#NNN` and read what is left, together with its enclosing comment block: the maximal run of consecutive comment lines holding the reference, plus the single code line it annotates. Nothing further.
2. If what remains still names what breaks, what the guard prevents, or what the test pins, the reference is **paired**, and the remedy is none. It stays; on a file an adopter receives it stays in the qualified form below, which is still a keep rather than a byte-identical line.
3. If what remains says nothing a reader can act on, the reference is **unpaired**, and the remedy is one of three: restore the failure mode to the comment; drop the number and keep the text that stands on its own; or, where the number is a grammatical constituent of the sentence, rewrite the sentence so the claim stands without the citation. Never leave a bare id behind and never truncate a comment down to one. Delete the whole line only when nothing stands once the number is gone.

A sentence whose only claim is when the code arrived, or by whose hand, is **provenance**, and its remedy is to lose that sentence while the block keeps its explanation. A reference is judged by what the surrounding comment asserts in the present tense, so provenance goes even when the block around it earns its place. A regression pin is not provenance: it states a present-tense hazard the code exists to prevent, and cites where that hazard was first observed.

The verdict is decidable from the block alone, with no issue tracker, no git history, and no second reader. The remedy is not. Restoring a failure mode may take reading the issue, so the offline default is to drop the number or rewrite the sentence rather than guess at a hazard.

A bats `@test` name takes the same test a comment takes: one pairing a number with a behavioural description passes and stays as written, an unpaired one does not. A `#NNN` inside data the repo parses is not a comment at all, and `## Comments that are not commentary` governs it instead.

On a file an adopter receives, write the reference as `gaia-react/gaia#NNN`, so it names the repository the number belongs to rather than the reader's own. That obligation is a property of the file rather than of comment syntax, so it reaches comments, test names, and user-facing message strings alike, while the strike-the-number test governs comments only. It is scoped to shipped files that are not Markdown, because Markdown spends `#` on headings and on quoted counter-examples, where a whole-file scan reads as noise. On a release-excluded file the unqualified `#NNN` stays: no reader there can be misled about whose issue it is.

Worked examples:

- **paired** — `never seen, so a status posted there 422s and never lands (gaia-react/gaia#726)`
- **paired** — `Invariant 7: every tracked path resolves an owner (#1245)`
- **paired** — `forbidden from adding one, that is option A, ruled out in #1053`
- **unpaired**, the number a grammatical constituent, so the remedy is a rewrite — `Verified against two Sonnet-5-only ledger records; #1088 must not disturb it.`
- **provenance**, a clause claiming only when the rows arrived — ``No stored `unpriced` at all, which is every row written before #1088 landed``
- **unpaired**, and dropping the number leaves a title that stands — ``Tests for `.gaia/scripts/verify-required-checks.sh` (#807)``

<!-- gaia:maintainer-only:start -->
## Audit

GAIA maintainers: the audit is maintainer-only because the obligation it enforces is GAIA's own. On an adopter clone a `#NNN` in a file they edited means their tracker, so a gate demanding the `gaia-react/gaia` form there would be wrong, and both the gate and its runners are release-excluded for that reason.

Every reference on a shipped non-Markdown file names its repository. One command is the gate, silent on a conforming tree and reporting `file:line` the moment an unqualified reference returns:

```bash
bash .gaia/scripts/lint-shipped-issue-refs.sh
```

That script is the gate rather than a command transcribed here, so the rule and the thing enforcing it cannot drift apart. It derives its file set from `.gaia/manifest.json`, skips Markdown and binary assets, and exempts a CSS short hex colour (`#333` is both a valid issue number and a valid colour); the script's own header states the exemption's accepted miss. `Distribution Audit` runs it on every pull request, and `.gaia/scripts/tests/lint-shipped-issue-refs.bats` proves it reds on a regression and pins the release-boundary split the next paragraph states in prose.

The grep below is a candidate list, not a gate. It surfaces qualified and unqualified references alike and asserts no silence, so a human triages its output at block level, where any non-empty match is a candidate for a verdict rather than a finding. The strike-the-number test applies on all four surfaces it sweeps. The qualification obligation applies to the shipped half only: the shipped `.claude/hooks/` scripts, and the shipped `.github/**` helper scripts under `.github/audit/` and `.github/actions/**/lib/`. `.gaia/tests/`, `.gaia/scripts/tests/`, and `.github/audit/tests/` are release-excluded and exempt from it, as are the release-excluded workflows. Neither comment rule's activation globs reach a `.yml`, so neither auto-loads on one, but the gate does reach every `.yml` the manifest ships, workflows and composite actions and issue templates alike. `.github/workflows/code-review-audit.yml` is absent from the manifest because it is regenerated from a shipped CLI template the gate already covers.

```bash
grep -rnE '((^|[^A-Za-z0-9_/#-])|gaia-react/gaia)#[0-9]{2,4}([^0-9A-Fa-f]|$)' \
  .gaia/tests/ .gaia/scripts/tests/ .github/audit/tests/ .claude/hooks/
```
<!-- gaia:maintainer-only:end -->
