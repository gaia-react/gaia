# UAT runbooks

Artifacts here are markdown UAT runbooks: maintainer-reading walk-throughs that map each step to the SPEC's UATs. Output is a walk-through narrative, not an exit code. Tied to a specific SPEC's UAT(s); lifetime is until the SPEC closes. See `.specify/extensions/gaia/rules/smoke.md` for the full convention.

Artifacts that should NOT be here are runnable harnesses with `pass()`/`fail()`/exit-code reporting — those are release-gate harnesses and live at `.gaia/tests/smoke/<feature>/` instead. The classifying axis is shape, not origin.

## Inventory

- `smoke.md` — `/gaia-spec` lifecycle smoke runbook.
- `uat-evidence.md` — UAT mapping for the v2 implementation.
- `v2-validation.md` — sandbox validation transcript for the v2 extension/preset.

## See also

- `.gaia/tests/smoke/README.md` — the sibling tree of release-gate harnesses.
