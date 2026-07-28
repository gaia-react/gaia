# /gaia-handoff

Write a self-contained handoff doc so the next session can pick up cold without re-reading this conversation.

**When:** end of session, context break, or when state is non-obvious.

## Inputs

- `$ARGUMENTS` (the args after `handoff`), optional inline notes from the user (decisions, gaps, open questions).
- Conversation transcript, primary source for accomplishments, decisions, gaps.
- Git state, branch, last commit, dirty files.

## Steps

### 0. Clear prior

Resolve the tree key first, reused for every `.gaia/local/handoff/` path for the rest of this run, including inside the file this run writes:

```bash
bash .gaia/scripts/main-root-lib.sh --tree-key
```

This prints 16 lowercase hex characters (`<tree_key>`) on stdout and exits 0, or prints nothing and writes one `GAIA_TREE_KEY_UNRESOLVABLE` line to stderr and exits 1. On failure, stop here: surface the stderr line to the user, write nothing, and never fall back to the unkeyed `.gaia/local/handoff/` path.

Delete any existing handoff before writing: `rm -f .gaia/local/handoff/<tree_key>/HANDOFF-*.md`. Only one handoff exists at a time. A new handoff supersedes whatever came before, carrying forward anything still unfinished. Never archive.

### 1. Gather

Run in parallel:

- `git rev-parse --abbrev-ref HEAD` + `git log -1 --oneline` + `git status --short`
- Extract from conversation: files edited, commands run, decisions ("let's…", "go with…"), gaps ("missing", "TODO"), unresolved questions.
- Derive a kebab-case slug for the filename from the session's main thread (e.g. `watch-voice-cues`, `coach-voice-s04`).

### 2. Write

Path: `.gaia/local/handoff/<tree_key>/HANDOFF-{YYYY-MM-DD}-{slug}.md`

`<tree_key>` is the value resolved in step 0; substitute it literally, the same as `{YYYY-MM-DD}` and `{slug}`. Derive `{YYYY-MM-DD}` from `date +%F` and the **Date** line's timestamps from `date '+%Y-%m-%d %H:%M'` (shell), never guess the current date/time.

Use the template below. **Omit any section with no real content**, don't leave empty headings. Keep entries factual and concrete (file paths, commit hashes, command invocations). Cross-reference files with `@path/to/file:line` so the next session can jump straight in.

```markdown
# Session Handoff

**Date:** {YYYY-MM-DD HH:MM – HH:MM}
**Branch:** `{branch}`
**Context:** {one-sentence summary of the session's work}

---

## Accomplishments

- {what shipped / was built, include commit hashes if committed}

## Decisions

| Decision          | Rationale | Impact                           |
| ----------------- | --------- | -------------------------------- |
| {what was chosen} | {why}     | {effect on the codebase/product} |

## Gaps & Open Questions

### {Gap or question title}

**Status:** FIXED / PARTIAL / UNKNOWN / DEFERRED / INTENTIONAL
**Notes:** {what's known, what's uncertain, what's the likely culprit}
**Next check:** {concrete diagnostic or test to run}
**Reference:** `@path/to/file:line`

## Environment State

- **Branch:** `{branch}`, {pushed/dirty}
- **Background processes:** {e.g. `pnpm dev` still running}
- **Devices / simulators:** {physical device IDs, sim names, build installed}
- **Test user / data:** {relevant fixtures}

## Reference Files
```

@path/one
@path/two

```

## Next Actions

| # | Action | Effort |
|---|--------|--------|
| 1 | {concrete, testable step} | {5–30 min} |

---

**Resume:** `/gaia-pickup`

## Teardown

One-and-done. When the Next Actions above are complete and verified (committed or tests green), delete this file. Do not archive:

`rm -f .gaia/local/handoff/<tree_key>/HANDOFF-{YYYY-MM-DD}-{slug}.md`

If you were interrupted before finishing, leave it. The next `/gaia-pickup` resumes from here.
```

### 3. Confirm

Report in one line: saved path + count of accomplishments / decisions / gaps / next-actions. No ASCII boxes.

## Rules

- Do **not** dump the conversation verbatim, synthesize.
- Every "Next Action" must be concrete enough to execute without context.
- Every "Gap" must name a file and a diagnostic, not just "look into X".
- Skip empty sections entirely rather than writing "N/A".
- Never fabricate commit hashes, file paths, or device IDs, if unsure, omit.
