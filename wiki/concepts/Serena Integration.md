---
type: concept
status: active
created: 2026-05-04
updated: 2026-05-04
tags: [concept, claude, code-search, mcp]
---

# Serena Integration

[Serena](https://github.com/oraios/serena) is the live-code layer; the wiki is the institutional-memory layer. They don't overlap.

## What Serena handles

- Symbol definitions, references, types
- File and module structure
- "Where is X used?" / "What calls Y?"
- Anything derivable from current source

## What the wiki handles

- Decisions and the rationale behind them (`wiki/decisions/`)
- Flows that span files (`wiki/flows/`)
- Conventions and rules-of-thumb (`wiki/modules/`, `wiki/concepts/`)
- Dependency context — why we use it, how it's wired (`wiki/dependencies/`)
- Entity-level institutional memory (`wiki/entities/`)

## Boundary tests

- "What does `useBreakpoint` return?" → Serena.
- "Why don't we use Redux?" → wiki (`wiki/decisions/`).
- "What's in `app/components/Form/`?" → Serena.
- "Why is the form folder co-located like this?" → wiki (`wiki/modules/Components.md`).

See `.claude/rules/code-search.md` for the routing rule.

## Quirks

- **Line numbers are 0-indexed.** `body_location.start_line` from `find_symbol` and friends counts from 0. When quoting a location to a human (`path:line`), report `start_line + 1`. Editor jump-to-line conventions are 1-indexed everywhere — emitting Serena's raw value silently misleads readers.
- **`name_path` may include workspace prefix.** Results can come back as `gaia/app/hooks/useBreakpoint` even though the file is `app/hooks/useBreakpoint.ts` from the project root. Strip the leading workspace segment when echoing paths to the user.
- **Modules can be directories.** A path like `app/sessions.server` may resolve to a directory containing one or more `.ts` files (no `index.ts` barrel). If `find_file` and `find_symbol` both return empty for such a path, follow up with `list_dir` on the directory or `get_symbols_overview` on each file inside before concluding the module doesn't exist.
