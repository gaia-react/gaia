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

## Provenance line

Beside the dedup-key line, the issue body (or a waived finding's pull-request-body entry) carries a second HTML comment recording which work surfaced the finding, byte-for-byte in this form:

```
<!-- gaia-debt-key: v1 class=holistic/unclassified path=app/services/foo.ts line=42 -->
<!-- gaia-debt-origin: branch=debt/1121-marker-sep mode=drain unit=1121 changed=1 head=a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2 -->
```

Both are HTML comments, so neither appears in the rendered issue. Fields are `key=value` pairs separated by single spaces, in the order above. The order is canonical for readability only: the pairs are self-describing, so a reader must not depend on position, and adding or removing a field breaks no reader.

There is no version prefix, ever. The dedup key carries one because it is an identity that must match across time. Provenance matches nothing, so a version would imply a versioned contract and invite the lockstep discipline this design exists to avoid.

The field table:

| field | value | survives branch deletion |
|---|---|---|
| `branch` | the raw branch verbatim, or `unknown` | yes |
| `mode` | one of `drain`, `plan`, `maintenance`, `adhoc`, `unknown` | yes |
| `unit` | the issue numbers or plan/spec id the work was executing, or `unknown` | yes |
| `changed` | `0`, `1`, or `unknown` | yes |
| `head` | the reviewed HEAD sha, or `unknown` | no |

**Reserved characters.** Two are percent-encoded in a value: `>`, because a git branch name may legally contain it and an unencoded one would terminate the HTML comment early and leak the remainder as visible text, and `%` itself, so the encoding is invertible and a reader can recover the exact branch name. `%` is encoded first, then `>`; that order is what makes the round trip exact. "Verbatim" above means the raw name after that reversible encoding, not a normalized or truncated one. This is the same reasoning `gaia_key_slug` applies in `.gaia/scripts/audit-key-lib.sh`, with a far smaller reserved set because this value is read by humans rather than used as a filename.

**Why `head` is carried despite rotting.** While the commit is reachable it makes a cited `path:line` resolvable with `git show <sha>:<path>`, a partial mitigation for the line drift that makes older keys stale. Everything else on the line is a stored conclusion rather than a coordinate, so it stays readable after the branch is gone.

**The convention table.** `branch` is normalized for matching only, the stored `branch` field always keeps the raw name: strip a single leading `worktree-`, then replace every `+` with `/` in what remains, both steps unconditional, in that order. The normalized name is matched against this table, first matching row wins:

| # | normalized branch | `mode` | `unit` |
|---|---|---|---|
| 1 | `debt/<members>-batch`, `<members>` matching `^[0-9]+(-[0-9]+)*$` | `drain` | `<members>` |
| 2 | `debt/<rest>` | `drain` | the leading `[0-9]+` of `<rest>`, else `unknown` |
| 3 | `spec-<nnn>` or `spec-<nnn>-<rest>`, `<nnn>` matching `^[0-9]+$` | `plan` | `SPEC-<nnn>` |
| 4 | `plan-<nnn>` or `plan-<nnn>-<rest>`, `<nnn>` matching `^[0-9]+$` | `plan` | `plan-<nnn>` |
| 5 | `chore/<rest>` or `chore-<rest>` | `maintenance` | `<rest>` |
| 6 | `harden/<rest>` or `harden-<rest>` | `maintenance` | `<rest>` |
| 7 | `wiki-sync/<rest>` | `maintenance` | `<rest>` |
| 8 | `audit-<rest>` | `maintenance` | `<rest>` |
| 9 | anything else, including `main`, `fix/<rest>`, `docs/<rest>`, `feat/<rest>` | `adhoc` | `unknown` |

Any derived `unit` that comes out empty becomes `unknown`. Row 9 routes `fix/`, `docs/`, and `feat/` to `adhoc` deliberately: those are hand-named human work with no unit encoded in the branch name. The table is keyed on prefix families rather than exact per-command branch names because a table of exact names matches almost no real branch: roughly twenty real `chore/*` and `harden/*` branches would fall through to `adhoc` otherwise. A new branch family that later deserves its own mode is a change to this file, not a new field and not a version bump.

When `branch` resolves to `unknown` (no explicit branch argument, no head-ref environment variable, and no current branch from git), `mode` and `unit` are also `unknown`, never `adhoc`. `adhoc` means a branch resolved and matched no row, a different fact from no branch resolving at all.

**The derivation.** One shared helper, `.gaia/scripts/debt-origin-lib.sh`, owns the encoding, the classification, and the line assembly. Each route calls it once per finding, in the spelling its own surface gives. Bare:

```bash
origin="$(bash .gaia/scripts/debt-origin-lib.sh --changed "<0|1|unknown>" 2>/dev/null || true)"
```

It fails open throughout: each field it cannot resolve becomes the literal `unknown`, it exits zero regardless, and a caller never treats its output as a precondition.

**The fail-open rule, stated as a rule.** Never block, fail, retry, or defer a filing or a waive because provenance is partial, absent, or malformed. If the helper prints nothing, omit the line and continue. Omitting the line is reserved for a route that predates provenance or for a helper that could not run: a working route must never omit the line as a way of expressing that nothing resolved, because a line of unknowns and no line at all must stay distinguishable.

**One route cannot call it.** In continuous integration the audit agent's tool policy grants no shell for this helper, so the audit workflow resolves provenance in a step of its own, ahead of the agent, and writes the finished lines to disk for the agent to read. The agent never re-derives them and carries no prose copy of the rules. One implementation, not two.

**The `changed` field, precisely.** It reports whether the cited path is in the pull request's fork-point changed-file set. Two nearer sets are explicitly wrong: not the filtered review scope (the frontend audit agent's own `changed` variable is pathspec-limited to TypeScript sources, so a finding on a non-TypeScript file the pull request touched would read `0`), and not the incremental audit base (the last cleared ancestor, which on a re-audit covers only the delta since the previous round, while the touched-file waive rule anchors on the whole-PR fork point). A route that does not already hold a fork-point set records `changed=unknown` and derives nothing. When the fork point does not resolve, `changed` is `unknown` and never `0`, because `0` asserts that the work did not touch the file and an unresolvable base asserts nothing.

