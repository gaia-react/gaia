# Smoke tests

Two subtrees. Both are maintainer-only; neither runs in CI, both inform release decisions.

Artifacts here are runnable release-gate harnesses: bash scripts with `pass()`/`fail()`/exit-code reporting, fully deterministic, every step machine-checkable. Audience is the machine, not a maintainer reading. Lifetime is until the feature is ripped out. See `.claude/rules/_internal/smoke.md` for the full convention.

Artifacts that should NOT be here are markdown walk-through runbooks tied to a specific SPEC's UATs; those are UAT runbooks and live at `.specify/extensions/gaia/test/` instead. Measurement tools (telemetry scanners with no PASS/FAIL) live at `.gaia/tests/observability/`; see the root umbrella `.gaia/tests/README.md`. The classifying axis is shape, not origin.

## Layout

- `wiki-sync/`; bash-driven E2E scenarios (billable). See `wiki-sync/README.md`.
- `wiki-promote/`; bash structural smoke for SPEC-004 `after_implement` hook artifacts. See `wiki-promote/README.md`.
- `uat-write/`; bash structural smoke for SPEC-003 `before_implement` hook artifacts. See `uat-write/README.md`.

## Running

### Wiki-sync E2E (billable)

```bash
bash .gaia/tests/smoke/run-all.sh
```

Walks every `wiki-sync/*.sh` scenario, prints PASS/FAIL, exits non-zero on any failure.

## When to run

- **Before cutting a GAIA release**; wiki-sync E2E. Verifies the wiki-sync system works under real Claude judgment, including the post-Serena WORTHY narrowing.
- **Before merging a PR that touches the SPEC-003 or SPEC-004 hook surface**; `uat-write/` and `wiki-promote/` structural smokes.

## See also

- `.specify/extensions/gaia/test/README.md`; the sibling tree of UAT runbooks.
