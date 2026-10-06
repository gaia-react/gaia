---
description: 'Manual runbook: immutability lint over a SPEC artifact, wrapping lib/lint.sh.'
---

# Immutability lint pass

**Status:** no automatic trigger. Run it by hand: read this file and follow it with a SPEC path or id, or run `bash .specify/extensions/gaia/lib/lint.sh <spec-path>`. `/gaia-spec` step 10 calls `lib/lint.sh` directly.

The agent audits one SPEC artifact against the immutability contract.

## Locate the artifact

The lint target is an explicit SPEC path, or a SPEC id resolved to the main-anchored `.gaia/local/specs/<id>/SPEC.md`:

```bash
MAIN_ROOT="$(bash .gaia/scripts/main-root-lib.sh)"
```

Resolve the path in this order:

1. If `$ARGUMENTS` carries an explicit path, use it.
2. Otherwise, if it carries a SPEC id, use `${MAIN_ROOT}/.gaia/local/specs/<id>/SPEC.md`.

If neither resolves to an existing file, surface:

> lint skipped: no SPEC artifact found at the given path or id.

## Run the lint helper

Run using the Bash tool:

```bash
bash .specify/extensions/gaia/lib/lint.sh <resolved-spec-path>
```

The helper emits a JSON result on stdout: `{"ok": true, "findings": []}` on pass; `{"ok": false, "findings": [...]}` on fail. Exit codes: `0` pass, `1` fail, `2` usage error.

## Surface results

- **Pass.** Emit:

  > lint passed: <path>

- **Fail.** Emit each finding's `code`, `message`, and `where` field on its own line. Then announce:

  > lint failed: <N> finding(s). Fix the SPEC and re-run.

- **Usage error (exit 2).** Treat as a tooling problem, not a SPEC problem; report the stderr message and skip the lint.

## What the helper checks (reference; helper is the source of truth)

- Frontmatter present (closed `--- ... ---` block).
- Required keys: `spec_id`, `type`, `status`, `immutable`, `wiki_promote_default`, `chain_trigger`, `intent`, `success_criteria`, `uats`, `scope_boundaries`, `clarifications`, `research_summary`, `created`, `updated`.
- `immutable: true`.
- `status` ∈ {`in-progress`, `reopened`, `closed`}.
- `spec_id` matches `SPEC-NNN`.
- Every UAT entry has a frozen `uat_id: UAT-NNN`.
- No placeholder text (`[PLACEHOLDER]`, `<TODO>`, `<TBD>`, `FIXME`, bare `TBD`).
- For `status: reopened`: body contains `## Reopen rationale` and `## UAT diff` sections (the reopen ceremony).

## Notes

- This runbook is read-only. Its only action is to emit the helper's findings and stop, it never edits, deletes, moves, or auto-fixes the SPEC. Fixing the SPEC is the author's job; lint only reports.
- The helper is pure: same SPEC in, same JSON out. Any mutation logic belongs in `/gaia-spec`, never here.
