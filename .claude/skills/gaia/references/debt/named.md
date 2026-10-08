# /gaia-debt: named numbers

The named-number procedures of `/gaia-debt`. `debt.md` routes here on every `numbers` result of its `## Argument parsing`, after its backlog read; every step after the pick returns to `debt.md`.

## Validate named numbers

Runs for every `numbers` result of `## Argument parsing` in `debt.md`, one number or several, after the backlog read in `debt.md` and before anything else the named flow does. Validation of every named number precedes the security pre-filter, the spec pre-filter, the branch-name dry-run, and the score in `## Fix a named set (two or more numbers)` below, and precedes the cluster offer in `## Fix a specific issue (direct-number path)` below. So a run naming a closed number alongside a spec-class or security-class member prints only the validation reasons.

Look each number up in the ordered backlog already fetched. A number present there is open and `tech-debt`-labeled by construction, so only the label rows of the table below can apply to it, read from its emitted `labels`. For a number absent from the backlog, make exactly one targeted call:

```bash
gh issue view <n> --json state,labels,url
```

`gh issue view` resolves a pull-request number too: it exits 0 with a state of `OPEN`, `CLOSED`, or `MERGED` and a `url` containing `/pull/`. No field flags a pull request; `url` is the discriminator. A number that is neither an issue nor a pull request exits non-zero with stderr containing `Could not resolve to an issue or pull request`.

Each ineligible number gets exactly one line, `<N>` being the number as parsed. The first matching row wins, read top to bottom:

| condition | line printed |
|---|---|
| the call exits non-zero and its stderr contains `Could not resolve to an issue or pull request`, or it exits 0 and its `url` contains `/pull/` (a pull request, whatever its state, `MERGED` included) | `#<N> is not an issue in this repository` |
| the call exits non-zero for any other reason (network, auth, rate limit) | `#<N> could not be read: <gh error, one line>` |
| state `CLOSED` | `#<N> is already closed` |
| open, no `tech-debt` label | `#<N> doesn't carry the tech-debt label` |
| carries `in-progress` | `#<N> is already being fixed by another session` |
| carries `debt:spec-pending` | `#<N> is parked pending a SPEC handoff` |
| carries `debt:spec-active` | `#<N> is parked with a SPEC underway or holding it open` |
| carries `severity:investigate` | `#<N> is graded severity:investigate: answer its question and re-grade it before fixing it` |

Print the line of every ineligible number, then stop: any ineligible number ends the run with nothing claimed, no branch, no prompt, and no fall-through to the top of the backlog or to any other issue. (Run ends here; see `## Cost record (run end)` in `debt.md`.) Only when every named number is eligible does the run continue: one number to `## Fix a specific issue (direct-number path)`, two or more to `## Fix a named set (two or more numbers)`.

## Fix a specific issue (direct-number path)

Runs only when Argument parsing in `debt.md` resolved exactly one issue number
(`numbers <N>`), from a bare `<issue-number>` or `#<issue-number>`.
It runs after the Backend probe, the
Read-and-order-the-backlog passes (reconcile, ordering, and the backlog pass), and
`## Validate named numbers` above, and it replaces the no-argument offer for this invocation, except on the one operator-chosen
fall-through noted inline (option 3 of the cluster offer).

**Validate the target.** `## Validate named numbers` above decides whether
`#<N>` is drainable; its table owns the reasons and their precedence, and this
section restates neither.

**Ineligible** (any row of that table matches) → print that row's line and
stop. The run ends with nothing claimed, no branch, and no prompt; it never
offers or drains a different issue in place of the one named. (Run ends here;
see `## Cost record (run end)` in `debt.md`.)

**Eligible** (open, `tech-debt`-labeled, not in-progress, not parked, not
investigate-graded) →
resolve which cluster, if any, anchors it, reusing the backlog pass's `clusters`
and the offer-time security and spec reads `debt.md` defines in `### Offer-time reads` (one visibility read, never a second prompt):

