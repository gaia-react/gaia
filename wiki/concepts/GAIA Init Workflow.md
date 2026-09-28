---
type: concept
status: active
created: 2026-05-07
updated: 2026-08-04
tags: [concept, claude, cli, workflow]
---

# GAIA Init Workflow

The `/gaia init` namespace provides subcommands for on-boarding a cloned GAIA template into a new project. Each subcommand handles a distinct phase of the setup process.

## Subcommands

**`strip-branding`**: Removes GAIA-specific branding and identifiers from the codebase (references in README, config files, and CLI scaffolds). Prepares a "vanilla" template for forking or white-label adoption. The `--title` it takes is escaped for each sink's own syntax (a single-quoted JavaScript literal in `.storybook/preview.ts`) rather than passed through raw.

**`configure-i18n`**: Edits `app/languages/index.ts` (the `LANGUAGES` array and `Language` union) and `app/i18n.ts` (`fallbackLng`) to match the chosen locales when `--strip false`, or removes the i18n scaffolding when `--strip true`. The locale list is recorded in the init state file.

**`rename`**: Changes the project name and title across the files that carry an identity: `package.json` (`name` → kebab slug), the first `# ` heading in `CLAUDE.md`, and the seeded English language files (`app/languages/en/common.ts` `meta.siteName`, and `app/languages/en/pages/_index.ts` `heroTitle` / `title` / `meta.title`). The `CLAUDE.md` heading is a precondition, not something this step creates: a `CLAUDE.md` with no top-level `# ` heading above its first fenced code block fails the step outright (`claude_md_heading_missing`, exit 1) before any file is renamed, rather than silently leaving the title-less file in place. Add the missing heading and re-run `rename` directly, since `resume` cannot replay a step that never completed. `--title` is spliced into the seeded language files through a function replacement that interprets no `$`-pattern and escapes the quote it matched, so a title like `Steve's App` or one containing `$1` lands as the literal string rather than corrupting the file.

Each language-file key is optional (the shipped `_index.ts` carries only `meta.title`) and is rewritten wherever it is a quoted string literal; a key present but holding something else (a template literal, a computed value) is left untouched. Each key is matched wherever its own rewrite looks for it, so a value wrapped in one quote may hold the other bare: `siteName: "Steve's Template"` is an ordinary literal and is rewritten, as is a value this command itself wrote when the title carried the non-wrapping quote.

**`wire-statusline`**: Inserts the canonical GAIA `statusLine` block at the top level of the chosen Claude settings file (`--mode project` writes `.claude/settings.json`, `global` writes `~/.claude/settings.json`, `skip` is a no-op). The statusline surfaces the per-machine setup gate plus `/update-gaia`, `/update-deps`, `/gaia-harden`, and `/gaia-audit` nudges.

**`bootstrap-env`**: Copies `.env.example` to `.env` when `.env` does not yet exist, running as a CLI subprocess so it bypasses Claude Code's `Write(.env)` deny rule. No-op when `.env` already exists or `.env.example` is absent.

**`configure-automation`**: Writes an automation config file (`automation.json` under `.gaia/`; created on first run) with the wiki maintenance mode and `setup_complete: false`. `/setup-gaia` later flips `setup_complete` to `true` and commits the file as part of its finalize step; it is absent from `.gaia/manifest.json`, so `/update-gaia` never touches it, and it also carries committed team-level GAIA preferences (such as the git isolation policy, once a team sets one) alongside the CI configuration.

**`finalize`**: Deletes `.claude/commands/gaia-init.md` so init cannot be re-run. It does not commit; the user reviews and commits the init changes.

**`resume`**: Resumes an interrupted init flow. If a previous init ran and failed partway, re-runs from where it left off without re-running completed phases.

## Target guard

The router refuses to run any subcommand in the wrong tree, before dispatching to the step: a tree with no `.gaia/manifest.json` is not a GAIA project (`not_a_gaia_project`), and a tree carrying the CLI's TypeScript sources is the GAIA template source itself rather than a project scaffolded from it (`gaia_template_source`, since adopters receive only the compiled `.gaia/cli/gaia` binary, never the source). The guard lives on the router rather than on any one step because all eight steps resolve their target identically from ambient state, and it hands the step the same resolved path it checked so the two cannot disagree.

## Integration

All subcommands are called by `/gaia-init` (the skill), which prompts the user through each phase and dispatches the matching subcommand. The init workflow can also be run manually via `gaia init <subcommand>` from the project root.