**The emitting routes:**

| route | instruction surface | `changed` |
|---|---|---|
| audit agent disposition pipeline, local | `.claude/agents/code-audit-frontend.md` | resolved |
| audit agent disposition pipeline, continuous integration | `.github/workflows/code-review-audit.yml` | resolved, by the workflow |
| pre-merge orchestrator cross-remit disposition | `wiki/concepts/PR Merge Workflow.md` | resolved |
| knowledge-audit filing block | `.claude/skills/gaia/references/audit.md` | `unknown` |
| comprehensive-audit filing offer and direct human invocation | this file | `unknown` |

Known limitation: on the routes with no reviewed diff, `branch`, `mode`, and `unit` describe the session that filed the finding, which is not always the work that surfaced it. That is still better than nothing and it is honest, because the fields say what the disposing agent observed. A reader must not treat those rows as review attribution.

**What the record does not answer.** It supports attribution, not causation. It says which work a finding was surfaced by; it does not say the work caused the defect, and for a pre-existing defect found during a visit it usually did not. Overreading it is the failure mode to avoid.

**Waived findings.** A finding recorded as waived rather than filed carries the same line, from the same helper, on its pull-request-body entry beside the dedup key already listed there. That entry is the waived finding's only durable surface: the disposition sidecar is gitignored, janitor-reaped, and dropped on the next digest rotation. The line is an HTML comment, so review-time visibility is unchanged. Note what this does not buy: `changed` does not separate the machinery waive from the touched-file waive, because a pull request fixing gate machinery is normally touching the machinery path it waives, so both arms usually read `changed=1`.

**Ownership.** This file is the contract's sole owner. Every other route references it and restates neither the vocabulary nor the table. `.gaia/scripts/debt-origin-lib.sh` is the implementation of the contract rather than a second statement of it.

## 5. Issue body schema

Build a self-contained issue body with these parts, in order:

- The dedup-key comment line from step 1, present verbatim.
- The provenance line (see "Provenance line" above), present verbatim, on its own line immediately after the dedup-key line and never merged into it.
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
- **Disclosure.** The three grade values are fixed and carry no information about the finding: they do not discriminate a security-class finding from any other, so a difficulty grade leaks nothing about security-sensitivity no matter who applies it or where the issue lands. Machine filing never reaches a public repo for a security-class finding, the agent's security-class divert path intercepts it first.
- **Where the grade comes from.** This file defines the rubric; it does not apply it. The two external grading routes named at the top of this section, the frontend audit agent and `audit.md`, read it and write the label; an edit to the value set or the rubric must reach both. The human-invocation grading applies this section's rubric in place, so it needs no separate propagation.

## 8. Touch the debt-count staleness sentinel

As the last step of this recipe, touch the sentinel so the statusline's debt count recomputes on its next tick:

```bash
debt_root="$(bash .gaia/scripts/main-root-lib.sh)" || debt_root="."
mkdir -p "$debt_root/.gaia/local/debt" && : > "$debt_root/.gaia/local/debt/refresh-requested"
```

Create the parent directory first. On a fresh clone, or in CI, no statusline tick has run yet, so `.gaia/local/debt/` may not exist, a bare `touch` against a missing directory fails silently and leaves the sentinel unset. The write is anchored on the main checkout because the sentinel is shared state, one copy for the clone: `debt/count.json|debt/refresh-requested` is registry scope `shared`, so every tree reads the same physical copy through the resolver. This step is best-effort: never let a failure here block or fail the caller's flow, which is why the fallback is `.` rather than an exit.

## Rollout: mark the pre-provenance cohort

The backlog that predates provenance does not get provenance, and this is a prohibition rather than a low priority. The two kinds of absence sit in the same field: a fail-open `unknown` records what the disposing agent observed and is an honest statement, while a backfilled value records what someone guessed, and nothing downstream can tell the two apart. Seeding the record with plausible attributions produces provenance-shaped noise rather than partial provenance.

What ships instead is a one-time cohort marker, per repository:

1. Create the `debt:pre-provenance` label idempotently, exactly as this recipe already creates its own labels in step 6. Nothing else creates it.
2. Apply it to every open `tech-debt` issue whose body carries no `gaia-debt-origin` line, raising the result limit so the sweep cannot silently stop at a default page size.
3. Re-running is safe and is the recovery path for a run that failed partway. The body test is what makes it so: a plain "label every open issue" sweep would be idempotent in the trivial sense and still wrong, because a re-run days later would stamp issues filed after provenance landed and destroy the very distinction the marker exists to draw.

```bash
gh label create debt:pre-provenance --color ededed 2>/dev/null || true
gh issue list --label tech-debt --state open --limit 1000 --json number,body \
  --jq '.[] | select(((.body // "") | test("<!-- gaia-debt-origin:")) | not) | .number' \
| while read -r n; do
    gh issue edit "$n" --add-label debt:pre-provenance
  done
```

The marker is only accurate when applied at the moment provenance starts writing in a given repository, which is why it is a rollout step rather than follow-up work. GAIA reaches adopter clones through its update flow, so that moment falls on a different date in every clone: this is a per-repository step carried to adopters as an action-required release note with its literal command, not a single action performed once. An adopter that skips it loses only the ability to distinguish its own two absence cases; nothing breaks.

The marker changes no displayed number, additive for the same reason the `difficulty:` namespace is (see the Contract-preserve note below).

Do not add `debt:pre-provenance` to step 6's idempotent label-creation loop: the rollout is a one-time per-repository step, not a per-filing one, and adding it would make that loop's "all eight labels" comment wrong.

## Brake self-check

```bash
gh issue list --label tech-debt --state open --limit 1000 --json number,body \
  --jq '[.[]
         | select((.body // "") | test("<!-- gaia-debt-origin:"))
         | select((.body // "") | test("(^|[[:space:]])mode=drain([[:space:]]|$)"))
         | select((.body // "") | test("(^|[[:space:]])changed=1([[:space:]]|$)"))]
        | map(.number)'
```

