# 08-marker-digest-empty-skip

**Path**: `.gaia/cli/src/harden/marker.ts`
**Line**: 41

## Title

The marker-freshness check only runs when the owning member's remit resolves at least
one file.

## Failure mode

`isMarkerFresh` computes a content digest over the member's remit-matched files and
compares it against the stored marker, but the comparison sits inside
`if (files.length > 0) { ... }`. When `files` is empty (for instance, right after a
member's last owned file is deleted or renamed out of its globs), the function returns
`true` unconditionally rather than evaluating freshness, so a stale marker from before
the rename is treated as fresh with no comparison performed at all.

## Verified by

Constructed a case where a member's remit resolves to zero files and confirmed
`isMarkerFresh` returns `true` regardless of the stored marker's age or content.

## Suggested fix

Treat an empty file set as a digest of the empty set (a fixed, well-defined hash) and
compare it against the stored marker like any other case, rather than short-circuiting
past the comparison.
