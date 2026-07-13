---
type: decision
title: spec-kit Extension Strategy
status: active
priority: 1
date: 2026-05-06
created: 2026-05-06
updated: 2026-07-13
tags: [decision, claude, spec-kit, architecture]
---

# spec-kit Extension Strategy

GAIA's `/gaia-spec` workflow runs on top of [GitHub spec-kit](https://github.com/github/spec-kit) v0.8.5. This page records the load-bearing contract decisions for that integration.

## Decision

GAIA distributes a spec-kit **extension** at `.specify/extensions/gaia/` and a spec-kit **preset** at `.specify/presets/gaia/`. The pair is registered during `/gaia-init` and ships in the GAIA template.

**Extension** declares slash commands and lifecycle hooks. **Preset** replaces core templates. Both are needed:

- The extension owns `speckit.gaia.spec` (the wrapper command) plus five hook-target commands: `constitution-check` (`before_specify`), `self-review` (`after_clarify`), `lint` (`after_specify`), `uat-write` (`before_implement`), and `wiki-promote` (`after_implement`). It also ships the unhooked `spec-close` command.
- The preset replaces `speckit.specify` and `spec-template` so a bare `/speckit-specify` invocation in a GAIA project still produces GAIA-shaped artifacts at `.gaia/local/specs/SPEC-NNN/SPEC.md`. Without the preset, the core path bypasses GAIA entirely.

## Contract invariants

Seven contract facts about spec-kit v0.8.5's extension API:

### 1. Hooks are slash commands, not shell scripts

When core invokes a skill (e.g. `/speckit-specify`), it reads `.specify/extensions.yml` for the matching event and emits an `EXECUTE_COMMAND: <id>` markdown directive into the agent's reasoning context. The agent then invokes the rendered slash command as a normal Claude skill. **No JSON payload, no stdin pipe, no env var.**

Block semantics live inside the hook command body; a "block" is a refusal message that the wrapper agent reads and chooses not to proceed past. There is no machine-enforced halt.

### 2. There is no `on_save` event

Spec-kit's hook lifecycle covers `before_specify`, `after_clarify`, `after_specify`, `before_implement`, and `after_implement`. **There is no `on_save`.** The `/gaia-plan` handoff from `/gaia-spec` lives inline at the end of the wrapper (Step 11 in `references/spec.md`), not in a hook.

### 3. Preset must declare `strategy: wrap` for command replacement

When a preset's `provides.templates[]` entry replaces a core command, the entry must declare `strategy: wrap` and use the `{CORE_TEMPLATE}` token in its body. The default `strategy: replace` silently leaves the literal `{CORE_TEMPLATE}` token unsubstituted, which breaks core's hook-bus path.

GAIA's `speckit.specify` replacement uses `wrap`. The `spec-template` replacement uses `replace` because templates are pure content, not orchestration. See `.specify/presets/gaia/preset.yml`.

### 4. Version pin is a range with runtime drift detection

The extension and preset declare `requires.speckit_version: ">=0.8.5,<0.10.0"`. Drift is enforced at runtime by `lib/version-check.sh`, which reads the active spec-kit version and surfaces a warning when it falls outside the range.

`/gaia-init` pins the install at `v0.8.5` exactly via `uvx --from git+https://github.com/github/spec-kit.git@v0.8.5 specify ...`.

### 5. Extension and preset are GAIA-internal

Neither is published to spec-kit's public extension/preset catalog. Distribution is via the GAIA template; `/gaia-init` clones them in place during scaffold, then runs `specify extension add --dev` and `specify preset add --dev` against the local directories.

### 6. The canonical artifact layout is a folder, not a flat file

Each SPEC lives in its own `.gaia/local/specs/SPEC-NNN/` folder containing `SPEC.md` plus any sibling notes (e.g. `IMPLEMENTATION-NOTES.md`). The folder is the archival unit. `lib/spec-folderize.sh` migrates any legacy flat `.gaia/local/specs/SPEC-NNN.md` into the folder shape, moving sibling `SPEC-NNN-<rest>.md` files alongside.

### 7. /gaia-spec runs its own clarify loop

- `/gaia-spec` does not invoke `/speckit-clarify`. It runs GAIA's own Socratic loop, whose mechanics live in `.claude/skills/gaia/references/spec.md` (step 5) and `.specify/extensions/gaia/templates/clarify-prompts.md`, whose stop condition is a coverage scan over the topic bank, and whose question ceiling is GAIA's own.
- The self-review is dispatched by the wrapper as a `general-purpose` Agent (step 6), not through the `after_clarify` hook, so it runs identically on a project with spec-kit core installed and on one without.
- The `after_clarify` hook declaration remains in `extension.yml`: a bare `/speckit-clarify` invocation still fires it.
- Why not a preset override of the core clarify body: hook emission in spec-kit is prose-driven, the core clarify body itself carries the hook blocks, and only `strategy: replace` produces a body free of the core cap text. A `replace` that does not re-implement those hook blocks silently stops firing them, so an override buys a permanent upstream-drift maintenance burden to reimplement a loop GAIA already reimplements in full. Decoupling makes the de-facto behavior official at zero cost.
- Accepted consequence: a bare `/speckit-clarify` on an adopter machine keeps core's question cap and keeps writing core's off-shape `## Clarifications` bullets. That is true today and is tracked separately.

## How the install lands

`/gaia-init` Step 9 (post-scaffold):

```bash
specify init --here --ai claude --force
specify extension add --dev .specify/extensions/gaia
specify preset add --dev .specify/presets/gaia
```

`specify init --here` populates `.specify/` with core skills. The two `add --dev` calls register GAIA's local extension and preset against that core install.

## Related

- [[GAIA Spec]]: the wrapper workflow this strategy enables.
- [[spec-kit]]: pin, install command, runtime requirements.
- [[GAIA Plan]]: downstream handoff target.
