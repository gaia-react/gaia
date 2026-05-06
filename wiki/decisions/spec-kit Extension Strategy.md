---
type: decision
title: spec-kit Extension Strategy
status: active
priority: 1
date: 2026-05-06
created: 2026-05-06
updated: 2026-05-06
tags: [decision, claude, spec-kit, architecture]
---

# spec-kit Extension Strategy

GAIA's `/gaia spec` workflow runs on top of [GitHub spec-kit](https://github.com/github/spec-kit) v0.8.5. This page records the load-bearing contract decisions that emerged from SPEC-002's empirical contract correction.

## Decision

GAIA distributes a spec-kit **extension** at `.specify/extensions/gaia/` and a spec-kit **preset** at `.specify/presets/gaia/`. The pair is registered during `/gaia-init` and ships in the GAIA template.

**Extension** declares slash commands and lifecycle hooks. **Preset** replaces core templates. Both are needed:

- The extension owns `speckit.gaia.spec` (the wrapper command) plus three hook-target commands (`constitution-check`, `lint`, `self-review`) declared as `before_specify`, `after_clarify`, `after_specify`.
- The preset replaces `speckit.specify` and `spec-template` so a bare `/speckit-specify` invocation in a GAIA project still produces GAIA-shaped artifacts at `.gaia/local/specs/SPEC-NNN.md`. Without the preset, the core path bypasses GAIA entirely.

## Contract invariants

These five facts are the hard-won output of sandbox probing v0.8.5's actual implementation. Earlier drafts assumed a different contract; they were wrong.

### 1. Hooks are slash commands, not shell scripts

When core invokes a skill (e.g. `/speckit-specify`), it reads `.specify/extensions.yml` for the matching event and emits an `EXECUTE_COMMAND: <id>` markdown directive into the agent's reasoning context. The agent then invokes the rendered slash command as a normal Claude skill. **No JSON payload, no stdin pipe, no env var.**

Block semantics live inside the hook command body — a "block" is a refusal message that the wrapper agent reads and chooses not to proceed past. There is no machine-enforced halt.

### 2. There is no `on_save` event

Spec-kit's hook lifecycle covers `before_specify`, `after_clarify`, and `after_specify`. **There is no `on_save`.** The chain-trigger from `/gaia spec` to `/gaia plan` lives inline at the end of the wrapper (Step 11 in `references/spec.md`), not in a hook.

### 3. Preset must declare `strategy: wrap` for command replacement

When a preset's `provides.templates[]` entry replaces a core command, the entry must declare `strategy: wrap` and use the `{CORE_TEMPLATE}` token in its body. The default `strategy: replace` silently leaves the literal `{CORE_TEMPLATE}` token unsubstituted, which breaks core's hook-bus path.

GAIA's `speckit.specify` replacement uses `wrap`. The `spec-template` replacement uses `replace` because templates are pure content, not orchestration. See `.specify/presets/gaia/preset.yml`.

### 4. Version pin is a range with runtime drift detection

The extension and preset declare `requires.speckit_version: ">=0.8.5,<0.10.0"`. There is no `requires.speckit_invocation` field — that was a SPEC-001 fiction. Drift is enforced at runtime by `lib/version-check.sh`, which reads the active spec-kit version and surfaces a warning when it falls outside the range.

`/gaia-init` pins the install at `v0.8.5` exactly via `uvx --from git+https://github.com/github/spec-kit.git@v0.8.5 specify ...`.

### 5. Extension and preset are GAIA-internal

Neither is published to spec-kit's public extension/preset catalog. Distribution is via the GAIA template — `/gaia-init` clones them in place during scaffold, then runs `specify extension add --dev` and `specify preset add --dev` against the local directories.

## How the install lands

`/gaia-init` Step 9 (post-scaffold):

```bash
specify init --here --ai claude --force
specify extension add --dev .specify/extensions/gaia
specify preset add --dev .specify/presets/gaia
```

`specify init --here` populates `.specify/` with core skills. The two `add --dev` calls register GAIA's local extension and preset against that core install.

## What changed vs. the original design

The first attempt (PR #84, SPEC-001) built against assumed contracts that diverged from spec-kit's actual extension API. SPEC-002 corrected the contracts via direct sandbox probing of v0.8.5 source. Three UATs changed shape:

| UAT | Original design | Corrected design |
|-----|-----------------|------------------|
| UAT-008 | `hooks/after_specify.sh` shell script | `commands/lint.md` slash command via `after_specify` hook |
| UAT-010 | Fictional `on_save` hook | Inline `AskUserQuestion` in `/gaia spec` Step 11 |
| UAT-018 | `==X.Y.Z` literal pin + fictional `requires.speckit_invocation` field | `requires.speckit_version: ">=0.8.5,<0.10.0"` + `lib/version-check.sh` |

The salvage map and per-commit verdict for the rewrite live in `.gaia/local/specs/SPEC-001-refit-decision.md`. The empirical contract source-of-truth is `.gaia/local/specs/SPEC-001-revised-contracts.md`.

## Sandbox validation

`.specify/extensions/gaia/test/v2-validation.md` captures live evidence against `/tmp/specify-validate-001/` confirming each invariant: extension+preset install, `{CORE_TEMPLATE}` substitution under `strategy: wrap`, `HookExecutor.format_hook_message` emits `EXECUTE_COMMAND` for the three GAIA hooks, `on_save` renders `(no hooks)`, and `specify preset resolve spec-template` returns the GAIA preset path.

`.specify/extensions/gaia/test/uat-evidence.md` cross-references each of SPEC-001's 18 UATs to the artifact (manifest, command body, helper script, or sandbox transcript) that satisfies it.

## Related

- [[GAIA Spec]] — the wrapper workflow this strategy enables.
- [[spec-kit]] — pin, install command, runtime requirements.
- [[GAIA Plan]] — downstream chain target.
