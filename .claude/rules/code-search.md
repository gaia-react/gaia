---
paths:
  - '**/*.{ts,tsx,js,jsx,mjs,cjs,py,go,rs,java,rb,php,cs,cpp,cc,c,h,hpp,kt,swift,scala}'
---

# Code Search

For symbol-level queries on code, prefer [Serena](https://github.com/oraios/serena)'s MCP tools over Read+grep, in any language Serena indexes for this project (TypeScript and any other language server the project configures). Serena is LSP-backed, canonical, type-resolved answers vs string matches.

## Prefer Serena

- Locate a definition or read a symbol's body ("Where is `X` defined?", "What's the type of `X`?") → `find_symbol`.
- Find callers or references ("What calls `X` / what does `X` call?") → `find_referencing_symbols`.
- See a file or module's structure ("Show me everything in module `Y`") → `get_symbols_overview`.
- Rename a symbol across the repo → `rename_symbol`, not find-and-replace.

## Grep is still right

Prose / comments / string literals, non-code files, files in a language Serena isn't indexing for this project, generated / gitignored files (not indexed), cross-language searches.

## Enforcement

The routing guidance above is language-agnostic, nudging toward Serena's symbol tools for any language Serena indexes. The enforcement guard (`.claude/hooks/serena-code-search-guard.sh`, PreToolUse) is deliberately narrower and stays TypeScript-conservative: it catches a bare-identifier symbol search scoped to `app/**` or `test/**` TS/TSX on both the `Grep` and `Bash` paths and points it at Serena, while non-TS searches and legitimate shell work pass through unblocked. Re-running the identical search passes, for the rare string-literal or comment search that is identifier-shaped. The guard no-ops unless Serena is a registered MCP server and the repo has a `tsconfig.json`, so adopters without Serena are unaffected.

## Limits

Cold-start language-server warm-up. Files the language server doesn't index (outside its project config) are invisible.

## Reference

Output quirks + wiki/Serena division of labor (optional deep-dive): `wiki/concepts/Serena Integration.md`.
