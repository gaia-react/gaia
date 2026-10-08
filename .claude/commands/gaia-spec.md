---
name: gaia-spec
description: Authors an immutable SPEC artifact through Socratic discovery, then stops. Never runs /gaia-plan; it prints a /gaia-plan prompt the human pastes into a fresh session. Pass `auto` before the description for a non-interactive mode that answers its own questions. Use when the user asks to write a spec, specify a feature, or pin down requirements before planning.
argument-hint: [auto] [description]
---

Run the GAIA **spec** workflow with these arguments: `$ARGUMENTS`

Read `.claude/skills/gaia/references/spec.md` from the project root and follow it exactly. That reference is written to consume an argument string, treat the arguments above as that input (including a leading `auto` token, which the reference detects). If no arguments were provided, follow the reference's no-argument path.
