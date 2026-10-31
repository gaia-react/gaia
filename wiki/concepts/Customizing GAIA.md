---
type: concept
title: Customizing GAIA
status: active
created: 2026-10-23
updated: 2026-10-29
tags: [concept, claude, configuration, customization]
---

# Customizing GAIA

Where each adopter customization lives, which files are safe to edit, and the check Claude runs after. A request to "customize", "extend", "turn off" or "change GAIA's ..." starts here.

## Where a change goes

`/update-gaia` sorts every file by its class in `.gaia/manifest.json`, the one authority on any file's class; [[Update Workflow#File classes]] says what each class means. In short:

- **A file you create** is absent from the manifest, so it is adopter-owned and `/update-gaia` never touches it. A new rule, skill, agent, command or hook beside GAIA's is the change that never meets a merge.
- **`shared` and `wiki-owned`** files are seeded by GAIA and meant to be edited. An update three-way merges your edits with GAIA's and asks about any hunk it cannot settle.
- **`owned`** files are GAIA's. An edit survives an update the same way, as a three-way merge, but every GAIA release that touches the file can turn it into a question. Prefer a new file that layers on (a path-scoped rule that adds to a shipped one, an overlay, a project label) over editing an owned file, and say so to the user before editing one.

Before editing a GAIA file, read its class:

```
jq -r --arg path '<repo-relative path>' '.files[$path] // "adopter-owned"' .gaia/manifest.json
```

## Customization map

