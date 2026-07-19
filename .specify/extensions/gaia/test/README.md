# UAT runbooks

Artifacts here are markdown UAT runbooks: maintainer-reading walk-throughs that map each step to the SPEC's UATs. Output is a walk-through narrative, not an exit code. Tied to a specific SPEC's UAT(s); lifetime is until the SPEC closes. See `.specify/extensions/gaia/rules/smoke.md` for the full convention.

Artifacts that should NOT be here are runnable harnesses with `pass()`/`fail()`/exit-code reporting, those are release-gate harnesses and live at `.gaia/tests/smoke/<feature>/` instead. The classifying axis is shape, not origin.

A structural-invariant assertion is a distinct third category: a bats suite that guards a manifest/filesystem invariant rather than walking a SPEC's UATs or gating a release. This extension's two such suites, `lint-yaml.bats` and `registry.bats`, live at `.gaia/tests/lib/` alongside GAIA's other `.specify` lib suites, where they get an audit owner and a CI runner; this directory holds only the manual UAT runbooks.

## Inventory

- `smoke.md`: `/gaia-spec` lifecycle smoke runbook.
- `uat-evidence.md`: UAT mapping for the v2 implementation.
- `v2-validation.md`: sandbox validation transcript for the v2 extension/preset.

## See also

- `.gaia/tests/smoke/README.md`: the sibling tree of release-gate harnesses.
- `.gaia/tests/lib/`: the bats suites guarding this extension's registry completeness and SPEC frontmatter YAML lint.
