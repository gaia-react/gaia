# 06-decline-field-count-docblock

**Path**: `.gaia/cli/src/schemas/decline-ledger.ts`
**Line**: 6

## Title

A docblock says six fields are recorded per decline entry; the type literal below
defines seven.

## Failure mode

The module docblock above the decline-entry type states "Six fields are recorded per
decline: the class, the reason, the actor, the timestamp, the PR number, and the
margin." The type literal immediately below carries a seventh field (a `window_start`
timestamp) added later without updating the docblock's count or its list.

## Verified by

Counted the type literal's own keys against the docblock's stated list: seven keys,
docblock names six.

## Suggested fix

Update the docblock's count and list to name all seven fields, or drop the enumeration
and describe the shape by pointing at the type itself.
