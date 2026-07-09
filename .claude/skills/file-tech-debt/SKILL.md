---
name: file-tech-debt
description: File a new tech-debt GitHub issue for an out-of-scope code-review finding, building the dedup key, checking for an existing open or declined-closed match, and only if none exists, creating the issue with the right labels and touching the debt-count staleness sentinel. Trigger on natural-language asks like "file a tech-debt issue", "record this as tech-debt", "open a tech-debt issue for this out-of-scope finding", or "file this finding as debt". Do NOT trigger on draining, fixing, listing, or prioritizing existing debt (that's `/gaia-debt`), nor on general "clean up the code" or "fix this bug" asks that aren't about filing a new tracked issue.
---

# File a tech-debt issue

This skill is the single source of truth for turning one out-of-scope finding (a real problem spotted while reviewing something else, and therefore not fixed in place) into a durable, deduplicated GitHub issue. It covers building the key, checking for a prior match, filing when there is none, and nudging the debt-count display to refresh. It does not decide *which* findings are out-of-scope, does not classify security-sensitivity, and does not fix anything, it only files.

**Callers own their own bookkeeping around this recipe.** Some callers record their own disposition-ledger entry and gate their own downstream state on it after filing succeeds; others file and stop. That bookkeeping is caller-specific and lives in the caller, not here. Follow the steps below exactly as written; do not invent a bookkeeping record, a completion flag, or a run-tracking step of your own on top of them, that would duplicate (or fight with) whatever the caller already does.

## 1. Build the dedup key

Every filed issue's body carries exactly one dedup-key line: a single HTML comment, byte-for-byte in this form:

```
<!-- gaia-debt-key: v1 class=<finding_class> path=<repo-relative-posix-path> line=<integer> -->
```

- `v1` is the schema version. Bump it only for a breaking change to the key's shape, not for routine use.
- `<finding_class>` is the finding's seeded class, or `holistic/unclassified` when the finding maps to no seeded class.
- `<path>` is a repo-relative POSIX path (forward slashes, never an absolute machine path).
- `<line>` is a plain integer.

This line is what every later step (dedup, re-filing checks, any caller-side ledger) matches against, so build it first and keep it verbatim in the body you construct in step 4.

## 2. Check for an existing match (dedup)

**Never rely on `gh`'s full-text search.** GitHub's search tokenizes on `/ : @`, so it cannot reliably match a key containing those characters. Query and match locally instead:

1. `gh issue list --label tech-debt --state open --json number,title,body` and look for an exact substring match of the key line inside `body`.
2. Also check `--state closed`: an exact key match on a closed issue that carries the `wontfix` label (or was closed as not-planned) means the finding was **declined**, not merely resolved. Do not re-file it.
3. Keyless fallback for issues a human filed by hand (no machine key present): scan open `tech-debt` issue bodies for the bare `<path>:<line>` substring. Anchor the match so the line number is followed by a non-digit or end-of-string, otherwise `foo.ts:4` false-matches a sibling `foo.ts:42`. A hit here suppresses re-filing even with no key line at all.

## 3. Idempotency: skip if a match exists

If step 2 found a matching open issue, or a declined-closed one, stop, do not file. The finding already has a disposition; re-filing would create a duplicate.

## 4. Otherwise, file the issue

If no match exists:

1. Create the labels idempotently first (step 6), a pre-existing label is not an error.
2. Build the full issue body (step 5) in a gitignored body-file, not inline (for example `.gaia/local/audit/issue-body.md`).
3. Re-check the dedup query from step 2 immediately before creating, this shrinks the race window where a concurrent run (CI plus a local run, for instance) files the same finding twice. Prefer a search-or-update path over a blind create when your environment supports it.
4. Create the issue with:

```bash
gh issue create --label tech-debt --label severity:<tier> --body-file <path>
```

**Never** pass `--body <argv>` here. CI runs this command with `--verbose`, and `--verbose` echoes argv into the public Actions log, so an inline `--body` string leaks the finding (and anything sensitive quoted inside it) into a public log. Always route the body through `--body-file` (or stdin); the body must never reach argv.

## 5. Issue body schema

Build a self-contained issue body with these parts, in order:

- The dedup-key comment line from step 1, present verbatim.
- The `file:line` location. The cited line must resolve to a real line in the named file, don't cite a location you haven't confirmed.
- A concrete, non-empty description of the failure mode: what input or state triggers it, and what the bad outcome is. "Could be cleaner" is not a failure mode; "a null `userId` reaches this branch and throws" is.
- A suggested fix.
- A handler-class line, exactly one of:
  - `Handler: prompt`, the fix is a single logical unit confined to one file, with no public-contract change and no cross-module ripple.
  - `Handler: plan`, anything larger or more structural.
  - Never `Handler: gaia-spec`, that classification does not exist here. This line is advisory, whatever later drains the issue may override it after reading the actual code.

## 6. Labels

Every out-of-scope non-security issue this recipe files carries `tech-debt` plus **exactly one** severity label. Map the finding's report tier to the label like this:

| Report tier | Label |
|---|---|
| Critical | `severity:critical` |
| Important | `severity:important` |
| Suggestion | `severity:suggestion` |

A finding that gets deliberately declined (closed without fixing) carries GitHub's `wontfix` label, that's what step 2 checks for to avoid re-filing it.

Create all five labels idempotently before the first filing in a run, a label that already exists is not an error:

```bash
for label in tech-debt severity:critical severity:important severity:suggestion wontfix; do
  gh label create "$label" --color <hex> 2>/dev/null || true
done
```

## 7. Touch the debt-count staleness sentinel

As the last step of this recipe, touch the sentinel so the statusline's debt count recomputes on its next tick:

```bash
mkdir -p .gaia/local/debt && : > .gaia/local/debt/refresh-requested
```

Create the parent directory first. On a fresh clone, or in CI, no statusline tick has run yet, so `.gaia/local/debt/` may not exist, a bare `touch` against a missing directory fails silently and leaves the sentinel unset. This step is best-effort: never let a failure here block or fail the caller's flow.

## Contract-preserve note

The wrapped `gaia-debt-key` format (step 1) and the label spellings (step 6) are not just prose here, they are a contract shared with several deterministic, non-LLM consumers and their tests, none of which read this recipe, they hard-code the format instead. Change the key format or any label spelling **only in lockstep** with all of these:

- `.claude/hooks/audit-disposition-check.sh`
- `.gaia/statusline/gaia-statusline.sh`
- `.gaia/scripts/debt-count-refresh.sh`
- `.claude/hooks/debt-session-reconcile.sh`
<!-- gaia:maintainer-only:start -->
- Tests: `.gaia/tests/hooks/debt-sentinel-touch.bats`, `.gaia/tests/hooks/debt-session-reconcile.bats`, `.gaia/scripts/tests/debt-count-refresh.bats`
<!-- gaia:maintainer-only:end -->

The governed set also includes the `debt:in-progress` claim label: `.claude/skills/gaia/references/debt.md` creates and applies it as the `/gaia-debt` in-progress claim, and `.gaia/scripts/debt-count-refresh.sh` consumes it, excluding any issue that carries it from the open count. This recipe never creates or applies `debt:in-progress` itself.

If you're only filing an issue, none of the above needs touching, this note exists so a future edit to the key/label shapes doesn't silently break them.
