---
type: concept
status: active
created: 2026-04-20
updated: 2026-09-17
tags: [concept, coding-rules]
---

# Coding Guidelines

GAIA coding guidelines live in `.claude/rules/coding-guidelines.md` and the per-domain rule files enumerated in [[Claude Integration]]. The rule file owns the principles and their wording; this page explains what earns a place in it.

## What belongs in the rule

Each line either records a project choice the model cannot work out on its own, or it does not belong. A line that only makes up for something an older model used to get wrong goes stale with each model upgrade, and because newer models follow instructions more literally, emphatic wording written for an older model gets over-applied. "Stop to ask when anything is unclear" is the worked example: it contradicts the harness's own "when you have enough information to act, act" and produces more questions than the work needs.

So the rule keeps project policy (file naming, what counts as a surgical change, TDD, the Quality Gate) and one narrow simplicity line, the distinction between an impossible state and a real failure mode, which a smaller model such as Sonnet still benefits from. General reasoning discipline (pushing back, characterizing a risk before acting on it, stating a plan) lives in the response-style and "Before responding" sections of `CLAUDE.md`, not here.

When adding a line, apply the same test: is this a choice, or a workaround?
