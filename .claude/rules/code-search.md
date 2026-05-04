---
paths:
  - 'app/**/*.ts'
  - 'app/**/*.tsx'
  - 'test/**/*.ts'
  - 'test/**/*.tsx'
---

# Code Search

GAIA registers Serena (LSP-backed MCP server) during `/gaia-init`. For symbol-level queries on TS/TSX files, prefer Serena's MCP tools over Read+grep.

## When to prefer Serena

Use Serena tools for any of:

- "Where is `X` defined?"
- "Find references to `X`."
- "What's the type of `X`?"
- "What calls `X` / what does `X` call?"
- "Show me everything in module `Y`."

Serena returns canonical, LSP-resolved answers. Read+grep returns string matches that miss re-exports, type aliases, and dynamic call sites.

## When grep is still right

- Searching prose, comments, or string literals (Serena indexes symbols, not strings).
- Files outside `app/**` and `test/**` (Serena follows `tsconfig` includes).
- Generated files (Serena respects `.gitignore`; generated output isn't indexed).
- Anything cross-language (CSS, JSON, YAML, scripts).

## Limits

- **Cold start.** First Serena call in a session pays a one-time tsserver warm-up. Worth it after one or two follow-up queries.
- **`tsconfig` scope.** Serena only sees files reachable from `tsconfig.json` `include`. Standalone scripts may be invisible.
- **Gitignored / generated files.** Not indexed. If you need to search build output, fall back to grep.

## Reference

- Serena: https://github.com/oraios/serena
- Pinned ref in `/gaia-init`: see `.claude/commands/gaia-init.md`
- Division of labor with the wiki: `wiki/concepts/Serena Integration.md`
