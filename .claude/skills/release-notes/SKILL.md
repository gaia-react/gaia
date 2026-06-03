---
name: release-notes
description: Maintainer-only. Translate a version's GAIA CHANGELOG entries into plain-language public release notes for the marketing site (gaiareact.com). Writes a release-data `.ts` file under `../website/src/pages/changelog/releases/` plus an editorial-decisions report for human review. Use whenever the maintainer wants the adopter-facing notes for a version, e.g. "write release notes", "generate the changelog page entry", "translate the CHANGELOG for the website", "what's new on the site for v1.5.0", "public notes for 1.4.0", or right after cutting a release, and for one-time backfill of historical `## [x.y.z]` blocks. This is the website-notes step only. It does NOT edit `CHANGELOG.md`, it is not how you cut a release (version bump, manifest, and tag are `/gaia-release`), and it is not for an adopter's own app's release notes.
---

# release-notes

Translate one version's CHANGELOG entries into adopter-facing release notes. The CHANGELOG is written for GAIA's own contributors: terse, imperative, full of internal mechanics and PR numbers. Adopters read the website. They don't care that an ADR was reframed or a memory was promoted; they care what GAIA now does for *their* project. This skill is the translation layer between the two audiences.

**Maintainer-only.** Adopters never release GAIA, so this skill ships nowhere — it's excluded from the distribution tarball by `.gaia/release-exclude` (category 1), the same as `/gaia-release`. It pairs with `/gaia-release` but runs independently: you can point it at the `[Unreleased]` block while cutting a release, or at any historical `## [x.y.z]` block to backfill the website.

**It never edits `CHANGELOG.md`.** The changelog stays technical and precise — that's its job. This skill only *reads* it.

## Inputs

Invocation carries a target version, e.g. `release-notes 1.4.0` (no leading `v`). Resolve which CHANGELOG block to translate, and where the date comes from, by that version:

- **Graduated / historical** — `CHANGELOG.md` contains `## [<version>] — <YYYY-MM-DD>`. Translate that block. Take `version` and `date` **verbatim from the header**. The release already happened on that date; the shell clock is irrelevant.
- **Live cut** — the version isn't graduated yet; its entries live under `## [Unreleased]`. Translate that block. `version` is the argument (the maintainer is cutting it now). `date` is **today from the shell clock** (`date +%F`).

If no version was supplied and an `[Unreleased]` block exists, ask the maintainer which version is being cut — the version label has to come from a human, not a guess.

### The date is never yours to invent

Whether historical or live, the date comes from the CHANGELOG header or the shell — **never** from your own notion of "today." Models routinely misdate by months; a wrong `date` silently ships a wrong timeline to every visitor. For a live cut, run `date +%F` and use exactly that. This is the same discipline GAIA enforces for wiki playbook dates.

## Output (a): the release data file

