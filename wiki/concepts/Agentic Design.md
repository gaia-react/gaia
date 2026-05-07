---
type: concept
status: active
created: 2026-04-25
updated: 2026-05-01
tags: [concept, philosophy, claude, agent]
---

# Agentic Design

Agentic design is the discipline of building AI systems that reason, observe, act on tools, and iterate toward goals rather than passively responding to one-shot prompts. The [canonical taxonomy](https://zeljkoavramovic.github.io/agentic-design-patterns/) catalogs 29 patterns across five categories: Core, Reasoning & Strategy, Orchestration, Infrastructure & State, and Reliability & Control.

GAIA implements 12 of those 29 structurally. "Structurally" means the implementation is wired in through hooks, agents, rules, commands, or wiki conventions. It runs the same way every session, every engineer, every model variant. Not as emergent model behavior on top of a vanilla Claude Code setup. That distinction is GAIA's defensible thesis: agentic behavior has to be structural to be predictable enough to stake production code on.

## The 12 patterns GAIA implements

### Core

#### Routing

Path-scoped rules in `.claude/rules/*.md` carry a `paths:` frontmatter and auto-load only when Claude is editing matching files. The i18n rule activates on `app/pages/**/*` and `app/components/**/*`; the API service rule activates on `app/services/**/*`. Conditional `Bash` hooks in `.claude/settings.json` route commands by shape: `Bash(pnpm *)` to the bare-test blocker, `Bash(git *)` to the destructive-git blocker, `Bash(gh pr merge:*)` to the audit-check reminder. Constraints are routed to context, not loaded globally.

#### Parallelization

The [[Code Review Audit Agent]] dispatches three specialist subagents and `react-doctor` in parallel from a single tool-call message. [[Task Orchestration]] dispatches implementation sub-agents per phase in parallel where dependencies allow. Both fan out work and collect results before advancing.

#### Tool Use

GAIA composes a project-specific tool surface for Claude on React projects: ESLint with 20+ plugins, TypeScript, Vitest with React Testing Library, Playwright, Storybook with Chromatic, MSW, the `gh` CLI, `react-doctor`, the Obsidian wiki, the `claude-obsidian` plugin, and `typescript-lsp`. Each tool has a curated role; nothing is bolted on by accident.

### Reasoning & Strategy

#### Reflection

Two distinct reflection layers, both blocking. The [[Quality Gate]] (typecheck + lint + test + build) is a pre-commit gate that loops until clean. The [[Code Review Audit Agent]] is a pre-merge gate that evaluates the branch diff against security, performance, architecture, accessibility, and project rules, returning Critical / Important / Suggestion findings. The gate runs again between Task Orchestration phases; each phase is self-correcting before the next begins.

#### Planning

[[Task Orchestration]] is GAIA's planning layer. [[GAIA Plan|`/gaia plan`]] writes durable file artifacts to `.gaia/local/plans/<slug>/`: per-task docs self-contained for fresh sub-agents, a `README.md` task graph with phases and frozen interface contracts, an `ORCHESTRATOR.md` execution playbook, and a `KICKOFF.md` entry-point. The user must approve the plan before any execution begins. Plans are concrete files, not chain-of-thought scribbles.

### Orchestration

#### Multi-Agent Collaboration

The [[Code Review Audit Agent]] is a manager-and-specialists system. The lead reviewer dispatches React Patterns, TypeScript & Architecture, and Translation subagents in parallel. Subagents have file-scope gates (`.tsx` files trigger React Patterns; files containing `t(` calls trigger Translation). Extension files in `.claude/agents/code-review-audit/*.md` inject library-specific rules into the right specialist at runtime via `subagents:` frontmatter, a configurable dispatch system at the file level. The orchestrator pattern in `/gaia plan` follows the same shape.

#### Resource-Aware Optimization

Model tier follows task complexity. [[GAIA Audit]] runs both stages on Sonnet — drift checks (sha256 + verbatim before/after snippets) carry the safety, so the research stage doesn't need a heavier model. `/gaia plan` asks the user whether to use Opus for planning, defaulting to yes; per-task implementation sub-agents inherit the running model (typically Sonnet). The Code Review Audit declares `model: sonnet` in its frontmatter so the structured rule-based review runs cheaply, leaving Opus for harder reasoning. Cost and quality discipline is wired in, not left to the user.

### Infrastructure & State

#### Memory Management

Five tiers of memory with explicit scope and decay:

- **Long-term**: the wiki at `wiki/`. Architecture, decisions, flows, concepts, dependencies, sources, all versioned with the repo.
- **Hot cache**: `wiki/hot.md`. Auto-loaded each session, ≤200 words, the recent-context summary every session starts with.
- **Episodic**: [[GAIA Handoff]] writes a structured doc; [[GAIA Pickup]] reads it and reconstitutes context cold.
- **Agent memory**: `.claude/agent-memory/<agent-name>/MEMORY.md` accumulates patterns across reviews and is auto-loaded into the agent's prompt. Created on demand per agent.
- **User auto-memory**: `~/.claude/projects/<project>/memory/`. Typed memories (user / feedback / project / reference) indexed by `MEMORY.md`.

[[GAIA Audit]] is a periodic two-stage sweep that detects duplication, stale entries, and auto-load bloat. Memory is not a pile; it has a maintenance loop.

#### Session Isolation

Sub-agents in [[Task Orchestration]] run in fresh-context isolation dispatched via the Agent tool. Each task doc is self-contained for a fresh sub-agent. The `ORCHESTRATOR.md` offers a git-worktree branch for filesystem-level isolation when the user is starting from `main`. The Code Review Audit's specialist subagents run in isolated agent contexts. `/gaia audit` separates research and apply across two isolated stages so reasoning cannot contaminate the mechanical applier.

### Reliability & Control

#### The Stop Hook

GAIA's hook layer is the canonical Stop Hook pattern, by name. Pre-tool-use hooks intercept dangerous commands and reject the call:

- `block-main-destructive-git.sh` blocks `git commit` on `main` and force-push to `main`.
- `block-bare-test.sh` blocks `pnpm test` (which would start watch mode and never stop), requires `--run`.
- `block-eslint-config-edit.sh` blocks edits to `eslint.config.mjs` so debt is fixed at the source rather than silenced.
- `block-vitest-globals-tsconfig.sh` blocks adding vitest globals.
- `pr-merge-audit-check.sh` reminds before `gh pr merge`.

Pre-commit Husky + lint-staged hooks are stop-hooks at the git layer. The [[Quality Gate]] command itself is a stop-hook protocol: stop and report before committing.

#### Human-in-the-Loop

Six structurally enforced checkpoints between Claude's intent and impact:

| Checkpoint                  | When           | What it guards                                                                |
| --------------------------- | -------------- | ----------------------------------------------------------------------------- |
| [[Quality Gate]]            | Pre-commit     | No broken types, lint errors, failing tests, or build failures reach the repo |
| [[Code Review Audit Agent]] | Pre-merge      | No security, performance, or code-quality issues reach `main`                 |
| Orchestrate plan approval   | Pre-execution  | No multi-file plan executes without explicit user sign-off                    |
| Orchestrator phase gates    | Between phases | No phase begins if the prior phase's gate failed                              |
| Destructive-git hook        | Always         | No commit-to-`main`, no force-push to `main`                                  |
| `gh pr merge` reminder hook | Pre-merge      | Reminds to run the code-review audit                                          |

Human-in-the-Loop in GAIA is enforced by hooks. The bypass paths are blocked at the hook layer.

#### Guardrails & Safety

Defense in depth, layered from filesystem up:

- **Filesystem deny list** in `.claude/settings.json`: `Read(.env)`, `Read(**/secrets/*)`, `Read(**/*credential*)`, `Read(**/*.pem)`, `Read(**/*.key)`.
- **Tool allow list** scopes Bash and Edit surfaces.
- **Block hooks** in `.claude/hooks/` reject debt-accumulating patterns at the source (eslint-config edits, vitest globals, watch-mode tests, destructive git).
- **Code Review Audit security dimension**: XSS, SSRF, IDOR, secret exposure, timing attacks, dependency vulnerabilities are explicit checklist items.
- **Accessibility guardrails**: rules block hardcoded English strings, missing `alt`, missing keyboard handlers; the audit subagent enforces semantic HTML, focus management, ARIA.
- **Coding-rule guardrails**: no `eslint-disable react-hooks/exhaustive-deps`, no `.catch(() => {})`, no `interface` (use `type`), no `switch`, no enums, no untyped exports.

Each rule prevents a class of debt at the source rather than catching it downstream.

## Honest non-features

A handful of patterns from the canonical taxonomy are deliberately absent in GAIA, and several others are partial. Worth naming so the structural claims stay defensible:

- **Dynamic Scaffolding**: absent by design. GAIA pre-curates a stable tool surface; tool sprawl is a non-goal.
- **Parallel Fusion**: absent. GAIA's parallelism is divide-and-conquer (specialist subagents on different scopes), not redundant attempts on the same task.
- **The Ralph Wiggum Loop**: explicitly rejected. GAIA fail-stops and surfaces to the user rather than looping until the environment passes.
- **Vector RAG**: wiki retrieval is symbolic (paths, grep, `wiki/index.md`, backlinks), not embedding-based. Closer to "structured-markdown retrieval-on-demand" than canonical RAG.
- **Code-Then-Execute**: a Claude Code runtime capability, not a GAIA convention.

The full pattern-by-pattern grading is 12 Strong, 13 Partial, 1 Inferential, 3 Absent.

## Why structural matters

Most Claude setups treat agentic behavior as emergent: give the model a good prompt and hope it reasons well. GAIA makes agentic behavior structural. Reflection loops, observation-action cycles, planning gates, specialist dispatch, model tiering, memory tiering. These are wired in, not prompted in. They run the same way every session, by any engineer on the team, whether or not they understand the underlying agentic theory.

The result is a system where Claude's autonomy is bounded, its quality is enforced, and its knowledge persists. Agentic behavior is predictable enough to stake production code on.

## See also

- [[GAIA Philosophy]]
- [[Task Orchestration]]
- [[Code Review Audit Agent]]
- [[Claude Hooks]]
- [[Quality Gate]]
- [[GAIA Plan]]
- [[GAIA Handoff]]
- [[GAIA Pickup]]
- [[GAIA Audit]]
- [[PR Merge Workflow]]
- [Source taxonomy: 29 agentic design patterns](https://zeljkoavramovic.github.io/agentic-design-patterns/)
