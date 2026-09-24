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
- `<path>` is a repo-relative POSIX path (forward slashes, never an absolute machine path). It may contain a space; write it verbatim, it terminates at the comment's own closer.
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
2. Build the full issue body (step 5) in a gitignored body-file, not inline. Give the file a per-run-unique name under `.gaia/local/audit/` (for example `.gaia/local/audit/issue-body-<something-unique>.md`). The name must be unique because the create-and-cleanup sub-step below deletes it: two runs sharing one fixed name (CI plus a local run, the same pair sub-step 3 below guards against) would race, and one run's cleanup would delete the other's in-flight body out from under it.
3. Re-check the dedup query from step 2 immediately before creating, this shrinks the race window where a concurrent run (CI plus a local run, for instance) files the same finding twice. It is the same path+line matching basis as step 2, so a reclassification that lands between your first check and now still resolves to the already-open issue. Prefer a search-or-update path over a blind create when your environment supports it.
4. **Check the metadata before creating, and do not create on a finding.** Pass the exact label set the create call is about to carry, comma-separated, together with the body file built in sub-step 2:

   ```bash
   # Graded filing, when a grade is in hand:
   bash .gaia/scripts/check-debt-issue-metadata.sh --pre-file \
     --labels "tech-debt,severity:<tier>,footprint:<class>,difficulty:<grade>" \
     --body-file "$body_file"

   # Ungraded filing, when no grade is available:
   bash .gaia/scripts/check-debt-issue-metadata.sh --pre-file \
     --labels "tech-debt,severity:<tier>,footprint:<class>" \
     --body-file "$body_file"
   ```

<!-- gaia:maintainer-only:start -->
   On the GAIA maintainer repository both `--labels` strings also carry
   `audience:<side>`; see the note under sub-step 5. Omitting it there fails this
   very check, which gates on the `audience:` count.

<!-- gaia:maintainer-only:end -->
   Two forms, matching sub-step 5's two `gh issue create` forms exactly. The ungraded form **drops the `difficulty:` entry** rather than passing it empty or with the placeholder still in it, for the same reason the create call does. The check rejects both of those, correctly: an unfilled placeholder is the shape an omitted grade most often arrives in, and letting it through would file the literal text as a label.

   Exit `0` is clean, `1` names one finding per line, `2` is a usage or environment error. On `1`, fix the label set or the body and re-run; do not file. On `2`, the check itself could not run: report that and do not treat it as a pass.

   Then run the investigate-cap check, with the same label set and no body file:

   ```bash
   bash .gaia/scripts/check-debt-issue-metadata.sh --investigate-cap \
     --labels "<the same comma-separated set passed above>"
   ```

   Run it on **every** filing, not only an investigate-graded one: it exits `0` without reading the network unless the set carries `severity:investigate`, so the ordinary filing pays nothing and no filer has to remember which case needs it. When the set does carry the grade, exit `1` means the open investigate queue is at its cap and this filing is refused. Take one of the two ways out rather than filing anyway: resolve one of the issues it names (answer its question, re-grade it, remove its research block), or grade this finding yourself from the code. Exit `2` means `gh` could not answer; that is advisory, so report it and file anyway. Refusing every filing while the tracker is unreachable loses findings, and a bound that leaks by one on a network failure is still a bound.

   **Why this blocks rather than advises.** Every rule the check enforces was already written in the prose above before the check existed, and every one of them was violated anyway. The label set is the one part of a filing that no later step re-reads, so a mistake there is silent until a drainer trips over it weeks later, by which time the code that would have justified the right grade has moved. The check reads no network and needs no `gh`, so this gate costs one local call and cannot fail for a reason outside the filing.

   **What it does not check.** It verifies the label vocabulary, the counts, and the key's shape. It cannot verify that the grade you chose is the grade the rubric gives: whether a fix carries a design decision is a judgment about code, and a passing check is not evidence that step 7 was applied honestly. The mechanical half is enforced here; the rubric half stays yours.

