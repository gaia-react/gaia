---
name: tdd
description: Test-driven development with red-green-refactor loop. Use when user wants to build features or fix bugs using TDD, mentions "red-green-refactor", wants integration tests, or asks for test-first development.
---

# Test-Driven Development

## Selecting a Stack Reference

Before writing the first red test, consult the reference for your stack:

- **React / Vitest / MSW / Storybook** → [references/tests-react.md](references/tests-react.md)

Add a new `references/tests-{stack}.md` when adopting a new stack. The stack reference covers concrete patterns, test layers, mocking rules, and good/bad examples specific to that environment.

## Philosophy

**Core principle**: tests verify behavior through public interfaces, not implementation details. Code can change entirely; tests shouldn't.

**Good tests** are integration-style, they exercise real code paths through public APIs and describe _what_ the system does, not _how_. A good test reads like a specification: "user submits a valid form and sees a success toast" tells you exactly what capability exists. These tests survive refactors because they don't care about internal structure.

**Bad tests** are coupled to implementation. They mock internal collaborators, spy on state setters, or assert on internal call signatures. The warning sign: your test breaks when you refactor, but behavior hasn't changed.

## Anti-Pattern: Horizontal Slices

**DO NOT write all tests first, then all implementation.** This is "horizontal slicing", treating RED as "write all tests" and GREEN as "write all code."

Tests written in bulk test _imagined_ behavior, not _actual_ behavior. You outrun your headlights, committing to structure before understanding the implementation, producing tests insensitive to real changes.

**Correct approach**: vertical slices via tracer bullets. One test → one implementation → repeat.

```
WRONG (horizontal):
  RED:   test1, test2, test3, test4, test5
  GREEN: impl1, impl2, impl3, impl4, impl5

RIGHT (vertical):
  RED→GREEN: test1→impl1
  RED→GREEN: test2→impl2
  RED→GREEN: test3→impl3
  ...
```

## Workflow

### 1. Planning

Before writing any code:

- [ ] Confirm which layer owns this test (see stack reference for layer breakdown)
- [ ] Confirm which behaviors to test (prioritize)
- [ ] Identify opportunities for [deep modules](deep-modules.md), small interface, deep implementation
- [ ] Design interfaces for [testability](interface-design.md)
- [ ] List the behaviors to test (not implementation steps)
- [ ] Get user approval on the plan

Ask: "What should the public interface look like? Which behaviors are most important to test?"

**You can't test everything.** Focus on critical paths and complex logic, not every edge case.

### 2. Tracer Bullet

Write ONE test that confirms ONE thing end-to-end for this layer. `RED → GREEN`. The tracer bullet confirms the testing infrastructure wires up before adding real coverage.

### 3. Incremental Loop

For each remaining behavior: `RED → GREEN`. One test at a time. Only enough code to pass the current test. Don't anticipate future tests.

**Bound the green chase.** If a test won't pass after a few focused attempts, stop and reassess instead of thrashing the implementation: the test, the interface, or an assumption may be wrong. Surface the blocker rather than looping indefinitely to force green.

#### Authoring an honest RED on the deterministic surface

The deterministic surface (pure utils, service parsers, spec-derivable hooks) is RED-gated: a new test there commits only after a genuine failing-first run is observed at its current body.

**Author the test against the not-yet-written or stub implementation symbol.** Write the test for the behavior you are about to build, pointing at a symbol that does not exist yet (or exists only as a stub that returns the wrong value). Run it; it fails because the implementation is missing or incomplete. That failure is the honest RED: a real missing-implementation failure, not a manufactured one. Then write the implementation that turns it green.

```
RIGHT:  test names parseAmount() → run → fails (parseAmount undefined / stub) → implement → green
WRONG:  implement parseAmount() → write the test → break parseAmount() to force red → restore it → green
```

**Never break working production code to force a red, then restore it.** That pattern relocates the theater into the implementation file: it is mechanically identical to the green-only theater the RED gate condemns, and mutating the body after the RED is captured changes the content signal and invalidates the captured RED, so the gate denies the commit anyway. The honest path is always to author the test against the absent or stub symbol, so the red comes for free from the missing implementation.

