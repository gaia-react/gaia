---
paths:
  - 'app/**/*.ts'
  - 'app/**/*.tsx'
  - 'test/**/*.ts'
  - 'test/**/*.tsx'
---

# Code Search

For symbol-level queries on TS/TSX files, prefer [Serena](https://github.com/oraios/serena)'s MCP tools over Read+grep. Serena is LSP-backed — it returns canonical, type-resolved answers instead of string matches.

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

## Output quirks

- **Line numbers are 0-indexed.** `body_location.start_line` from `find_symbol` and friends counts from 0. When quoting a location to a human (`path:line`), report `start_line + 1`. Editor jump-to-line conventions are 1-indexed everywhere — emitting Serena's raw value silently misleads readers.
- **`name_path` may include workspace prefix.** Results can come back as `gaia/app/hooks/useBreakpoint` even though the file is `app/hooks/useBreakpoint.ts` from the project root. Strip the leading workspace segment when echoing paths to the user.
- **Modules can be directories.** A path like `app/sessions.server` may resolve to a directory containing one or more `.ts` files (no `index.ts` barrel). If `find_file` and `find_symbol` both return empty for such a path, follow up with `list_dir` on the directory or `get_symbols_overview` on each file inside before concluding the module doesn't exist.

## Reference

- Division of labor with the wiki: `wiki/concepts/Serena Integration.md`
