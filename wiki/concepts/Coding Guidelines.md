---
type: concept
status: active
created: 2026-04-20
updated: 2026-09-17
tags: [concept, coding-rules]
---

# Coding Guidelines

GAIA coding guidelines live in `.claude/rules/coding-guidelines.md` and the per-domain rule files enumerated in [[Claude Integration]]. The rule file owns the principles and their wording.

## What belongs in the rule

A line belongs in the rule when it records a project choice the model cannot work out on its own. A line that only compensates for a model weakness does not: it goes stale as models improve, and emphatic wording gets over-applied by a model that follows instructions literally. General reasoning discipline (pushing back, characterizing a risk before acting on it, stating a plan) lives in `CLAUDE.md`, not here.
