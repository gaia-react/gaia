---
type: concept
status: active
created: 2026-05-07
updated: 2026-10-03
tags: [concept, claude, cli, workflow]
---

# GAIA Init Workflow

The `/gaia init` namespace provides subcommands for on-boarding a cloned GAIA template into a new project. Each subcommand handles a distinct phase of the setup process.

## Subcommands

**`strip-branding`**: Removes GAIA-specific branding and identifiers from the codebase (references in README, config files, and CLI scaffolds). Prepares a "vanilla" template for forking or white-label adoption. The `--title` it takes is escaped for each sink's own syntax (a single-quoted JavaScript literal in `frontend/.storybook/preview.ts`) rather than passed through raw.

**`configure-i18n`**: Edits `frontend/app/languages/index.ts` (the `LANGUAGES` array and `Language` union) and `frontend/app/i18n.ts` (`fallbackLng`) to match the chosen locales when `--strip false`, or removes the i18n scaffolding when `--strip true`. The locale list is recorded in the init state file.

**`configure-data-layer`**: Applies the two data-layer answers `/gaia-init` Step 2 collects, and runs after `configure-i18n`. The first answer is the backend's field casing (snake_case, camelCase, an SDK client, or unsure). Only camelCase changes a file: it writes `useSnakeCase: false` into the domain layer's `api.ts` `create()` call. The SDK and unsure answers behave like snake_case and are recorded nowhere; an SDK-backed domain's request functions wrap the SDK instead of `api`, and the data-loading rule applies unchanged. The second answer is whether to use TanStack Query (default off). On, it pins the dependency in `frontend/package.json`, writes the Query runtime files, and makes one anchored edit each in the state provider, the Storybook preview, and the two Vite configs; it never runs pnpm. It is additive and idempotent (a missing anchor exits 1 with nothing written), and it prints one JSON line, `{"changed": [...], "next": [...]}`, where `next` lists `pnpm install` when the run added the dependency, then any `scaffold service <name> --queries-only` commands. `/gaia-init` runs `pnpm install` when Query is on. After init has finalized, `./.gaia/cli/gaia init configure-data-layer --query true` is the supported way to add Query later; see [[Data Loading]].

**`rename`**: Changes the project name and title across the files that carry an identity: `package.json` (`name` → kebab slug), the first `# ` heading in `CLAUDE.md`, and the seeded English language files (`frontend/app/languages/en/common.ts` `meta.siteName`, and `frontend/app/languages/en/pages/_index.ts` `heroTitle` / `title` / `meta.title`). The `CLAUDE.md` heading is a precondition, not something this step creates: a `CLAUDE.md` with no top-level `# ` heading above its first fenced code block fails the step outright (`claude_md_heading_missing`, exit 1) before any file is renamed, rather than silently leaving the title-less file in place. Add the missing heading and re-run `rename` directly, since `resume` cannot replay a step that never completed. `--title` is spliced into the seeded language files through a function replacement that interprets no `$`-pattern and escapes the quote it matched, so a title like `Steve's App` or one containing `$1` lands as the literal string rather than corrupting the file.

Each language-file key is optional (the shipped `_index.ts` carries only `meta.title`) and is rewritten wherever it is a quoted string literal; a key present but holding something else (a template literal, a computed value) is left untouched. Each key is matched wherever its own rewrite looks for it, so a value wrapped in one quote may hold the other bare: `siteName: "Steve's Template"` is an ordinary literal and is rewritten, as is a value this command itself wrote when the title carried the non-wrapping quote.

**`wire-statusline`**: Inserts the canonical GAIA `statusLine` block at the top level of the chosen Claude settings file (`--mode project` writes `.claude/settings.json`, `global` writes `~/.claude/settings.json`, `skip` is a no-op). The statusline surfaces the per-machine setup gate plus `/update-gaia`, `/update-deps`, `/gaia-harden`, and `/gaia-audit` nudges.

**`bootstrap-env`**: Copies `.env.example` to `.env` when `.env` does not yet exist, running as a CLI subprocess so it bypasses Claude Code's `Write(.env)` deny rule. No-op when `.env` already exists or `.env.example` is absent.

**`write-project-config`**: Records the answers `/gaia-init` collects in its project-settings step (whether a sandbox is recommended and the git isolation policy) in the team-shared settings file described in [[Project Config]], creating it when absent. `/gaia-init` asks no CI or wiki-mode question. The file is committed with the rest of the init changes and never overwritten by `/update-gaia`.

**`finalize`**: Deletes `.claude/commands/gaia-init.md` so init cannot be re-run. It does not commit; the user reviews and commits the init changes.

**`resume`**: Resumes an interrupted init flow. If a previous init ran and failed partway, re-runs from where it left off without re-running completed phases.

## Target guard

The router refuses to run any subcommand in the wrong tree, before dispatching to the step: a tree with no `.gaia/manifest.json` is not a GAIA project (`not_a_gaia_project`), and a tree carrying the CLI's TypeScript sources is the GAIA template source itself rather than a project scaffolded from it (`gaia_template_source`, since adopters receive only the compiled `.gaia/cli/gaia` binary, never the source). The guard lives on the router rather than on any one step because every step resolves their target identically from ambient state, and it hands the step the same resolved path it checked so the two cannot disagree.

## Integration

All subcommands are called by `/gaia-init` (the skill), which prompts the user through each phase and dispatches the matching subcommand. The init workflow can also be run manually via `gaia init <subcommand>` from the project root. The step order and the `--from-step` numbering belong to the init CLI, which resume reads from the saved state.
