---
description: 'GAIA before_implement hook: render PO-authored UATs into Playwright e2e specs at .playwright/e2e/spec-NNN/.'
---

# UAT auto-write pass

Fired automatically by spec-kit on the `before_implement` event (mandatory hook). The agent reads this skill and renders the active SPEC's PO-authored UATs into one Playwright e2e spec per UAT, leaving a red-state harness in place before `/speckit-implement` edits source.

## Locate the active SPEC

The render target is the SPEC artifact whose UATs back the upcoming `/speckit-implement` run. In a GAIA project that artifact lives at `.gaia/local/specs/SPEC-NNN.md`.

Resolve the path in this order (4-step algorithm; locked post-probe — `.specify/feature.json` carries no SPEC backreference, so a feature-cross-walk step was dropped):

1. If `$ARGUMENTS` carries an explicit `SPEC-NNN` id or absolute path, use it.
2. Otherwise pick the most-recent `.gaia/local/specs/SPEC-NNN.md` with `status: in-progress`, modified within the last 30 minutes.
3. Otherwise the single `.gaia/local/specs/SPEC-NNN.md` with `status: in-progress` (only if exactly one exists).
4. Otherwise `AskUserQuestion`: list all in-progress SPECs and ask which one to render. Do NOT guess.

The GAIA preset's `/speckit-specify` wrapper relocates and stamps the SPEC immediately after authoring, so the just-written SPEC is the most-recent in-progress entry — step 2 covers the `/speckit-specify` → `/gaia plan` → `/speckit-implement` chain. Step 3 handles the common single-feature case.

## Run the render helper

```bash
bash .specify/extensions/gaia/lib/uat-write.sh <resolved-spec-path>
```

The helper emits a JSON summary on stdout. Capture it verbatim; do NOT pipe through anything else. Exit codes: `0` success, `1` operational failure, `2` usage error.

## Surface results

- **Success (`ok: true`).** Emit a one-line summary:

  > `before_implement` UAT-write complete: <written> written, <rewritten> rewritten, <deleted> deleted, <fixme> fixme, <unchanged> unchanged. Specs at `.playwright/e2e/<spec-dir>/`. Cache: `.gaia/local/cache/uat-write/<SPEC-ID>.json`.

  Then, if `summary.fixme > 0`, list each fixme'd UAT with its `abstraction_blocker`. The implementer needs to see these on turn 1 — those UATs need a SPEC reopen before they can turn green.

  Suggest the implementer's first command:

  > Suggested first action: `pnpm pw .playwright/e2e/<spec-dir>/` — confirms red-state baseline.

- **Operational failure (`ok: false`, exit `1`).** Emit the helper's `error` message verbatim. Do NOT proceed to `/speckit-implement`'s source edits — the implementer agent is responsible for reading the failure and halting the lifecycle.

- **Usage error (exit `2`).** Treat as a tooling problem, not a SPEC problem. Report the stderr message and skip without blocking the lifecycle. The user's `/speckit-implement` continues, but without a generated harness — the implementer should write tests inline as fallback and acknowledge the harness was not available.

## Notes

- The hook is **idempotent**: re-firing on an unchanged SPEC produces zero file diffs. Per-UAT content hashes are stored in the cache file at `.gaia/local/cache/uat-write/<SPEC-ID>.json`; matching hashes short-circuit the write path.
- The hook reads/writes **only** to `.playwright/e2e/<spec-dir>/` plus the cache file under `.gaia/local/cache/uat-write/`. It never edits the SPEC, source, or any other directory.
- Generated specs carry an inline divergence-rule header pointing to `.specify/extensions/gaia/rules/uat-divergence.md`. The implementer may make cosmetic edits (selector text, button label, copy) but logical changes (flow, success criteria, error handling) are forbidden.
- Orphaned spec files (a `uat-NNN.spec.ts` whose `UAT-NNN` no longer appears in the SPEC) are **hard-deleted**, not archived. Git preserves history; an `_archived/` directory would be picked up by CI globs.
- The hook fires only on `before_implement`. It is not invoked by any other lifecycle event.
- Pluggability: only Playwright is supported in this SPEC. Vitest e2e / Cypress is a future SPEC.
- The helper is pure: same SPEC in, same JSON out. Any rendering logic belongs in `lib/uat-write.sh`, never inline in this command body.
