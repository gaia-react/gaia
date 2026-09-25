---
type: concept
status: active
created: 2026-05-04
updated: 2026-07-04
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
- Dependency context: why we use it, how it's wired (`wiki/dependencies/`)
- Entity-level institutional memory

## Boundary tests

- "What does `useBreakpoint` return?" → Serena.
- "Why don't we use Redux?" → wiki (`wiki/decisions/`).
- "What's in `app/components/Form/`?" → Serena.
- "Why is the form folder co-located like this?" → wiki (`wiki/modules/Components.md`).

See `.claude/rules/code-search.md` for the routing rule.

Serena's symbol tools return canonical, type-resolved answers where the built-in Read and Grep return string matches. Opus defaults to its own built-in tools even when a symbol tool fits better, which is why `.claude/rules/serena-cc-override.md` loads at session start as an always-on nudge to prefer Serena's symbol tools for symbol-level code work, rather than relying on the routing rule alone (that rule activates only on code files, so it is absent from context during pure exploration).

## Language drift

Serena freezes its language list at first startup and does not re-detect, so a project that grows a new language gets no symbol intelligence for it until Serena's configuration catches up. `/gaia-serena-sync` reconciles that drift: a passive statusline nudge appears when a project grows a language Serena is not indexing, and on explicit consent the command adds the language to Serena's configuration and prompts a restart. See [[Serena]] for how the freeze works and what the command edits.

The nudge renders from a `serenaLangDrift` field in `.gaia/local/cache/shared/update-check.json`, which `check-updates.sh` recomputes on every session start. When `/update-deps` and `/update-gaia` finish they rewrite that cache to clear the post-update state, and each preserves `serenaLangDrift` so a pending nudge survives the update. That preservation is a step the skill performs, not shell code, so no automated test exercises it: the drift computation is unit-tested, but its survival across a cache-bust rests on the skill's prose. This is an accepted, self-correcting residual risk. The next session-start refresh recomputes `serenaLangDrift` from source, so a dropped value costs at most one session's missing nudge before it returns.

## Quirks

- **Line numbers are 0-indexed.** `body_location.start_line` from `find_symbol` and friends counts from 0. When quoting a location to a human (`path:line`), report `start_line + 1`. Editor jump-to-line conventions are 1-indexed everywhere; emitting Serena's raw value silently misleads readers.

- **`name_path` may include workspace prefix.** Results can come back as `gaia/app/hooks/useBreakpoint` even though the file is `app/hooks/useBreakpoint.ts` from the project root. Strip the leading workspace segment when echoing paths to the user.
- **Modules can be directories.** A path like `app/sessions.server` may resolve to a directory containing one or more `.ts` files (no `index.ts` barrel). If `find_file` and `find_symbol` both return empty for such a path, follow up with `list_dir` on the directory or `get_symbols_overview` on each file inside before concluding the module doesn't exist.
