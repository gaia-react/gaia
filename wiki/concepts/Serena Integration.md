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
