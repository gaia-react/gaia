# 13-duplicated-gate-command-text

**Path**: `.claude/skills/gaia/references/debt.md`
**Line**: 51

## Title

The debt skill's quality-gate description has drifted out of step with the quality-gate
rule it copies.

## Failure mode

This page restates the quality-gate command as `"pnpm typecheck && pnpm lint"` in its
own prose, duplicating (rather than pointing at) the same sentence in
`.claude/rules/quality-gate.md`. The rule page was later edited to add a third command
to the sequence for a maintainer-only surface; this page's copy was never updated and
still lists only the original two.

## Verified by

Diffed this page's quality-gate sentence against the current text of
`.claude/rules/quality-gate.md`; the two no longer agree on the command sequence.

## Suggested fix

Replace the duplicated sentence with a pointer to `.claude/rules/quality-gate.md`
rather than restating its content, so the two can't drift apart again.
