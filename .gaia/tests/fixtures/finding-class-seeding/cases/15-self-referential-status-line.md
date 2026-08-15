# 15-self-referential-status-line

**Path**: `.claude/skills/gaia/references/fitness.md`
**Line**: 8

## Title

A status line describes the skill's own coverage in the past tense, ahead of a change
that widened it.

## Failure mode

The page opens with "this check previously covered only the hooks directory." The
check's scope was widened to cover the settings file as well, but the sentence still
frames the earlier, narrower scope as if it were a fact about history rather than
stating the current scope directly, leaving a reader unsure whether "previously" means
the sentence has since been corrected or is describing an ongoing limitation.

## Verified by

Compared the sentence against the check's current implementation, which covers both
the hooks directory and the settings file.

## Suggested fix

State the current scope directly ("this check covers the hooks directory and the
settings file") rather than narrating what it used to cover.
