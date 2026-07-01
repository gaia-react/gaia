# GAIA React

## Response style

Terse in conversation: lead with the verdict, telegraphic phrasing welcome, no filler, preamble, or validation. Brevity cuts filler, never coverage. Audits, reviews, plans, handoffs, wiki pages, and specs stay complete.

Be a partner, not a cheerleader: flag flawed ideas, challenge assumptions, ask hard questions about viability. Coach as well as critique: explain the why, offer the better pattern, and bring some warmth. Relentless pushback wears thin. The goal is to enjoy the work and do great work together.

## Wiki

`wiki/` is the knowledge base: architecture, dev practices **Committed to git, shared across developers.** When you need facts not already in context:

1. Start with `wiki/index.md` (catalog)
2. **Do not preload wiki content.** Fetch only the specific page you need.
3. **Don't cross-load domains.** Technical work → `wiki/modules/`, `wiki/concepts/`, `wiki/decisions/`, `wiki/components/`, `wiki/flows/`, `wiki/dependencies/`. Only pull from other domains when the task genuinely spans both.
4. `wiki/hot.md` auto-loads at session start; it's a 200-word cache of "where we left off", not a fact store. Don't bloat it on updates.

When writing or editing wiki body prose or code comments, follow `.claude/rules/wiki-style.md`: present tense only, no UAT references, no inline PR/commit/date-of-change references. Git history and `wiki/log.md` carry the historical record. (The rule auto-loads on edits to `wiki/**` or `app/**` via path-scoped activation.)

## Memory Discipline

The machine-local auto-memory (`~/.claude/projects/.../memory/`) is **not** the place for project knowledge; it isn't committed and other developers can't see it. Save durable knowledge to the wiki or `.claude/rules/` instead. Only keep genuinely machine-local personal prefs in memory.

## Code Search

For TS/TSX symbol queries (definitions, references, types, module exports), prefer Serena MCP tools over Read+grep. See `.claude/rules/code-search.md` for routing rules and when grep is still right. (The rule auto-loads on edits to `app/**` or `test/**` `.ts`/`.tsx` files via path-scoped activation.)

## Universal Principles

- No hardcoded secrets or tokens in source; use environment variables
- No hardcoded machine-specific absolute paths anywhere in the repo; keep paths repo-relative. See `.claude/rules/repo-relative-paths.md`
- Prefer structured logs/errors over ad hoc console text
- Keep files focused; split when a file exceeds ~400 lines
- The current visual styling is a deliberate neutral baseline, not a chosen design system. Before designing or restyling, read `.claude/rules/design-baseline.md` and `wiki/concepts/Design System.md`.
