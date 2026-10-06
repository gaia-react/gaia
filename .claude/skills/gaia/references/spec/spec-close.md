---
description: Close a SPEC after implementation+merge. Optional drain of deferred wiki-promote, cold-consolidates an out-of-band merge into SUMMARY.md, then early-reaps the local SPEC folder once cost is represented in cost.jsonl.
---

# Spec Close, Lifecycle

**Status:** no automatic trigger. Run it by hand: read this file and follow it with the SPEC id. A person also reaches it from `wiki-promote` Step 8 when they run wiki-promote by hand on the immediate-merge path; the deferred path and retroactive cleanup use the same manual run.

Closes a SPEC after its implementing PR has merged. Two responsibilities:

1. **Drain a deferred wiki-promote**, if a wiki-promote run saw the PR unmerged and cached a defer flag.
2. **Cold-consolidate and reap the local SPEC folder**, once the wiki side is settled and the ledger records the merge.

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
3. If merged: read `.claude/skills/gaia/references/spec/wiki-promote.md` and follow it, with the SPEC id and the exact literal string `drained: true` stated in the instruction. Wiki-promote's Step 3 detects the merged PR, runs Steps 4–7, and deletes the cache. **Wiki-promote's Step 8 chain is suppressed in this drain context** to avoid re-entering spec-close: its Step 8 suppression guard matches that literal `drained: true` token in the instruction, so emit it verbatim, not a paraphrase, and do not rely on the surrounding conversation to convey it (see wiki-promote Step 8 for the guard).

**If no cache exists** (immediate-merge or never-promoted path): skip drain. Proceed to Step 3.

Track `drained = <bool>` for telemetry and the final report.

## Step 3: Flip ledger status

Resolve the SPEC folder: `.gaia/local/specs/<spec_id>/` (canonical source is the consolidated `SUMMARY.md`; `SPEC.md`/`AUDIT.md` are pre-consolidation layers, present only until the cold-consolidation backstop in Step 4 replaces them). Track whether it exists as `folder_exists`, used in Step 4 and the final report.

Update the `.gaia/local/specs/ledger.json` row for `<spec_id>` to record the merge: set `status: merged` and stamp `merged_at` with the current UTC timestamp. `merged` is the terminal ledger state; the folder is reaped next, so this stamp is the identity record that survives once it is gone.

Run using the Bash tool:

```bash
PATCH=$(jq -nc --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  '{status: "merged", merged_at: $ts}')
bash .gaia/scripts/spec/ledger-update.sh "$PWD" "$SPEC_ID" "$PATCH" \
  || echo "ledger-update skipped (row missing), non-blocking" >&2
```

Failure is non-blocking. Pre-ledger SPECs (allocated before `.gaia/local/specs/ledger.json` existed) will not have a row and exit 4, log and continue.

## Step 4: Cold-consolidate, then delete via the sweep

If `folder_exists` is false (Step 3), set `disposition = "skipped"` and skip to Step 5; there is nothing to delete.

**Cold consolidation backstop (out-of-band merge).** If the folder still holds `SPEC.md` or `AUDIT.md` with no well-formed consolidated `SUMMARY.md` (the PR merged out-of-band, or the warm orchestrator's own consolidation never ran), consolidate before reaping:

1. Read the layers in precedence `SPEC.md` → `AUDIT.md` → plan `PROGRESS.md` (top wins), grounded in the merged code and passing tests, present-tense, surfacing material intent-divergence. This is an agent synthesis step, there is no script for it.
2. Write `.gaia/local/specs/<spec_id>/SUMMARY.md` in the pinned shape (`wiki_promote_default` + `wiki_promote_targets` frontmatter, non-empty H1, non-empty body, optional `## Divergence`).
3. Gate the layer removal on the verify script:

   ```bash
   bash .gaia/scripts/summary-verify.sh ".gaia/local/specs/${SPEC_ID}/SUMMARY.md"
   ```

   - Exit 0 → `rm .gaia/local/specs/<spec_id>/SPEC.md .gaia/local/specs/<spec_id>/AUDIT.md`.
   - Exit 1 → keep the layers in place (do NOT delete them) and skip the reap delegation below for this SPEC this run (fail-closed). Set `disposition = "blocked"` and report the verify failure.

If a well-formed `SUMMARY.md` already exists (the common case, the warm orchestrator already consolidated at merge), skip straight to the reap delegation.

**Reap.** Delegate to the single-id sweep with `--close` for early-reap (bypasses only the retention-window age gate; cost representation, the drain-cache check, and the consolidation gate still apply). It purges the SPEC's cache keyset, all in one place:

```bash
bash .gaia/scripts/spec/spec-archive-merged.sh "$PWD" "$SPEC_ID" --close || true
```

Read the delegate's output to set `disposition` for Step 5:

- Its stdout reports `Deleted <N> merged SPEC folder(s): <ids>` including `$SPEC_ID` → `disposition = "delete"`.
- Its stderr reports cost not fully represented for `$SPEC_ID` → `disposition = "blocked"`; the folder is retained.
- Its stderr reports consolidation never ran for `$SPEC_ID` (should not happen once the backstop above has run, but the script re-checks) → `disposition = "blocked"`; the folder is retained.

## Step 5: Report

Print one of (prefix with `Drained <N> wiki pages. ` if Step 2 drained, where `<N>` is the count from wiki-promote's report):

- `<spec_id> closed. SPEC folder deleted (cost preserved in cost.jsonl).`
- `<spec_id> closed; folder retained (cost not fully represented - review).`
- `<spec_id> closed; folder retained (consolidation verify failed - review).`
- `<spec_id> closed. (Artifact missing; nothing to dispose.)`

If wiki content was promoted, also surface: `Run /gaia-wiki consolidate periodically to keep the wiki coherent across SPECs.`

## Notes

- **This flow does NOT re-summarize into the wiki.** `wiki-promote` already wrote `wiki/<domain>/<slug>.md` pages with `promoted_from: <spec_id>` provenance when it was run. Re-summarizing here would duplicate. To consolidate redundant or superseded wiki pages across SPECs, run `/gaia-wiki consolidate`.
- This command never touches `wiki/`. The wiki-promote → wiki-sync chain owns wiki writes.
- Deletion is local-only: `.gaia/local/` is gitignored, so the SPEC folder is not recoverable from git history once deleted. The durable record is `cost.jsonl`, the `specs`/`plans` ledgers, and the merged PR.
- The chain from wiki-promote Step 8 fires only on the immediate-merge path. The deferred-drain path runs spec-close once and does not re-enter via the chain (see Step 2's `drained: true` guard).
- `--close` (Step 4's reap delegation) bypasses only the retention-window age gate. Cost representation, the drain-cache check, and the consolidation gate still apply, so a not-yet-consolidated or cost-unrepresented folder is retained even at close.