- **Heads a public-batch-eligible cluster of 2 or more** → one `AskUserQuestion`
  prompt (header `Debt item`, single-select), the same shape as the
  no-argument batch offer, anchored on the passed issue:
  1. `Batch #<N> #<B> #<C> (Recommended)`: shared signal, member count,
     severity span, "one branch, one PR, all close on merge."
  2. `#<N> only`: fix just the passed issue, one at a time.
  3. `Next available highest-priority item(s) instead`: picking this falls
     through to the no-argument offer, over the full backlog, exactly as if
     no argument had been passed. Read
     `.claude/skills/gaia/references/debt/recommend.md` now and follow its
     `## Recommend and present`.
  - The built-in **Other** entry still lets the human type any open
    `tech-debt` issue number to fix that one alone, handled as
    `### Offer-time reads` in `debt.md` states.
- **Singleton (no cluster), security-class on a non-PRIVATE repo, or
  spec-class (any repo)** → no prompt: the run claims only `#<N>` and
  proceeds straight to fixing it alone, the same nothing-to-decide rule
  the no-argument offer applies to a lone remaining candidate. A spec-class `#<N>` (emitted `footprint`
  equal to `"spec"`) is never anchored or batched, mirroring the
  security-class singleton rule. The Fix-time security screen in `debt.md` still
  screens and, if needed, diverts a security-class `#<N>` exactly as it would
  for any other selected issue, and it still proceeds to "## Claim the fix
  unit" so the Fix-time spec screen catches a spec-class `#<N>` and hands it
  off.

Whatever this section resolves to, continue at "## Claim the fix unit" in
`debt.md`, the same way the no-argument offer does. `#<N>` is a named
selection there: losing `#<N>` at the claim-time re-read (a peer session
claimed it, or it was parked on a SPEC, after validation) stops the run with
no re-present and no substitute issue, as `## Claim the fix unit` step 1
states. A cluster sibling that option 1 added and that is lost at the same
re-read follows the existing batch rule instead: it is dropped and the
surviving members proceed.

## Fix a named set (two or more numbers)

Runs only when `## Argument parsing` in `debt.md` resolved two or more issue numbers (`numbers <N1> <N2> ...`): a batch the operator chose. It replaces the no-argument offer and its clustering for this invocation; the named set is the batch, and no issue the operator did not name joins it. `## Validate named numbers` above has already run on every named number, and this section runs only when nothing failed validation. Its steps run in this order, and a step that stops the run stops it before every later step:

1. **Security pre-filter.** Read `gh repo view --json visibility` once. Anything but a confirmed `PRIVATE` (`PUBLIC`, `INTERNAL`, or a failed read) is non-private.
   - On a **confirmed-PRIVATE** repo nothing is filtered: a security-class member passes and batches normally.
   - On a non-private repo, classify each named member with the fail-safe content classification `## Fix-time security screen` in `debt.md` applies, read from the emitted `body`. A **benign member** passes. For each security-class member print exactly this line, and nothing else about it:

     `#<P> can't join a batch on a non-private repo; drain it alone.`

     Then stop when any member was rejected: no claim, no force, no hand-off, even when a spec-class member is also named. (Run ends here; see `## Cost record (run end)` in `debt.md`.)

   **No disclosure.** The rule covers the run's printed messages: the text relayed or written to the operator, its prompts, and its cost lines. Local tool output, such as the backlog read's JSON, is not a printed message. No printed message names a security-class member's title, body, or path, which is why no step before this one prints a named member's title, and the staleness probe's annotation is never printed for a named set's security-class member.
