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

**Never rely on `gh`'s full-text search.** GitHub's search tokenizes on `/ : @`, so it cannot reliably match a key containing those characters. Query and match locally instead, and match on **the parsed `path=` and `line=` fields alone, ignoring `class=`**: a finding reclassified from `holistic/unclassified` to a seeded class (or the reverse) still carries the same `path=`+`line=` and must resolve to the same issue, not a new one.

1. `gh issue list --label tech-debt --state open --limit 1000 --json number,title,body`. For each issue's `gaia-debt-key` comment, parse out its `path=` and `line=` fields and compare them against the finding's own path and line: `path=` as a string, `line=` as a parsed integer, so `line=4` never matches `line=42`. Two keys equal on both fields are the same finding regardless of what `class=` either one carries.
2. Also check `--state closed` with the same `--limit 1000`: the same path+line comparison on a closed issue that carries the `wontfix` label (or was closed as not-planned) means the finding was **declined**, not merely resolved. Do not re-file it.
3. Keyless fallback for issues a human filed by hand (no machine key present): scan open `tech-debt` issue bodies for the bare `<path>:<line>` substring. Anchor the match so the line number is followed by a non-digit or end-of-string, otherwise `foo.ts:4` false-matches a sibling `foo.ts:42`. This is the same path+line identity as 1 and 2, sourced from a bare-text scan instead of a parsed key; a hit here suppresses re-filing even with no key line at all.

On any match (1, 2, or 3), hand back to the caller the **matched issue's number**, its **open/closed state**, and, when the match came from a parsed key (1 or 2), that key's **existing verbatim inner key** (`v1 class=… path=… line=…`). This recipe records nothing itself; callers own their bookkeeping (see above).

Accepted tradeoff: two genuinely distinct findings that land on the exact same `path:line` with different root-cause classes collapse to one issue under path+line dedup. This is the same residual risk the keyless `path:line` fallback already accepted; matching on path+line alone extends it to the machine-keyed case too.

## 3. Idempotency: skip if a match exists

If step 2 found a matching open issue, or a declined-closed one, stop, do not file. The finding already has a disposition; re-filing would create a duplicate. For an open match, the caller records the matched issue's number and its existing inner key (both returned by step 2) in its own bookkeeping, not a freshly-built key that may carry a different `class=`. For a declined-closed match, the caller adds no bookkeeping entry, exactly as an unmatched-skip is today.

## 4. Otherwise, file the issue

If no match exists:

1. Create the labels idempotently first (step 6), a pre-existing label is not an error.
2. Build the full issue body (step 5) in a gitignored body-file, not inline. Give the file a per-run-unique name under `.gaia/local/audit/` (for example `.gaia/local/audit/issue-body-<something-unique>.md`). The name must be unique because sub-step 4 below deletes it: two runs sharing one fixed name (CI plus a local run, the same pair step 3 guards against) would race, and one run's cleanup would delete the other's in-flight body out from under it.
3. Re-check the dedup query from step 2 immediately before creating, this shrinks the race window where a concurrent run (CI plus a local run, for instance) files the same finding twice. It is the same path+line matching basis as step 2, so a reclassification that lands between your first check and now still resolves to the already-open issue. Prefer a search-or-update path over a blind create when your environment supports it.
4. Create the issue with the form that matches whether a grade is available, then delete the body file **in a second, separate Bash tool call**. A filing that has a difficulty grade in hand (step 7) uses the graded form; a filing with no grade drops the `--label difficulty:<grade>` flag entirely rather than passing it empty or with a placeholder:

```bash
body_file=.gaia/local/audit/issue-body-<something-unique>.md

# Graded filing, when a grade is in hand:
gh issue create --label tech-debt --label severity:<tier> --label difficulty:<grade> --body-file "$body_file"

# Ungraded filing, when no grade is available:
gh issue create --label tech-debt --label severity:<tier> --body-file "$body_file"
```

**Never** pass `--body <argv>` here. CI runs this command with `--verbose`, and `--verbose` echoes argv into the public Actions log, so an inline `--body` string leaks the finding (and anything sensitive quoted inside it) into a public log. Always route the body through `--body-file` (or stdin); the body must never reach argv.

Then, as its own tool call, spelling the path literally:

```bash
rm -f .gaia/local/audit/issue-body-<something-unique>.md
```

The body-file is scratch, and this recipe is its only owner: nothing else reaps it, so a file left behind is permanent litter in the adopter's working tree. **Delete it unconditionally**, whether the create succeeded or failed. The body is fully reconstructible from step 5, so there is nothing worth keeping on a failed create, and the cleanup cannot mask that failure: `gh`'s own output and exit status are what you report.

