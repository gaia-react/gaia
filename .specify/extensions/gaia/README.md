# GAIA spec-kit extension

GAIA-tailored Socratic discovery layer over [spec-kit](https://github.com/github/spec-kit). Adds coach-tone prompting, `AskUserQuestion`-driven multiple choice with recommended-first ordering, per-topic exhaustion checkpoints, two-gate ceremony, immutability lint on saved SPECs, and a chain trigger into `/gaia plan`. Implementation contract: `.gaia/local/specs/SPEC-001.md`.

This extension is registered with spec-kit via `specify extension add gaia` and pinned to spec-kit `v0.8.5`. The pin is duplicated in the GAIA-side manifest at `.gaia/extension.yml` so version drift between GAIA releases and spec-kit is detectable before discovery starts.

The extension layout follows spec-kit's documented extension API:

- `extension.yml` — manifest (schema_version `"1.0"`).
- `commands/` — slash-command implementations (e.g. `speckit.gaia.spec`).
- `templates/` — preset overrides (spec-template, clarify prompts, system prompt) layered on top of spec-kit's defaults.
- `hooks/` — shell scripts wired through spec-kit's `before_/after_` hook bus.
- `lib/` — shared utilities; `lib/hook-payload.md` documents the JSON payload contract every hook receives on stdin.
