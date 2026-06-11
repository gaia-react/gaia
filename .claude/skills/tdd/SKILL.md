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

### 4. Refactor

After all tests pass, look for [refactor candidates](refactoring.md):

- [ ] Extract duplication
- [ ] Deepen modules (move complexity behind simple interfaces)
- [ ] Apply SOLID principles where natural
- [ ] Consider what new code reveals about existing code
- [ ] Run tests after each refactor step

**Never refactor while RED.** Get to GREEN first.

## Checklist Per Cycle

```
[ ] Test describes behavior, not implementation
[ ] Test uses public interface only (no spying on internals)
[ ] Test would survive an internal refactor
[ ] Code is minimal for this test
[ ] No speculative features added
[ ] Mock only at system boundaries (network, time, randomness)
```
