---
type: concept
status: active
created: 2026-05-07
updated: 2026-05-07
tags: [concept, claude, cli, workflow]
---

# GAIA Init Workflow

The `/gaia init` namespace provides subcommands for on-boarding a cloned GAIA template into a new project. Each subcommand handles a distinct phase of the setup process.

## Subcommands

**`strip-branding`** — Removes GAIA-specific branding and identifiers from the codebase (references in README, config files, and CLI scaffolds). Prepares a "vanilla" template for forking or white-label adoption.

**`configure-i18n`** — Guides locale setup (default language, supported locales, i18n config generation). Stores preferences in `.gaia/local/i18n.json` for use by scaffolds.

**`rename`** — Changes the project name and workspace identifier throughout the codebase (package.json, Remix config, site metadata, etc.).

**`wire-statusline`** — Registers GAIA status indicators in the Claude Code statusline (shows drift count, setup gate status, mentorship state). Edits `.claude/settings.json` to inject the status hook.

**`finalize`** — Commits the init changes (branding removal, i18n config, renames, statusline setup) in a single structured commit: `feat: finalize gaia init — project renamed, branding stripped, i18n configured, statusline wired`.

**`resume`** — Resumes an interrupted init flow. If a previous init ran and failed partway, re-runs from where it left off without re-running completed phases.

## Integration

All subcommands are called by `/gaia-init` (the skill), which prompts the user through each phase and dispatches the matching subcommand. The init workflow can also be run manually via `gaia init <subcommand>` from the project root.
