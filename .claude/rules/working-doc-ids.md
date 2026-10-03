---
paths:
  - 'frontend/app/**/*.{ts,tsx,js,jsx,css}'
  - 'frontend/test/**/*.{ts,tsx}'
  - 'frontend/.playwright/**/*.ts'
  - 'frontend/.storybook/**/*.{ts,tsx}'
  - 'frontend/.claude/**/*.md'
  - '.gaia/**/*.{ts,sh}'
  - '.claude/**/*.{md,sh}'
  - '.github/**'
  - '.specify/**/*.{md,sh}'
  - 'wiki/**/*.md'
  - '**/*.bats'
---

# Working-Document IDs

Code, comments, test names, user-facing strings, and prose never cite the project's working-document ids. Describe the behavior and why it exists instead; for provenance, a reader has `git log -L` and `git blame`.

## What is banned

- **SPEC, UAT, and plan ids**: `SPEC-` and `UAT-` plus a number, `PLAN-` plus a number.
- **Plan and audit directive ids**: the lens- or contract-prefixed ids a plan, a SPEC audit, or a decomposition audit assigns its findings and constraints (a letter prefix plus a number, with or without a dash).
- **This project's own issue and pull request references**: a bare `#` plus a number, its `owner/repo#` qualified form, and an issue or pull request URL.

## Why

These ids point at documents no other reader can open. A SPEC or plan lives under the gitignored `.gaia/local/` on the one machine that wrote it and is deleted when the plan is archived, so a teammate, a CI run, or an adopter meeting the id has nothing to follow. The ids are per-project working references: they get renumbered, superseded, or deleted, and an adopter's SPEC of the same number is a different document. An issue number adds nothing the change's history does not already record, and it stays behind after the reasoning it stood for has moved on.

The usual way one gets written is copying: a plan task doc cites the directive it honors, and the executor copies the citation into the file it edits. A directive id belongs in the plan, never in the files the plan changes.

## Not covered

- **Placeholders**: `SPEC-NNN`, `#<N>`, `Closes #<N>`, and illustrative `(e.g. SPEC-002)` examples in usage docs.
- **Data, not references**: template format examples showing a SPEC's shape, fixture values (CLI args, JSON/YAML literals, URLs in test fixtures), regex targets that match SPEC structure, filename literals, and identifier fragments inside variable names (`uat_id`).
- **An upstream third-party tracker** cited beside the platform quirk it documents (a dependency's own issue). It names a public, stable record outside this project.
- **Generated provenance**: the `## References` and `## UAT references` blocks `.specify/extensions/gaia/commands/wiki-promote.md` writes onto a promoted wiki page.
- **History ledgers**: `wiki/log.md`, `wiki/hot.md`, `wiki/meta/`, `CHANGELOG.md`, commit messages, and pull request bodies.
<!-- gaia:maintainer-only:start -->
- **`.gaia/tests/`**: release-excluded test infrastructure whose `UAT-`, `SEC-`, and `TST-` prefixes are deliberate SPEC-conformance traceability.
<!-- gaia:maintainer-only:end -->

A section heading or inline parenthetical naming a working-doc id (`#### 5b. Discuss-this escape (UAT-…)`) is narrative and is covered.

## Editing a file that already carries one

When an edit touches a line citing a working-doc id, rewrite it to the behavior it stood for, or delete it if the surrounding text already says that. Never truncate it to a bare id. Leave untouched lines alone.
