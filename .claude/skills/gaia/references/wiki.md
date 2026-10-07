# /gaia-wiki

Wiki-maintenance router. It runs the full wiki maintenance chain: sync, consolidate, and lint with fixes, on one branch and one PR.

## Arguments

`/gaia-wiki` takes no arguments.

```
Usage: /gaia-wiki
```

If `$ARGUMENTS` is non-empty, whatever it holds (a retired argument: `sync`, `consolidate`, or `lint`; `--help`; free text from a natural-language trigger such as `run wiki maintenance`), print this notice once, with the whole argument string in place of `<arguments>`, then run "Full chain" exactly as with no argument:

```
Note: /gaia-wiki takes no arguments; ignoring "<arguments>" and running the full chain.
```

## Full chain

The whole chain lands on **one branch and one PR**, not one PR per stage. The parent (the agent reading this file) owns the branch lifecycle through `gaia wiki chain`; each stage still runs as its own subagent. The `chain` calls are the only parent-side git/branch/PR actions, the playbook bans inlining any other branch logic, manual `gh pr` calls, or push narrative.

1. **Begin.** Run `.gaia/cli/gaia wiki chain begin --branch-aware`. On `main`/`master` it cuts a `wiki/sync-<date>-<sha>` branch so every stage commits there; on a feature branch it is a no-op and the chain commits in place. If `chain begin` exits non-zero, stop the chain: run no stage, make no commit, and surface its error output to the user.

2. **Sync.** Run the "Sync" section below. Capture the final summary. The chain branch (or the feature branch) is already checked out, so sync's Step 7 `chain commit` commits in place.

3. **Branch on sync's outcome.** Sync's summary ends with the line `SYNC_COMPLETE: true` on every normal path, including drift=0 and the `suggested_base` recovery path. The line is **absent** on the state-init path, the fallback re-anchor path, a cancelled run, a refused `chain commit`, and every interruption and abort `references/wiki/sync.md`'s Failure modes section lists, all of which leave the wiki in a known-incomplete state. No other condition decides whether consolidate runs.
   - **Line present**: run consolidate (step 4), then lint (step 5), then finish (step 6).
   - **Line absent**: skip consolidate and lint, then go straight to step 6 (finish) and surface the exceptional state. `chain finish` lands a lone re-anchor commit, removes the branch if sync committed nothing, or leaves an aborted (uncommitted) tree in place for the maintainer.

4. **Consolidate.** Run the "Consolidate" section below. After its apply loop completes, commit the staged edits: `.gaia/cli/gaia wiki chain commit --label "wiki: consolidate through <head-sha>"` (the short HEAD sha sync reported in `State advanced to {head_sha}`). The command is a no-op when nothing was applied.

5. **Lint.** Run the "Lint" section below, both stages. Lint runs after consolidate because consolidate may move, rename, or archive pages and lint's orphan/dead-link/broken-wikilink/drift checks need the true post-state. Once the fix loop has returned, commit its fixes and the final report together: `.gaia/cli/gaia wiki chain commit --label "wiki: lint through <head-sha>"`. Fixing before this commit, rather than on the PR `finish` opens, keeps the PR's head on the sha `finish` stamps: a push after `finish` moves the head off that stamp, and a queued auto-merge then waits on a `GAIA-Audit` status that never arrives.

6. **Finish.** Run `.gaia/cli/gaia wiki chain finish --branch-aware` with an explicit Bash `timeout` of `600000`. On the chain branch it pushes, opens ONE PR carrying every stage's commit, enables auto-merge, then takes one bounded in-CLI wait; on the common path it returns to base with the local cleanup outstanding, because the merge gate outlasts any wait that fits in one call. If the merge does not land within the wait, auto-merge stays queued (GitHub completes it once checks pass) and the local pull/delete is deferred to the session-start janitor. If no stage produced a commit it drops the empty branch and returns to base. On a feature-branch (in-place) run it is a no-op and the commits remain on the current branch. Relay its summary to the user.

A `chain commit` that exits non-zero (sync's or the parent's) stops the chain: surface its message. For the non-wiki-changes refusal, tell the user to commit or stash the non-wiki changes, then rerun `/gaia-wiki`. For the protected-branch refusal, relay the CLI's own next step.

Each stage still dispatches its own subagent; never run a subagent's playbook yourself in this conversation. The parent-side stages, consolidate's apply loop and lint's fix loop, are the ones that run here.

## Sync

Dispatch a Sonnet subagent via `Agent`. Sync generates judgment and prose (deep-reading WORTHY diffs, locating the right page, writing accurate edits and ADRs), which is beyond Haiku's reliability on a long multi-step run; a fresh context also keeps git diffs and log content out of the parent.

Spawn:

