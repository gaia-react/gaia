# Smoke harness convention

GAIA's verification artifacts split across two trees: `.specify/extensions/gaia/test/` for **UAT runbooks** (maintainer-reading, walk-through narrative, judgment-allowed steps) and `.gaia/tests/smoke/` for **release-gate harnesses** (machine-running, exit-code + PASS/FAIL log, fully deterministic). The classifying axis is **shape** (procedural-determinism vs maintainer-judgment), not **origin** (which SPEC the artifact came from). A SPEC-evidence artifact whose every step is procedural-deterministic belongs in the release-gate-harness tree.

## Decision table

| Property        | UAT runbook                                 | Release-gate harness                                       |
| --------------- | ------------------------------------------- | ---------------------------------------------------------- |
| Tree            | `.specify/extensions/gaia/test/`            | `.gaia/tests/smoke/`                                     |
| Audience        | maintainer reading                          | machine running                                            |
| Output          | walk-through narrative                      | exit code + PASS/FAIL log                                  |
| Tied to         | a specific SPEC's UAT(s)                    | a feature shipping in the wild                             |
| Lifetime        | retired when the SPEC closes                | lives until the feature is ripped out                      |
| When run        | once, during SPEC verification              | repeatedly, before each release                            |
| Determinism     | mixed: maintainer-judgment steps allowed    | fully deterministic; every step is machine-checkable       |

## Naming convention

- UAT runbooks: `.specify/extensions/gaia/test/smoke-<feature>.md`.
- Release-gate harnesses: `.gaia/tests/smoke/<feature>/{run.sh, README.md, fixture/}` — matches `wiki-promote/`, `wiki-sync/` precedent.
- Existing artifacts that pre-date this convention (`smoke.md`, `uat-evidence.md`, `v2-validation.md`) are grandfathered by name and retain their original filenames.

## Precedent shapes

- Release-gate harness canonical example: `.gaia/tests/smoke/wiki-promote/run.sh` — `set -euo pipefail`, `pass()`/`fail()` helpers, structural assertions, exit-code summary.
- UAT runbook canonical example: `.specify/extensions/gaia/test/smoke.md` — narrative steps a maintainer reads and walks through.

## Enforcement

Maintainer rule + good-faith review. No CI lint, no `/gaia spec close` audit hook. When authoring a new verification artifact, classify it by shape against the decision table and place it in the matching tree; when reviewing, flag misclassification and migrate. If repeated violations surface post-launch, escalate to a `/gaia spec close` audit step — never CI lint.
