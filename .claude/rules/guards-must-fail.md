---
paths:
  - '**/*.bats'
  - '.gaia/scripts/**/*.sh'
  - '.playwright/**/*.ts'
  - '.claude/hooks/**/*.sh'
  - '.github/workflows/**/*.yml'
---
<!-- gaia-harden: promoted from recurring finding_class holistic/hollow-assertion; pruned by /gaia-audit on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->
<!-- gaia-harden: promoted from recurring finding_class holistic/unarmed-guard; pruned by /gaia-audit on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->
<!-- gaia-harden: promoted from recurring finding_class holistic/fail-open-discovery; pruned by /gaia-audit on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->

# Guards Must Be Able to Fail

A guard (test assertion, lint script, CI condition, hook precondition) is only evidence a construct holds when red is reachable. Before relying on one:

- **Prove it can fail.** Break the construct, run the guard, confirm red; restore, confirm green. Commit an awkward-to-hand-break case as a fixture instead.
- **Assert the input set is non-empty and the expected size**, derived from the same source the rule binds to.
- **Stage a new guard and its sibling suite before the run that validates them** (or confirm their paths appear in the discovery output): both are untracked at the moment they are first run, which is exactly when a discovery over tracked files cannot see them, and that first-run "clean" is indistinguishable from a real one.

Full anti-pattern (the three independent stages a guard can lose its power to fail at: discovery, arming, match region) and worked correct-pattern detail: `wiki/concepts/GAIA Scripts.md` ("Why a guard must be able to fail"). Mechanism-level `.bats` cases: `.claude/rules/bats-assertions.md`.
