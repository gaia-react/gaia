---
type: skill
status: active
description: Maintainer-only. Translate a version's GAIA CHANGELOG entries into plain-language public release notes for the marketing site.
---

# Release Notes

Maintainer-only skill that translates a version's CHANGELOG entries into adopter-facing public release notes for gaiareact.com.

## Purpose

The CHANGELOG is written for GAIA's own contributors: terse, imperative, full of internal mechanics and PR numbers. Adopters reading the website care what GAIA now does for their project, not internal implementation details.

## Outputs

1. **Release data file** — a `.ts` file under `../website/src/pages/changelog/releases/<version>.ts` following the `Release` type schema. The changelog page auto-discovers these files and sorts by version.

2. **Editorial-decisions report** — printed to terminal, auditing which CHANGELOG lines were dropped, consolidated, or flagged as ambiguous. Never silent cuts.

## Key rules

- **Restate at adopter impact altitude.** Name the component adopters touch — CI, Code Review Audit, `/update-gaia`. "What changed and what it means for me," not "which function moved."
- **Drop changes with no adopter relevance.** Test: would an adopter building their own product notice or benefit? Drop ADR reframes, internal wiki work, maintainer-only tooling, and docs-only edits.
- **Flag ambiguous actors, don't guess.** When a CHANGELOG line could mean "GAIA now does X" (keep) or "I did X to the repo" (drop), surface it under "Needs a human ruling."
- **Consolidate scattered lines about one subject** into one bullet per adopter-facing change.
- **Keep breaking changes plainly framed** with a pointer to exact steps.
- **House style:** no em-dashes, present tense, no filler words like "improved performance" without specifics.

## Invocation

`release-notes <version>` (e.g. `release-notes 1.4.0`, no leading `v`). Resolves which CHANGELOG block to translate (graduated `## [x.y.z]` or `[Unreleased]`) and derives the date from the block header or system clock.

## Workflow

1. Resolve version → block → date. For a live cut, run `date +%F`.
2. Read `../website/src/pages/changelog/types.ts` for current fields and the newest `releases/*.ts` for current file form. Read the version's block from `CHANGELOG.md`.
3. Classify every line: keep, drop (rule category), consolidate-with-siblings, or ambiguous.
4. Translate kept lines through the contract. Group by bucket (Added / Improved / Fixed). Omit empty optional keys.
5. Write the `.ts` in exact form of the reference file (today: bare default export, keys alphabetical).
6. Print the editorial-decisions report — no silent cuts.

## Relation to other skills

- **Not `/gaia-release`** — that cuts the release itself (version bump, manifest, tag). This translates CHANGELOG for the website.
- **Not for adopters' own release notes** — only for GAIA public notes on gaiareact.com.
- **Excludes from distribution tarball** — maintainers only, like `/gaia-release`.
