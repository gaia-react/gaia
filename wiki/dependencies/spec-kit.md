---
type: dependency
status: active
package: spec-kit
version: v0.8.5
role: spec-authoring-engine
created: 2026-05-06
updated: 2026-05-06
tags: [dependency, spec-kit, claude]
---

# spec-kit

[GitHub spec-kit](https://github.com/github/spec-kit) is the SPEC-authoring engine that backs GAIA's `/gaia spec` workflow. GAIA wraps it with a Socratic discovery loop, GAIA-shaped frontmatter, and an inline chain-trigger to `/gaia plan`.

## Pin

- Version: `v0.8.5` exactly (installed via `uvx --from git+https://github.com/github/spec-kit.git@v0.8.5`).
- Compatible range declared in extension + preset: `>=0.8.5,<0.10.0`. Drift detection at runtime via `.specify/extensions/gaia/lib/version-check.sh`.
- Scope: project (registered via `specify init --here` during `/gaia-init`).
- Runtime: requires `uv` (Astral Python toolchain runner).

## Install

`/gaia-init` Step 9 runs three commands after the scaffold:

```bash
specify init --here --ai claude --force
specify extension add --dev .specify/extensions/gaia
specify preset add --dev .specify/presets/gaia
```

`specify init` populates `.specify/` with core skills. The two `add --dev` calls register GAIA's local extension and preset against that core install.

## When to use

- `/gaia spec` — Socratic discovery wrapper (see [[GAIA Spec]]). The user-facing entry point.
- `/speckit.specify` / `/speckit.clarify` — invoked by the wrapper. Direct invocation also works in a GAIA project; the GAIA preset still produces GAIA-shaped artifacts.

## Architecture

GAIA distributes a spec-kit **extension** at `.specify/extensions/gaia/` (declares `speckit.gaia.spec` and three hook-target commands) and a **preset** at `.specify/presets/gaia/` (replaces `speckit.specify` under `strategy: wrap` and replaces `spec-template`). Both are GAIA-internal — not published to spec-kit's catalog; distribution is via the GAIA template.

Full contract details and the SPEC-002 correction history: [[spec-kit Extension Strategy]].

## Limits

- Hook events are limited to `before_specify`, `after_clarify`, `after_specify`. There is no `on_save`. Chain-triggers must live inline.
- Hooks fire as slash commands (`EXECUTE_COMMAND` directive), not shell scripts. Hook bodies are markdown skill files.
- Default `strategy: replace` silently leaves `{CORE_TEMPLATE}` unsubstituted in command preset replacements. Use `strategy: wrap` when replacing a command preset.

## Related

- [[GAIA Spec]] — the workflow built on top.
- [[spec-kit Extension Strategy]] — architectural decision and contract invariants.
