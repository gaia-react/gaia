---
type: concept
status: active
created: 2026-04-20
updated: 2026-04-30
tags: [concept, claude, agent, review]
---

# Code Review Audit Agent

Defined in `.claude/agents/code-review-audit.md`. Sonnet-class subagent for comprehensive code review beyond what ESLint and TypeScript catch.

Full spec: `.claude/agents/code-review-audit.md`.

Reviews security, performance, code smells, architecture, robustness, and maintainability. Output is tiered: Critical (must fix) → Important (should fix) → Suggestions → What's done well. After its own pass, spawns three specialist subagents in parallel (React Patterns & Accessibility, TypeScript & Architecture, Translation) plus `react-doctor` in a single tool call. Each subagent is gated on file scope so it doesn't spawn when there's nothing to review (e.g. no `.tsx` → skip Subagent 1).

## Durable knowledge

The wiki (`wiki/`) is the source of truth for patterns, decisions, and conventions worth preserving across reviews. The agent surfaces recurring anti-patterns or architectural concerns in its report so they can be filed into the wiki.

`.claude/agent-memory/` is **not** treated as canonical: in this repo it is gitignored / machine-local, so anything written there is invisible to other developers and to fresh checkouts. Use the wiki for durable knowledge; let agent-memory accumulate only ephemeral, machine-local notes if at all.

## Extension mechanism

Library-specific audit rules live in `.claude/agents/code-review-audit/*.md`. Each file targets one or more specialist subagents via YAML frontmatter (`subagents: [react-patterns, typescript, translation]`). The agent reads all extension files at startup and injects their rules into the relevant subagent prompts.

To swap a library: remove its extension file, add one for the replacement. The main agent definition stays unchanged. See the `README.md` in that directory for the full format.

| File                 | Library              |
| -------------------- | -------------------- |
| `conform.md`         | `@conform-to/zod`    |
| `tailwind-merge.md`  | `tailwind-merge`     |
| `react-i18next.md`   | `react-i18next`      |
| `form-components.md` | GAIA Form Components |

## Trigger

Always before `gh pr merge` ([[PR Merge Workflow]]) — enforced by the `pr-merge-audit-check.sh` advisory hook ([[Claude Hooks]]). Also on demand for any review.
