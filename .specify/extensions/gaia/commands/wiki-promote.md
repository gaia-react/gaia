---
name: speckit-gaia-wiki-promote
description: Promote merged SPEC content into the GAIA wiki.
---

# Wiki Promote — `after_implement` hook

Fires automatically on `/speckit-implement` completion. Reads the SPEC artifact, detects whether the implementing PR has merged, and either promotes content into `gaia/wiki/` or persists a defer flag.

## Step 1 — Resolve the SPEC

(filled in by Phase 2 task-wiki-promote-command-body)

## Step 2 — Read promotion gate

(filled in by Phase 2 task-wiki-promote-command-body)

## Step 3 — Detect merged PR

(filled in by Phase 2 task-wiki-promote-command-body + task-defer-cache)

## Step 4 — Route to wiki destinations

(filled in by Phase 3 task-routing)

## Step 5 — Render and write pages

(filled in by Phase 3 task-idempotency + task-cross-links)

## Step 6 — Hand off to wiki-sync

(filled in by Phase 4 task-wiki-sync-handoff)

## Step 7 — Report

(filled in by Phase 4 task-wiki-sync-handoff)
