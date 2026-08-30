---
paths:
  - '**/*.bats'
  - '.gaia/tests/**/*.sh'
  - '.gaia/scripts/**/*.sh'
  - '.gaia/cli/src/**/*.ts'
  - '.playwright/**/*.ts'
  - '.claude/hooks/**/*.sh'
  - '.github/workflows/**/*.yml'
---
<!-- gaia-harden: promoted from recurring finding_class holistic/hollow-assertion; pruned by /gaia-audit on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->
<!-- gaia-harden: promoted from recurring finding_class holistic/unarmed-guard; pruned by /gaia-audit on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->
<!-- gaia-harden: promoted from recurring finding_class holistic/fail-open-discovery; pruned by /gaia-audit on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->

# Guards Must Be Able to Fail

A guard is a test assertion, a lint script, a CI condition, a hook precondition: anything whose green result is read as evidence that a construct holds. Green is only evidence when red is reachable. A guard that cannot go red says nothing, and it says it in the exact voice of a guard that checked and approved.

The failure is silent by construction, so it does not surface as a broken guard. It surfaces as a construct nobody defends, discovered when the construct breaks in a place the guard was believed to cover.

Three stages sit between an input and a verdict, and a guard can lose its power to fail at any one of them independently. A guard that is sound at two of the three still proves nothing.

## Anti-pattern

**Discovery, the input set.** The step that builds the guard's own input set drops an element and says nothing: a glob that misses an extension, a `find` whose prune reaches further than intended, a list derived from a manifest that does not enumerate every member. The guard then reports clean over input it never opened. An empty or short input set reads exactly like a clean pass.

**Arming, which inputs reach the check.** The check is correct wherever it runs, but its arming condition covers less than the surface the rule governs: a path filter narrower than the files the rule binds, a `changed-files` list that omits a directory, a refinement keyed to an optional field being present. The diff that creates the obligation is the one that skips the check.

**Match region, what the check accepts.** The assertion runs on the right input and admits a region wider than the construct its own name pins: an expectation whose needle is satisfied by surrounding boilerplate, a substring match that the file's unrelated prose also satisfies, a snapshot standing in for the behavioral claim beside it, an exit-code check where the message content is the actual claim. Corrupt the construct and the check stays green.

## Correct pattern

**Prove the guard can fail before relying on it.** This is the one obligation that catches all three stages at once, and it is cheap: break the construct the guard names, run the guard, and confirm it goes red. Restore, confirm green. A guard whose red state has never been observed is an unverified claim, whatever its logic reads like. Where the break is awkward to perform by hand, commit the broken form as a fixture the suite drives deliberately.

**Assert the input set is non-empty and the expected size.** A discovery step states how many elements it expects to find, or at minimum that it found any, and fails loudly when the set is short. Deriving the set from the same source the rule binds to, rather than from a hand-maintained parallel list, removes the drift that makes the two disagree.

**Derive the arming condition from the surface the rule governs.** When a rule binds a set of paths, the check's trigger reads that same set rather than a hand-copied subset of it. Where the two must be written separately, a check that they still agree is itself a guard, and it is subject to this whole page.

**Pin the match region to the construct.** The assertion names the thing it claims: anchor the pattern, match the full value rather than a substring of it, and assert on the field carrying the behavioral claim rather than on a status code that many distinct outcomes share. When an assertion's needle would be satisfied by text the construct does not own, it is matching the wrong region.

Mechanism-level cases of this on the `.bats` surface, where an assertion's status never reaches the test result at all, are `.claude/rules/bats-assertions.md`.
