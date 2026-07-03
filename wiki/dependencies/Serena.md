---
type: dependency
status: active
package: serena
version: v1.2.0
role: code-intelligence-mcp
created: 2026-05-04
updated: 2026-07-03
tags: [dependency, mcp, code-search]
---

# Serena

LSP-backed MCP server. Gives Claude live, always-fresh access to symbol definitions, references, types, and module structure across the project's TS/TSX files.

## Pin

- Version: `v1.2.0`.
- Scope: user (registered globally for the user's Claude Code, not project-scoped).
- Runtime: requires `uv` (Astral Python toolchain runner).
- Context: `--context claude-code`, which trims Serena to its symbol and memory tools and drops the file read/create, shell, directory-list, and pattern-search tools that Claude Code's own tools already cover.
- Activation: `--project-from-cwd` auto-activates the project from the working directory, so the language server indexes the repo without a manual `activate_project` call. The context is single-project, so project switching is off.
- Override: Claude Code loads Serena's system-prompt override so Opus reaches for the symbol tools instead of defaulting to its built-in Read/Grep. The recommended launch is `claude --append-system-prompt="$(serena prompts print-cc-system-prompt-override)"` (the append form, never `--system-prompt`, which would replace Claude Code's base prompt); the always-loaded `.claude/rules/serena-cc-override.md` is the durable fallback when a session starts without the flag.

## Exposed tools

The `claude-code` context exposes Serena's LSP-backed symbol tools and its memory tools, and excludes the file-level tools Claude Code already provides. Available for symbol work: `find_symbol`, `find_referencing_symbols`, `get_symbols_overview`, `rename_symbol`, `replace_symbol_body`, `insert_before_symbol`, `insert_after_symbol`, `replace_content`, and `safe_delete_symbol`, alongside the memory tools (`write_memory`, `read_memory`, `list_memories`, `edit_memory`, `rename_memory`, `delete_memory`) and session helpers (`check_onboarding_performed`, `onboarding`, `get_current_config`, `initial_instructions`). Excluded in this context: `read_file`, `create_text_file`, `execute_shell_command`, `find_file`, `list_dir`, and `search_for_pattern`. `activate_project` is off because the context is single-project. The `think_about_*` reflection tools are not part of this Serena build at all, so no context exposes them. This is the statically declared surface; a running single-project session may narrow it further to the project's configured language-server needs.

## When to use

Symbol-level queries on TS/TSX:

- Definitions: "where is `X`?"
- References: "what calls `Y`?"
- Types: "what's the type of `Z`?"

For prose / string / cross-language search, fall back to Read+grep. Routing rule: `.claude/rules/code-search.md`.

## Limits

- Cold-start cost on first invocation per session (tsserver warm-up).
- Indexes only files reachable from `tsconfig.json`.
- Doesn't see gitignored or generated files.

See [[Serena Integration]].
