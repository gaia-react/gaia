# 31-release-exclusion-bullet-lists-five-of-ten

**Path**: `.claude/rules/maintainers/github-workflow-distribution.md`
**Line**: 44

## Title

The "maintainer-only, release-excluded, no template" bullet names five workflows, the
exclude file excludes ten, and the bullet carries no marker that it is naming a sample.

## Failure mode

The bullet reads as the roster of maintainer-only workflows: five names, no "e.g.", no
"among others", nothing that tells a reader it is partial. The release-exclude file's
own category for these workflows carries ten entries. A maintainer auditing whether a
workflow needs a shipped template opens this rule, finds the workflow absent from the
bullet, and concludes it is a shipped one that owes a template. The five it names are
correct, which is what makes the sentence read as authoritative rather than illustrative.

## Verified by

Listed the entries under the relevant category of `.gaia/release-exclude` at HEAD and
diffed them against the names in the bullet: five present, five absent. Confirmed the
bullet carries no hedge token by reading the full sentence.

## Suggested fix

Either name all ten, or replace the literal names with a pointer to the exclude file's
category so the rule reads the roster rather than restating part of it.