- `subagent_type`: `"general-purpose"`
- `model`: `"sonnet"`
- `description`: `"Wiki sync"`
- `prompt`: the string below (literal, no paraphrasing):

  > `You are running the GAIA wiki-sync workflow in a fresh context. Read .claude/skills/gaia/references/wiki/sync.md from the project root and execute the "Playbook" section (Steps 1–8) verbatim. Your working directory is the project root. Print only the final summary block from Step 8, ending with the SYNC_COMPLETE: true line when Step 8 emits it, no preamble, no recap, no narration of intermediate steps.`

When the subagent returns, relay its final summary verbatim. Do not redo the work in the parent.

## Consolidate

Two-stage. **Detection (Steps 1–3) runs in a Sonnet subagent** so the heavy page-index walk and frontmatter reads stay out of the parent. **Apply, state, and report (Steps 4–6) run in the parent** because Step 4 calls `AskUserQuestion` per finding, and `AskUserQuestion` is unavailable inside dispatched subagents.

### Stage 1, detection subagent

Spawn:

- `subagent_type`: `"general-purpose"`
- `model`: `"sonnet"`
- `description`: `"Wiki consolidate (detection)"`
- `prompt`: the string below (literal):

  > `You are running the detection stage of the GAIA wiki-consolidate workflow in a fresh context. Read .claude/skills/gaia/references/wiki/consolidate.md from the project root and execute Steps 1–3 of the "Playbook" section verbatim, then STOP. Do NOT execute Steps 4–6. Your working directory is the project root. After writing the report file in Step 3, return ONLY a JSON payload on stdout, no preamble, no narration:`
  >
  > ```json
  > {
  >   "report_path": "wiki/meta/consolidate-report-YYYY-MM-DD.md",
  >   "findings": [
  >     {
  >       "id": "<stable id, e.g. supersession-0, near-collision-2>",
  >       "kind": "supersession" | "reversed" | "near_collision" | "subject_orphan",
  >       "domain": "<domain>",
  >       "label": "<short label suitable for a question>",
  >       "canonical": { "path": "<rel path>", "title": "<title>", "slug": "<slug>" },
  >       "other":     { "path": "<rel path>", "title": "<title>", "slug": "<slug>" },
  >       "summary":   "<one-sentence summary of the apply action>"
  >     }
  >   ]
  > }
  > ```

### Stage 2, parent loop

After the subagent returns, the parent (the agent reading this file in the live conversation):

1. Parses the `findings[]` payload.
2. Iterates findings in order **supersession → reversed → near-collision → subject-orphan** (most-impactful first), surfacing each via `AskUserQuestion` per Step 4 of the playbook in `references/wiki/consolidate.md`.
3. Applies the user's chosen action (Apply / Keep both / Skip) per the playbook's per-kind rules.
4. Runs Step 5 (advance state) and Step 6 (report) directly; the commit is Full chain step 4.

If any HIGH-severity supersession or reversed-decision finding is applied, surface it prominently (prefix the final summary line with `WIKI CONSOLIDATE:`).

## Lint

Two-stage, like consolidate. **Detection runs in a Haiku subagent** and writes the report. **Fixing runs in the parent** because it asks the user where a fix needs judgment, and `AskUserQuestion` is unavailable inside dispatched subagents. Both stages run on every chain: a report that lists defects and leaves them standing fixes nothing.

### Stage 1, detection subagent

Dispatch a Haiku subagent via `Agent`. The work is mechanical (rule-based orphan, dead-link, broken-wikilink, and frontmatter checks plus a deterministic drift severity table), Haiku is sufficient.

Spawn:

- `subagent_type`: `"general-purpose"`
- `model`: `"haiku"`
- `description`: `"Wiki lint"`
- `prompt`: the string below (literal):

  > `You are running the GAIA wiki-lint workflow in a fresh context. Read .claude/skills/gaia/references/wiki/lint.md from the project root and execute the "Playbook" section (Steps 1–9) verbatim. Your working directory is the project root. Return only the report path and the one-line summary required by Step 9: no recap of the report contents.`

When the subagent returns, relay its summary verbatim. If the drift severity is **`high`**, prefix the surfaced line with `WIKI DRIFT:` per Step 9. If the subagent returns a `WIKI DEAD-PATHS:`, `UAT-SPEC DRIFT:`, `WIKI ORPHANS:`, `WIKI FRONTMATTER:`, `WIKI EMPTY-SECTIONS:`, or `WIKI BROKEN-LINKS:` line, surface it too.

### Stage 2, parent fix loop

Read `.claude/skills/gaia/references/wiki/lint-fix.md` and run it in this conversation, then relay its summary line. It fixes each finding, asks only where a fix needs judgment, files the instruction-file findings that cannot ride a wiki branch as tech-debt, and re-dispatches stage 1 so the final report describes the fixed wiki.