**Single-pass-author exemption.** When the implementation already exists in the same change with no prior failing observation (a single-pass author landing impl and test together), do NOT manufacture a red by breaking and restoring the impl. Author the test honestly against the existing behavior and route it to the worthiness audit, exactly as an emergent test is routed. A test that lands alongside its implementation with no prior failing observation is detectable, and a missed RED on it is caught late by the advisory audit, never by forcing theater up front.

### 4. Refactor

After all tests pass, look for [refactor candidates](refactoring.md):

- [ ] Extract duplication
- [ ] Deepen modules (move complexity behind simple interfaces)
- [ ] Apply SOLID principles where natural
- [ ] Consider what new code reveals about existing code
- [ ] Run tests after each refactor step

**Never refactor while RED.** Get to GREEN first.

### 5. Determinism Roll-up

After green, classify every touched source file and report the verdict. Classification is **per-file and silent**: never prompt the human to choose strict versus test-after, the classifier decides from the file's content.

Run the determinism classifier over each touched source file:

```
node .gaia/scripts/classifier/classify-determinism.mjs <repo-relative-source-path>
```

It emits `{file, classification: "strict" | "emergent", reasons}`. A `strict` file is on the deterministic surface and owes a RED; an `emergent` file is clock-/entropy-/I-O-bound or tree-dependent and commits without one.

**Emit the per-file verdict for every touched file in the end-of-task summary, unconditionally.** One line per file, listed whether or not you judged the classification surprising. The roll-up is not gated on your sense of what is non-obvious: a silent misclassification (a pure-looking file the classifier marks emergent, or vice versa) only stays auditable if it appears as a named line. Do not suppress the routine-looking ones.

```
Determinism roll-up:
  • app/utils/money.ts            strict
  • app/components/Cart/index.tsx  emergent (path not a .ts under app/components)
```

This roll-up shares the end-of-task summary with any worthiness findings: render the classifier verdicts and the worthiness lines in ONE summary, not two.

### 6. Worthiness Audit (emergent surface)

The deterministic surface earns its honesty proof from the RED gate. The emergent surface (`app/components/**`, `.playwright/**`) has no stable failing-then-passing run to gate on, so its honesty and worthiness come from an **advisory audit** instead. Run this audit after green, on the emergent-surface test files the task changed (the classifier roll-up above tells you which touched files are `emergent`).

#### Dispatch a fresh-context audit (no-orchestrator path)

On the main loop, with no orchestrator above you, the audit MUST run in a **genuine fresh-context `Agent` sub-leaf**, never as an in-context self-review by the test author. The author who just wrote the tests shares their blind spots; a same-model fresh-context reviewer that never saw the authoring rationale is the cheapest way to recover honesty signal. An in-context "I'll review my own tests" pass does not satisfy this step.

Dispatch one `Agent` leaf running the committed evaluator prompt (`.claude/agents/worthiness-evaluator.md`) over the task's changed emergent test files plus their sibling suites. The evaluator judges each test on two axes (honesty, worthiness), returns a `keep`/`fix`/`delete` verdict per test, and **edits no files**: every `delete` is a proposal a human confirms.

#### Write the worthiness ledger (no-orchestrator path)

With no orchestrator to record verdicts, **the tdd skill is the ledger writer**, otherwise principle-6 always-on is violated and the merge presence gate has nothing to read. For each verdict the evaluator returns, append one ledger line via the writer:

```
node .gaia/scripts/audit-ledger/append-worthiness.mjs <repo-rel-test-path> <fullName> <verdict> [artifact]
```

`<verdict>` is `keep` | `fix` | `delete`; `[artifact]` is REQUIRED for a non-keep verdict (the cited machine-verified sibling for a redundancy delete, the unreachable/missing assertion for a fix) and omitted for `keep`. The writer recomputes the test-identity signal from the file via the RED-ledger signal helper, so it byte-matches what the presence gate later recomputes; the ledger at `.gaia/local/audit-ledger/worthiness.jsonl` is append-only and gitignored.

