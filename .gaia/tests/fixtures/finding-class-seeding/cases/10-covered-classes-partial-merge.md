# 10-covered-classes-partial-merge

**Path**: `.gaia/cli/src/harden/covered-classes.ts`
**Line**: 22

## Title

The "classes currently covered" set is built from one vocabulary array and never
merged with the other two.

## Failure mode

`collectCoveredClasses()` builds its return set by iterating `HOLISTIC_FINDING_CLASSES`
alone. `RULE_FINDING_CLASSES` and `WORKFLOW_FINDING_CLASSES` are separate arrays in the
same schema module and are never read by this function, so a caller that asks "is this
rule- or workflow-bucket class covered?" gets a negative answer for every one of them,
regardless of whether it is actually seeded.

## Verified by

Called `collectCoveredClasses()` and confirmed the returned set contains zero entries
with a `rule/` or `workflow/` prefix, despite both arrays being non-empty in the same
module.

## Suggested fix

Merge all three arrays (`HOLISTIC_FINDING_CLASSES`, `RULE_FINDING_CLASSES`,
`WORKFLOW_FINDING_CLASSES`) into the returned set, or document plainly that the
function is holistic-only and rename it to say so.
