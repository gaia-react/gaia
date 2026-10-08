---
name: gaia-spec
description: Authors an immutable SPEC artifact through Socratic discovery, then stops. Never runs /gaia-plan; it prints a /gaia-plan prompt the human pastes into a fresh session. Pass `auto` before the description for a non-interactive mode that answers its own questions. Use when the user asks to write a spec, specify a feature, or pin down requirements before planning.
argument-hint: [auto] [description]
---

Run the GAIA **spec** workflow with these arguments: `$ARGUMENTS`

Read `.claude/skills/gaia/references/spec.md` from the project root and follow it exactly. That reference is written to consume an argument string, treat the arguments above as that input (including a leading `auto` token, which the reference detects). If no arguments were provided, follow the reference's no-argument path.

`spec.md` routes each run to these sub-references. Read one only when a line in `spec.md` says to, and then read the whole file:

- `.claude/skills/gaia/references/spec/lifecycle.md`: step 2's pre-flight sweep.
- `.claude/skills/gaia/references/spec/resume.md`: step 2, only when the allocator reports a draft and the run is interactive.
- `.claude/skills/gaia/references/spec/spec-template.md`: step 3's initial draft.
- `.claude/skills/gaia/references/spec/clarify-loop.md`, `.claude/skills/gaia/references/spec/clarify-prompts.md` and `.claude/skills/gaia/references/spec/system-prompt.md`: step 5's Socratic loop.
- `.claude/skills/gaia/references/spec/self-review-dispatch.md`: step 6, and step 10's loop back to 6c.
- `.claude/skills/gaia/references/spec/audit.md` and `.claude/skills/gaia/references/spec/lens-dispatch.md`: step 7's adversarial audit.
- `.claude/skills/gaia/references/spec/self-review.md`: read by the self-review sub-agent, never this thread.
