---
type: decision
status: active
priority: 2
date: 2026-07-20
created: 2026-07-20
updated: 2026-10-08
tags: [decision, claude, configuration]
---

# Decision: Deliberate Configuration Asymmetries

Some of the configuration GAIA ships is deliberately asymmetric: one item in a
set is treated differently from its siblings, on purpose. This page records
those choices and the reasoning behind each, so a project built on GAIA can
keep them, or change them knowingly.

**Absence of a recorded rationale is not evidence that no rationale exists.**
An asymmetry that looks like drift is not automatically drift. Before
"correcting" one of the items below to match its siblings, establish what the
asymmetry protects and what removing it would cost. That question is answered
by reading what the differing thing actually does, not by reading history for
evidence of intent.

## `.claude/hooks/**` is excluded from the Edit allow-list

The `permissions.allow` list in GAIA's `.claude/settings.json` grants `Edit()`
on the `.claude/` directories that hold instruction prose (see that file for
the list). It grants nothing on `.claude/hooks/`, so editing a hook script
prompts for confirmation.

Instruction prose *guides* the agent. `.claude/hooks/` holds executable shell
scripts that *constrain* it, and several of them enforce guardrails the agent
itself is subject to: the merge gate that denies `gh pr merge` until an audit
marker exists, the secret-write and env-read blocks, the hook-bypass
(`--no-verify`) block, and the destructive-git blocks on `main`.

Granting unprompted edit access to that directory would let a session weaken
or disable the checks that govern it, without a human seeing the change. The
confirmation prompt is the point, not friction to be removed. Hook edits are
infrequent and deliberate; the prompt is proportionate to what is being
changed. Keep `.claude/hooks/` off the allow-list when adding your own `Edit()`
grants.

See [[Claude Hooks]] for what each script enforces.

## Skill `model:` pinning tracks the task class, not file shape

Some skills pin `model:` in their frontmatter. Most omit it and inherit
whatever model the session is running.

The criterion is the model table in [[Workflow Doctrine]]:

- **Pin** only when the skill's whole invocation is the lookup, scaffold,
  mechanical task class: scaffolding from a template, or applying a fix keyed
  to a specific rule id. The pinned model is the one that row names.
- **Omit `model:`** when the work needs judgment: orchestration, diagnosis,
  design decisions, review, or any multi-step workflow whose shape is not
  known in advance.

The trigger surface decides as much as the content. A skill's `model:`
overrides the session model for the rest of the turn it loads in. A
convention skill that fires whenever code is being written (`typescript`,
`tailwind`, `naming-conventions`) reads like a lookup, yet a pin there would
move the rest of an implementation or review turn onto the pinned model, so
those skills omit it. `skeleton-loaders` omits it for the same reason: it
triggers whenever a loading state is added to a component, mid-implementation. The scaffolding skills and the rule-id fix skills keep
their pin, because the turn that loads them is doing exactly that bounded
task. `react-code` omits it for the same reason, and because its trigger
surface is decision-shaped: compiler-first memoization decisions (whether a
manual memo or `"use no memo"` is justified), stale closures, choosing between
React idioms, deciding whether a dependency is warranted.

**A pin is a ceiling, not a floor.** An unpinned skill inherits the session
model, so pinning a judgment-heavy skill would cap it *below* the model the
user deliberately chose. Fit selects a pin; the lower price follows from it
and is never the reason for it. The same criterion applies to skills you
write.

## The GAIA update check has no opt-out

The statusline's background refresher queries the GitHub releases API for the
latest published GAIA version. It deliberately has no opt-out switch.

It is a version lookup. It reads a public endpoint and compares the result
against the project's installed GAIA version. Update detection is
load-bearing for keeping an installation current, so it stays on.

## The agent-teams flag stays off

GAIA's settings never set `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, in either
direction. A project is free to carry its own `env` block in
`.claude/settings.json`; this decision concerns only that one variable.

With the flag on, any Agent call that passes `name` (and is not a fork or an
isolated dispatch) launches an agent-team teammate instead of a sub-agent. A
teammate can spawn its own sub-agents, route permission prompts to the user,
message its peers, and self-claim shared tasks. That contradicts the depth-1
star in [[Workflow Doctrine]], where the main thread decides and dispatches,
and sub-agents return JSON artifacts without prompting the user or spawning
further agents. GAIA's multi-agent workflows assume that shape.

No GAIA surface uses a teams-specific API. Every dispatch goes through the
Agent tool, which needs no flag, so leaving it off breaks no GAIA workflow.
Enabling it is a per-developer choice made in user or local settings, with the
tradeoff above. Do not set it to `0` in project settings either: project
settings outrank user settings, so a project-level `0` silently cancels an
opt-in made there.

## Related

- [[Claude Hooks]]
- [[Claude Skills]]
- [[GAIA CLI]]
- [[Workflow Doctrine]]
