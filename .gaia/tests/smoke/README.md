# Smoke tests

Two subtrees. Both are maintainer-only; neither runs in CI, both inform release decisions.

Artifacts here are runnable release-gate harnesses: bash scripts with `pass()`/`fail()`/exit-code reporting, fully deterministic, every step machine-checkable. Audience is the machine, not a maintainer reading. Lifetime is until the feature is ripped out. See `.claude/rules/maintainers/smoke.md` for the full convention.

Artifacts that should NOT be here are markdown walk-through runbooks tied to a specific SPEC's UATs; those are UAT runbooks and live at `.specify/extensions/gaia/test/` instead. Measurement tools (telemetry scanners with no PASS/FAIL) live at `.gaia/tests/observability/`; see the root umbrella `.gaia/tests/README.md`. The classifying axis is shape, not origin.

## Layout

- `wiki-sync/`; bash-driven E2E scenarios (billable). See `wiki-sync/README.md`.
- `wiki-promote/`; bash structural smoke for SPEC-004 `after_implement` hook artifacts. See `wiki-promote/README.md`.
- `uat-write/`; bash structural smoke for SPEC-003 `before_implement` hook artifacts. See `uat-write/README.md`.
- `telemetry-v1/`; bash structural smoke for the telemetry three-stream surface (cloud / mentorship / analytics). See `telemetry-v1/README.md`.

## Running

```bash
bash .gaia/tests/smoke/run-all.sh
```

Two lanes:

- **Blocking** (sets the exit code): the deterministic structural harnesses `wiki-promote/run.sh`, `uat-write/run.sh`, and `telemetry-v1/run.sh`.
- **Advisory** (never gates): `wiki-sync/run.sh` (billable). It drives real `claude -p` sessions, so its assertions depend on free-form LLM output and cannot block a release on a coin-flip. It retries each scenario to absorb one-off variance and surfaces the captured session output on a final failure. Run it standalone with `bash .gaia/tests/smoke/wiki-sync/run.sh`. See `wiki-sync/README.md` for the rationale.

Every harness in this tree belongs to exactly one lane, and `run-all.sh`'s two lane lists are the whole of it, in both directions: a `smoke/<feature>/run.sh` that neither lane names fails the run until it is assigned to one, and a harness a lane names but that is missing from the tree fails the run too. A harness no lane runs guards nothing while still reading as coverage, so adding one is not finished until `run-all.sh` names it. Only an advisory harness's **result** is non-gating; its **absence** is a config error in `run-all.sh`, not an LLM coin-flip, so it fails like any other.

A blocking harness that exits `2` reports as a missing prerequisite rather than a plain failure (the harnesses reserve exit `2` for pre-flight: no `node_modules/.bin/tsx`, no built `.gaia/cli/gaia`). It still gates, since an unverified harness cannot clear a release, but the summary line tells you to run `pnpm install` instead of implying the feature broke.

## When to run

- **Before cutting a GAIA release**; wiki-sync E2E (advisory). Verifies the wiki-sync system works under real Claude judgment, including the post-Serena WORTHY narrowing. Read the advisory summary; an `ADVISORY` line is a signal to investigate, not a hard block.
- **Before merging a PR that touches the SPEC-003 or SPEC-004 hook surface**; `uat-write/` and `wiki-promote/` structural smokes.
- **Before merging a PR that touches the telemetry surface** (`.gaia/cli/src/telemetry/`, `.gaia/cli/src/mentorship/`); `telemetry-v1/` structural smoke. It needs `node_modules/.bin/tsx`, so run `pnpm install` first; the harness exits `2` on a missing prerequisite.

## See also

- `.specify/extensions/gaia/test/README.md`; the sibling tree of UAT runbooks.
