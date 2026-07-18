---
name: distribution-audit
description: Maintainer-only. Find every file that would newly ship to adopters and decide, one file at a time, whether to ship it or withhold it. Drives the release CLI, which refuses to produce a manifest until every shipping file has an answer.
---

# /distribution-audit

Maintainer-only. Thin orchestrator over `.gaia/cli/gaia-maintainer`, which owns every deterministic step. This command supplies the one thing the CLI cannot: a human answering, file by file, whether a newly-shipping file should ship or be withheld.

`.gaia/release-exclude` is the distribution boundary: a file ships to adopters if and only if git tracks it and no line in that file masks it. `.gaia/manifest.json` is the update policy `/update-gaia` consumes, and incidentally the ledger of which shipping files a maintainer has acknowledged. A file that git tracks, that no exclude line masks, and that the manifest does not yet list is "unanswered": it would ship, but nobody has said so on purpose.

## Step 1. Find the unanswered files

```bash
.gaia/cli/gaia-maintainer release manifest --check --json
```

`--check` is read-only. It exits non-zero whenever it finds any of six conditions, so capture stdout and parse it as JSON regardless of the exit code; a non-zero exit here is not a failure, it is the normal signal that something needs attention. The payload shape is:

```json
{"missing": [{"expected": "owned", "file": ".gaia/statusline/example.sh"}], "extra": [], "drift": [], "versionDrift": null, "classifierOverlaps": [], "scanScopeGaps": []}
```

`missing` is an array of objects, not of path strings: the path lives in `.file`, and `.expected` is the update class the classifier would assign. Extract paths with:

```bash
jq -r '.missing[].file'
```

Treating `missing`'s entries as if they were bare strings prints JSON blobs instead of paths and silently breaks the per-file question in Step 3.

`missing` is not "everything that ships." Four paths, `.gaia/manifest.json`, `.gaia/VERSION`, `wiki/hot.md`, and `wiki/log.md`, are permanent adopter-owned fixtures that ship with baseline content but are never classified, so they never enter `missing` and this command never asks about them. That is correct, not a gap.

## Step 2. Decide which path applies

- **Nothing outstanding.** `missing` is empty and the other five conditions (`extra`, `drift`, `versionDrift`, `classifierOverlaps`, `scanScopeGaps`) are all empty: report that the boundary is current, write nothing, regenerate nothing, and stop. Regenerating here would rewrite the manifest's timestamp for no reason. `git status --porcelain` for `.gaia/manifest.json` and `.gaia/release-exclude` must stay empty.
- **Bookkeeping only.** `missing` is empty but at least one of the other five conditions is not: this is accounting drift, not a boundary question, nobody needs to decide whether a file ships. Name the condition(s) that fired and list their entries, then ask the maintainer via `AskUserQuestion` whether to regenerate now to absorb them. Do not regenerate unprompted.
- **Files await an answer.** `missing` is non-empty: continue to Step 3.

## Step 3. Ask, one file at a time

For each path in `missing`, ask a separate `AskUserQuestion`: ship it to adopters, or withhold it? Give the maintainer enough to answer without guessing: what the file is, which directory it sits in, and whether its neighbors already ship (check whether sibling paths appear in `.gaia/manifest.json` or fall under an existing line in `.gaia/release-exclude`).

Rules for this step, because nothing downstream enforces them:

- Never supply the answer, never recommend one, never batch multiple files into a single question.
- There is no default direction. Silence is not an answer; if the maintainer doesn't respond, the file stays unanswered and Step 4 cannot proceed for it.
- State no answer the maintainer has not actually given.

A withhold answer additionally needs two things from the maintainer: a **category** (read `.gaia/release-exclude` and offer its numbered categories by number and title as the choices) and a **reason** (one line; the CLI rejects a reason containing a newline or carriage return).

## Step 4. Apply every answer in one call

Once every path in `missing` has an answer, hand the whole set to the CLI in a single invocation:

```bash
.gaia/cli/gaia-maintainer release manifest \
  --ship <path> \
  --ship <path> \
  --withhold <path> --category <N> --reason "<one-line reason>"
```

`--ship <path>` repeats for each shipped answer. `--withhold <path>` opens a record that must be immediately closed by exactly one `--category <N>` and exactly one `--reason <text>` before the next `--withhold` or the end of the command. In the bookkeeping-only branch of Step 2, once the maintainer agreed to regenerate, call the same command with no `--ship` / `--withhold` flags at all.

The CLI snapshots the unanswered set once, validates the whole answer set against that snapshot, and only then writes: it appends the withheld entries to `.gaia/release-exclude` itself and regenerates the manifest. If it exits non-zero, surface its stderr verbatim and stop, do not retry with a different flag shape, and do not work around it by any other means.

The CLI is the sole writer of `.gaia/release-exclude`. This command never edits that file itself: no direct file write, no in-place edit, no shell redirect into it. Every withheld entry is written by the CLI's own answer machinery, which is the only place the literal-path rule is enforced and under test. If this command hand-edited the boundary instead, that rule would be enforced by nothing at all, no code would own the write, and it would be exactly the kind of unenforced promise this feature exists to eliminate.

Land the manifest-answer commit before starting a PR's Code Audit Team pre-merge audit handshake, not after; see `wiki/concepts/PR Merge Workflow.md` for why the ordering matters.

## What this command never does

- **Never take the CLI's undecided escape hatch.** That flag waives the answer requirement entirely and exists for the release path, where relitigating what a file is for is out of scope on release day. This command exists precisely to not take it.
- **Never regenerate through the command that cuts a release.** That command carries the escape hatch above by design; routing through it here is the same violation as using it directly, a single sentence pointing there would need no flag and no new file, so there is no reason to.
- **Never mutate the git index or the ignore file to change what the CLI sees.** The unanswered set comes from what git already tracks; changing that set to make the accounting trivially satisfiable defeats the point of asking.
- **Never use a manifest-write bypass marker.** This command needs none; the CLI's own gate is what stands between an unanswered file and a produced manifest, and nothing here should route around it.

## Coverage note

The per-file ship-or-withhold question, the clean-tree stop, and the bookkeeping-only confirmation have no automated test behind them: their actor is a conversation, and nothing can run a conversation as a unit test. The prose above is the enforcement. Follow it as written rather than treating it as a suggestion.
