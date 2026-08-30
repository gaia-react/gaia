# 30-invariant-claim-wider-than-its-binding

**Path**: `.claude/hooks/pr-merge-audit-check.sh`
**Line**: 932

## Title

The comment calls the new binding a whole-gate invariant, and the binding establishes it
within the gate's home repository rather than everywhere the gate runs.

## Failure mode

The comment says the check binding a merge command's target to this checkout's own
pull-request record makes agreement "a whole-gate invariant". The binding compares the
target number against that record and reads nothing else. An earlier arm in the same
script classifies a merge as foreign by comparing repository **basename** only, so a
merge naming a same-named repository under a different owner is not classified foreign,
reaches the binding, and passes on the number alone. The outcome is correct by design,
because a genuinely foreign merge is allowed at that early exit, so nothing here decides
wrongly. The sentence is what is wider than what it rests on: it holds for the home-repo
case the writer was reasoning about, and a maintainer who reads it as covering every
merge the gate sees will not think to check the owner half.

## Verified by

Traced the binding at HEAD: it reads the target number and the record's number and no
repository field, though the same scan populates one. Read the upstream foreign-repo arm
and confirmed it compares basenames. Ran the gate against a merge naming a same-named
repository under a different owner: not classified foreign, reaches the binding, passes.

## Suggested fix

Narrow the sentence to the pull-request number within this gate's home-repo scope, or
add the repository slug to the comparison so the sentence becomes true as written. The
same sentence is carried in two other places and takes whichever narrowing is chosen.
