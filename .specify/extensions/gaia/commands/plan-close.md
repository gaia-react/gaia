---
name: speckit-gaia-plan-close
description: Close a plan after implementation+merge. Offers wiki-promote for the plan's consolidated SUMMARY.md, cold-consolidates an out-of-band merge, then early-reaps the local plan folder once cost is represented in cost.jsonl.
---

# Plan Close, Lifecycle

Closes a spec-less `PLAN-NNN` after its implementing PR has merged. Mirrors `spec-close`, with one difference: a plan has no authoring-time `wiki_promote_default` decision, so this command makes the promotion ask itself. Three responsibilities:

1. **Drain a deferred wiki-promote**, if a prior run of this command accepted the promotion offer but the PR had not yet merged.
2. **Offer wiki-promote**, a human ask, gated (no size heuristic, no default-on).
3. **Cold-consolidate and reap the local plan folder**, once the wiki side is settled (or declined) and the ledger records the merge.

Invokable manually as `/speckit-gaia-plan-close [PLAN-NNN]`. Nothing auto-triggers it today; a plan reaches this command only by explicit invocation.

## Step 1: Resolve target plan

If `$ARGUMENTS` matches `PLAN-NNN`, target that plan.

Otherwise, build the candidate list:

1. Caches (deferred-drain candidates): `ls .gaia/local/cache/wiki-promote/PLAN-*.json 2>/dev/null` → PLAN IDs awaiting drain.
2. Plans (in-flight or pending disposition): `ls -d .gaia/local/plans/PLAN-*/ 2>/dev/null` → PLAN IDs from folder names.

If exactly one candidate exists, default to it. If multiple, surface via `AskUserQuestion`:

- Question: `Multiple plans eligible for close. Which one?`
- Header: `Plan close`
- Options: one per candidate, labeled `<plan_id>, <intent first line>` with description noting `(awaiting drain)` if the cache exists.

If no candidates: report `plan-close: no plans to close.` and exit.

## Step 2: Conditional drain

Test for `.gaia/local/cache/wiki-promote/<plan_id>.json`.

**If the cache exists** (a prior run of this command accepted the promotion offer but the PR was unmerged at the time):

1. Read the cache. Run `gh pr list --head "$branch" --state merged --json number,mergedAt,url,body --limit 1`.
2. If still unmerged: report `<plan_id>: PR for branch <branch> not yet merged. Re-run after merge.` and exit. Do not delete the cache. Do not proceed to Step 4, the plan is not closed yet.
3. If merged: re-invoke `/speckit-gaia-wiki-promote` by calling the Skill tool to run that command with the plan ID as its argument, and include the exact literal string `drained: true` in the invoking message. Wiki-promote's Step 3 detects the merged PR, runs Steps 4-7, and deletes the cache. **Wiki-promote's Step 8 chain-back is suppressed by that literal token** (this command handles the ledger reconcile and reap itself, in Step 4 below), emit it verbatim, see wiki-promote Step 8 for the guard.

**If no cache exists**, there is nothing to drain (never offered, offered-and-declined on a prior run, or this is the first run): proceed to Step 3.

Track `drained = <bool>` for the final report.

## Step 3: Offer wiki-promote

Skip this step if Step 2 drained a cache this run, the promotion was already accepted and just completed.

Present the promotion offer via `AskUserQuestion`:

- Question: `Promote <plan_id>'s consolidated SUMMARY.md to the wiki?`
- Header: `Plan wiki-promote`
- Options: `Yes, promote now` / `No, skip`

No default-on and no size heuristic, every plan close asks.

**On accept:** invoke `/speckit-gaia-wiki-promote` by calling the Skill tool to run that command with `<plan_id>` as its argument, including the exact literal string `drained: true` in the invoking message (this command always handles the ledger reconcile and reap itself in Step 4, so wiki-promote's Step 8 chain-back is suppressed here too, the same guard as Step 2's drain).

- If wiki-promote completes a full run (PR already merged): pages are written and committed; proceed to Step 4 in this same run.
- If wiki-promote defers (PR not yet merged): it writes the drain cache and exits. Report `<plan_id>: promotion accepted; awaiting PR merge for branch <branch>. Re-run /speckit-gaia-plan-close <plan_id> after merge.` and exit. Do not proceed to Step 4, the plan is not closed yet.

**On decline:** no wiki page is written. The plan counts as **drained**, there is nothing left pending; proceed directly to Step 4.

## Step 4: Reconcile ledger status

