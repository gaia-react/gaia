# GAIA spec-kit extension

GAIA-tailored Socratic discovery layer over [spec-kit](https://github.com/github/spec-kit). Adds coach-tone prompting, `AskUserQuestion`-driven multiple choice with recommended-first ordering, per-topic exhaustion checkpoints, two-gate ceremony, immutability lint on saved SPECs, and a handoff to `/gaia-plan`.

This extension is registered with spec-kit via `specify extension add gaia` and pinned to spec-kit `v0.8.5`. The pin is duplicated in the GAIA-side manifest at `.gaia/extension.yml` so version drift between GAIA releases and spec-kit is detectable before discovery starts.

The extension layout follows spec-kit's documented extension API:

- `extension.yml`: manifest (schema_version `"1.0"`).
- `commands/`: slash-command implementations fired via `EXECUTE_COMMAND` directives at spec-kit's `before_specify` / `after_clarify` / `after_specify` events.
- `templates/`: preset overrides (spec-template, clarify prompts, system prompt) layered on top of spec-kit's defaults.
- `lib/`: shared shell utilities invoked by the slash-command bodies (spec allocation, lint, UAT rendering).
- `rules/`: supporting rules referenced by the commands.
