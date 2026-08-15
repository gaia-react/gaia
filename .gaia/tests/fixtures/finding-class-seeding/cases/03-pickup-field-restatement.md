# 03-pickup-field-restatement

**Path**: `.claude/skills/gaia/references/pickup.md`
**Line**: 24

## Title

The pickup skill's resume-point description names a `wiki/hot.md` field the pickup
logic no longer reads.

## Failure mode

The page states that the pickup flow "reads `wiki/hot.md`'s `Last touched` field to
decide the resume point." The pickup flow instead resolves the newest file under
`.gaia/local/handoffs/` and never opens `wiki/hot.md` at all. A maintainer who edits
`wiki/hot.md`'s `Last touched` field expecting it to steer the next resume run changes
a value the flow never consults.

## Verified by

Traced the pickup flow's file reads; the only handoff-resolution read is under
`.gaia/local/handoffs/`, and no read touches `wiki/hot.md`.

## Suggested fix

Rewrite the sentence to name the file the flow actually reads, or drop the specific
mechanism and describe only the observable behavior.
