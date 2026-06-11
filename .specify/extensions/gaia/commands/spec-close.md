---
name: speckit-gaia-spec-close
description: Close a SPEC after implementation+merge. Optional drain of deferred wiki-promote, then disposition prompt (archive / delete / keep) for the local SPEC artifact.
---

# Spec Close, Lifecycle

Closes a SPEC after its implementing PR has merged. Two responsibilities:

1. **Drain a deferred wiki-promote**, if `/speckit-implement` saw the PR unmerged and cached a defer flag.
2. **Prompt for SPEC artifact disposition**, archive, delete, or keep in place, once the wiki side is settled.

Auto-triggered from `wiki-promote` Step 8 on the immediate-merge path. Also invokable manually as `/gaia-spec close [SPEC-NNN]` for the deferred path or for retroactive disposition.

## Step 1: Resolve target SPEC

If `$ARGUMENTS` matches `SPEC-NNN`, target that SPEC.

Otherwise, build the candidate list:

1. Caches (deferred-drain candidates): `ls .gaia/local/cache/wiki-promote/*.json 2>/dev/null` → SPEC IDs awaiting drain.
2. Specs (in-flight or pending disposition): `ls -d .gaia/local/specs/SPEC-*/ 2>/dev/null` → SPEC IDs from folder names (excludes `archived/`).

If exactly one candidate exists, default to it. If multiple, surface via `AskUserQuestion`:

- Question: `Multiple SPECs eligible for close. Which one?`
- Header: `SPEC close`
- Options: one per candidate, labeled `<spec_id>, <intent first line>` with description noting `(awaiting drain)` if the cache exists.

If no candidates: report `spec-close: no SPECs to close.` and exit.

## Step 2: Conditional drain

Test for `.gaia/local/cache/wiki-promote/<spec_id>.json`.

**If the cache exists** (deferred path):

1. Read the cache. Run `gh pr list --head "$branch" --state merged --json number,mergedAt,url,body --limit 1`.
2. If still unmerged: report `<spec_id>: PR for branch <branch> not yet merged. Re-run after merge.` and exit. Do not delete the cache. Do not proceed to disposition, the SPEC is not closed yet.
3. If merged: re-invoke `/speckit-gaia-wiki-promote` with the SPEC ID as context. Wiki-promote's Step 3 detects the merged PR, runs Steps 4–7, and deletes the cache. **Wiki-promote's Step 8 chain is suppressed in this drain context** to avoid re-entering spec-close, pass `drained: true` in the chain context (see wiki-promote Step 8 for the guard).

**If no cache exists** (immediate-merge or never-promoted path): skip drain. Proceed to Step 3.

Track `drained = <bool>` for telemetry and the final report.

## Step 3: Disposition prompt

Resolve the SPEC folder: `.gaia/local/specs/<spec_id>/` (canonical artifact at `.gaia/local/specs/<spec_id>/SPEC.md`).

If the folder is missing, set `disposition = "skipped"`, skip Step 4, and continue to Step 5. Report line surfaces "(artifact missing; nothing to dispose)".

Surface via `AskUserQuestion`:

- Question: `<spec_id> implementation complete and PR merged. Disposition?`
- Header: `SPEC dispose`
- Options:
  - `{ label: "Archive (Recommended)", description: "Move the SPEC folder to .gaia/local/specs/archived/ with status=archived. Preserves the SPEC artifact and its siblings for posterity. Wiki content was already promoted at implement time; no re-summarization." }`
  - `{ label: "Delete", description: "Remove the SPEC folder. Local-only (.gaia/local/ is gitignored), so the SPEC is not recoverable from git history." }`
  - `{ label: "Keep in place", description: "Leave the folder at .gaia/local/specs/<spec_id>/ unchanged. Choose if undecided; re-run /gaia-spec close <spec_id> later to revisit." }`

## Step 4: Apply disposition

**On `Archive`:**

1. `mkdir -p .gaia/local/specs/archived/`.
2. If `.gaia/local/specs/archived/<spec_id>/` already exists, the SPEC is already archived, report `<spec_id> already archived at .gaia/local/specs/archived/<spec_id>/.`, set `disposition = "archive"`, and skip the remaining sub-steps.
3. Edit `.gaia/local/specs/<spec_id>/SPEC.md` frontmatter in place: set `status: archived`; set `archived_at: <ISO 8601 UTC>`. Preserve all other fields verbatim.
4. Move the whole folder: `mv .gaia/local/specs/<spec_id> .gaia/local/specs/archived/<spec_id>`. Sibling artifacts move with it.

**On `Delete`:**

1. `rm -rf .gaia/local/specs/<spec_id>`.

**On `Keep in place`:**

1. No-op.

## Step 5: Flip ledger status

Update the `.gaia/specs.json` row for `<spec_id>` to record the merge: set `status: merged` and stamp `merged_at` with the current UTC timestamp. Disposition lives on the artifact (and in telemetry); the ledger tracks SPEC lifecycle independently of artifact location.

Run using the Bash tool:

```bash
PATCH=$(jq -nc --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  '{status: "merged", merged_at: $ts}')
bash .specify/extensions/gaia/lib/ledger-update.sh "$PWD" "$SPEC_ID" "$PATCH" \
  || echo "ledger-update skipped (row missing), non-blocking" >&2
```

Failure is non-blocking. Pre-ledger SPECs (allocated before `.gaia/specs.json` existed) will not have a row and exit 4, log and continue.

## Step 6: Telemetry

Append to `.gaia/local/telemetry/spec-pacing.jsonl`:

    { "event": "spec_closed", "spec_id": "<id>", "disposition": "archive|delete|keep|skipped", "drained": <bool>, "ts": "<ISO 8601 UTC>" }

Append via `printf '%s\n' '<json>' >> .gaia/local/telemetry/spec-pacing.jsonl`. Failure to append never blocks the flow.

Then chain `gaia telemetry compute-profile`:

    .gaia/cli/gaia telemetry compute-profile

The compute-profile command short-circuits when mentorship is disabled (no-op exit 0). When mentorship is enabled, it regenerates `profile.md` over the rolling 30-day window and writes today's analytics report. Failure of compute-profile never blocks the spec-close flow, log to stderr, continue.

## Step 7: Report

Print one of (prefix with `Drained <N> wiki pages. ` if Step 2 drained, where `<N>` is the count from wiki-promote's report):

- `<spec_id> closed. Archived to .gaia/local/specs/archived/<spec_id>/.`
- `<spec_id> closed. SPEC folder deleted.`
- `<spec_id> closed. SPEC folder kept at .gaia/local/specs/<spec_id>/.`
- `<spec_id> closed. (Artifact missing; nothing to dispose.)`

If wiki content was promoted, also surface: `Run /gaia-wiki consolidate periodically to keep the wiki coherent across SPECs.`

## Notes

- **Disposition does NOT re-summarize into the wiki.** `wiki-promote` (the `after_implement` hook) already wrote `wiki/<domain>/<slug>.md` pages with `promoted_from: <spec_id>` provenance at implement time. Re-summarizing here would duplicate. To consolidate redundant or superseded wiki pages across SPECs, run `/gaia-wiki consolidate`.
- This command never touches `wiki/`. The wiki-promote → wiki-sync chain owns wiki writes.
- Archive is reversible (move the folder back). Delete is local-only, `.gaia/local/` is gitignored, so the SPEC is not recoverable from git history. Default to Archive if uncertain.
- The chain from wiki-promote Step 8 fires only on the immediate-merge path. The deferred-drain path runs spec-close once and does not re-enter via the chain (see Step 2's `drained: true` guard).