**Two tool calls, not one.** A `PreToolUse` hook returns a single allow/deny decision for an entire Bash invocation before any of it reaches the shell, so a hook that denies the cleanup drops the create standing beside it too: no issue filed, and no output naming the cause. Splitting them keeps a denied cleanup from costing you the filing. One consequence for how the second call is written: shell variables do not survive between tool calls, so spell the path literally rather than reusing `$body_file`. Either spelling of it works, relative or absolute, and the destructive-command guard whitelists this directory both ways.

## 5. Issue body schema

Build a self-contained issue body with these parts, in order:

- The dedup-key comment line from step 1, present verbatim.
- The `file:line` location. The cited line must resolve to a real line in the named file, don't cite a location you haven't confirmed.
- A concrete, non-empty description of the failure mode: what input or state triggers it, and what the bad outcome is. "Could be cleaner" is not a failure mode; "a null `userId` reaches this branch and throws" is.
- A suggested fix.
- A handler-class line, exactly one of:
  - `Handler: prompt`, the fix is a single logical unit confined to one file, with no public-contract change and no cross-module ripple.
  - `Handler: plan`, anything larger or more structural.
  - `Handler: spec`, the fix must begin with a design SPEC, a new subsystem, a schema or contract decision, or a cross-cutting redesign. `/gaia-debt` resolves a spec-class issue by printing a `/gaia-spec` handoff and stopping, not by opening a fix PR.

  This line is advisory, whatever later drains the issue may override it after reading the actual code.

## 6. Labels

Every out-of-scope non-security issue this recipe files carries `tech-debt` plus **exactly one** severity label; a filing that carries a difficulty grade (see step 7) carries exactly one severity label and exactly one difficulty label. Map the finding's report tier to the label like this:

| Report tier | Label |
|---|---|
| Critical | `severity:critical` |
| Important | `severity:important` |
| Suggestion | `severity:suggestion` |

See step 7 for the difficulty label's three permitted values and the rubric for choosing between them.

A finding that gets deliberately declined (closed without fixing) carries GitHub's `wontfix` label, that's what step 2 checks for to avoid re-filing it.

Create all eight labels idempotently before the first filing in a run, a label that already exists is not an error:

```bash
for label in tech-debt severity:critical severity:important severity:suggestion \
             difficulty:easy difficulty:medium difficulty:hard wontfix; do
  gh label create "$label" --color <hex> 2>/dev/null || true
done
```

## 7. Difficulty grade

A filing grades, carrying exactly one `difficulty:` label, when the cited code is read at filing time (a reviewer or an audit agent surfaces the defect and you open the code to file it, as with a review follow-up), so the grade is the rubric below applied to real code rather than guessed from a description. Every filed issue already carries a concrete `file:line` and failure mode (step 5 makes both mandatory), so the discriminator is not those but whether the code behind them was read here. A filing that has not read the cited code omits the label rather than guess one. Two routes always read the code and so always grade: `.claude/agents/code-audit-frontend.md`'s non-security disposition pipeline and the tech-debt filing block in `.claude/skills/gaia/references/audit.md`. This section is the single source of truth for the permitted values and for choosing between them; a grading filing never grades against a private reading of a grade's name.

Grade the difficulty of **the fix**, never the model, agent, or tooling that would perform it.

| Grade | The fix carries |
|---|---|
| `difficulty:easy` | no design decision left to make: the issue text and the cited code together determine the change, and two competent engineers would write the same fix. |
| `difficulty:medium` | a design decision the surrounding code settles: more than one implementation is reasonable in the abstract, and reading the adjacent code, its conventions, and its call sites picks one. |
| `difficulty:hard` | a design decision the surrounding code does not settle: two competent engineers who have both read all the cited code could still reasonably choose differently, or the fix must first settle what the correct behavior is. |

Read the three rows top to bottom and take the first whose properties all hold. The rows are exclusive by construction: they ask how many design decisions the fix carries and whether the code answers them, and exactly one answer holds for any one fix.

Difficulty adds the dimension the `Handler:` line does not capture. `Handler:` grades how far the change reaches; difficulty grades how much design the fix needs. The two often move together, and they are not meant to: a one-file fix whose correct behavior is genuinely in question is `Handler: prompt` and `difficulty:hard`, and a mechanical rename across twenty files is `Handler: plan` and `difficulty:easy`.

Worked boundary, easy versus medium. A swallowed error the issue text says to rethrow is `difficulty:easy`: the issue determines the change. The same swallowed error, where the issue says only that it must not be swallowed and leaves the choice between rethrowing, logging and continuing, and surfacing to the caller, is `difficulty:medium`: the choice is real, and the sibling call sites settle it.

