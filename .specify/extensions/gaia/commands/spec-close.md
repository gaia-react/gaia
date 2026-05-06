---
name: speckit-gaia-spec-close
description: Drain deferred wiki-promote cache for a SPEC; re-runs promotion if the PR has now merged.
---

# Spec Close — Wiki-Promote Drain

Minimal scope for SPEC-004: re-run wiki-promote against a SPEC whose `after_implement` hook deferred. Full `/gaia spec close` lifecycle (status transitions, archive ceremony) is a separate downstream SPEC.

## Step 1 — Resolve target

If `$ARGUMENTS` matches `SPEC-NNN`, target that SPEC. Otherwise list `.gaia/local/cache/wiki-promote/*.json` and ask the user via `AskUserQuestion` which to drain.

## Step 2 — Re-probe PR merge

Read the cache file. Run `gh pr list --head <branch> --state merged --json number,mergedAt,url,body --limit 1`.

If still unmerged: report `SPEC-NNN: PR for branch <branch> not yet merged. Try again after the PR merges.` and exit. Do not delete the cache.

If merged: continue.

## Step 3 — Re-fire wiki-promote

Re-invoke `/speckit-gaia-wiki-promote` with the SPEC ID as context. The wiki-promote command's Step 3 will now find the merged PR and proceed to Steps 4–7. It will delete the cache file when it finishes.

## Step 4 — Report

`SPEC-NNN drained: <N> wiki pages staged. Wiki-sync invoked for commit.`

## Known followup

The drain re-fires `/speckit-gaia-wiki-promote`, which re-prompts on `wiki_promote_default: ask` by design. Because the user already confirmed at deferral time, the second prompt is redundant. Accepted for now; a future enhancement can pass a `--drained` context flag to suppress the re-prompt.