5. Create the issue with the form that matches whether a grade is available, then delete the body file **in a second, separate Bash tool call**. A filing that has a difficulty grade in hand (step 7) uses the graded form; a filing with no grade drops the `--label difficulty:<grade>` flag entirely rather than passing it empty or with a placeholder:

```bash
body_file=.gaia/local/audit/issue-body-<something-unique>.md

# Graded filing, when a grade is in hand:
gh issue create --label tech-debt --label severity:<tier> --label footprint:<class> --label difficulty:<grade> --body-file "$body_file"

# Ungraded filing, when no grade is available:
gh issue create --label tech-debt --label severity:<tier> --label footprint:<class> --body-file "$body_file"
```

The `footprint:<class>` flag is on both forms because it is not optional the way the grade is: a filing that has not read the cited code still knows how far its own suggested fix reaches.
<!-- gaia:maintainer-only:start -->

On the GAIA maintainer repository every filing carries one more label, `audience:<side>` (step 6). It rides in both `--labels` strings above and on both `gh issue create` forms as `--label audience:<side>`, immediately after `severity:<tier>`. Like the footprint class it is not optional the way the grade is: a filing that has not read the cited code still knows which side of the adopter/maintainer split its cited path sits on.
<!-- gaia:maintainer-only:end -->

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
- **The research block, on a `severity:investigate` filing only** (step 6). Three lines, byte-for-byte in this shape, appearing exactly once, anywhere in the body:

  ```
  <!-- gaia-investigate: v1 -->
  **Question:** <what specifically must be determined>
  **Settled by:** <what evidence, test, or measurement would answer it>
  ```

  Both lines carry real content. "Needs more thought" is not a question and "investigation" is not evidence; the question names the fact whose value decides the grade, and `**Settled by:**` names the thing that would establish it. This is what the grade costs, and the cost is the point: the value is only worth having if saying "I do not know" requires saying what is not known. A filing that cannot fill these two lines was not uncertain about the severity, it just did not look.

  On a filing graded anything else the block is **forbidden**, not merely unnecessary. Re-grading an issue removes the block in the same edit that replaces the label, because a block left behind asserts an open question that has since been answered, and a reader believes it.

The body carries no classification fields of its own. Every classification axis steps 6 and 7 define rides as a label, so a body line restating one of them is a second representation of a value the labels already hold, and the two drift.

## 6. Labels

Every out-of-scope non-security issue this recipe files carries `tech-debt` plus **exactly one** severity label, plus **exactly one** footprint label; a filing that carries a difficulty grade (see step 7) carries exactly one difficulty label as well. Map the finding's report tier to the severity label like this:

| Report tier | Label |
|---|---|
| Critical | `severity:critical` |
| Important | `severity:important` |
| Suggestion | `severity:suggestion` |

`severity:investigate` is the fourth value and it does not map from a report tier, because it is not a tier. It records that the severity is **not yet determined** and that research is needed before it can be. Choose it when the finding's consequence turns on a fact about the code that the filing has not established: whether a branch is reachable, whether a guard ever fails open in practice, whether a caller depends on the behavior. Do not choose it when the answer is merely inconvenient to look up, and never choose it as a way of not choosing. The other three grades are judgments; this one is the admission that no judgment was made, and it is checked accordingly.

Two obligations ride with it, and both exist because this repository has already run the experiment of a free "I do not know" value and lost it: the dedup key's `class=` field grew a `holistic/unclassified` fallback that absorbed 91.4% of that axis at its worst. An uncertainty grade nothing rations stops carrying information.

- **The research block**, required in the body and forbidden without the grade. Step 5 states it.
- **The queue is capped**, at whatever `INVESTIGATE_CAP` in `.gaia/scripts/check-debt-issue-metadata.sh` holds. Over the cap a filing is refused. Step 4 runs the check and states the two ways out.

`/gaia-debt` never fixes an investigate-graded issue: it is excluded from fix candidacy, shown in `list` annotated `[investigate]`, and resolved by answering its question and re-grading it. `.claude/skills/gaia/references/debt.md` owns that behavior.
<!-- gaia:maintainer-only:start -->

