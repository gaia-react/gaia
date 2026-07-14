---
type: concept
status: active
created: 2026-05-07
updated: 2026-06-24
tags: [concept, claude, cli, workflow]
---

# GAIA Init Workflow

The `/gaia init` namespace provides subcommands for on-boarding a cloned GAIA template into a new project. Each subcommand handles a distinct phase of the setup process.

## Subcommands

**`strip-branding`**: Removes GAIA-specific branding and identifiers from the codebase (references in README, config files, and CLI scaffolds). Prepares a "vanilla" template for forking or white-label adoption.

**`configure-i18n`**: Edits `app/languages/index.ts` (the `LANGUAGES` array and `Language` union) and `app/i18n.ts` (`fallbackLng`) to match the chosen locales when `--strip false`, or removes the i18n scaffolding when `--strip true`. The locale list is recorded in the init state file.

**`rename`**: Changes the project name and title across the files that carry an identity: `package.json` (`name` → kebab slug), the first `# ` heading in `CLAUDE.md`, and the seeded English language files (`app/languages/en/common.ts` `meta.siteName`, and `app/languages/en/pages/_index.ts` `heroTitle` / `title` / `meta.title`).

**`wire-statusline`**: Inserts the canonical GAIA `statusLine` block at the top level of the chosen Claude settings file (`--mode project` writes `.claude/settings.json`, `global` writes `~/.claude/settings.json`, `skip` is a no-op). The statusline surfaces the per-machine setup gate plus `/update-gaia`, `/update-deps`, `/gaia-harden`, and `/gaia-audit` nudges.

**`bootstrap-env`**: Copies `.env.example` to `.env` when `.env` does not yet exist, running as a CLI subprocess so it bypasses Claude Code's `Write(.env)` deny rule. No-op when `.env` already exists or `.env.example` is absent.

**`configure-automation`**: Writes an automation config file (`automation.json` under `.gaia/`; created on first run) with the four maintenance-tool mode selections (wiki, update-deps, pnpm-audit, stale-branches) and `setup_complete: false`. `/setup-gaia` later flips `setup_complete` to `true` and commits the file as part of its finalize step; it is absent from `.gaia/manifest.json`, so `/update-gaia` never touches it, and it also carries committed team-level GAIA preferences (such as the git isolation policy, once a team sets one) alongside the CI configuration.

**`finalize`**: Deletes `.claude/commands/gaia-init.md` so init cannot be re-run. It does not commit; the user reviews and commits the init changes.

**`resume`**: Resumes an interrupted init flow. If a previous init ran and failed partway, re-runs from where it left off without re-running completed phases.

## Integration

All subcommands are called by `/gaia-init` (the skill), which prompts the user through each phase and dispatches the matching subcommand. The init workflow can also be run manually via `gaia init <subcommand>` from the project root.
