# GAIA React

When reporting information to me, be extremely concise and sacrifice grammar for the sake of concision.

## Wiki

`wiki/` is the knowledge base — architecture, dev practices **Committed to git, shared across developers.** When you need facts not already in context:

1. Start with `wiki/index.md` (catalog)
2. **Do not preload wiki content.** Fetch only the specific page you need.
3. **Don't cross-load domains.** Technical work → `wiki/modules/`, `wiki/concepts/`, `wiki/decisions/`, `wiki/components/`, `wiki/flows/`, `wiki/dependencies/`. Only pull from other domains when the task genuinely spans both.
4. `wiki/hot.md` auto-loads at session start — it's a 200-word cache of "where we left off", not a fact store. Don't bloat it on updates.

When writing or editing wiki body prose or code comments, follow `.claude/rules/wiki-style.md` — present tense only, no UAT references, no inline PR/commit/date-of-change references. Git history and `wiki/log.md` carry the historical record. (The rule auto-loads on edits to `wiki/**` or `app/**` via path-scoped activation.)

## Memory Discipline

The machine-local auto-memory (`~/.claude/projects/.../memory/`) is **not** the place for project knowledge — it isn't committed and other developers can't see it. Save durable knowledge to the wiki or `.claude/rules/` instead. Only keep genuinely machine-local personal prefs in memory.

## Code Search

For TS/TSX symbol queries (definitions, references, types, module exports), prefer Serena MCP tools over Read+grep. See `.claude/rules/code-search.md` for routing rules and when grep is still right. (The rule auto-loads on edits to `app/**` or `test/**` `.ts`/`.tsx` files via path-scoped activation.)

## Universal Principles

- No hardcoded secrets or tokens in source — use environment variables
- Prefer structured logs/errors over ad hoc console text
- Keep files focused — split when a file exceeds ~400 lines
- Mentorship raw event files are not Claude-displayable. The binding rule lives in per-machine user memory, projected from `.gaia/cli/src/mentorship/display-rule.ts` whenever mentorship is enabled. Removed/added by the mentorship CLI lifecycle (`enable` / `disable` / `purge` / `gaia mentorship _internal-write-config`); a session-start hook re-asserts it each session.