| Customization | Where it lives | Class | How-to | Check Claude runs after |
| --- | --- | --- | --- | --- |
| Team preferences: isolation policy, sandbox recommendation, fitness nudge threshold | `.gaia/project.json` | adopter-owned | [[Project Config]] | `jq . .gaia/project.json` parses |
| Add a rule, skill, agent or command | `.claude/rules/`, `.claude/skills/`, `.claude/agents/`, `.claude/commands/`, or the package's own `.claude/` | adopter-owned (new file) | [[Claude Integration Conventions]] (layer choice, `paths:` scoping) | `.gaia/cli/gaia fitness check --json` |
| Change a shipped rule, skill, agent or command | the shipped file | `owned` | layer a new file on it where possible (above) | `.gaia/cli/gaia fitness check --json` |
| Add, disable or override a hook | `.claude/hooks/`, registered in `.claude/settings.json` | `shared` settings, `owned` bundled hooks | [[Claude Hooks#Adding hooks]], [[Claude Hooks#Disabling or overriding a hook]]; the shell audit member reviews hooks you add or edit; an edit to `.claude/settings.json` asks first in every permission mode, so an unattended run cannot make it through those routes, and the shell audit member reviews settings changes too | `./.gaia/cli/gaia packages sync-settings --check` |
| Package-only settings (permissions, env) | `frontend/.claude/settings.overlay.json` | `shared` | [[Package Descriptor]] | `./.gaia/cli/gaia packages sync-settings`, then `--check` |
| Add a package beside `frontend/` (a backend) | the package folder, `pnpm-workspace.yaml`, `.gaia/packages.json` | adopter-owned, `shared`, sentinel | [[Claude Integration Conventions#6. Monorepo retrofit playbook]] | that playbook's closing verify block |
| Add a Code Audit Team member | a new agent, its `.gaia/audit-ci.yml` roster entry, and any new finding classes in `.gaia/finding-classes.json` | adopter-owned (new agent), `shared` roster, sentinel classes file | [[Registering a Code Audit Team Member]] | `bash .gaia/scripts/verify-audit-roster.sh` ([[Registering a Code Audit Team Member#6. Verify the roster]]) |
| Languages and translations | `frontend/app/languages/` | per the manifest | [[i18n]] | the closing check that page names |
| Swap the API layer or add an external service | new rules and agent extensions | adopter-owned (new files) | [[Claude Integration Conventions#9. API service layer swap]] | `.gaia/cli/gaia fitness check --json` |
| Add a CI workflow | `.github/workflows/` | adopter-owned (new file); GAIA's shipped workflows are `shared` | [[Workflow Naming Convention]]; GAIA's `tests.yml` lints changed shell and runs bats by default; `"shellcheck": false` in `.gaia/project.json` turns the lint off ([[Shell Testing and CI]]) | the pushed branch's Actions run; the `code-audit-github-workflows` member audits the file at merge |
| Project labels | GitHub, documented in the appendix of [[GitHub Labels]] | `wiki-owned` page; `.gaia/labels.json` is `owned` | [[GitHub Labels#Project labels]] | `.gaia/cli/gaia labels sync --dry-run` reports the label as unrecognized, never removed |
| Silence a fitness finding | `.claude/gaia-fitness.json` | adopter-owned | [[#Silencing a fitness finding]] | `.gaia/cli/gaia fitness check --json` lists it as suppressed |
| Move the base dev and Storybook ports | `frontend/dev-ports.ts` and two shell libraries | `owned` | [[#Changing the base ports]] | `bash .gaia/scripts/ports.sh` |
| Statusline left side | `/setup-gaia` records the choice per machine | per-machine | [[Claude Integration]] (statusline paragraph), `.claude/skills/gaia/references/setup/statusline-left.md` | the statusline still shows GAIA's nudges |
| Turn off the adoption ping | the `GAIA_TELEMETRY_PING_DISABLE` environment variable | per-machine | [[GAIA CLI#Adoption ping]] | none needed |

Files with no adopter extension point, where the only change is an edit to an `owned` file: `.githooks/pre-commit` (a package changes what it runs through its own `package.json` scripts, which [[Pre-commit Hooks]] names), `.gaia/conventional-commits.json` ([[Naming Conventions]]), and the generator templates under `.gaia/cli/templates/` ([[CLI Scaffolding]]).

Replacing `statusLine` in any settings file with a command that does not run `.gaia/statusline/gaia-statusline.sh` stops the GAIA nudges and the context readings the audit loop's checkpoint relies on; `statusline-left.md` (`## The routing warning`) says how to keep both.

## Silencing a fitness finding

`.gaia/cli/gaia fitness check --json` reads an optional `.claude/gaia-fitness.json`. Each entry silences one finding, matched by the finding's `rule_id` and `file` as the JSON report prints them, and carries the reason a reader needs:

```json
{
  "version": 1,
  "ignore": [
    {
      "rule_id": "<rule_id from the report>",
      "path": "<file from the report>",
      "reason": "Why this finding does not apply here."
    }
  ]
}
```

A malformed file is itself a finding, so the check never runs silently with a broken suppression list. `gaia fitness rules --json` lists every rule id. See [[Claude Integration Fitness]].

## Changing the base ports

The main checkout uses the base ports (dev 5173, Storybook 6006) and every linked worktree offsets them by its slot ([[Worktrees#Ports per worktree]]). GAIA has no setting for the base: it is a literal in three `owned` files, and all three must agree, or the main checkout's servers and the worktree slots disagree about which ports are whose.

1. `DEV_BASE_PORT` and `STORYBOOK_BASE_PORT` in `frontend/dev-ports.ts`, which Vite, Storybook and Playwright read in the main checkout.
2. The defaults in `gaia_ports_dev_base_port` and `gaia_ports_storybook_base_port` in `.gaia/scripts/worktree-ports-lib.sh`, which assign the worktree slots and back `ports.sh`.
3. The defaults in `gaia_server_reap_tombstones` in `.gaia/scripts/server-process-lib.sh`.

The environment variables those shell functions read are test seams, not a setting: leave them unset. Because the files are `owned`, each edit is a three-way merge on the next `/update-gaia`; tell the user so before making it. Then re-enter each linked worktree (or run `bash .claude/hooks/provision-worktree.sh <worktree-path>`) so its port file is rewritten, and run `bash .gaia/scripts/ports.sh` in the main checkout and in one worktree to confirm both print the new numbers.

## Closing a customization

Every row above ends with its check. Claude runs it before reporting the customization done, and then the [[Quality Gate]] when the commit carries source. A check Claude cannot run (no `gh` auth, no network) is reported as not run, never as passed.

See [[Update Workflow]], [[Project Config]], [[Claude Integration Conventions]].
