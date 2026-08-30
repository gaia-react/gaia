---
paths:
  - '.gaia/scripts/**/*.sh'
  - '.claude/hooks/**/*.sh'
  - '**/*.bats'
---
<!-- gaia-harden: promoted from recurring finding_class holistic/partial-cause-reporting; pruned by /gaia-audit on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->

# A Diagnostic Names Every Cause That Reaches It

A diagnostic, error, or status message is read as a description of what happened. When several distinct conditions reach one branch and the message names only one of them, the operator is not merely under-informed: they are pointed at a repair that cannot fix what actually failed. They apply it, the symptom persists, and the message keeps asserting the cause they already ruled out.

This is worse than a terse message. A message that says nothing sends the operator to read the code. A message that names one of three causes sends them to fix the wrong thing with confidence.

## Anti-pattern

A branch is reachable from more than one condition, and the message assumes the one that prompted it being written:

- A file read fails and the message says the file is missing, when the same branch also catches a permission denial and a malformed payload.
- A lookup returns nothing and the message says the name is unknown, when an upstream fetch failing yields the same empty result.
- A precondition check fails and the message names the flag the author had in mind, when a second, unrelated flag lands on the same refusal.
- An exit code is documented against one trigger while a sibling trigger returns it too, so a caller branching on that code mishandles the second.

The tell is a branch whose entry conditions outnumber the causes its message admits to.

## Correct pattern

Before writing the message, enumerate every condition that reaches the branch, then write a message that holds for all of them.

- **Name each cause the branch admits**, and where they are genuinely indistinguishable at that point, say so: naming the set honestly beats naming one member confidently.
- **Separate the branches when the repairs differ.** Where a missing file and an unreadable file need different fixes, distinguishing them at the check is better than describing both in one message. A shared message is the right answer only where the operator's next step is the same either way.
- **Carry the discriminating evidence.** The underlying error, the exit status, the path actually attempted: whatever separates the causes at runtime belongs in the message, so the operator can tell which one they hit without reproducing it under a debugger.
- **Keep an exit code's documented triggers complete.** When a second condition starts returning an existing code, the code's documented cause set grows with it, or every caller branching on that code is now wrong.
