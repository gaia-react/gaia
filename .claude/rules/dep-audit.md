# Dependency-CVE Advisory — pnpm audit

`pnpm audit --json` is the deterministic oracle for "known vulnerable dependencies." It runs pre-merge inside the `code-review-audit` agent (parallel with `react-doctor` and `knip`) as an ADVISORY surface — it reads the live advisory DB, reports high/critical findings so the operator can decide, and never blocks the audit marker or `gh pr merge`.

This local check is **read-only and distinct from the blocking CI path.** GAIA CI's automation runs its own `pnpm audit` cron that opens review-required security PRs and issues for high/critical advisories — that is the blocking placement, on the network side. The local check duplicates none of that: it opens no PR, files no issue, bumps no package. It only informs one review.

## Noise scoping

Two filters keep the same unfixable transitive advisory from spamming every review:

1. **Severity threshold** — only `high` and `critical` advisories are candidates (matches the CI floor; drops low/moderate transitive noise).
2. **Baseline allowlist** — `.gaia/local/dep-audit-baseline.json` (machine-local, gitignored). Acknowledge an unfixable advisory by its ID and it is suppressed (count-only) on later reviews:

   ```jsonc
   { "acknowledged": [{ "id": 1098765, "module": "tough-cookie", "note": "why" }] }
   ```

   The audit only READS this file — acknowledging is an explicit operator action, never something the audit writes (that would turn an advisory into a self-managed suppression gate). Missing file ⇒ empty baseline ⇒ every high/critical surfaces.

## Reference

Extraction recipe + bucket format + acting-on-output: `.claude/agents/code-review-audit.md` (Dependency-CVE advisory). Blocking CI path: `.gaia/cli/src/automation/templates/workflows/gaia-ci-pnpm-audit.yml.tmpl`.
