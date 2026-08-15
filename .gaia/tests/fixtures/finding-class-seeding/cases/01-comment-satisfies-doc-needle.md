# 01-comment-satisfies-doc-needle

**Path**: `.gaia/tests/lib/doc-isolation.bats`
**Line**: 142

## Title

A bats assertion's grep needle also matches inside an HTML comment, so deleting the
instruction it pins leaves the suite green.

## Failure mode

The suite asserts a worktree-isolation instruction is present by running
`grep -q "runs in an isolated worktree per phase" <file>`. The same file carries an
HTML comment two lines above the real sentence that also contains that exact phrase,
left over from an earlier draft note. Deleting the real instruction sentence while
leaving the comment in place still satisfies the grep, so the suite reports green over
a file that no longer carries the instruction it is supposed to guard.

## Verified by

Manually deleted the instruction sentence, left the comment untouched, and reran the
suite; the relevant `@test` still passed.

## Suggested fix

Anchor the grep to the instruction's own markdown structure (require the phrase inside
a non-comment line under its specific heading) rather than a bare substring match
anywhere in the file, or strip HTML comments before grepping.