**Maintainer repository only.** Every filing on the GAIA maintainer repository carries **exactly one** `audience:` label as well. It records **who can observe the defect**, which is a different question from how bad it is and from how hard it is to fix:

| Label | The defect is |
|---|---|
| `audience:adopter` | observable by an adopter: something GAIA ships misbehaves, misleads, or blocks them. |
| `audience:maintainer` | observable only in the GAIA maintainer repository: continuous integration, release-excluded tests, maintainer-only tooling. |

Resolve it from the cited path first: a release-excluded path is `audience:maintainer`, a shipped path is `audience:adopter`. Then override that default when the failure mode contradicts it, because the two do come apart. A defect in a shipped file that is only reachable through a maintainer-only runner is `audience:maintainer` even though the file ships, and a maintainer-only script whose wrong output is copied into an adopter-facing artifact is `audience:adopter` even though the script does not. The path is the prior, the failure mode is the verdict.

Unlike severity, this label has no fallback: an unlabeled issue is not sorted into a default band, it is simply unfiled against the split. Exactly one is required on every filing.
<!-- gaia:maintainer-only:end -->

The footprint label records **how far the fix reaches**. `narrow` and `wide` drain the same way, inline through one fix pull request; only `spec` routes differently:

| Label | The fix is |
|---|---|
| `footprint:narrow` | a single logical unit confined to one file, with no public-contract change and no cross-module ripple. |
| `footprint:wide` | anything larger or more structural. |
| `footprint:spec` | design-first: it must begin with a design SPEC, a new subsystem, a schema or contract decision, or a cross-cutting redesign. `/gaia-debt` resolves a spec-class issue by printing a `/gaia-spec` handoff and stopping, not by opening a fix PR. |

The three share one color family, a violet ramp that deepens with reach. `wiki/concepts/GitHub Labels.md` documents the family, and `gaia labels sync` applies it.

The class is advisory: whatever later drains the issue re-derives it from the cited code and may override it, in either direction, including the `spec` value. That is precisely why it rides as a label rather than as body prose. Re-grading is `gh issue edit <n> --remove-label footprint:spec --add-label footprint:wide`, which leaves the transition in the issue's timeline, where a body edit would have destroyed the prior value and a correcting comment would have left the body still asserting the overruled one.

Being advisory also sets how strictly it is checked. `.gaia/scripts/check-debt-issue-metadata.sh` validates at most one footprint label and rejects a value outside the three above, but absence is not a finding: a human-filed issue that carries no class is legal, and the drain treats it as unclassified and grades it from code like any other.

The `fold:` label records that **the repair's cost is dominated by a fixed cost the finding alone does not justify**, so draining it on its own pays that cost for a change too small to warrant it.

| Label | Apply it when |
|---|---|
| `fold:required` | the repair should ride a change that already pays its fixed cost, and nothing about the finding on its own justifies paying that cost. |

That one condition is the whole application rule. The instance it was written for is a small prose edit to a path the audit gate treats as global (`AUDIT_GLOBAL_RULES_PATHS` in `.claude/hooks/lib/audit-rules-changed.sh`), which discards every Code Audit Team member's incremental review anchor repo-wide: the repair is one sentence and the reset is not. The general form is any repair whose cost sits in the change around it rather than in the change itself.

**Display-only, gating nothing.** `.claude/skills/gaia/references/debt.md` reads it in three places, `list`'s annotation, `why`'s report, and the description of that issue's option in the recommendation prompt, so the intent reaches the human making the pick. It never filters the candidate pool, never changes the ordering, and never changes the clustering pass. Which carrier a folded repair should ride is a property of the *other* change's fix, so no pure function over this issue's fields can compute it, and the ordering and clustering are deliberately model-free. An annotation on the option is enough leverage, because with two or more candidates the drain always stops for a human-approved pick anyway.

