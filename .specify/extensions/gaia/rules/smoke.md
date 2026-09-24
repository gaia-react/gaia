# UAT runbook convention

GAIA's verification artifacts include **UAT runbooks** under `.specify/extensions/gaia/test/`: maintainer-reading, walk-through narrative, judgment-allowed steps, tied to a specific SPEC's UAT(s) and retired when that SPEC closes.

## Naming convention

- UAT runbooks: `.specify/extensions/gaia/test/smoke-<feature>.md`.
- Existing artifacts that pre-date this convention (`smoke.md`, `uat-evidence.md`, `v2-validation.md`) are grandfathered by name and retain their original filenames.

## Precedent shape

- UAT runbook canonical example: `.specify/extensions/gaia/test/smoke.md`, narrative steps a maintainer reads and walks through.

## Enforcement

Maintainer rule + good-faith review. No CI lint, no `/speckit-gaia-spec-close` audit hook. Name a new UAT runbook per this convention. A fully deterministic artifact that reports by exit code is not a runbook and does not belong in `.specify/extensions/gaia/test/`; when reviewing, flag one that lands there. If repeated violations surface post-launch, escalate to a `/speckit-gaia-spec-close` audit step, never CI lint.
