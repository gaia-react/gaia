---
type: concept
title: Update Workflow
status: active
created: 2026-04-22
updated: 2026-05-01
tags: [release, claude, adopter, drift]
---

# Update Workflow

How `/update-gaia` pulls a newer GAIA release into an initialized project without clobbering customizations. Modeled on GSD's update pattern: explicit confirmation, three-way diff per file, sidecar patches for conflicts, no silent overwrite.

## Primitives

| File                  | Role                                                                                                                |
| --------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `.gaia/VERSION`       | Adopter's current baseline — which GAIA version `my-app/` was scaffolded from (or last `/update-gaia`d to).         |
| `.gaia/manifest.json` | Ships with every release. Maps each file in the release to a class.                                                 |
| `.gaia/cache/`        | Gitignored. Holds downloaded baseline + latest tarballs for the 3-way comparison.                                   |
| `.gaia-merge/`        | Gitignored. Sidecar `.patch` files emitted for files the update can't safely auto-merge. Adopter resolves manually. |
| `.gaia-backup/`       | Gitignored. Per-timestamp backups of any file the adopter agreed to overwrite.                                      |

## File classes

The manifest assigns each shipped file exactly one class. Anything **not** in the manifest is implicitly adopter-owned and invisible to `/update-gaia`.

| Class        | Meaning                                                                                                                                     | Drift handling                                                                                        |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `owned`      | GAIA controls fully — skills, commands, rules, hooks, config files.                                                                         | Pristine → overwrite silently. Drifted → prompt: skip / overwrite / backup+overwrite.                 |
| `shared`     | GAIA seeds; adopter customizes — `package.json`, `CLAUDE.md`, `README.md`, `.claude/settings.json`, `.github/workflows/*`, `wiki/index.md`. | Pristine → overwrite silently. Drifted → write `.gaia-merge/<path>.patch`, skip, let adopter resolve. |
| `wiki-owned` | GAIA-seeded wiki pages adopter may edit — concepts, decisions, modules, flows, dependencies.                                                | Same as `shared`.                                                                                     |
| _(implicit)_ | Adopter-owned. `wiki/hot.md`, `wiki/log.md`, `CHANGELOG.md`, and any file the adopter created.                                              | Never touched by `/update-gaia`.                                                                      |

Sentinel paths (always adopter-owned regardless of what GAIA ships): `wiki/hot.md`, `wiki/log.md`, `CHANGELOG.md`, `.gaia/VERSION`, `.gaia/manifest.json`.

## Flow

1. Read `.gaia/VERSION`. Missing → tell user to run `/gaia-init` on a fresh `create-gaia` scaffold.
2. Resolve latest release via `gh release list --repo gaia-react/gaia` (or GitHub API fallback).
3. Compare to baseline. Same or older → exit. Never downgrade.
4. Show the adopter the release notes and **confirm** before touching anything.
5. Download baseline + latest tarballs to `.gaia/cache/`.
6. Walk the latest manifest. For each file, apply the decision table below.
7. Only after the full walk succeeds, bump `.gaia/VERSION` and replace `.gaia/manifest.json` with the latest version's copy.
8. Report summary: overwritten / added / skipped / conflicts / deleted / backed up.
9. Remind the adopter to review `.gaia-merge/`, run the [[Quality Gate]], and commit manually.

## Decision table

For every file `P` in the latest manifest:

| Condition                                                 | Action                                                                 |
| --------------------------------------------------------- | ---------------------------------------------------------------------- |
| Not in adopter, not in baseline                           | **New file** — add (default yes).                                      |
| Not in adopter, present in baseline                       | Adopter deleted — **skip** (respect intent).                           |
| `adopter[P] == baseline[P]`                               | **Overwrite** with latest (any class).                                 |
| Adopter drifted, latest unchanged from baseline           | **Skip** (no upstream change).                                         |
| Adopter drifted, latest changed, `owned`                  | Show diff, prompt `skip` (default) / `overwrite` / `backup+overwrite`. |
| Adopter drifted, latest changed, `shared` or `wiki-owned` | Write `.gaia-merge/<path>.patch`. Adopter resolves.                    |

Files deleted upstream (in baseline, not in latest):

| Condition                   | Action                              |
| --------------------------- | ----------------------------------- |
| Not in adopter              | Already gone. Skip.                 |
| `adopter[P] == baseline[P]` | Prompt `delete` (default) / `keep`. |
| Adopter drifted             | Prompt `keep` (default) / `delete`. |

## Safety invariants

- **Never touch adopter-owned paths.** Anything not in the manifest is invisible.
- **Never auto-clobber drift.** `owned` drift prompts; `shared` / `wiki-owned` drift writes a patch.
- **Atomic version marker.** `.gaia/VERSION` flips to latest only after the full walk succeeds. Abort mid-walk → version stays at baseline, and a re-run resumes cleanly. Any already-overwritten files live in `.gaia-backup/`.
- **No auto-commit.** `/update-gaia` leaves the working tree dirty; the adopter reviews + commits.

## Rollback

`/update-gaia` does not commit, so the rollback path depends on whether the adopter has already committed the merge.

**Before commit** — discard the entire update:

```bash
git restore --staged --worktree .
rm -rf .gaia-merge .gaia-backup
```

`git restore` reverts every overwritten file (including `.gaia/VERSION` and `.gaia/manifest.json`) to its committed baseline. The sidecar `.gaia-merge/` and `.gaia-backup/` directories are gitignored, so `git restore` does not touch them — the `rm -rf` is the cleanup pass.

**After commit** — revert the commit:

```bash
git revert <update-commit-sha>
```

A single revert undoes the merge cleanly because `/update-gaia` lands its changes as ordinary edits, not a merge commit. The revert restores `.gaia/VERSION` and `.gaia/manifest.json` to baseline alongside everything else.

In both cases the adopter is back at the prior baseline and can retry `/update-gaia` against the same release. Local customizations made AFTER the rollback point survive (`git restore` and `git revert` only undo the update walk's edits, not subsequent commits or unstaged changes touching files outside the manifest).

## When to run

After a new GAIA release is announced (watch releases on `gaia-react/gaia`). Cadence is fully at the adopter's discretion — skipping versions is fine; the three-way diff works with any gap.

## See also

- [[Quality Gate]] — run the gate after the `update-gaia` skill finishes and before committing.

## Communications Guidance (User-Facing Docs)

The update flow is **fully automatic from the adopter's perspective**: the `gaia-session-update-prompt.sh` SessionStart hook detects available updates and presents the choice. **Do not mention `/update-gaia`, the `update-gaia` skill, or any manual update step in user-facing release notes, README, CHANGELOG, or marketing docs.** Surfacing a manual command implies adopters need to remember to run it — which is wrong.

The skill and command files in `.claude/skills/update-gaia/` exist as the implementation but must not be promoted as a user-invoked workflow in external-facing copy.

_Recorded 2026-05-01._
