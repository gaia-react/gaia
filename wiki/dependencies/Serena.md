---
type: dependency
status: active
package: serena
version: v1.2.0
role: code-intelligence-mcp
created: 2026-05-04
updated: 2026-05-04
tags: [dependency, mcp, code-search]
---

# Serena

LSP-backed MCP server. Gives Claude live, always-fresh access to symbol definitions, references, types, and module structure across the project's TS/TSX files.

## Pin

- Version: `v1.2.0`.
- Scope: user (registered globally for the user's Claude Code, not project-scoped).
- Runtime: requires `uv` (Astral Python toolchain runner).

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
