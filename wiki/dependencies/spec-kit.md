---
type: dependency
status: active
package: spec-kit
version: v0.8.5
role: spec-authoring-engine
created: 2026-05-06
updated: 2026-06-24
tags: [dependency, spec-kit, claude]
---

# spec-kit

[GitHub spec-kit](https://github.com/github/spec-kit) is the SPEC-authoring engine that backs GAIA's `/gaia-spec` workflow. GAIA wraps it with a Socratic discovery loop, GAIA-shaped frontmatter, and a `/gaia-plan` handoff.

## Pin

- Version: `v0.8.5` exactly (installed via `uvx --from git+https://github.com/github/spec-kit.git@v0.8.5`).
- Compatible range declared in extension + preset: `>=0.8.5,<0.10.0`. Drift detection at runtime via `.specify/extensions/gaia/lib/version-check.sh`, fired from the `before_specify` constitution-check hook. It caches a pass for the calendar day at `.gaia/local/cache/version-check.lock` and exits 1 (surfacing stderr verbatim, then halting) when the runtime version drifts below the floor or at-or-above the ceiling.
- Scope: project (registered via `specify init --here` during `/gaia-init`).
- Runtime: requires `uv` (Astral Python toolchain runner).

## Install

`/gaia-init` Step 8 registers spec-kit's runtime around the template-shipped extension and preset. All three `specify` invocations are pinned via `uvx --from git+https://github.com/github/spec-kit.git@v0.8.5`:

```bash
uvx --from "git+https://github.com/github/spec-kit.git@v0.8.5" specify init --here --ai claude --force
uvx --from "git+https://github.com/github/spec-kit.git@v0.8.5" specify extension add --dev "${SPECKIT_STAGE}/extension"
uvx --from "git+https://github.com/github/spec-kit.git@v0.8.5" specify preset add --dev "${SPECKIT_STAGE}/preset"
```

`specify init` populates `.specify/` with core skills. The two `add --dev` calls register GAIA's local extension and preset against that core install. `extension add --dev` and `preset add --dev` consume their source directory when source equals install dest, so the install first stages throwaway copies of `.specify/extensions/gaia` and `.specify/presets/gaia` into a unique in-project temp dir (`SPECKIT_STAGE`) and points the `--dev` adds at those copies, leaving the originals in `.specify/` intact.

## When to use

- `/gaia-spec`: Socratic discovery wrapper (see [[GAIA Spec]]). The user-facing entry point.
- `/speckit.specify` / `/speckit.clarify`: invoked by the wrapper. Direct invocation also works in a GAIA project; the GAIA preset still produces GAIA-shaped artifacts.

## Architecture

GAIA distributes a spec-kit **extension** at `.specify/extensions/gaia/` (declares the `speckit.gaia.spec` wrapper plus five hook-target commands, `constitution-check`, `self-review`, `lint`, `uat-write`, `wiki-promote`, and the unhooked `spec-close` lifecycle command) and a **preset** at `.specify/presets/gaia/` (replaces `speckit.specify` under `strategy: wrap` and replaces `spec-template`). Both are GAIA-internal: not published to spec-kit's catalog; distribution is via the GAIA template.

The extension also automates the implement half of the SPEC lifecycle: the `before_implement` hook (`uat-write`) renders the active SPEC's PO-authored UATs into Playwright e2e specs at `.playwright/e2e/spec-NNN/` before `/speckit-implement` edits source, and the `after_implement` hook (`wiki-promote`) promotes merged SPEC content into the wiki on `/speckit-implement` completion. The unhooked `spec-close` command closes a SPEC after its PR merges, optionally draining a deferred wiki-promote, then prompting to archive, delete, or keep the local SPEC artifact.

Full contract details: [[spec-kit Extension Strategy]].

## Limits

- Hook events cover `before_specify`, `after_clarify`, `after_specify`, `before_implement`, and `after_implement`. There is no `on_save`, so the spec-to-plan handoff lives inline in the wrapper rather than in a hook.
- Hooks fire as slash commands (`EXECUTE_COMMAND` directive), not shell scripts. Hook bodies are markdown skill files.
- Default `strategy: replace` silently leaves `{CORE_TEMPLATE}` unsubstituted in command preset replacements. Use `strategy: wrap` when replacing a command preset.

## Related

- [[GAIA Spec]]: the workflow built on top.
- [[spec-kit Extension Strategy]]: architectural decision and contract invariants.