Resolve the plan folder: `.gaia/local/plans/<plan_id>/` (canonical source is the consolidated `SUMMARY.md`; a spec-less plan's live `PROGRESS.md` is its pre-consolidation layer). Track whether it exists as `folder_exists`, used in Step 5 and the final report.

Reconcile the `.gaia/local/plans/ledger.json` row to record the merge, via the guarded chokepoint:

```bash
bash .specify/extensions/gaia/lib/plan-reconcile.sh "$PWD" "$PLAN_ID" \
  || echo "plan-reconcile skipped (row missing or lock timeout), non-blocking" >&2
```

This sets `status: merged` and stamps `merged_at`, unified vocabulary with the spec side. Failure is non-blocking.

## Step 5: Cold-consolidate, then delete via the sweep

If `folder_exists` is false (Step 4), set `disposition = "skipped"` and skip to Step 6; there is nothing to reap.

**Cold consolidation backstop (out-of-band merge).** If the folder still holds `SPEC.md` or `AUDIT.md` with no well-formed consolidated `SUMMARY.md` (defensive, a spec-less plan folder does not normally carry these; covers a plan folder assembled outside the usual flow), consolidate before reaping:

1. Read the layers in precedence `SPEC.md` → `AUDIT.md` → plan `PROGRESS.md` (top wins), grounded in the merged code and passing tests, present-tense, surfacing material intent-divergence. This is an agent synthesis step, there is no script for it.
2. Write `.gaia/local/plans/<plan_id>/SUMMARY.md` in the pinned shape (`wiki_promote_default` + `wiki_promote_targets` frontmatter, non-empty H1, non-empty body, optional `## Divergence`).
3. Gate the layer removal on the verify script:

   ```bash
   bash .gaia/scripts/summary-verify.sh ".gaia/local/plans/${PLAN_ID}/SUMMARY.md"
   ```

   - Exit 0 → `rm` the layers found above.
   - Exit 1 → keep the layers in place (do NOT delete them) and skip the reap delegation below for this plan this run (fail-closed). Set `disposition = "blocked"` and report the verify failure.

If a well-formed `SUMMARY.md` already exists (the common case, `plan-archive.sh` already reduced the folder to `SUMMARY.md` + `cost.json` at merge), skip straight to the reap delegation.

**Reap.** Delegate to the single-id sweep with `--close` for early-reap (bypasses only the retention-window age gate; cost representation, the drain-cache check, and the consolidation gate still apply):

```bash
bash .specify/extensions/gaia/lib/plan-archive-merged.sh "$PWD" "$PLAN_ID" --close || true
```

Read the delegate's output to set `disposition` for Step 6:

- Its stdout reports `Deleted <N> merged plan folder(s): <ids>` including `$PLAN_ID` → `disposition = "delete"`.
- Its stderr reports cost not fully represented for `$PLAN_ID` → `disposition = "blocked"`; the folder is retained.
- Its stderr reports consolidation never ran for `$PLAN_ID` (should not happen once the backstop above has run, but the script re-checks) → `disposition = "blocked"`; the folder is retained.

## Step 6: Report

Print one of (prefix with `Drained <N> wiki pages. ` if Step 2 or Step 3 promoted this run, where `<N>` is the count from wiki-promote's report; prefix with `Promotion declined. ` instead if Step 3 was declined):

- `<plan_id> closed. Plan folder deleted (cost preserved in cost.jsonl).`
- `<plan_id> closed; folder retained (cost not fully represented - review).`
- `<plan_id> closed; folder retained (consolidation verify failed - review).`
- `<plan_id> closed. (Folder missing; nothing to dispose.)`

## Notes

- **This flow does NOT re-summarize into the wiki.** `wiki-promote` already wrote `wiki/<domain>/<slug>.md` pages with `promoted_from: <plan_id>` provenance, if the offer was accepted. Re-summarizing here would duplicate. To consolidate redundant or superseded wiki pages, run `/gaia-wiki consolidate`.
- This command never touches `wiki/` directly. The wiki-promote → wiki-sync chain owns wiki writes.
- Deletion is local-only: `.gaia/local/` is gitignored, so the plan folder is not recoverable from git history once deleted. The durable record is `cost.jsonl`, the `specs`/`plans` ledgers, and the merged PR.
- A declined promotion offer (Step 3) counts as drained: there is no pending wiki-promote cache, so the reap gates proceed on this same run.
- `--close` (Step 5's reap delegation) bypasses only the retention-window age gate. Cost representation, the drain-cache check, and the consolidation gate still apply, so a not-yet-consolidated or cost-unrepresented folder is retained even at close.
