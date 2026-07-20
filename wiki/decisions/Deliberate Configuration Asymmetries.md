---
type: decision
status: active
priority: 2
date: 2026-07-20
created: 2026-07-20
updated: 2026-07-20
tags: [decision, claude, configuration]
---

# Decision: Deliberate Configuration Asymmetries

Some of GAIA's configuration is deliberately asymmetric: one item in a set is
treated differently from its siblings, on purpose. This page records those
choices and the reasoning behind each.

**Absence of a recorded rationale is not evidence that no rationale exists.**
An asymmetry that looks like drift is not automatically drift. Before
"correcting" one of the items below to match its siblings, establish what the
asymmetry protects and what removing it would cost. That question is answered
by reading what the differing thing actually does, not by reading history for
evidence of intent.

## `.claude/hooks/**` is excluded from the Edit allow-list

`permissions.allow` in `.claude/settings.json` grants `Edit()` for
`.claude/agents/`, `.claude/commands/`, `.claude/instructions/`,
`.claude/rules/`, and `.claude/skills/`. It does not grant it for
`.claude/hooks/`, so editing a hook script prompts for confirmation.

The five granted directories hold instruction prose that *guides* the agent.
`.claude/hooks/` holds executable shell scripts that *constrain* it, and
several of them enforce guardrails the agent itself is subject to: the merge
gate that denies `gh pr merge` until an audit marker exists, the secret-write
and env-read blocks, the hook-bypass (`--no-verify`) block, and the
destructive-git blocks on `main`.

Granting unprompted edit access to that directory would let a session weaken
or disable the checks that govern it, without a human seeing the change. The
confirmation prompt is the point, not friction to be removed. Hook edits are
infrequent and deliberate; the prompt is proportionate to what is being
changed.

See [[Claude Hooks]] for what each script enforces.

## Skill `model:` pinning tracks task difficulty, not file shape

Some skills pin `model: haiku` in their frontmatter. Most omit `model:`
entirely and inherit whatever model the session is running.

The criterion is what the skill's work demands:

- **Pin `model: haiku`** when the work is mechanical and bounded: scaffolding
  from a template, applying a fix keyed to a specific rule id, looking up a
  convention.
- **Omit `model:`** when the work needs judgment: orchestration, diagnosis,
  design decisions, or any multi-step workflow whose shape is not known in
  advance.

Skills that read as structurally similar can still fall on opposite sides of
this line. `tailwind` and `typescript` are convention lookups and pin.
`react-code` does not pin, because its trigger surface is decision-shaped:
memoization and reference stability, stale closures, choosing between React
idioms, deciding whether a dependency is warranted. That work needs whatever
model the session is running.

**A pin is a ceiling, not a floor.** An unpinned skill inherits the session
model, so pinning a judgment-heavy skill would cap it *below* the model the
user deliberately chose. Pinning is a cost optimization for work that cannot
benefit from a stronger model, and applying it more widely than that trades
correctness for tokens.

## The GAIA update check has no opt-out

The statusline's background refresher queries the GitHub releases API for the
latest published GAIA version. It deliberately has no opt-out switch.

It is a version lookup. It reads a public endpoint and compares the result
against the local version. Update detection is load-bearing for keeping an
installation current, so it stays on.

## Related

- [[Claude Hooks]]
- [[Claude Skills]]
- [[GAIA CLI]]
