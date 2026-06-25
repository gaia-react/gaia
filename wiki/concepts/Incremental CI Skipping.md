---
type: concept
status: active
created: 2026-06-02
updated: 2026-06-24
tags: [concept, ci, audit]
---

# Incremental CI Skipping

The expensive required checks skip their work when the **delta since that check
last passed green** touches no files relevant to it, even when earlier,
already-green commits in the same PR touched relevant files. A code commit that
passes followed by a prose-only commit (wiki, CHANGELOG, instruction files)
re-reviews an empty relevant delta and skips, instead of re-running the whole
suite on a tree it has already cleared.

## Scope

`main`'s ruleset requires three checks: `Run Chromatic`, `Vitest and
Playwright`, and `code-review-audit`. All three are **job-level** checks; the
required context equals the job `name:`. A job that runs but gates its
expensive steps off still completes and posts a green check under that name, so
the ruleset stays satisfied with no external check stamping.

Incremental skipping applies to the two expensive checks:

- **`code-review-audit`** (`.github/workflows/code-review-audit.yml`): see
  [[Code Review Audit CI]].
- **`Vitest and Playwright`** (`.github/workflows/tests.yml`).

`Run Chromatic` is left always-on. It is the cheapest of the three (TurboSnap
`onlyChanged` already skips unchanged snapshots), and its `UI Review` /
`UI Tests` / `Storybook Publish` results are commit **statuses** the Chromatic
app posts only when it runs. Leaving Chromatic always-on keeps it adopter-safe
regardless of which Chromatic context an adopter chooses to require.

## Mechanism

Each gated workflow does two things before its expensive steps:

1. **Resolve the last-green base.** Walk `merge-base(origin/main, HEAD)..HEAD`,
   newest→oldest, skipping HEAD, and return the most recent ancestor that
   already passed:
   - `code-review-audit` uses `.github/audit/resolve-audit-base.sh`; the base
     is the most recent ancestor carrying a version-matched `GAIA-Audit` signal
     (commit trailer or commit status). Version-aware: a `.gaia/VERSION` bump
     invalidates older audits and forces a full re-audit under the new ruleset.
   - `tests.yml` uses `.github/audit/resolve-check-base.sh "Vitest and
Playwright"`; the base is the most recent ancestor whose `check-runs`
     include that context with `conclusion == "success"`.
2. **Diff `<base>...HEAD` against a path allowlist.** The workflow lists the
   changed files in the un-passed delta and matches them (ERE) against the
   files that affect it. No match → gate the expensive steps off; the job still
   reports its required check green.

When no green ancestor exists (the first run on a PR, every prior run
failed/cancelled (those leave no green signal), a `.gaia/VERSION` bump (audit
only), or the Checks API is unreachable (fork PRs run with a token that the
helper falls back from)), the helper emits `origin/main` and the diff covers
the full PR scope. The helpers never anchor on an un-passed commit, so they
never skip code the check has not cleared.

For `code-review-audit`, in-scope PRs by `local`-mode authors with no override
label add a third terminal state: CI stands down without spending tokens and
posts a `pending` `GAIA-Audit` commit status on HEAD. The audit job still
concludes green, so the gate is the `GAIA-Audit` commit status, not the job
conclusion: a `pending` stand-down keeps the merge button blocked until the
local audit clears it. See [[Code Review Audit CI]].

## Why "last green", not "last run"

Only a `success` conclusion anchors a base. A failed or cancelled run on a
commit leaves no green signal, so the walk continues past it. A later
prose-only commit then diffs back to the last truly-green tree and re-runs,
catching any code introduced in the failed commit in between. Anchoring on the
last _run_ (rather than the last _green_ run) would let a broken commit hide
behind a subsequent prose commit.

## Permissions

`resolve-check-base.sh` reads the Checks API, so `tests.yml` declares
`permissions: { contents: read, checks: read }` and exports `GH_TOKEN` to the
resolve step. Without a readable token (some fork PRs) the helper falls back to
full scope.

## Source-of-truth links

- Generic last-green resolver: `.github/audit/resolve-check-base.sh` (tests +
  any future check).
- Version-aware audit resolver: `.github/audit/resolve-audit-base.sh`.

## See also

- [[Code Review Audit CI]]: the audit workflow and its trailer/chore-deps skip
  rules; this is its incremental-scope companion.
- [[Chromatic Opt-Out]]: why and how the Chromatic check can be disabled.
- [[PR Merge Workflow]]: the local-side audit handshake.
