---
description: 'GAIA after_specify hook: immutability lint over the just-written SPEC artifact.'
---

# Immutability lint pass

Fired automatically by spec-kit on the `after_specify` event (mandatory hook). The agent reads this skill and audits the SPEC that `/speckit-specify` (or the GAIA preset's wrap) just produced.

## Locate the artifact

The lint target is the SPEC artifact written by the preceding `/speckit-specify` invocation. In a GAIA project the preset redirects writes into `.gaia/local/specs/SPEC-NNN.md`; in a bare spec-kit project the artifact lives at `specs/<NNN>-<slug>/spec.md`.

Resolve the path in this order:

1. If `$ARGUMENTS` carries an explicit path, use it.
2. Otherwise inspect `.gaia/local/specs/` for a SPEC file modified within the last five minutes (the just-written artifact).
3. Otherwise fall back to `.specify/feature.json` (spec-kit's pointer to the active feature directory) and resolve `<feature-dir>/spec.md`.

If no candidate resolves, surface:

> `after_specify` lint skipped: no SPEC artifact found at expected paths.

## Run the lint helper

```bash
bash .specify/extensions/gaia/lib/lint.sh <resolved-spec-path>
```

The helper emits a JSON result on stdout: `{"ok": true, "findings": []}` on pass; `{"ok": false, "findings": [...]}` on fail. Exit codes: `0` pass, `1` fail, `2` usage error.

## Surface results

- **Pass.** Emit:

  > `after_specify` lint passed: <path>

- **Fail.** Emit each finding's `code`, `message`, and `where` field on its own line. Then announce:

  > `after_specify` lint failed: <N> finding(s). Fix the SPEC and re-run, or invoke `/gaia spec` again to amend before save.

- **Usage error (exit 2).** Treat as a tooling problem, not a SPEC problem; report the stderr message and skip the lint without blocking the lifecycle.

## What the helper checks (reference; helper is the source of truth)

- Frontmatter present and well-formed.
- Required keys: `spec_id`, `type`, `status`, `immutable`, `wiki_promote_default`, `chain_trigger`, `intent`, `success_criteria`, `uats`, `scope_boundaries`, `clarifications`, `research_summary`, `created`, `updated`.
- `immutable: true`.
- `status` ∈ {`in-progress`, `reopened`, `closed`}.
- `spec_id` matches `SPEC-NNN`.
- Every UAT entry has a frozen `uat_id: UAT-NNN`.
- No placeholder text (`[PLACEHOLDER]`, `<TODO>`, `<TBD>`, `FIXME`, bare `TBD`).
- For `status: reopened`: body contains `## Reopen rationale` and `## UAT diff` sections (the reopen ceremony).

## Notes

- This hook is read-only; it never edits the SPEC.
- "Block save" semantics: a failing lint surfaces the findings to the agent driving `/gaia spec`; that agent is responsible for halting before the on-disk save and looping back to the user.
- The helper is pure: same SPEC in, same JSON out. Any mutation logic belongs in `/gaia spec` (the wrapper command), never here.
