---
type: dependency
status: active
package: serena
role: code-intelligence-mcp
created: 2026-05-04
updated: 2026-10-03
tags: [dependency, mcp, code-search]
---

# Serena

LSP-backed MCP server. Gives Claude live, always-fresh access to symbol definitions, references, types, and module structure across the project's source files, in any language the project configures a language server for.

## Pin

- Version: `.claude/commands/setup-gaia.md` owns the pin.
- Scope: user (registered globally for the user's Claude Code, not project-scoped).
- Runtime: requires `uv` (Astral Python toolchain runner).
- Context: `--context claude-code`, which trims Serena to its symbol and memory tools and drops the file read/create, shell, directory-list, and pattern-search tools that Claude Code's own tools already cover.
- Activation: `--project-from-cwd` auto-activates the project from the working directory, so the language server indexes the repo without a manual `activate_project` call. The context is single-project, so project switching is off.
- Override: Claude Code loads Serena's system-prompt override so Opus reaches for the symbol tools instead of defaulting to its built-in Read/Grep. The recommended launch is `claude --append-system-prompt="$(serena prompts print-cc-system-prompt-override)"` (the append form, never `--system-prompt`, which would replace Claude Code's base prompt); the always-loaded `.claude/rules/serena-cc-override.md` is the durable fallback when a session starts without the flag.

The prescribed registration passes `--project-from-cwd` (see Pin above), so the project auto-activates from the session's own working directory rather than through `activate_project`. That resolves each linked worktree to its own tree directly, sidestepping Serena's machine-global registry (`~/.serena/serena_config.yml`), which would otherwise resolve the `project_name` that `.serena/project.yml` carries identically across every linked worktree to whichever checkout first registered it. See [[Worktrees]] for the underlying per-tree identity model.

## Exposed tools

The `claude-code` context exposes Serena's LSP-backed symbol tools and its memory tools, and excludes the file-level tools Claude Code already provides (file read and create, shell, directory listing, file and pattern search). `activate_project` is off because the context is single-project. The exact tool list moves with Serena releases, so Serena's own documentation and `.claude/rules/code-search.md` own it rather than this page. A running single-project session may narrow the surface further to the project's configured language-server needs.

## When to use

Symbol-level queries in any language Serena indexes for the project:

- Definitions: "where is `X`?"
- References: "what calls `Y`?"
- Types: "what's the type of `Z`?"

For prose / string / cross-language search, fall back to Read+grep. Routing rule: `.claude/rules/code-search.md`.

The advisory routing rule is language-agnostic: it activates on a broad multi-language source glob and nudges toward Serena's symbol tools for any language Serena indexes, not TypeScript or `frontend/app/`/`frontend/test/` alone. See [[Serena Integration]] for detail.

## Language configuration

Serena decides which language servers to start from the `language_servers:` list in `.serena/project.yml`. Serena releases before 1.7 call that list `languages:`; a file uses exactly one of the two names, and GAIA's tooling reads and writes whichever the file already carries. A file carrying both is left untouched. Under GAIA's non-interactive registration (`--project-from-cwd`), Serena autogenerates that file at first startup and enables only the single most prominent language it detects; from then on it reads `.serena/project.yml` verbatim and never re-detects. A project that begins as TypeScript-only and later grows a Go or Python module keeps getting single-language symbol intelligence, because the new language is absent from the frozen list and nothing signals that it is invisible to symbol search.

`/gaia-serena-sync` closes that gap for languages GAIA recognizes from a high-signal manifest: it detects the drift and, on explicit consent, additively appends the missing language(s) to the list in place under its existing key name, then prompts a restart so the new language is indexed.

A Serena that predates the `language_servers:` name cannot load a file that carries only that key. A team therefore re-registers every collaborator on the current Serena before anyone commits a `.serena/project.yml` that Serena auto-migrated to the new name.

## Limits

- Cold-start cost on first invocation per session (language-server warm-up).
- Indexes only files reachable from the language server's project config (`frontend/tsconfig.json` for TypeScript).
- Doesn't see gitignored or generated files.

See [[Serena Integration]].
