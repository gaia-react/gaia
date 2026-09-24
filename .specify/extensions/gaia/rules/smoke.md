# Smoke harness convention

GAIA's verification artifacts include **UAT runbooks** under `.specify/extensions/gaia/test/`: maintainer-reading, walk-through narrative, judgment-allowed steps, tied to a specific SPEC's UAT(s) and retired when that SPEC closes.

## Naming convention

- UAT runbooks: `.specify/extensions/gaia/test/smoke-<feature>.md`.
- Existing artifacts that pre-date this convention (`smoke.md`, `uat-evidence.md`, `v2-validation.md`) are grandfathered by name and retain their original filenames.

## Precedent shape

- UAT runbook canonical example: `.specify/extensions/gaia/test/smoke.md`, narrative steps a maintainer reads and walks through.

## Enforcement

Maintainer rule + good-faith review. No CI lint, no `/speckit-gaia-spec-close` audit hook. When authoring a new verification artifact, classify it by shape against this convention and place it accordingly; when reviewing, flag misclassification and migrate. If repeated violations surface post-launch, escalate to a `/speckit-gaia-spec-close` audit step, never CI lint.
