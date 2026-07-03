---
paths:
  - '**/*.{ts,tsx,js,jsx,mjs,cjs,py,go,rs,java,rb,php,cs,cpp,cc,c,h,hpp,kt,swift,scala}'
---

# Code Search

For symbol-level queries on code, prefer [Serena](https://github.com/oraios/serena)'s MCP tools over Read+grep, in any language Serena indexes for this project (TypeScript and any other language server the project configures). Serena is LSP-backed, canonical, type-resolved answers vs string matches.

## Prefer Serena

"Where is `X` defined?", "Find references to `X`", "What's the type of `X`?", "What calls `X` / what does `X` call?", "Show me everything in module `Y`."

## Grep is still right

Prose / comments / string literals, non-code files, files in a language Serena isn't indexing for this project, generated / gitignored files (not indexed), cross-language searches.

## Enforcement

The routing guidance above is language-agnostic: it nudges toward Serena's symbol tools for any language Serena indexes for this project. The enforcement guard is deliberately narrower and stays TypeScript-conservative, so a wrong block on a non-TS search can't happen. A PreToolUse guard (`.claude/hooks/serena-code-search-guard.sh`) catches a bare-identifier symbol search on either search path and points it at Serena's symbol tools. Through the `Grep` tool it blocks a pattern that is a bare identifier (>= 3 chars, no spaces or regex metacharacters) scoped to `app/**` or `test/**` TS/TSX. Through `Bash` it blocks a single `grep`/`rg`/`ag` whose lone pattern is such an identifier and which carries an explicit `app/**` or `test/**` TS/TSX path. The Bash path favors false negatives: a pipeline, a compound or sequenced command, a command substitution, a redirection, a quoted or multi-word or regex pattern, multiple patterns, or any search not explicitly scoped to app/test source passes through, so legitimate shell work is never blocked. Re-running the identical search passes, for the rare string-literal or comment search that is identifier-shaped. The guard no-ops unless Serena is a registered MCP server and the repo has a `tsconfig.json`, so adopters without Serena are unaffected.

## Limits

Cold-start language-server warm-up. Files the language server doesn't index (outside its project config) are invisible. Generated files not indexed.

## Reference

Output quirks + wiki/Serena division of labor (optional deep-dive): `wiki/concepts/Serena Integration.md`.
