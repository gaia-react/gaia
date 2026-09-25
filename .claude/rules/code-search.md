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

## Limits

Cold-start language-server warm-up. Files the language server doesn't index (outside its project config) are invisible.

## Reference

Output quirks + wiki/Serena division of labor (optional deep-dive): `wiki/concepts/Serena Integration.md`.
