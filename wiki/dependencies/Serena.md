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

## Conventions

- Registered globally (`-s user` scope) by `/gaia-init` Step 9.
- Pinned at `v1.2.0`.
- Requires `uv` (Astral Python toolchain runner). If `uv` is missing at init time, registration is skipped with a print-out hint; `/gaia-init` does not abort.
- Routing rule: `.claude/rules/code-search.md`.

## When to use

Symbol-level queries on TS/TSX:

- Definitions: "where is `X`?"
- References: "what calls `Y`?"
- Types: "what's the type of `Z`?"

For prose / string / cross-language search, fall back to Read+grep.

## Limits

- Cold-start cost on first invocation per session (tsserver warm-up).
- Indexes only files reachable from `tsconfig.json`.
- Doesn't see gitignored or generated files.

## Removal

```
claude mcp remove serena -s user
```

See [[Serena Integration]], [[Quality Gate]].
