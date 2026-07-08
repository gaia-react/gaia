---
paths:
  - '.gaia/tests/smoke/**'
  - '.specify/extensions/gaia/test/**'
---

# Smoke-harness convention (maintainer-only)

**Maintainer-repo only.** This rule never ships (`.claude/rules/maintainers/` is release-excluded). It routes GAIA's own verification artifacts between two trees; an adopter clone has neither, so it is out of scope there.

GAIA's verification artifacts split by **shape** (procedural-determinism vs maintainer-judgment), not by **origin** (which SPEC the artifact came from). A SPEC-evidence artifact whose every step is procedural and machine-checkable is a release-gate harness, not a runbook.

| Tree | Shape | Audience | Lifetime |
|---|---|---|---|
| `.gaia/tests/smoke/<feature>/` | Release-gate harness: `set -euo pipefail`, `pass()`/`fail()`, exit-code + PASS/FAIL log, fully deterministic. | Machine, before each release. | Until the feature is ripped out. |
| `.specify/extensions/gaia/test/smoke-<feature>.md` | UAT runbook: markdown walk-through, maintainer-judgment steps allowed. | Maintainer reading, during SPEC verification. | Until the SPEC closes. |

Routing rule: classify a new verification artifact by shape and place it in the matching tree. Every step procedural and machine-checkable, harness (first row), even when it came from a SPEC's UATs; needs a maintainer to read and judge, runbook (second row).

## Reference

The authoritative decision table, naming convention, precedent shapes, and enforcement live in `.specify/extensions/gaia/rules/smoke.md`. This rule is the maintainer-side entry point to that convention; keep the detail in the `.specify` doc and let this one route.
