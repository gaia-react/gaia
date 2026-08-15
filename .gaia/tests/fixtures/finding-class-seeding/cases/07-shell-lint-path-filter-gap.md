# 07-shell-lint-path-filter-gap

**Path**: `.github/workflows/shell-lint.yml`
**Line**: 4

## Title

The workflow's trigger path filter excludes a directory its own shellcheck step still
lints.

## Failure mode

The job's trigger `paths:` filter is `'.gaia/scripts/**/*.sh'`. The shellcheck step
inside the job actually globs and lints both `.gaia/scripts/**/*.sh` and
`.claude/hooks/**/*.sh`. A change landing purely under `.claude/hooks/` never matches
the trigger filter, so the workflow never runs at all for that diff, even though the
step it would have run is correct and would have caught a shellcheck violation there.

## Verified by

Compared the trigger `paths:` glob against the shellcheck step's own file-selection
command; the step's selection is broader than the trigger that would fire it.

## Suggested fix

Widen the trigger `paths:` filter to match the step's own selection, or narrow the
step's selection to match the trigger, so the two stay in lockstep.