- **When a filing omits the grade.** A filing omits the label whenever the cited code was not read at filing time, rather than guessing a grade from a description: a direct human invocation that files from a relayed summary or hand-off without reopening the cited code has no rubric-applied grade to give; the orchestrator's cross-remit disposition has not read the finding against this rubric; and the `/health-audit` comprehensive runbook's human-gated filing offer files from an operator's yes on a written report rather than from freshly-read code. A human invocation that *does* read the cited code as it files grades instead (above); it is not forced ungraded merely for arriving by the human path. An issue carrying no grade is normal: it orders, clusters, and drains exactly as a graded one does. That guarantee is what keeps a mixed adopter state safe, since every file this feature touches resolves independently on update: a new copy of this recipe running against an old `debt.md` files grades that nothing yet reads, and a new `debt.md` running against old agents reads a backlog where nothing is graded. Both states are reachable and both benign.
- **Argv constraint.** The value written to the `difficulty:<grade>` label must be one of the three literals above, byte-for-byte, before it reaches any `gh` argv. Argv exposure is minimal here, the token is fixed-vocabulary, which is why the `--body-file` mandate in step 4 is not implicated, but a model-produced string interpolated into a command CI runs with `--verbose` argv echoing earns the one-clause constraint anyway.
- **Disclosure.** The three grade values are fixed and carry no information about the finding: they do not discriminate a security-class finding from any other, so a difficulty grade leaks nothing about security-sensitivity regardless of who applies it or where the issue lands. Machine filing never reaches a public repo for a security-class finding, the agent's security-class divert path intercepts it first; and because the grade itself is non-discriminating, a human-invoked filing that now carries one discloses nothing a graded machine filing would not.
- **Where the grade comes from.** This file defines the rubric; it does not apply it. The two external grading routes named at the top of this section, the frontend audit agent and `audit.md`, read it and write the label; an edit to the value set or the rubric must reach both. The human-invocation grading applies this section's rubric in place, so it needs no separate propagation.

## 8. Touch the debt-count staleness sentinel

As the last step of this recipe, touch the sentinel so the statusline's debt count recomputes on its next tick:

```bash
mkdir -p .gaia/local/debt && : > .gaia/local/debt/refresh-requested
```

Create the parent directory first. On a fresh clone, or in CI, no statusline tick has run yet, so `.gaia/local/debt/` may not exist, a bare `touch` against a missing directory fails silently and leaves the sentinel unset. This step is best-effort: never let a failure here block or fail the caller's flow.

## Contract-preserve note

The wrapped `gaia-debt-key` format (step 1) and the label spellings (step 6) are not just prose here, they are a contract shared with several deterministic, non-LLM consumers and their tests, none of which read this recipe, they hard-code the format instead. Step 2's dedup **matching basis** is `path=`+`line=` (ignoring `class=`), but that only changes which issue this recipe treats as a match, it does not change the wrapped key format (step 1) or any label spelling (step 6), so none of the consumers below need a change on account of it. Change the key format or any label spelling **only in lockstep** with all of these:

- `.claude/hooks/audit-disposition-check.sh`
- `.gaia/statusline/gaia-statusline.sh`
- `.gaia/scripts/debt-count-refresh.sh`
- `.claude/hooks/debt-session-reconcile.sh`
<!-- gaia:maintainer-only:start -->
- Tests: `.gaia/tests/hooks/debt-sentinel-touch.bats`, `.gaia/tests/hooks/debt-session-reconcile.bats`, `.gaia/scripts/tests/debt-count-refresh.bats`
<!-- gaia:maintainer-only:end -->

The governed set also includes the `debt:in-progress` claim label: `.claude/skills/gaia/references/debt.md` creates and applies it as the `/gaia-debt` in-progress claim, and `.gaia/scripts/debt-count-refresh.sh` consumes it, excluding any issue that carries it from the open count. This recipe never creates or applies `debt:in-progress` itself. The same holds for `debt:spec-pending`: `debt.md` creates and applies it as the `/gaia-debt` design-first handoff park label, and `.gaia/scripts/debt-count-refresh.sh` consumes it, excluding any issue that carries it from the open count too. This recipe never creates or applies `debt:spec-pending` itself.

The `difficulty:` namespace (step 7) is not part of this lockstep contract. No deterministic non-LLM consumer reads it, verified against all four named above: `.gaia/scripts/debt-count-refresh.sh` filters by excluding two specific label names (`debt:in-progress` and `debt:spec-pending`) and ignores anything else, `.claude/hooks/audit-disposition-check.sh` matches the dedup key in the issue body and parses no labels, `.gaia/statusline/gaia-statusline.sh` parses no labels, and `.claude/hooks/debt-session-reconcile.sh` only reconciles the count downward. Adding this namespace therefore requires zero changes to any of the four, which is exactly why the grade could be a label at all.

If you're only filing an issue, none of the above needs touching, this note exists so a future edit to the key/label shapes doesn't silently break them.
