# GAIA React

When reporting information to me, be extremely concise and sacrifice grammar for the sake of concision.

## Wiki

`wiki/` is the knowledge base — architecture, dev practices **Committed to git, shared across developers.** When you need facts not already in context:

1. Start with `wiki/index.md` (catalog) or the domain `_index.md`
2. **Do not preload wiki content.** Fetch only the specific page you need.
3. **Don't cross-load domains.** Technical work → `wiki/modules/`, `wiki/concepts/`, `wiki/decisions/`, `wiki/components/`, `wiki/flows/`, `wiki/dependencies/`. Only pull from other domains when the task genuinely spans both.
4. `wiki/hot.md` auto-loads at session start — it's a 200-word cache of "where we left off", not a fact store. Don't bloat it on updates.

## Memory Discipline

The machine-local auto-memory (`~/.claude/projects/.../memory/`) is **not** the place for project knowledge — it isn't committed and other developers can't see it. Save durable knowledge to the wiki or `.claude/rules/` instead. Only keep genuinely machine-local personal prefs in memory.

## Code Search

For TS/TSX symbol queries (definitions, references, types, module exports), prefer Serena MCP tools over Read+grep. See @.claude/rules/code-search.md for routing rules and when grep is still right.

## Smoke Harnesses

Two trees: `.specify/extensions/gaia/test/` for UAT runbooks (maintainer-reading evidence) and `.claude-tests/smoke/` for release-gate harnesses (machine-running, exit-code-reporting). Routing rule: @.claude/rules/smoke-harness-convention.md.

## Universal Principles

- No hardcoded secrets or tokens in source — use environment variables
- Prefer structured logs/errors over ad hoc console text
- Keep files focused — split when a file exceeds ~400 lines
