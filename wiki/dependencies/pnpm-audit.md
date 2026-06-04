---
type: dependency
status: active
package: pnpm audit
role: dependency-cve-advisory
created: 2026-06-04
updated: 2026-06-04
tags: [dependency, security, quality]
---

# pnpm-audit

`pnpm audit --json` is the deterministic oracle for "known vulnerable dependencies": the live advisory DB answers for certain what an LLM cannot reliably recall. It surfaces high/critical advisories so the operator can decide.

## Conventions

- Run: `pnpm audit --json || true` (parse the JSON regardless of exit code; `pnpm audit` exits non-zero when advisories exist)
- Runs automatically pre-merge inside the [[Code Review Audit Agent]] (alongside `react-doctor` and `knip`), dispatched in the same parallel advisory call.
- Not part of the [[Quality Gate]] (pre-commit): it is a read-only review surface, not a commit gate.

## Noise scoping

Two filters keep the same unfixable transitive advisory from spamming every review:

1. **Severity threshold**: only `high` and `critical` advisories are candidates (matches the CI floor; drops the long tail of low/moderate transitive noise). Within-run dedup is free: the JSON is keyed by advisory ID.
2. **Baseline allowlist**: `.gaia/local/dep-audit-baseline.json` (machine-local, gitignored). Acknowledge an unfixable advisory by its ID and it is suppressed (count-only) on later reviews:

   ```jsonc
   {"acknowledged": [{"id": 1098765, "module": "tough-cookie", "note": "why"}]}
   ```

   The audit only READS this file: acknowledging is an explicit operator action, never something the audit writes (writing it would turn the advisory into a self-managed suppression gate). Missing file ⇒ empty baseline ⇒ every high/critical advisory surfaces.

## Distinct from the CI blocking path

This local check is read-only. GAIA CI's automation runs its own `pnpm audit` cron that opens review-required security PRs and issues for high/critical advisories; that is the blocking placement, on the network side. The local check duplicates none of it: it opens no PR, files no issue, bumps no package. CI blocks the merge train; the local run only informs one review.

## Acting on output

High/critical advisories surface in the audit's advisory bucket, never in Critical/Important/Suggestions (those are blocking tiers). They are **advisory, not blocking**, like knip's and react-doctor's; they never block the audit marker or [[PR Merge Workflow]]. Per surfaced advisory, the fix path is one of:

1. **Bump**: a `patched_versions` range exists; update the dependency to a patched version.
2. **Override**: no patched range and the advisory is transitive; pin a safe version via a `pnpm.overrides` entry.
3. **Acknowledge**: unfixable for now; add the advisory `id` to `.gaia/local/dep-audit-baseline.json` so it is suppressed (count-only) on later reviews.

See [[Code Review Audit Agent]], [[PR Merge Workflow]], [[Quality Gate]].
