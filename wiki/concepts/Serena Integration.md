---
type: concept
status: active
created: 2026-05-04
updated: 2026-07-03
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

## Enforcement

The routing rule is advisory and language-agnostic: it activates on a broad multi-language source glob and prefers Serena's symbol tools for any language Serena indexes for the project, not TypeScript or `app/`/`test/` alone. A rule is still absent from context during pure exploration (no edit in flight), exactly when the grep-vs-Serena decision gets made, so a PreToolUse guard (`.claude/hooks/serena-code-search-guard.sh`) closes that gap. The guard is deliberately narrower than the rule: it stays TypeScript-conservative and tsconfig-gated, so a hard block never lands on a non-TS search. It fires at the search call itself on both the `Grep` tool and a single `grep`/`rg`/`ag` issued through `Bash`, and blocks a bare identifier (≥ 3 chars, no spaces or regex metacharacters) scoped to `app/**`/`test/**` TS/TSX, pointing it at `find_symbol` / `find_referencing_symbols` / `get_symbols_overview`. The Bash path stays conservative and favors false negatives: a pipeline, a compound or sequenced command, a command substitution, a redirection, a quoted or regex pattern, multiple patterns, or any grep not carrying an explicit `app/**`/`test/**` TS/TSX path passes through untouched, so ordinary shell work is never blocked. Re-running the identical search passes, for the rare string-literal or comment search that's identifier-shaped. It no-ops unless Serena is a registered MCP server and the repo has a `tsconfig.json`, so adopters without Serena never see it. The split is deliberate: the advisory rule nudges broadly across languages at zero false-block risk, while the guard blocks only where a wrong block is impossible. See [[Claude Hooks]].

## Language drift

Serena freezes its language list at first startup and does not re-detect, so a project that grows a new language gets no symbol intelligence for it until Serena's configuration catches up. `/gaia-serena-sync` reconciles that drift: a passive statusline nudge appears when a project grows a language Serena is not indexing, and on explicit consent the command adds the language to Serena's configuration and prompts a restart. See [[Serena]] for how the freeze works and what the command edits.

## Quirks

- **Line numbers are 0-indexed.** `body_location.start_line` from `find_symbol` and friends counts from 0. When quoting a location to a human (`path:line`), report `start_line + 1`. Editor jump-to-line conventions are 1-indexed everywhere; emitting Serena's raw value silently misleads readers.

- **`name_path` may include workspace prefix.** Results can come back as `gaia/app/hooks/useBreakpoint` even though the file is `app/hooks/useBreakpoint.ts` from the project root. Strip the leading workspace segment when echoing paths to the user.
- **Modules can be directories.** A path like `app/sessions.server` may resolve to a directory containing one or more `.ts` files (no `index.ts` barrel). If `find_file` and `find_symbol` both return empty for such a path, follow up with `list_dir` on the directory or `get_symbols_overview` on each file inside before concluding the module doesn't exist.
