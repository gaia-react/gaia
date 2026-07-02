---
paths:
  - 'app/**/*.ts'
  - 'app/**/*.tsx'
  - 'test/**/*.ts'
  - 'test/**/*.tsx'
---

# Code Search

For symbol-level queries on TS/TSX files, prefer [Serena](https://github.com/oraios/serena)'s MCP tools over Read+grep. Serena is LSP-backed, canonical, type-resolved answers vs string matches.

## Prefer Serena

"Where is `X` defined?", "Find references to `X`", "What's the type of `X`?", "What calls `X` / what does `X` call?", "Show me everything in module `Y`."

## Grep is still right

Prose / comments / string literals, files outside `app/**` and `test/**`, generated / gitignored files (not indexed), cross-language searches.

## Enforcement

A PreToolUse guard (`.claude/hooks/serena-code-search-guard.sh`) blocks a `Grep` whose pattern is a bare identifier (>= 3 chars, no spaces or regex metacharacters) scoped to `app/**` or `test/**` TS/TSX, and points it at Serena's symbol tools. Re-running the identical grep passes, for the rare string-literal or comment search that is identifier-shaped. The guard no-ops unless Serena is a registered MCP server and the repo has a `tsconfig.json`, so adopters without Serena are unaffected.

## Limits

Cold-start tsserver warm-up. Files outside `tsconfig` `include` invisible. Generated files not indexed.

## Reference

Output quirks + wiki/Serena division of labor (optional deep-dive): `wiki/concepts/Serena Integration.md`.
