---
type: concept
status: active
created: 2026-10-01
updated: 2026-10-04
tags: [concept, claude, config, workflow]
---

# Project Config

`.gaia/project.json` is the committed, team-shared file where a GAIA project records its own preferences. It holds answers a repository owner gives once and every clone then reads, as opposed to a per-machine choice, which lives in gitignored local settings. The audit loop's context checkpoint line is one such per-machine choice: it lives in `.gaia/local/protected/checkpoint-override.json`, not here, because teammates can run different models with different context windows, so no single committed value fits them all. That file is machine-local, human-edited, can only lower the shipped default, and Claude tool writes to it are denied; see [[Local Working State]].

## Keys

All keys are optional except `version`, which is `1`.

| Key | Values | Meaning |
| --- | --- | --- |
| `sandbox_recommended` | `true` or `false` | The owner's recommendation to run Claude Code's OS sandbox. Each machine still resolves it for itself; see [[OS Sandbox]]. |
| `isolation_policy` | `always-worktree`, `prefer-worktree`, `prefer-branch` | How a session isolates work that closes an issue or runs a plan. The reading rules live in `.claude/skills/gaia/references/isolation.md`. |

A reader treats an unknown or invalid value as absent, so a typo or a value a newer GAIA wrote never breaks the file. The known values are enforced when the file is written.

## Writers

Two CLI commands write the file, each creating it (with `version` set) when it does not exist:

- `gaia init write-project-config`, called by `/gaia-init` for the sandbox recommendation and the isolation policy (see [[GAIA Init Workflow]]).
- `gaia setup-ci write-isolation-policy`, called by `/setup-gaia` when a repo admin records the isolation policy.

A writer merges into the existing JSON, so a key it does not know survives, and writes atomically.

## Readers

`/setup-gaia` reads the file to resolve the sandbox recommendation and the isolation policy before it asks anything a prior answer already settled. The isolation policy is also read at the start of work that cuts a branch or worktree.

## Ownership

The file is adopter-owned. It is absent from `.gaia/manifest.json`, so `/update-gaia` never overwrites or deletes it, and it is committed so the whole team shares one answer. No GAIA command creates it before something has a value to record.

See [[Update Workflow]] for the merge rules the file sits outside.