2. **Spec pre-filter.** A named member whose emitted `footprint` is `spec` needs a SPEC and cannot be batched. Print that for each such member (`#<S> needs a SPEC and cannot be batched`), then ask one `AskUserQuestion` (header `Debt batch`, single-select) with exactly two options:
   - `Hand off #<S> [#<S2> ...] to /gaia-spec`
   - `Cancel`

   `Cancel`, anything typed into the built-in Other, or a declined or dismissed prompt prints `Cancelled; nothing was claimed. Re-run /gaia-debt <numbers> to choose again.` and ends the run with nothing claimed. (Run ends here; see `## Cost record (run end)` in `debt.md`.)

   `Hand off` runs the spec member(s) alone as one selection: they go through `## Claim the fix unit` and the security, staleness, and spec screens in `debt.md`, and no other named member gains `in-progress` in that run. The outcomes:
   - A confirmed spec-class member is parked with `debt:spec-pending` and its `/gaia-spec` handoff block is printed exactly as `.claude/skills/gaia/references/debt/spec-handoff.md` prints it, which the spec screen's Read line routes each confirmed member to, one block per confirmed member.
   - One downgraded member (the spec screen found it needs no SPEC) drains alone exactly as `/gaia-debt <S>` would.
   - With two or more downgraded members, the first downgraded member in backlog order drains alone exactly as `/gaia-debt <S>` would; every other downgraded member's claim is released (`gh issue edit <n> --remove-label in-progress`), and one line names them: `Released #<S2> [#<S3> ...]: the spec screen found no SPEC needed, and a hand-off drains one downgraded issue per run. Re-run /gaia-debt <S2> [<S3> ...] to drain them.` Downgraded members never drain together.

   This step runs before scoring, so a set that names a spec member shows the spec prompt and no scores, whether or not it would fit the budget.
3. **Branch-name dry-run.** Mint the batch name the claim would cut, before claiming anything:

   ```bash
   bash .gaia/scripts/branch-name-lib.sh name debt <every named number>
   ```

   Any non-zero exit prints `The batch branch name for <#A #B ...> would exceed the 64-byte branch-name limit; name fewer issues. Nothing was claimed.`, then the library's own stderr line, and ends the run: nothing claimed, no scoring. (Run ends here; see `## Cost record (run end)` in `debt.md`.)
4. **Score.** Pipe the ordering command in `## Read and order the backlog` in `debt.md`, run unchanged, into the scorer:

   ```bash
   <the ordering command in debt.md> | bash .gaia/scripts/debt-batch-budget.sh <every named number>
   ```

   It prints one JSON document: `members` (each with `number`, `cost`, `base`, `surcharge`, `waived`, `difficulty`, `footprint`), `total`, `budget`, `verdict`, and `subsets`. The weights and the budget live in the scorer alone; print its numbers and never state one here. Overlap credit comes from the dedup-key path alone: a keyless member earns no shared-directory waiver even when its body cites a path in another member's directory, unlike the clustering pass's body fallback. The outcomes, named by meaning (the exit codes behind them live in the scorer's header):
   - **fits** → the named set is the confirmed selection, with no prompt.
   - **over** → first print each member's cost line, then the total line, built from the JSON:

     `#<N>: cost <cost> (<difficulty or ungraded>, <footprint or no footprint label><, surcharge waived: shared directory when waived>)`

     `Total <total> against a budget of <budget>: over budget.`

     Then ask one `AskUserQuestion` (header `Debt batch`, single-select) whose question text says to use Other to cancel. Its options, in order:
     - each of the scorer's `subsets`, in the order it lists them, labelled with its members (`#<A> #<B>`) and its total, the first suffixed `(Recommended)`;
     - `Force #<A> #<B> ...` last, naming every named member in backlog order.

     There is no separate Cancel option. A picked subset becomes the selection, and a one-member subset drains that issue alone, with no cluster prompt. Force selects every named member, over budget. Anything typed into Other, or a declined or dismissed prompt, prints `Cancelled; nothing was claimed. Re-run /gaia-debt <numbers> to choose again.` and ends the run with nothing claimed: it never forces and never drains. (Run ends here; see `## Cost record (run end)` in `debt.md`.)
   - **usage or malformed input** → report the scorer's stderr line, claim nothing, and end the run. (Run ends here; see `## Cost record (run end)` in `debt.md`.)
   - **unreadable input, jq missing included** → report it, claim nothing, and end the run. When the cause is a missing `jq`, say so in its own message: a named batch needs `jq`, and naming one number at a time still works. (Run ends here; see `## Cost record (run end)` in `debt.md`.)
5. **Claim and drain.** The selection enters `## Claim the fix unit` in `debt.md` as a named selection, and everything after it runs unchanged. The branch is minted by `## Pre-flight isolation (branch vs worktree)` unchanged: the single-issue `--slug` form for a one-member selection, the batch form for two or more. The PR carries one `Closes #N` per selected member and no other.
