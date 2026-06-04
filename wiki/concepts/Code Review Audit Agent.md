---
type: concept
status: active
created: 2026-04-20
updated: 2026-06-02
tags: [concept, claude, agent, review]
---

# Code Review Audit Agent

Defined in `.claude/agents/code-review-audit.md`. Sonnet-class subagent for comprehensive code review beyond what ESLint and TypeScript catch.

Full spec: `.claude/agents/code-review-audit.md`.

Reviews security, performance, code smells, architecture, robustness, and maintainability. Output is tiered: Critical (must fix) → Important (should fix) → Suggestions → What's done well. After its own pass, spawns three specialist subagents in parallel (React Patterns & Accessibility, TypeScript & Architecture, Translation) plus `react-doctor`, `pnpm knip --reporter json`, and `pnpm audit --json` in a single tool call. Each subagent is gated on file scope so it doesn't spawn when there's nothing to review (e.g. no `.tsx` → skip Subagent 1).

Knip runs pre-merge here (post-task by design) and its findings are bucketed advisory: real dead code, intentional library export (update `entry` globs), or implicit dependency (update `ignoreDependencies`). See [[knip]].

A deterministic `pnpm audit --json` run is the oracle for known-vulnerable dependencies; the Security dimension does not LLM-judge current CVEs. Its high/critical advisories surface in an advisory bucket (read-only; never blocking the marker), scoped by a severity threshold and a machine-local baseline allowlist at `.gaia/local/dep-audit-baseline.json`. It is distinct from the blocking GAIA CI `pnpm audit` cron, which opens review-required security PRs. See [[pnpm-audit]].

## Incremental scope

The audit does not always review the full `origin/main...HEAD` diff. `.github/audit/resolve-audit-base.sh` resolves a review base, the most recent ancestor of HEAD that already passed a clean audit under the current `.gaia/VERSION`, proven by a GAIA-Audit commit trailer (local stamps) or a GAIA-Audit commit status (CI stamps; see [[PR Merge Workflow]] for the trailer/status handshake). The audit then reviews only `<base>...HEAD`.

The base is only ever a commit that passed a clean audit. An interrupted, failed, or differently-versioned run leaves no signal to anchor on, so the base falls back to `origin/main` and the full PR diff is reviewed. The scope therefore can never skip uncleared code; worst case it reviews too much. A `.gaia/VERSION` bump invalidates every prior base and forces a full re-audit under the new ruleset.

The benefit lands when an audit completes between pushes: a follow-up push reviews only its own delta instead of re-reviewing the whole PR. The `cancel-in-progress` concurrency policy means rapid-fire pushes cancel before a base is stamped, so they fall back to full scope safely. The one risk an incremental scope must guard is a delta that breaks an already-cleared caller, so the agent rechecks importers of any exported symbol whose contract changed in the delta.

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

Always before `gh pr merge` ([[PR Merge Workflow]]), enforced by the `pr-merge-audit-check.sh` advisory hook ([[Claude Hooks]]). Also on demand for any review.
