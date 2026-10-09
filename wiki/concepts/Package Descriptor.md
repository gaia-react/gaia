---
type: concept
status: active
created: 2026-10-03
updated: 2026-10-03
tags: [concept, monorepo, guards, claude]
---

# Package Descriptor

GAIA is a monorepo: the harness (`.claude/`, `.gaia/`, `.githooks/`, `.github/`, `wiki/`) lives at the repo root and the React app lives in a package folder, `frontend/`. Two JSON files tell the harness where a package is and which of its paths each guard cares about, so no guard hardcodes `app/` or `frontend/`.

## The two files

- **Registry, `.gaia/packages.json`.** A list of `{name, path}` entries, one per package. When the file is absent, the harness uses a built-in default that registers `frontend` at `frontend/`.
- **Descriptor, `<package path>/gaia.package.json`.** Names the package and holds its glob lists: which files are unit tests, which are strict TDD candidates, which tests are emergent, which sources trigger the pre-commit gate, and where the package's dependency manifests and doctor config sit. It also carries the `wiki` path lists the wiki tooling reads. Globs are package-relative.

The schema lives in the readers and the shipped `frontend/gaia.package.json` is the worked example; read those rather than a list here.

## Who reads them

Three implementations of one contract, each pinned to the same shared conformance corpus:

- Bash, `.claude/hooks/lib/gaia-packages.sh`, for hooks and guard scripts.
- Node, `.gaia/scripts/lib/gaia-packages.mjs`, for the TDD helpers.
- TypeScript, in the CLI source, for the CLI (scaffolds, wiki tooling, settings sync).

Consumers include the TDD classifier ([[Determinism Classifier]]), the RED gate ([[TDD RED Verification]]), the worthiness gate ([[Worthiness Presence Gate]]), the pre-commit plan ([[Pre-commit Hooks]]), and the wiki dead-path scan.

## Fail-closed rule

A guard never guesses a layout. An absent registry means the built-in default. A registry or descriptor that is present but malformed, a descriptor that is missing, or a missing `jq` makes the reader return a non-zero status and a one-line `gaia-packages:` error with a next step, and every query then answers as if nothing were loaded. Each guard maps that to its own safe direction: a refusal set refuses everything, a gate blocks, a classifier denies. A path no registered package owns is not in scope for a package guard; the root-level arms of each guard still apply.

## Launch scope

Harness workflows run from a root launch. A `frontend/` launch supports frontend work through commit: it loads `frontend/CLAUDE.md`, the frontend rules and skills, and the generated `frontend/.claude/settings.json`. The root settings reach it only through `gaia packages sync-settings`, which regenerates the frontend file from the root file plus `frontend/.claude/settings.overlay.json`; run it after any change to the root `.claude/settings.json`. `.gaia/scripts/check-settings-drift.sh` fails the commit when the two disagree.

See also [[Claude Hooks]] and [[Folder Structure]].
