---
description: "GAIA before_specify hook: constitution placeholder check + spec-kit version-pin drift detection."
---

# Constitution + version-pin precondition check

Fired automatically by spec-kit on the `before_specify` event (mandatory hook). The agent reads this skill and runs the two checks below before `/speckit-specify` proceeds.

## Inputs

- `$ARGUMENTS` — the same arguments the user passed to `/speckit-specify` or `/speckit-gaia-spec`. Echoed through unchanged; this hook does not consume them.
- Working directory — the project root (a spec-kit-initialized project containing `.specify/memory/constitution.md` and `.specify/extensions/gaia/extension.yml`).

## Step 1 — version-pin drift detection (UAT-018)

Run the version-check helper and capture its result:

```bash
bash .specify/extensions/gaia/lib/version-check.sh
```

The helper reads `requires.speckit_version` from `.specify/extensions/gaia/extension.yml`, resolves the runtime spec-kit version, and exits `0` on match or non-zero on drift. On drift, surface the helper's stderr verbatim to the user, **do not proceed**, and announce:

> `before_specify` blocked: spec-kit version drift detected. Align versions before continuing — see message above.

## Step 2 — constitution placeholder scan (UAT-007)

Read `.specify/memory/constitution.md`. Match the bracketed-placeholder pattern `\[[A-Z_0-9]+\]` (e.g. `[PROJECT_NAME]`, `[PRINCIPLE_1_NAME]`, `[CONSTITUTION_VERSION]`). If any matches are present:

- Report the count and the first three placeholder identifiers found.
- Block proceed with the message:

  > `before_specify` blocked: spec-kit constitution still contains placeholder values. Run `/speckit-constitution` to populate it before authoring a SPEC.

- Do not proceed to `/speckit-specify`.

If the file is absent entirely, treat as the same block (constitution must exist).

## Step 3 — pass-through

If both checks pass, emit a single confirmation line and let `/speckit-specify` continue:

> `before_specify` ok: constitution populated, spec-kit version matches pin.

This hook has no return value to spec-kit; control returns to the running `/speckit-specify` (or `/speckit-gaia-spec`) skill on completion.

## Notes

- The check is read-only. No writes to `.specify/memory/`, no writes to `.gaia/local/`.
- The helper script is the single source of truth for the version-pin format; this skill never inlines version constants.
- "Block" here means: the agent reads this skill's output, sees the block message, and chooses not to call `/speckit-specify`. Spec-kit does not enforce a hard halt — discipline is in the prompt.
