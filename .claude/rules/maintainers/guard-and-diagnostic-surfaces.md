---
paths:
  - '.gaia/cli/src/**/*.ts'
  - '.gaia/tests/**/*.sh'
---

# Guard and Diagnostic Rules on the Maintainer-Only Surfaces

Two shipped rules govern how a guard is written and how a diagnostic names its causes:

- `.claude/rules/guards-must-fail.md`, on the three stages at which a guard silently loses the ability to go red.
- `.claude/rules/partial-cause-reporting.md`, on a branch reachable from several conditions whose message admits to one of them.

Both apply here in full. This file exists only to activate them on the two surfaces their own `paths:` cannot name: the CLI source and its test suites under `.gaia/cli/src/**`, and the bats harness scripts under `.gaia/tests/**`. Both directories are release-excluded, and the shipped-surface leak check forbids a file an adopter receives from referencing a path their clone does not have, so the globs live here instead of there.

Nothing else is scoped to this file. It carries no provenance marker: the markers for the promoted classes stay in the two shipped rules, where the coverage scan reads them.
