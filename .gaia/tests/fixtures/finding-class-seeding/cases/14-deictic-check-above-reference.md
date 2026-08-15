# 14-deictic-check-above-reference

**Path**: `.claude/skills/gaia/references/isolation.md`
**Line**: 33

## Title

A step references "the check above" across a section break that no longer places any
check directly above it.

## Failure mode

A later step on this page says "if the check above fails, stop before making any
edits." An earlier reorganization inserted a new subsection between the referenced
check and this sentence, so "the check above" now points at unrelated prose about
worktree naming rather than the check the sentence means. A reader following the page
in order lands on the wrong referent.

## Verified by

Read the page top to bottom and confirmed the content immediately preceding the
sentence is the worktree-naming subsection, not the check the sentence describes.

## Suggested fix

Name the check by its heading or label instead of a positional reference, so a later
reorganization can't silently change what the sentence points at.
