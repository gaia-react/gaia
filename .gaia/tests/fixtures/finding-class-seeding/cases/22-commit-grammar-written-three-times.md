# 22-commit-grammar-written-three-times

**Path**: `.gaia/cli/src/wiki/commit-classify.ts`
**Line**: 34

## Title

The conventional-commit subject grammar is written out separately in three CLI modules.

## Failure mode

The regular expression that splits a commit subject into type, optional scope, and
description appears here, again in the release bump module, and again in the changelog
generator. Each was typed independently; two of the three already accept a scope
containing a slash and the third does not. Nothing imports one from another, so adding
a commit type means editing three literals, and the module nobody remembers to edit
keeps classifying against the older grammar while its own tests stay green.

## Verified by

Grepped the CLI source for the subject-splitting pattern, found three separate literals,
and confirmed by reading each that they disagree today on whether a slash may appear in
the scope.

## Suggested fix

Export the pattern once from a shared module and import it at all three sites, so the
grammar has a single definition and one place to extend.