Surface the evaluator's verdicts in the **same end-of-task summary** as the determinism roll-up above: one summary, not a parallel one. Deletes are proposals: present them for human confirmation, never act on them.

#### Path-scoped guarantees

The guarantee this audit provides is scoped to **the subset a same-model fresh-context reviewer reliably flags**, not a proof of test worthiness. State the surviving guarantees by path:

- **No-orchestrator path (this skill alone), surviving guarantees:** static honesty lint on every test; a real RED on the deterministic surface; the fresh-subagent worthiness audit **if it was dispatched**. The audit is advisory and depends on this dispatch step running; a skipped dispatch leaves only the static lint and the RED gate.
- **Orchestrated path, additional guarantees (NOT available here):** the post-phase merge presence gate (which recomputes signals and refuses a merge whose audit ledger is absent or mismatched) and leaf isolation enforced by the orchestrator. These are orchestrator-owned; the no-orchestrator path does not provide them.

### 7. Surfacing the advisory findings

Advisory findings (worthiness verdicts and the structural a11y floor below) NEVER interrupt mid-implementation. There are no mid-flow prompts. They surface only where attention already is: the end-of-task summary, before commit (no-orchestrator path), and the orchestrator's `SUMMARY.md` plus the pre-merge summary (orchestrated path). This is the SAME end-of-task summary the determinism roll-up and the worthiness verdicts already render into; the surfacing rules here describe how that one summary presents the findings, not a second summary.

#### Structural a11y floor (judge-independent non-triviality)

Run the structural a11y floor over each changed emergent-surface test file that calls an a11y helper (`expectNoA11yViolations` / `runAxe`):

```
node .gaia/scripts/a11y-structural/check-a11y-triviality.mjs <repo-relative-test-path>
```

It emits `{file, verdict: "trivial" | "non-trivial" | "not-a11y", findings}`. A `trivial` verdict flags a vacuous a11y test as an advisory **non-triviality fix**, on a static-AST shape alone: the render passes no props (only defaults), or the rendered markup carries no interactive or landmark node while the component's stories declare interactive variants. This is the judge-independent producer of the non-triviality signal; the worthiness evaluator's matching `fix` is corroborating evidence, never the pass condition. When the floor says `trivial` and the evaluator says `keep`, the floor wins and the disagreement is surfaced. A render-only axe pass stays a complete a11y test for a component with no interactive behavior (a Spinner, a static badge); the floor only flags it when the shape or the stories show unexercised behavior. The floor is ADVISORY: it adds a `fix` finding to the summary, it never blocks a commit. Route a `trivial` finding into the worthiness ledger as a `fix` with the structural reason as its artifact.

#### Two tiers, capped

The summary presents advisory findings in two tiers:

- **HONESTY findings auto-fix.** A test that fails the honesty axis (couples to implementation, asserts a tautology, asserts platform bytes) is rewritten in place and left in the working tree for normal review. No confirmation prompt: the fix is a normal code edit the human reviews like any other.
- **Every proposed DELETE requires human confirmation and renders its evidence INLINE.** A delete is never acted on. Each proposed delete renders, in the summary, the cited redundant sibling assertion AND the subsuming seam assertion that makes it redundant, so the human confirms against the evidence without opening files. A delete whose cited sibling cannot be machine-verified is downgraded, never shown as a delete.

Cap the list: show the **top-N by severity with a count** (`delete` proposals before `fix` findings; "3 of 11 findings shown"), never a wall of every line.

#### Where it renders

- **No-orchestrator path (main loop):** one end-of-task summary before commit, sharing the surface with the determinism roll-up and the worthiness verdicts. One summary, not three.
- **Orchestrated path:** the same two-tier content goes into the leaf's `SUMMARY.md` ledger entry and the pre-merge summary, so the orchestrator's merge presence gate and the human reviewer see the deletes and their inline evidence before a merge.

## Checklist Per Cycle

```
[ ] Test describes behavior, not implementation
[ ] Test uses public interface only (no spying on internals)
[ ] Test would survive an internal refactor
[ ] Code is minimal for this test
[ ] No speculative features added
[ ] Mock only at system boundaries (network, time, randomness)
```
