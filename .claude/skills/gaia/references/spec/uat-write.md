---
description: 'Manual runbook: render PO-authored UATs into Playwright e2e specs at <package>/.playwright/e2e/spec-NNN/ in the frontend package.'
---

# UAT write pass

**Status:** no automatic trigger. Run it by hand before implementing: read this file and follow it with the SPEC id, or run `bash .gaia/scripts/spec/uat-write.sh <spec-path>`.

The agent renders the active SPEC's PO-authored UATs into one Playwright e2e spec per UAT, leaving a red-state harness in place before source is edited.

## Locate the active SPEC

The render target is the SPEC artifact whose UATs back the upcoming implementation. In a GAIA project that artifact lives at `.gaia/local/specs/SPEC-NNN/SPEC.md`.

Resolve the path in this order:

1. If `$ARGUMENTS` carries an explicit `SPEC-NNN` id or absolute path, use it.
2. Otherwise pick the most-recent `.gaia/local/specs/SPEC-NNN/SPEC.md` with `status: in-progress`, modified within the last 30 minutes.
3. Otherwise the single `.gaia/local/specs/SPEC-NNN/SPEC.md` with `status: in-progress` (only if exactly one exists).
4. Otherwise `AskUserQuestion`: list all in-progress SPECs and ask which one to render. Do NOT guess.

Step 2 covers a SPEC just written by `/gaia-spec`; step 3 handles the common single-feature case.

## Run the render helper

Run using the Bash tool:

```bash
bash .gaia/scripts/spec/uat-write.sh <resolved-spec-path>
```

The helper emits a JSON summary on stdout. Capture it verbatim; do NOT pipe through anything else. Exit codes: `0` success, `1` operational failure, `2` usage error.

## Surface results

- **Success (`ok: true`).** Emit a one-line summary:

  > UAT-write complete: <written> written, <rewritten> rewritten, <deleted> deleted, <fixme> fixme, <unchanged> unchanged. Specs at `<spec_dir>/` (the helper's `spec_dir`, e.g. `frontend/.playwright/e2e/spec-NNN`). Cache: `.gaia/local/cache/uat-write/<SPEC-ID>.json`.

  Then, if `summary.fixme > 0`, list each fixme'd UAT with its `abstraction_blocker`. The implementer needs to see these on turn 1, those UATs need a SPEC reopen before they can turn green.

  Suggest the implementer's first command:

  > Suggested first action: `pnpm pw <spec_dir>/`, confirms red-state baseline.

- **Operational failure (`ok: false`, exit `1`).** Emit the helper's `error` message verbatim, then **stop**, do not proceed to source edits and do not call any further tool. End the turn on the failure so the work halts here rather than relying on a downstream agent to notice and stop.

- **Usage error (exit `2`).** Treat as a tooling problem, not a SPEC problem. Report the stderr message and skip. Implementation can continue, but without a generated harness, the implementer should write tests inline as fallback and acknowledge the harness was not available.

## Notes

- The runbook is **idempotent**: re-running on an unchanged SPEC produces zero file diffs. Per-UAT content hashes are stored in the cache file at `.gaia/local/cache/uat-write/<SPEC-ID>.json`; matching hashes short-circuit the write path.
- The runbook reads/writes **only** to the `<spec_dir>/` the helper reports (under the `frontend` package registered in `.gaia/packages.json`, `frontend/` by default) plus the cache file under `.gaia/local/cache/uat-write/`. It never edits the SPEC, source, or any other directory.
- Generated specs carry an inline divergence-rule header pointing to `.claude/skills/gaia/references/spec/uat-divergence.md`. The implementer may make cosmetic edits (selector text, button label, copy) but logical changes (flow, success criteria, error handling) are forbidden.
- Orphaned spec files (a `uat-NNN.spec.ts` whose `UAT-NNN` no longer appears in the SPEC) are **hard-deleted**, not archived. Git preserves history; an `_archived/` directory would be picked up by CI globs.
- Pluggability: only Playwright is supported in this SPEC. Vitest e2e / Cypress is a future SPEC.
- The helper is pure: same SPEC in, same JSON out. Any rendering logic belongs in `.gaia/scripts/spec/uat-write.sh`, never inline in this command body.
- On completion (success, failure, or skip) it touches only `<spec_dir>/` and its cache file, and performs no other action.
