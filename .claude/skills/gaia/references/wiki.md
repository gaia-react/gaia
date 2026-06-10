# /gaia-wiki

Wiki-maintenance router. Sub-commands run individually or chain end-to-end.

## Argument parsing

Tokenize `$ARGUMENTS`. Detect a trailing `--force` token; if present, strip
it and set `FORCE=true`. Then tokenize the first remaining whitespace-
separated word.

| First arg       | Action                                                                       |
| --------------- | ---------------------------------------------------------------------------- |
| `sync`          | Dispatch sync subagent (see "Sync" below). No chaining.                      |
| `consolidate`   | Dispatch consolidate detection subagent (see "Consolidate" below). No chain. |
| `lint`          | Dispatch lint subagent (see "Lint" below). No chaining.                      |
| (empty)         | Full chain: sync → (gated) consolidate → lint. See "Full chain".             |
| (anything else) | Print help.                                                                  |

`--force` is positional-flexible but the contract is "trailing", it must be
the LAST argument so it doesn't shadow `sync` / `consolidate` / `lint`:

- `/gaia-wiki --force` (full chain, force)
- `/gaia-wiki sync --force` (sync only, force)

Help message:

```
Usage: /gaia-wiki [--force] [sync|consolidate|lint]

  --force        Override GAIA CI deferral (no-op when wiki.mode != "ci")
  (no arg)       Full chain: sync, then consolidate if gate trips, then lint
  sync           Evaluate commits since last sync; update wiki where warranted
  consolidate    Cross-SPEC redundancy + contradiction audit; surfaces findings
  lint           Health check: orphans, dead links, drift, narrative-ref scrub
```

## GAIA CI deferral check

Before any sub-command dispatches (sync / consolidate / lint / full chain),
the parent reads `.gaia/automation.json` to determine whether wiki updates
are CI-managed.

```
STATUS=$(.gaia/cli/gaia automation read-config --json 2>/dev/null \
         | jq -r '.wiki.mode // "local"') || STATUS=local
```

If the binary or config is missing the read fails; treat that as `local`
and proceed.

If `STATUS == "ci"` and `FORCE != "true"`, print this conflict-risk
warning to stderr and exit 1 without dispatching anything:

```
GAIA CI manages /gaia-wiki for this repo. Running it locally now risks colliding
with the next scheduled run. To override, re-invoke with --force.
```

If `STATUS == "ci"` and `FORCE == "true"`, the chain runs as normal.

If `STATUS != "ci"`, behave as before (no defer, no force).

## Sync

Dispatch a Sonnet subagent via `Agent`. Sync generates judgment and prose (deep-reading WORTHY diffs, locating the right page, writing accurate edits and ADRs), which is beyond Haiku's reliability on a long multi-step run; a fresh context also keeps git diffs and log content out of the parent. The playbook's Step 5b fabrication guard backstops any model that narrates edits without writing them.

Spawn:

- `subagent_type`: `"general-purpose"`
- `model`: `"sonnet"`
- `description`: `"Wiki sync"`
- `prompt`: the string below (literal, no paraphrasing):

  > `You are running the GAIA wiki-sync workflow in a fresh context. Read .claude/skills/gaia/references/wiki/sync.md from the project root and execute the "Playbook" section (Steps 1–9) verbatim. Your working directory is the project root. Print only the final summary block from Step 8 followed by the CONSOLIDATE_TRIGGERED line from Step 9, no preamble, no recap, no narration of intermediate steps.`

When the subagent returns, relay its final summary verbatim. Do not redo the work in the parent.

If invoked as `/gaia-wiki sync` (sub-arg form): stop after relaying the summary. Do **not** chain into consolidate or lint, that's only the no-arg form's job. The sub-arg form `/gaia-wiki sync --force` is also valid; the same defer / force logic from "GAIA CI deferral check" applies.

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
4. Runs Step 5 (advance state) and Step 6 (hand off + report) directly.

If any HIGH-severity supersession or reversed-decision finding is applied, surface it prominently (prefix the final summary line with `WIKI CONSOLIDATE:`).

## Lint

Dispatch a Haiku subagent via `Agent`. The work is mechanical (rule-based orphan/dead-link/frontmatter checks plus a deterministic drift severity table), Haiku is sufficient.

Spawn:

- `subagent_type`: `"general-purpose"`
- `model`: `"haiku"`
- `description`: `"Wiki lint"`
- `prompt`: the string below (literal):

  > `You are running the GAIA wiki-lint workflow in a fresh context. Read .claude/skills/gaia/references/wiki/lint.md from the project root and execute the "Playbook" section (Steps 1–8) verbatim. Your working directory is the project root. Return only the report path and the one-line summary required by Step 8: no recap of the report contents.`

When the subagent returns, relay its summary verbatim. If the drift severity is **`high`**, prefix the surfaced line with `WIKI DRIFT:` per Step 8. If the subagent returns a `WIKI DEAD-PATHS:`, `UAT-SPEC DRIFT:`, `WIKI ORPHANS:`, `WIKI FRONTMATTER:`, or `WIKI EMPTY-SECTIONS:` line, surface it too.

## Full chain (no sub-arg)

Run sync first, then branch on its `CONSOLIDATE_TRIGGERED` line, then run lint.

1. **Sync.** Run the "Sync" section above. Capture the final summary.
2. **Inspect last line of summary.** Step 9 of sync emits `CONSOLIDATE_TRIGGERED: <true|false>` as the summary's last line on normal sync paths (including drift=0). The line is **absent** on the re-anchor path (Step 1 rebase recovery) and on partial-sync interruptions (Step 7 failure mode), both leave the wiki in a known-incomplete state. Branch on its presence:
   - **Line absent**: skip both consolidate and lint. The maintainer needs to address the exceptional state first.
   - **`CONSOLIDATE_TRIGGERED: true`**: run consolidate, then run lint.
   - **`CONSOLIDATE_TRIGGERED: false`**: skip consolidate, run lint.

3. **Lint runs last** because consolidate may move, rename, or archive pages, and lint's orphan/dead-link/drift checks need the true post-state.

Each sub-section dispatches its own subagent, never run their playbooks yourself in this conversation.
