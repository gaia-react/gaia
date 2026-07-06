---
name: speckit-gaia-spec-close
description: Close a SPEC after implementation+merge. Optional drain of deferred wiki-promote, then delete the local SPEC artifact once cost is represented in cost.jsonl.
---

# Spec Close, Lifecycle

Closes a SPEC after its implementing PR has merged. Two responsibilities:

1. **Drain a deferred wiki-promote**, if `/speckit-implement` saw the PR unmerged and cached a defer flag.
2. **Delete the local SPEC artifact**, once the wiki side is settled and the ledger records the merge.

Auto-triggered from `wiki-promote` Step 8 on the immediate-merge path. Also invokable manually as `/speckit-gaia-spec-close [SPEC-NNN]` for the deferred path or for retroactive cleanup.

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
3. If merged: re-invoke `/speckit-gaia-wiki-promote` by calling the Skill tool to run that command with the SPEC ID as its argument, and include the exact literal string `drained: true` in the invoking message. Wiki-promote's Step 3 detects the merged PR, runs Steps 4–7, and deletes the cache. **Wiki-promote's Step 8 chain is suppressed in this drain context** to avoid re-entering spec-close: its Step 8 suppression guard matches that literal `drained: true` token in the invocation, so emit it verbatim, not a paraphrase, and do not rely on the surrounding conversation to convey it (see wiki-promote Step 8 for the guard).

**If no cache exists** (immediate-merge or never-promoted path): skip drain. Proceed to Step 3.

Track `drained = <bool>` for telemetry and the final report.

## Step 3: Flip ledger status

Resolve the SPEC folder: `.gaia/local/specs/<spec_id>/` (canonical artifact at `.gaia/local/specs/<spec_id>/SPEC.md`). Track whether it exists as `folder_exists`, used in Step 4 and the final report.

Update the `.gaia/local/specs/ledger.json` row for `<spec_id>` to record the merge: set `status: merged` and stamp `merged_at` with the current UTC timestamp. `merged` is the terminal ledger state; the folder is deleted next, so this stamp is the identity record that survives once it is gone.

Run using the Bash tool:

```bash
PATCH=$(jq -nc --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  '{status: "merged", merged_at: $ts}')
bash .specify/extensions/gaia/lib/ledger-update.sh "$PWD" "$SPEC_ID" "$PATCH" \
  || echo "ledger-update skipped (row missing), non-blocking" >&2
```

Failure is non-blocking. Pre-ledger SPECs (allocated before `.gaia/local/specs/ledger.json` existed) will not have a row and exit 4, log and continue.

## Step 4: Delete via the sweep

If `folder_exists` is false (Step 3), set `disposition = "skipped"` and skip to Step 5; there is nothing to delete.

Otherwise, delegate the delete to the single-id sweep. It gates deletion on cost representation, purges the SPEC's cache keyset, appends the `spec_closed` telemetry event, and runs the mentorship compute-profile chain, all in one place:

```bash
bash .specify/extensions/gaia/lib/spec-archive-merged.sh "$PWD" "$SPEC_ID" || true
```

Read the delegate's output to set `disposition` for Step 5:

- Its stdout reports `Deleted <N> merged SPEC folder(s): <ids>` including `$SPEC_ID` → `disposition = "delete"`.
- Its stderr reports cost not fully represented for `$SPEC_ID` → `disposition = "blocked"`; the folder is retained.

## Step 5: Report

Print one of (prefix with `Drained <N> wiki pages. ` if Step 2 drained, where `<N>` is the count from wiki-promote's report):

- `<spec_id> closed. SPEC folder deleted (cost preserved in cost.jsonl).`
- `<spec_id> closed; folder retained (cost not fully represented - review).`
- `<spec_id> closed. (Artifact missing; nothing to dispose.)`

If wiki content was promoted, also surface: `Run /gaia-wiki consolidate periodically to keep the wiki coherent across SPECs.`

## Notes

- **This flow does NOT re-summarize into the wiki.** `wiki-promote` (the `after_implement` hook) already wrote `wiki/<domain>/<slug>.md` pages with `promoted_from: <spec_id>` provenance at implement time. Re-summarizing here would duplicate. To consolidate redundant or superseded wiki pages across SPECs, run `/gaia-wiki consolidate`.
- This command never touches `wiki/`. The wiki-promote → wiki-sync chain owns wiki writes.
- Deletion is local-only: `.gaia/local/` is gitignored, so the SPEC folder is not recoverable from git history once deleted. The durable record is `cost.jsonl`, the `specs`/`plans` ledgers, and the merged PR.
- The chain from wiki-promote Step 8 fires only on the immediate-merge path. The deferred-drain path runs spec-close once and does not re-enter via the chain (see Step 2's `drained: true` guard).