Optional, and absence is the ordinary case: most repairs carry their own cost. Exactly one is permitted when present, and `.gaia/scripts/check-debt-issue-metadata.sh` validates the value the way it validates a difficulty grade.

See step 7 for the difficulty label's three permitted values and the rubric for choosing between them.

A finding that gets deliberately declined (closed without fixing) carries GitHub's `wontfix` label, that's what step 2 checks for to avoid re-filing it.

The registry is reconciled before the first filing in a run, then anything still missing is created directly. This is the idiom `.claude/skills/gaia/references/debt.md` already uses: key the fallback on the labels the repository actually has, never on whether the sync announced a problem. A sync that cannot run at all announces nothing, so a guard reading its output treats the worst case as the healthy one.

```bash
.gaia/cli/gaia labels sync 2>/dev/null || true
present="$(gh label list --limit 200 --json name --jq '.[].name' 2>/dev/null)"
for label in tech-debt severity:critical severity:important severity:suggestion severity:investigate \
             footprint:narrow footprint:wide footprint:spec \
             fold:required \
             difficulty:easy difficulty:medium difficulty:hard wontfix; do
  printf '%s\n' "$present" | grep -qx "$label" || gh label create "$label" 2>/dev/null || true
done
```

The fallback reaches every case the sync leaves a label uncreated: a CLI predating the `labels` command, a token without label-write scope, and a registry entry this repository's audience or feature set does not reach. It is advisory, not a guarantee: a token that cannot write labels cannot create one here either, so the filing continues without it rather than failing. A label that already exists is not an error.
<!-- gaia:maintainer-only:start -->

On the GAIA maintainer repository, the registry's maintainer set is reconciled as well:

```bash
.gaia/cli/gaia labels sync --audience maintainer 2>/dev/null || true
present="$(gh label list --limit 200 --json name --jq '.[].name' 2>/dev/null)"
for label in audience:adopter audience:maintainer; do
  printf '%s\n' "$present" | grep -qx "$label" || gh label create "$label" 2>/dev/null || true
done
```
<!-- gaia:maintainer-only:end -->

## 7. Difficulty grade

A filing grades, carrying exactly one `difficulty:` label, when the cited code is read at filing time (a reviewer or an audit agent surfaces the defect and you open the code to file it, as with a review follow-up), so the grade is the rubric below applied to real code rather than guessed from a description. Every filed issue already carries a concrete `file:line` and failure mode (step 5 makes both mandatory), so the discriminator is not those but whether the code behind them was read here. A filing that has not read the cited code omits the label rather than guess one. Two routes always read the code and so always grade: `.claude/agents/code-audit-frontend.md`'s non-security disposition pipeline and the tech-debt filing block in `.claude/skills/gaia/references/audit.md`. This section is the single source of truth for the permitted values and for choosing between them; a grading filing never grades against a private reading of a grade's name.

Grade the difficulty of **the fix**, never the model, agent, or tooling that would perform it.

| Grade | The fix carries |
|---|---|
| `difficulty:easy` | no design decision left to make: the issue text and the cited code together determine the change, and two competent engineers would write the same fix. |
| `difficulty:medium` | a design decision the surrounding code settles: more than one implementation is reasonable in the abstract, and reading the adjacent code, its conventions, and its call sites picks one. |
| `difficulty:hard` | a design decision the surrounding code does not settle: two competent engineers who have both read all the cited code could still reasonably choose differently, or the fix must first settle what the correct behavior is. |

Read the three rows top to bottom and take the first whose properties all hold. The rows are exclusive by construction: they ask how many design decisions the fix carries and whether the code answers them, and exactly one answer holds for any one fix.

Difficulty adds the dimension the footprint class does not capture. `footprint:` grades how far the change reaches; difficulty grades how much design the fix needs. The two often move together, and they are not meant to: a one-file fix whose correct behavior is genuinely in question is `footprint:narrow` and `difficulty:hard`, and a mechanical rename across twenty files is `footprint:wide` and `difficulty:easy`.

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