Write to `../website/src/pages/changelog/releases/<version>.ts` (version with no leading `v`; `mkdir -p` the directory if it's missing). The changelog page auto-discovers every file via `import.meta.glob('../releases/*.ts')` and sorts by version, so **dropping the file in is all that's needed** — there's no index or import list to update.

**The schema lives in `../website/src/pages/changelog/types.ts` (the `Release` type) — read it as the source of truth before writing.** As of this writing it is:

```ts
export type Release = {
  added?: string[]; // "New"
  date: string; // ISO yyyy-mm-dd
  fixed?: string[]; // "Fixed"
  headline?: string;
  improved?: string[]; // "Improved"
  summary?: string; // freeform fallback for legacy/coarse entries
  version: string; // semver, no leading 'v'
};
```

**Match the file form of the existing release files — don't trust this skill's literal shape.** The website's convention drifts (export style and key order have both changed). Before writing, open the newest `releases/*.ts` and mirror it exactly: `types.ts` gives you the *fields*, a live sibling file gives you the *serialization*. Today that form is a bare default export with keys in **alphabetical order** (the formatter sorts them). Omit any optional key with no content:

```ts
export default {
  added: ['...'],
  date: '2026-06-02',
  fixed: ['...'],
  headline: 'A short title or one plain sentence.',
  improved: ['...'],
  version: '1.4.0',
};
```

- `added` → "New" (capabilities that didn't exist before). `improved` → "Improved" (changed/enhanced behavior). `fixed` → "Fixed".
- `headline` — optional. A short title or one plain sentence, leading with the release's reason to exist. Skip it only if the release is a grab-bag with no single story. For a newly-shipped capability, carry the rule 1 `now` into the headline too — "GAIA apps now ship with a CSP", not "ship with".
- `summary` vs buckets — **mutually exclusive.** The renderer shows `summary` as a single paragraph *instead of* the `added`/`improved`/`fixed` lists. The choice is driven by **how many distinct adopter-facing items survive the cut — not by the release's age or whether it's a backfill.** Use **buckets** whenever one or more itemizable adopter-facing changes remain; each lands as its own bullet under New/Improved/Fixed. Reserve `summary` for: (1) an **internal-only** release where every change was dropped as maintainer plumbing — a one-line "no adopter-facing changes" note (e.g. "Internal release-tooling fixes. No change to how GAIA apps behave."); (2) a genuine **one-sentence** story; or (3) a broad **inaugural / overview** release where a narrative reads better than a long list (the `1.0.0` entry). **Never mash two or more distinct items into one summary paragraph — if it can be two bullets, use buckets.** Never set both.
- Bullet strings are markdown-lite: inline code in backticks, links as `[text](url)` (rendered as a new-tab link). PR links (`https://github.com/gaia-react/gaia/pull/NNN`) are *optional* — include one only when a reader would genuinely follow it for detail, never as decoration. The exemplars below omit them.

## Output (b): the editorial-decisions report

After writing the file, print a report to the terminal (don't write a file — this is a human gate the maintainer reads before accepting the notes). It makes your editorial judgment auditable. Use this structure:

```
## Release notes — v<version> (<date>)

Wrote ../website/src/pages/changelog/releases/<version>.ts

**Dropped** (with reason)
- <changelog line> — <why: pure-internal / housekeeping / docs-only>

**Consolidated**
- <N changelog lines about X> → one <bucket> item

**Needs a human ruling** (ambiguous actor — see rule 6)
- <line> — feature or housekeeping? <why it's ambiguous>
```

Omit a section if it's empty. Never drop something silently: if it didn't make the notes, it appears under Dropped or Needs a human ruling.

## The translation contract

This is the substance of the skill — the rules that turn a contributor's changelog into an adopter's release notes.

1. **Restate at capability/impact altitude, with a concrete subject.** Name the component the adopter touches — CI, Code Review Audit, `/update-gaia`, the quality gate. "what changed and what it means for me," not "which function moved." Avoid vague subjects — "the app", "the system", "the tooling", "things" read as placeholders. The scaffolded React app is **GAIA apps** (apps built from the template); effects on the developer's own code or files are **your …** (your utility classes, your `package.json`). So "the app ships with a CSP" becomes "GAIA apps now ship with a CSP."
2. **Be more specific, not less.** Plain language is not vague language. One dense technical line often *splits* into two clear ones. Resist the urge to compress meaning out.
3. **Ban filler.** No "improved performance," "various fixes," "enhanced reliability," "general improvements." If you write "optimized," say optimized *what* and the *observable result*. A bullet a reader can't act on or verify is noise. Don't restate the semver tier either: a "Patch release" / "Minor release" / "Major release" lead is redundant with the version number, which already conveys it. Descriptive framing ("Maintenance release", "Security release") is fine.
4. **Drop changes with no adopter relevance — judge by relevance, not residence.** The test is whether an adopter *building their own product* would notice or benefit, not whether the changed file physically ships to their machine. A hook, guard, or workflow can ship to every adopter and still be maintainer-only in effect. Drop: ADR reframes, leak-check tweaks, internal status stamping, test-harness changes, docs-only edits, and fixes to GAIA's *own* development and release plumbing — sibling-repo push handling, release lockstep, contributor-only guard edge cases. The adopter's product behaves identically with or without them. Trap: "strip surrounding quotes from literal `git -C` captures so a quoted sibling-repo push is recognized as foreign" ships inside an adopter hook, yet only fires when *you* push across GAIA's own sibling repos during a release — drop it. (Contrast: GAIA CI / Code Review Audit that an adopter opts into via `/setup-gaia-ci` *is* adopter-facing — residence aside, an adopter who runs it sees the benefit, so keep it.)
5. **Drop maintainer housekeeping on GAIA's own repo/wiki.** Promoting memories, reorganizing the wiki, dated audit artifacts, version-stamp bumps. These change GAIA's *own* state, not what GAIA *does* for an adopter.
6. **Flag ambiguous actors — don't guess.** Imperative/passive changelog voice often hides the subject. "promote machine-local feedback memories into shared wiki" *reads* like a feature ("GAIA now promotes memories") but was the maintainer running `/gaia-audit` on GAIA's own wiki — housekeeping, drop it. When a line could mean "GAIA now does X" (keep) or "I did X to the repo" (drop) and the voice won't tell you which, put it under **Needs a human ruling** rather than picking. Guessing wrong either invents a feature or buries a real one.
7. **Consolidate scattered lines about one subject.** Four CI / Code-Review-Audit lines describing one coherent change become one item. The adopter wants the story, not the commit-by-commit trail.
8. **Keep breaking changes and migrations — plainly framed, with a pointer.** Plain does not mean painless. State the breakage in adopter terms, then point to the exact steps: "See the full changelog for exact steps" (or link the entry). Dropping the scary part to sound friendly is the one unforgivable edit.
9. **House style: no em-dashes, present tense.** Use colons, commas, periods. The raw CHANGELOG violates both freely (em-dashes everywhere, "was changed from"), so never pipe a line through verbatim — always rewrite.
10. **Bucket mapping.** `### Added` → `added` ("New"). `### Changed` → `improved` ("Improved"). `### Fixed` → `fixed` ("Fixed"). A `**BREAKING:**` or **Migration** sub-bullet stays in whatever bucket its parent lives in (usually `improved`).

## Worked exemplars

These are the calibration. Study how dense, internal-sounding changelog blocks collapse into a few adopter-meaningful bullets — and what gets cut. They show the *editorial result* and house style; take the literal export form and key order from a live `releases/*.ts` (see Output (a)), since the convention drifts.

### `1.3.5` — seven Added, five Changed, four Fixed → two / three / one

```ts
export default {
  added: [
    'Dependency supply-chain hardening: new package versions are quarantined for 7 days before GAIA installs them, and downgrades are blocked, defending against a compromised fresh release.',
    'GAIA apps now ship with a Content-Security-Policy that restricts which scripts can run, hardening them against script injection.',
  ],
  date: '2026-06-02',
  fixed: [
    "`Form/Chain` merges class names with `twMerge`, so your utility classes override the component's defaults instead of conflicting with them.",
  ],
  headline: 'Faster, cheaper CI and a hardened dependency supply chain.',
  improved: [
    'Code Review Audit on CI is now opt-in and installs on demand. When it runs, it only audits changes since the last green run instead of the whole codebase, so CI is faster and cheaper.',
    'React Router v8 future flags are enabled so your app is ready for the v8 upgrade early. One flag (`v8_passThroughRequests`) changes how loaders and actions receive the request: if you have customized `app/root.tsx`, a small migration is needed. See the full changelog for exact steps.',
    'Kickoff prompts print to the terminal instead of silently copying to your clipboard.',
  ],
  version: '1.3.5',
};
```

Report for `1.3.5`:

```
**Dropped** (with reason)
- stamp GAIA-Audit status on out-of-scope skips — internal status stamping, no adopter effect
- clarify the gate owns formatting; make PR merge marker-first — internal workflow mechanics
- document useDebounce return semantics — docs-only
- detect orphaned wiki drift in preflight via suggested_base — internal release tooling
- recover the un-evaluated window on sync re-anchor — internal wiki-sync mechanics
- gaia-release updates softwareVersion — maintainer-only release tooling

**Consolidated**
- four Code Review Audit / CI lines (install on demand, honor both tokens, gate on since-last-green delta, incremental scope, opt-in) → one "Improved" item
- two pnpm supply-chain lines (minimumReleaseAge quarantine, no-downgrade trustPolicy) → one "New" item
```

### `1.4.0` — note the `#270` housekeeping drop (rules 5/6)

```ts
export default {
  date: '2026-06-02',
  fixed: [
    '`/update-gaia` no longer re-adds files you intentionally deleted.',
    '`/update-gaia` only raises conflicts for files that actually changed in the release, instead of flooding you with spurious patches.',
    'Wiki entries take their dates from your system clock instead of the model, so timestamps are always correct.',
  ],
  headline: '`/update-gaia` stops fighting you over your own files.',
  version: '1.4.0',
};
```

Report for `1.4.0`:

```
**Dropped** (with reason)
- promote machine-local feedback memories into shared wiki (#270) — reads like a feature but was the maintainer running /gaia-audit, a content action on GAIA's own wiki, not adopter-visible behavior (rule 5/6)
```

The `#270` trap is the whole point of rule 6: under `### Changed`, in imperative voice, it looks exactly like a shipped capability. It isn't. When the voice hides the subject and you can't resolve it from context, surface it under "Needs a human ruling" instead of dropping or keeping on instinct.

### When `summary` fits — internal-only or one-line releases

A release with no distinct adopter-facing items left after the cut — an internal-only patch where everything was dropped as maintainer plumbing, or a genuinely one-sentence story — collapses to a single `summary` paragraph. This is about item count, not age: a backfilled old release with two real adopter changes still earns buckets. The shape, for an internal-only patch like `1.1.1`:

```ts
export default {
  date: '2026-05-11',
  headline: 'GAIA release fixes',
  summary:
    'Fix to the gaia-release maintainer reference, plus follow-ups from live init runs.',
  version: '1.1.1',
};
```

Use this only for an internal-only release or a genuinely one-line story. Anything with two or more distinct adopter-facing changes earns buckets — backfill or not.

## Workflow

1. Resolve the version → block → date (Inputs above). For a live cut, run `date +%F` now.
2. Read `../website/src/pages/changelog/types.ts` for the current `Release` fields and the newest `releases/*.ts` for the current file form (export style + key order). Then read the version's block from `CHANGELOG.md`. Classify every line: keep, drop (rule 4/5), consolidate-with-siblings (rule 7), or ambiguous (rule 6).
3. Translate the kept lines through the contract. Group by bucket (rule 10). Merge consolidations.
4. Draft a `headline` if the release has a single story; otherwise omit it. For a coarse backfill with no bucket-worthy detail, write a `summary` paragraph instead of buckets.
5. Assemble the `.ts` in the exact form of the file you read in step 2 (today: bare default export, keys alphabetical). Omit empty optional keys. Sweep for em-dashes and banned filler before writing (rule 3/9).
6. `mkdir -p ../website/src/pages/changelog/releases` and write `<version>.ts`. No index to update — the page globs the directory.
7. Print the editorial-decisions report. Every changelog line that didn't survive appears under Dropped or Needs a human ruling — no silent cuts.

## See

- `.claude/commands/gaia-release.md` — the release process this feeds; Step 14 already locksteps other website version sites.
- `CHANGELOG.md` — the source. Read-only. Never edited here.
- `eval/probe.py` — trigger-boundary validation harness (maintainer-only, excluded from the tarball). After editing the frontmatter `description`, re-run `python3 .claude/skills/release-notes/eval/probe.py --runs 3` to confirm the boundary still holds (target: 100% recall, 0% false-positive). Options in its docstring.
