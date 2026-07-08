---
name: gaia-harden
description: Judge-the-form, human-gated hardening. Reviews recurring code-audit-frontend findings and, with approval, drafts the lowest-context-weight form (deterministic check / skill / path-scoped prose rule) into the working tree. Pass `list` to see live candidates or `why <finding_class>` to explain one.
argument-hint: [review|list|why <finding_class>]
---

Run the GAIA **harden** workflow with these arguments: `$ARGUMENTS`

Read `.claude/skills/gaia/references/harden.md` from the project root and follow it exactly. That reference is written to consume an argument string, treat the arguments above as that input (the leading token selects the subcommand: `review`, `list`, or `why <finding_class>`). If no arguments were provided, follow the reference's no-argument path (which defaults to `review`).