Each field is matched independently rather than as one ordered pattern, because the line's field order is canonical for readability only and no reader may depend on it. The `.body // ""` guard matters: an issue with an empty body would otherwise abort the whole query.

This query is a triage aid, not a gate. Legitimate members of the result set exist, a security-class finding that is never waive-eligible among them, so a non-empty result is a prompt to look rather than proof of a bug. It promises no rate: no baseline exists, and producing one is what this query is for.

## Contract-preserve note

The wrapped `gaia-debt-key` format (step 1) and the label spellings (step 6) are not just prose here, they are a contract shared with several deterministic, non-LLM consumers and their tests, none of which read this recipe, they hard-code the format instead. Step 2's dedup **matching basis** is `path=`+`line=` (ignoring `class=`), but that only changes which issue this recipe treats as a match, it does not change the wrapped key format (step 1) or any label spelling (step 6), so none of the consumers below need a change on account of it. Change the key format or any label spelling **only in lockstep** with all of these:

- `.claude/hooks/audit-disposition-check.sh`
- `.gaia/statusline/gaia-statusline.sh`
- `.gaia/scripts/debt-count-refresh.sh`
- `.claude/hooks/debt-session-reconcile.sh`
- `.claude/skills/gaia/references/debt.md`
<!-- gaia:maintainer-only:start -->
- Tests: `.gaia/tests/hooks/debt-sentinel-touch.bats`, `.gaia/tests/hooks/debt-session-reconcile.bats`, `.gaia/scripts/tests/debt-count-refresh.bats`
<!-- gaia:maintainer-only:end -->

The governed set also includes the `debt:in-progress` claim label: `.claude/skills/gaia/references/debt.md` creates and applies it as the `/gaia-debt` in-progress claim, and `.gaia/scripts/debt-count-refresh.sh` consumes it, excluding any issue that carries it from the open count. This recipe never creates or applies `debt:in-progress` itself. The same holds for `debt:spec-pending`: `debt.md` creates and applies it as the `/gaia-debt` design-first handoff park label, and `.gaia/scripts/debt-count-refresh.sh` consumes it, excluding any issue that carries it from the open count too. This recipe never creates or applies `debt:spec-pending` itself.

The `difficulty:` namespace (step 7) is not part of this lockstep contract. No consumer gates on it, verified against all five named above: `.gaia/scripts/debt-count-refresh.sh` filters by excluding two specific label names (`debt:in-progress` and `debt:spec-pending`) and ignores anything else, `.claude/hooks/audit-disposition-check.sh` matches the dedup key in the issue body and parses no labels, `.gaia/statusline/gaia-statusline.sh` parses no labels, `.claude/hooks/debt-session-reconcile.sh` only reconciles the count downward, and `.claude/skills/gaia/references/debt.md` reads it only to annotate `list` output (`[difficulty: <grade>]`), never to gate a path. Adding this namespace therefore requires zero gating changes to any of the five, which is exactly why the grade could be a label at all.

Provenance (the `gaia-debt-origin` line, see "Provenance line" above) is a separate line and joins none of that lockstep set. Adding, removing, or renaming a provenance field requires no change to any deterministic consumer of the dedup key. No consumer reads the issue body positionally, so a second HTML comment beside the dedup key is safe: `.claude/hooks/lib/audit-dispositions.sh` reconstructs the wrapped dedup key and tests it as a substring, and `.claude/skills/gaia/references/debt.md` captures on the literal `<!-- gaia-debt-key: ` prefix; neither reads past it. The keyless `<path>:<line>` fallback cannot false-match a provenance field either, since no provenance field yields a colon followed by digits. The `debt:pre-provenance` label is additive for exactly the reason the paragraph above gives for `difficulty:`. The helper deliberately inverts `audit-key-lib.sh`'s fail-closed rule, printing `unknown` in a slot it cannot resolve rather than refusing to print a partial line; that inversion is deliberate, not a bug to "fix" into agreement.

If you're only filing an issue, none of the above needs touching, this note exists so a future edit to the key/label shapes doesn't silently break them.
