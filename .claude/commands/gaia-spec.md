---
name: gaia-spec
description: Author an immutable SPEC artifact through Socratic discovery (spec-kit wrapper), then STOP. Terminal, never runs /gaia-plan; it prints a /gaia-plan prompt the human pastes into a fresh session. Pass `auto <description>` for non-interactive mode that answers its own questions.
argument-hint: [auto] [description]
---

Run the GAIA **spec** workflow with these arguments: `$ARGUMENTS`

Read `.claude/skills/gaia/references/spec.md` from the project root and follow it exactly. That reference is written to consume an argument string, treat the arguments above as that input (including a leading `auto` token, which the reference detects). If no arguments were provided, follow the reference's no-argument path.
