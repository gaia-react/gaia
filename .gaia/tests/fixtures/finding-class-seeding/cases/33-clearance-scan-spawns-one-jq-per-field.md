# 33-clearance-scan-spawns-one-jq-per-field

**Path**: `.gaia/scripts/resolve-audit-spawn.sh`
**Line**: 208

## Title

The clearance scan starts a separate `jq` for each field of each marker, and the
resolver runs the scan twice per invocation.

## Failure mode

`clearance_scan` loops over the marker store and, inside the loop, reads five fields
with five separate `jq -r` calls against the same JSON document. At the 54 markers
currently on disk that is roughly 270 process spawns, measured at 1.29s per scan, and
the resolver calls the scan twice in one invocation. The result is identical to what one
`jq -r '[...] | @tsv'` per document returns; every extra spawn is process startup and a
re-parse of a document already parsed. The cost grows linearly with store size, on a
path every merge runs.

## Verified by

Counted spawns with a `jq` wrapper logging each invocation across one resolver run: 270
against 54 markers. Timed the scan at 1.29s, and timed a single-`jq` rewrite over the
same store at 0.06s with byte-identical output.

## Suggested fix

Read all five fields in one `jq -r '[...] | @tsv'` per marker document and split the
line in the shell, and hold the scan's result across the resolver's two uses instead of
recomputing it.
