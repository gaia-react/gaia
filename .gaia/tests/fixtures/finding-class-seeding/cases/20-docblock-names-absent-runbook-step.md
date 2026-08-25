# 20-docblock-names-absent-runbook-step

**Path**: `.gaia/cli/src/release/bump.ts`
**Line**: 1

## Title

The module docblock tells the reader to see step 7 of a runbook whose steps stop at
five.

## Failure mode

The docblock opens with "runs step 7 of the release runbook", and the runbook it names
carries five numbered steps. A maintainer reading this file to learn where it sits in
the release sequence goes to the runbook, finds no seventh step, and has nothing to
read: the sentence supplies a coordinate into a document that has no such coordinate,
so it locates the module nowhere.

## Verified by

Opened the cited runbook and counted its numbered steps: five, the last of which is the
tag push. No section, heading, or list item in that document is numbered seven.

## Suggested fix

Cite the step by its name rather than its position, or say what the module does in the
release sequence without a coordinate into another document.
