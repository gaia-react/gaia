---
name: file-tech-debt
description: Files a new tech-debt GitHub issue for an out-of-scope code-review finding. Builds the dedup key, checks for an existing open or declined-closed match, and only if none exists, creates the issue with the right labels and touches the debt-count staleness sentinel. Trigger on natural-language asks like "file a tech-debt issue", "record this as tech-debt", "open a tech-debt issue for this out-of-scope finding", or "file this finding as debt". Do NOT trigger on draining, fixing, listing, or prioritizing existing debt (that's `/gaia-debt`), nor on general "clean up the code" or "fix this bug" asks that aren't about filing a new tracked issue.
---

# File a tech-debt issue

This skill is the single source of truth for turning one out-of-scope finding (a real problem spotted while reviewing something else, and therefore not fixed in place) into a durable, deduplicated GitHub issue. It covers building the key, checking for a prior match, filing when there is none, and nudging the debt-count display to refresh. It does not decide *which* findings are out-of-scope, does not fix anything, and takes the caller's word on whether a finding is security-sensitive (section 0), it only files.

**Callers own their own bookkeeping around this recipe.** Some callers record their own disposition-ledger entry and gate their own downstream state on it after filing succeeds; others file and stop. That bookkeeping is caller-specific and lives in the caller, not here. Follow the steps below exactly as written; do not invent a bookkeeping record, a completion flag, or a run-tracking step of your own on top of them, that would duplicate (or fight with) whatever the caller already does.

Contents: 0. Run the filing script; 1. Build the dedup key; 2. Check for an existing match (dedup); 3. Idempotency: skip if a match exists; 4. Otherwise, file the issue; 5. Issue body schema; 6. Labels; 7. Difficulty grade; 8. Touch the debt-count staleness sentinel.

## 0. Run the filing script

Every caller files through the script and never runs `gh issue create` itself:

```bash
bash .gaia/scripts/file-tech-debt.sh file --finding <finding.json> --outcome-file <outcome.jsonl> [--repo <owner/name>] [--disposition file|divert]
```

Execute it; do not read it for the mechanics. Its header owns the finding JSON, the outcome line, the stdout words and the exit codes. Steps 1 to 8 below are the reference the script implements, for a caller that needs to understand a filing or a label rather than reproduce one.

The caller owns one judgment: the finding's boolean `security` flag, true when the content reads as an exploitable weakness (missing authentication or authorization, injection, secret exposure, SSRF, path traversal, unsafe deserialization, crypto misuse). Everything else is mechanical and fails safe toward diverting:

- **Security first.** A security-class finding (flag true, absent or non-boolean; severity `error` or `Critical`; secret-shaped text; an absent or malformed `finding_class`) never reaches a public or internal issue. It files only when repository visibility reads exactly `PRIVATE` before the probe and again immediately before the first write. Any other answer, including a failed read, writes a redacted record under `.gaia/local/audit/security/` and reports a count and that path, nothing more. `holistic/unclassified` is a valid class and never a trigger.
- **Backend probe.** `absent` (no repository, unauthenticated, Issues disabled, no write permission) files nothing and records outcome `absent`. `transient` (timeout, rate limit, 5xx) files nothing, records outcome `transient`, and keeps the finding in a retry directory beside the outcome file for the next round. `present` goes on to dedup and filing.
- **Verify after filing.** The script re-queries open issues for the wrapped key and records `failed` when the new issue is not found.

Honest limits: an issue filed while the repository is PRIVATE becomes public if its visibility later flips, and a caller that sets `security` to false on a real weakness defeats the flag, which is why the severity and content triggers sit beside it.

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

Run the dedup script with the finding's own path and line (the `path=` and `line=` from the key built in step 1):

```bash
bash .gaia/scripts/debt-dedup.sh --path <repo-relative-path> --line <line>
```

Its exit code is the answer:

- **0**: no match. Continue to step 4.
- **1**: a match. Read `number`, `state`, `declined`, and `inner_key` from its one JSON line and hand them back to the caller. An open match's `inner_key` is the key the caller records, never a freshly built one; it is `null` when `source` is `keyless` (a hand-filed issue with no parsed key), so the caller records the number alone; a declined match gets no bookkeeping entry.
- **2 or 3**: the check could not run (usage error, or an input it could not read or that hit its result limit). Report its stderr line, do not file, and do not treat it as a pass.

The script's header owns the matching rules: path plus line with `class=` ignored, declined-closed detection, the keyless fallback for hand-filed issues, and the accepted collapse of distinct findings on one `path:line`. This recipe records nothing itself; callers own their bookkeeping (see above).

## 3. Idempotency: skip if a match exists

If step 2 found a matching open issue, or a declined-closed one, stop, do not file. The finding already has a disposition; re-filing would create a duplicate. For an open match, the caller records the matched issue's number and its existing inner key (both returned by step 2) in its own bookkeeping, not a freshly-built key that may carry a different `class=`. For a declined-closed match, the caller adds no bookkeeping entry, exactly as an unmatched-skip is today.

## 4. Otherwise, file the issue

If no match exists (the script performs this step; the commands below are its reference, not a second route to `gh issue create`):

1. Create the labels idempotently first (step 6), a pre-existing label is not an error.
2. Build the full issue body (step 5) in a gitignored body-file, not inline. Give the file a per-run-unique name under `.gaia/local/audit/` (for example `.gaia/local/audit/issue-body-<something-unique>.md`). The name must be unique because the create-and-cleanup sub-step below deletes it: two runs sharing one fixed name (CI plus a local run, the same pair sub-step 3 below guards against) would race, and one run's cleanup would delete the other's in-flight body out from under it.
3. Re-run the step 2 script call immediately before creating, with the same exit mapping (a match or an exit of 2 or 3 means do not create). This shrinks the race window where a concurrent run (CI plus a local run, for instance) files the same finding twice, and a reclassification that lands between your first check and now still resolves to the already-open issue. Prefer a search-or-update path over a blind create when your environment supports it.
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

**Never** pass `--body <argv>` here. An inline `--body` string puts the finding (and anything sensitive quoted inside it) on the command line, where verbose tooling echoes it and process listings show it. Always route the body through `--body-file` (or stdin); the body must never reach argv.

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

Two obligations ride with it, and both exist because GAIA's own backlog has already run the experiment of a free "I do not know" value and lost it: the dedup key's `class=` field grew a `holistic/unclassified` fallback that absorbed 91.4% of that axis at its worst. An uncertainty grade nothing rations stops carrying information.

- **The research block**, required in the body and forbidden without the grade. Step 5 states it.
- **The queue is capped**, at whatever `INVESTIGATE_CAP` in `.gaia/scripts/check-debt-issue-metadata.sh` holds. Over the cap a filing is refused. Step 4 runs the check and states the two ways out.

`/gaia-debt` never fixes an investigate-graded issue: it is excluded from fix candidacy and resolved by answering its question and re-grading it. `.claude/skills/gaia/references/debt.md` owns that behavior.
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

See step 7 for the difficulty label's three permitted values and the rubric for choosing between them.

A finding that gets deliberately declined (closed without fixing) carries GitHub's `wontfix` label, that's what step 2 checks for to avoid re-filing it.

The registry is reconciled before the first filing in a run, then anything still missing is created directly. This is the idiom `.claude/skills/gaia/references/debt.md` already uses: key the fallback on the labels the repository actually has, never on whether the sync announced a problem. A sync that cannot run at all announces nothing, so a guard reading its output treats the worst case as the healthy one.

```bash
.gaia/cli/gaia labels sync 2>/dev/null || true
present="$(gh label list --limit 200 --json name --jq '.[].name' 2>/dev/null)"
for label in tech-debt severity:critical severity:important severity:suggestion severity:investigate \
             footprint:narrow footprint:wide footprint:spec \
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

A filing grades, carrying exactly one `difficulty:` label, when the cited code is read at filing time (a reviewer or an audit agent surfaces the defect and you open the code to file it, as with a review follow-up), so the grade is the rubric below applied to real code rather than guessed from a description. Every filed issue already carries a concrete `file:line` and failure mode (step 5 makes both mandatory), so the discriminator is not those but whether the code behind them was read here. A filing that has not read the cited code omits the label rather than guess one. Two routes always read the code and so always grade: the audit loop unit's non-security disposition (`.gaia/scripts/audit-dispositions-check.sh` gates it, `.gaia/scripts/file-tech-debt.sh` files) and the tech-debt filing block in `.claude/skills/gaia/references/audit.md`. This section is the single source of truth for the permitted values and for choosing between them; a grading filing never grades against a private reading of a grade's name.

Grade the difficulty of **the fix**, never the model, agent, or tooling that would perform it.

| Grade | The fix carries |
|---|---|
| `difficulty:easy` | no design decision left to make: the issue text and the cited code together determine the change, and two competent engineers would write the same fix. |
| `difficulty:medium` | a design decision the surrounding code settles: more than one implementation is reasonable in the abstract, and reading the adjacent code, its conventions, and its call sites picks one. |
| `difficulty:hard` | a design decision the surrounding code does not settle: two competent engineers who have both read all the cited code could still reasonably choose differently, or the fix must first settle what the correct behavior is. |

Read the three rows top to bottom and take the first whose properties all hold. The rows are exclusive by construction: they ask how many design decisions the fix carries and whether the code answers them, and exactly one answer holds for any one fix.

Difficulty adds the dimension the footprint class does not capture. `footprint:` grades how far the change reaches; difficulty grades how much design the fix needs. The two often move together, and they are not meant to: a one-file fix whose correct behavior is genuinely in question is `footprint:narrow` and `difficulty:hard`, and a mechanical rename across twenty files is `footprint:wide` and `difficulty:easy`.

Worked boundary, easy versus medium. A swallowed error the issue text says to rethrow is `difficulty:easy`: the issue determines the change. The same swallowed error, where the issue says only that it must not be swallowed and leaves the choice between rethrowing, logging and continuing, and surfacing to the caller, is `difficulty:medium`: the choice is real, and the sibling call sites settle it.

- **When a filing omits the grade.** A filing omits the label whenever the cited code was not read at filing time, rather than guessing a grade from a description: a direct human invocation that files from a relayed summary or hand-off without reopening the cited code has no rubric-applied grade to give; and the orchestrator's cross-remit disposition has not read the finding against this rubric. A human invocation that *does* read the cited code as it files grades instead (above); it is not forced ungraded merely for arriving by the human path. An issue carrying no grade is normal: it orders, clusters, and drains exactly as a graded one does; in a named batch's budget it scores as medium. That guarantee is what keeps a mixed adopter state safe, since every file this feature touches resolves independently on update: a new copy of this recipe running against an old `debt.md` files grades that nothing yet reads, and a new `debt.md` running against old agents reads a backlog where nothing is graded. Both states are reachable and both benign.
- **Argv constraint.** The value written to the `difficulty:<grade>` label must be one of the three literals above, byte-for-byte, before it reaches any `gh` argv. Argv exposure is minimal here, the token is fixed-vocabulary, which is why the `--body-file` mandate in step 4 is not implicated, but a model-produced string interpolated into a command whose argv can surface in a public log earns the one-clause constraint anyway.
- **Disclosure.** The three grade values are fixed and carry no information about the finding: they do not discriminate a security-class finding from any other, so a difficulty grade leaks nothing about security-sensitivity no matter who applies it or where the issue lands. Machine filing never reaches a public repo for a security-class finding, the script's security screen intercepts it first.
- **Where the grade comes from.** This file defines the rubric; it does not apply it. The two external grading routes named at the top of this section, the audit loop unit and `audit.md`, read it and write the label; an edit to the value set or the rubric must reach both. The human-invocation grading applies this section's rubric in place, so it needs no separate propagation.

## 8. Touch the debt-count staleness sentinel

As the last step of this recipe, touch the sentinel so the statusline's debt count recomputes on its next tick:

```bash
debt_root="$(bash .gaia/scripts/main-root-lib.sh)" || debt_root="."
mkdir -p "$debt_root/.gaia/local/debt" && : > "$debt_root/.gaia/local/debt/refresh-requested"
```

Create the parent directory first. On a fresh clone, or in CI, no statusline tick has run yet, so `.gaia/local/debt/` may not exist, a bare `touch` against a missing directory fails silently and leaves the sentinel unset. The write is anchored on the main checkout because the sentinel is shared state, one copy for the clone: `debt/count.json|debt/refresh-requested` is registry scope `shared`, so every tree reads the same physical copy through the resolver. This step is best-effort: never let a failure here block or fail the caller's flow, which is why the fallback is `.` rather than an exit.

