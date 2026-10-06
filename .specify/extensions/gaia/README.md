# GAIA spec lifecycle

GAIA's own spec-lifecycle scripts, templates, and manual runbooks. `/gaia-spec` and the plan tooling call these directly: Socratic discovery with coach-tone prompting, `AskUserQuestion`-driven multiple choice with recommended-first ordering, per-topic exhaustion checkpoints, a two-gate ceremony, an immutability lint on saved SPECs, and a terminal `/gaia-plan` handoff the human runs in a fresh session (never chained in-session; a guard enforces it).

The folder keeps its historical `.specify/` location for now.

Layout:

- `commands/`: manual runbooks with no automatic trigger. A person runs one by reading the file and following it. `self-review.md` is the exception in kind: `/gaia-spec` step 6 dispatches it as an Agent.
- `templates/`: the SPEC skeleton, the clarify prompts, the system prompt, and the UAT render templates.
- `lib/`: shell utilities called directly by skills, hooks, and scripts (spec allocation, lint, UAT rendering, ledger and archive helpers).
- `rules/`: supporting rules the runbooks and generated files reference.
