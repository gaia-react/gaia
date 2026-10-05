# /gaia-debt

Fix the `tech-debt` backlog the audit files. `/gaia-debt` reads the open `tech-debt` issues, orders them deterministically (highest severity then oldest first, no model call), recommends the top candidate, and resolves **one fix unit** per invocation, a single issue, a user-approved related batch of issues, or a batch the operator names by number, on a fresh branch through the same Code Audit Team marker gate every feature PR passes, with one `Closes #N` per member issue in the PR body so the merge closes every issue in the unit natively.

The ordering is a pure, source-checkable sort over the issues' severity labels and `createdAt` timestamps. It never calls a model to rank the backlog, and it never resolves more than one fix unit per run.

## Execution model, READ FIRST

Execute the playbook yourself in the current conversation. The happy path runs start to finish without stopping, exactly like `/update-deps`: once the fix unit is chosen and isolated the skill implements the fix, runs the Quality Gate, commits, pushes, opens the PR, clears the marker gate, and merges, all in one invocation. There are **up to two** up-front interactive decisions, in order: (1) the pick: with no issue number named, the candidate/batch pick, only when the backlog holds two or more issues; with one number named, the cluster offer, only when that issue heads a batchable cluster; with two or more numbers named, only the spec hand-off prompt or the over-budget prompt, when one applies (`## Fix a named set (two or more numbers)` below), and (2) the isolation-mode pick (`## Pre-flight isolation (branch vs worktree)` below), resolved through the shared isolation reference: on `main`/`master` the team's isolation policy decides whether this surfaces a prompt at all, and on any other branch it is always a silent forced worktree with no prompt. After both, the flow does not pause for confirmation. Pause only when input is genuinely needed (those two picks) or something stops the path: an unrecognized argument, a named number that cannot be drained, a named member that cannot join a batch, a named batch whose branch name would exceed the branch-name limit, or something unexpected that blocks it (a security-class diversion, an issue whose premise the staleness screen finds no longer holds, a rejected push, a gate that will not go green). Resolve **one fix unit** per invocation, a single issue, a user-confirmed related batch, or an operator-named batch; the skill never auto-advances to an unrelated issue.

The skill drives a fix PR through the **full** PR Merge Workflow (cut a branch, implement, run the Quality Gate, commit, push, `gh pr create`, then the marker handshake and merge). Once the PR is up it drives straight through to merge with no second confirmation, resolving the PR to completion the standard way: the same Code Audit Team marker gate every feature PR passes, then `gh pr merge`. The gate is inviolate: never bypass, fake, or pre-empt the marker, and never substitute a bare `gh pr merge` for the workflow's handshake.

The Workflow Doctrine (`wiki/concepts/Workflow Doctrine.md`) defines roles, git ownership, checkpoint and resume, and model choice. This playbook's own contract governs where it differs (for example it implements inline on the main thread and runs the Quality Gate once for the combined diff).

## Argument parsing

Parse the argument first, before `## Backend probe` and the stale-claim reconcile, so an argument the grammar does not accept stops the run before anything is read or written. The grammar is executable, not prose to interpret: hand `$ARGUMENTS` to the parser verbatim, through a quoted heredoc so nothing in it is expanded by the shell:

```bash
bash .gaia/scripts/debt-parse-args.sh <<'GAIA_DEBT_ARGUMENTS'
<the $ARGUMENTS text, verbatim>
GAIA_DEBT_ARGUMENTS
```

The accepted forms are `fix`, `list`, `why <issue-number>`, and one or more issue numbers, each with an optional leading `#`, after an optional leading `fix`, separated by spaces or commas; a repeated number counts once. The parser's header owns the grammar. It prints exactly one line; map it:

- `top` (empty `$ARGUMENTS`, or a bare `fix`) → the full interactive flow, recommending the top-of-backlog candidate. This is the default the statusline nudge (`Run /gaia-debt (N issues)`) points at, and these two forms are the only ones that run it.
- `list` → `## list subcommand`: print the ordered backlog and stop. No branch, no PR, no prompts. (Run ends here; see `## Cost record (run end)`.)
- `why <N>` → `## why subcommand` for `#<N>`: explain where that issue sits in the ordering, its recommended footprint class, and the rationale, then stop. `why` takes exactly one number. No authoring, no prompts. (Run ends here; see `## Cost record (run end)`.)
- `numbers <N>` (one number) → `## Validate named numbers`, then `## Fix a specific issue (direct-number path)` for `#<N>`.
- `numbers <N1> <N2> ...` (two or more numbers) → `## Validate named numbers`, then `## Fix a named set (two or more numbers)`.
- `unrecognized <token>` (the parser refused the argument) → relay its two stderr lines verbatim (the unrecognized token, then the accepted forms), claim nothing, run no backend probe and no reconcile, and end the run. (Run ends here; see `## Cost record (run end)`.)

If the parser reports that it was misused or could not read its input (no stdout line, one `debt-parse-args:` stderr line), report that line and end the run the same way: nothing claimed, no probe. (Run ends here; see `## Cost record (run end)`.)

## Backend probe

Probe the issue backend before reading the backlog. Three outcomes:

- **Definitive-absent** → report "no GitHub issues backend; /gaia-debt no-ops" and stop. Triggers: repo unresolvable, `gh` unauthenticated, Issues disabled (`gh repo view --json hasIssuesEnabled` false **or** a structurally-failing issue-list probe, **never** `gh repo view` resolution alone), or the viewer lacks write permission. (Run ends here; see `## Cost record (run end)`.)
- **Transient/ambiguous** (timeout, rate-limit, 5xx) → surface the failure and stop without action. Retrying later is safe; nothing was authored. (Run ends here; see `## Cost record (run end)`.)
- **Present** → proceed.

## Read and order the backlog (deterministic, no LLM evaluator)

Read the open backlog and order it with a pure sort. No model call ranks the backlog; the order is reproducible from this source.

### Reconcile stale claims (fix only)

This reconcile runs only in `fix` (a `top` or `numbers` parse), never in `list`/`why`: it writes (it can strip a label), and those two subcommands never write. It runs **before** the backlog read below, so it recovers a claim leaked by a session that died ungracefully mid-fix before the ordering and clustering passes below ever see the backlog.

Ask the verdict helper which claims are stale. It owns the whole liveness rule and computes it rather than leaving any part of it to judgment:

```bash
bash .gaia/scripts/debt-stale-claims.sh
```

It prints the number of every stale claim, one per line, and nothing else. A claim is **live** when a branch names the issue as a debt member (local or remote-tracking, in either the plain or the worktree spelling, every member of a batch branch counted), when an open pull request names it by head branch or by a closing keyword in its body, or when the issue was updated within the grace window; the script's header states each arm and the window. For each number printed, strip the claim (`gh issue edit <n> --remove-label in-progress`, best-effort) and touch the sentinel once (`mkdir -p .gaia/local/debt && : > .gaia/local/debt/refresh-requested`). **On a non-zero exit, strip nothing:** the helper fails closed when any input it needs cannot be read, because stripping a live claim hands one issue to two sessions while leaving a stale one costs a single reconcile cycle. Report the reason it printed on stderr and continue to the backlog read.

The verdict is repo-wide over open `tech-debt` issues and carries no origin check, so a claim set by hand rather than by a drain is stripped on the same terms. `.claude/rules/issue-claim.md` sends a hand claim on a `tech-debt` issue through `/gaia-debt` for that reason.

The age grace exists because the claim lands *first*, before any branch is cut (`## Claim the fix unit` below): a just-locked issue has no branch yet, so "no branch ⇒ dead" alone would false-strip a fresh lock. A recent update protects that fresh lock; the branch check protects every active fix once past branch-cut, regardless of age, and it reads branch names through the same naming library `## Pre-flight isolation (branch vs worktree)` mints them with, so the two cannot disagree about what a drain's branch looks like.

This reconcile queries and strips only `in-progress`. `debt:spec-pending` and `debt:spec-active` are distinct, durable labels parking a spec-class issue, handed off and underway (or holding the issue open on a recorded trigger) respectively (see `## Fix-time spec screen`); this reconcile never iterates either one and never strips either one, spared by construction.

```bash
gh issue list --label tech-debt --state open --limit 1000 \
  --json number,title,labels,createdAt,body \
  --jq '
    map({
      number, title, createdAt, body,
      labels: [.labels[].name],
      sev: ([.labels[].name]
            | if   index("severity:critical")    then 3
              elif index("severity:important")   then 2
              elif index("severity:investigate") then 0
              else 1 end),
      difficulty: ([.labels[].name]
                   | map(select(startswith("difficulty:")) | ltrimstr("difficulty:"))
                   | .[0] // null),
      key: (((.body | capture("<!-- gaia-debt-key: v1 class=(?<class>[^ ]+) path=(?<path>[^>\n]+) line=(?<line>[0-9]+) -->")) // null)
            | if . then (.line |= tonumber) else . end),
      footprint: ([.labels[].name]
                  | map(select(startswith("footprint:")) | ltrimstr("footprint:"))
                | .[0] // null)
    })
    | sort_by([(-.sev), .createdAt])
  '
```

How the sort works, and why it is deterministic:

- **Severity descending.** Each issue's one severity label maps to a rank: `severity:critical → 3`, `severity:important → 2`, `severity:suggestion → 1`, `severity:investigate → 0`. An issue with **no** severity label falls through the `else` branch to rank `1`, the **suggestion** band, so a human-filed fieldless issue is a valid candidate and sorts with the suggestions.
- **`severity:investigate` ranks below every band, and is not one.** It records that the severity is not yet determined, so it is not a fourth rung on the ramp and the rank exists only to give `list` a place to print it: below the suggestions, where a reader looks last. `fix` excludes it from candidacy outright (see the exclusion paragraph below), because the work an investigate issue asks for is research and `/gaia-debt` fixes.
- **The unlabelled `else` stays at rank 1 and does not become investigate.** Two reasons, and either alone settles it. A fallback that lands on `investigate` makes "I do not know" the value an issue acquires by default, which is what turned the dedup key's `class=` axis into a graveyard; and because `fix` excludes investigate from candidacy, every human-filed fieldless issue would silently leave the fix pool. The `else` branch assigns a sort position, never a label, so nothing about it is a grade.
- **`createdAt` ascending within a band.** `sort_by([(-.sev), .createdAt])` sorts by negated rank first (highest severity first) then by `createdAt`. `gh` returns `createdAt` as a `Z`-normalized RFC 3339 string, so a lexicographic ascending sort is chronological ascending: of two equal-severity issues, the **older** one sorts first (FIFO within the band).
- **Every issue also carries `body`, `labels`, `key`, and `footprint`.** `labels` is the label name list; `body` is the raw issue body, populated unconditionally; `key` is the parsed dedup key (`class`, `path`, an integer `line`) or `null` when absent or malformed; `footprint` is the footprint class taken from the `footprint:<class>` label with its namespace prefix stripped (`narrow` | `wide` | `spec`), or `null` when the issue carries no `footprint:` label. These ride the sort but play no part in it; the passes below read them.

The entire ordering is this one `--jq` expression over fields GitHub returns. There is no judgment step, so `list`, `why`, and `fix` all agree on the order and anyone can reproduce it by re-running the command.

After the sort, run a second deterministic pass that clusters the ordered backlog into related groups. No model call ranks or clusters the backlog: clustering is a pure function of parsed fields, exactly like the sort. It never changes the sort order, it only groups issues within it, so `list`, `why`, and `fix` all agree on the clusters too. The clustering **function** is identical across all three; only `fix`'s **input** differs, because it filters in-progress issues out of the backlog before clustering (below), so its offered clusters can legitimately differ from what `list`/`why` display over the unfiltered backlog.

Each issue's dedup key, the `<!-- gaia-debt-key: v1 class=<finding_class> path=<repo-relative-posix-path> line=<integer> -->` comment defined by `.claude/skills/file-tech-debt/SKILL.md` step 1, arrives pre-parsed as the emitted `key` object; read its `class` and `path` directly. `key` is `null` both when the issue carries no key comment and when the comment is malformed, and in either case the fallback is the same: scan the emitted `body` for the bare `<path>:<line>` pattern `file-tech-debt/SKILL.md` step 2.3 uses to recover a `path` (a keyless human-filed issue takes this path too, since `body` is always populated). If no path is parseable at all, the issue does not cluster and stands alone.

Two issues belong to the same cluster when either holds, strongest signal first:

1. **Same `path`.** Byte-identical dedup-key `path=` values. Fixing two defects in one file is the canonical case for fixing them together.
2. **Same seeded `class` and same directory.** Identical `class=` values whose `path` share the same `dirname` (immediate parent directory), the same root-cause pattern in one subsystem. The `class` must be a **real seeded class**: the fallback sentinel `holistic/unclassified` (`OUT_OF_SCOPE_FALLBACK_FINDING_CLASS`) never satisfies this rule. Two issues that both fall back to the sentinel share no root-cause signal, only the absence of one, so pairing it with a shared directory is just clustering on the directory, which the next paragraph rejects. A backlog whose issues all carry the sentinel therefore clusters on rule 1 alone, and rule 2 starts contributing on its own once real classes are seeded.

A shared directory alone is too weak to cluster on (a whole `app/services/` directory is not one fix); only same-`path` or same-seeded-`class`-plus-same-dirname cluster. A **cluster is a batch candidate only when it has 2 or more members**; a singleton fixes the normal one-issue way. Clustering is security-blind: it never looks at severity, security-classification, or repo visibility, those are handled where the batch is offered (below).

**In-progress exclusion (fix only).** `fix` derives an `inProgress` flag per issue from the `labels` field the ordering query above already fetches (true when the issue carries `in-progress`) and excludes every in-progress issue from both the candidate pool and the clustering pass above: an in-progress issue neither offers itself as a candidate nor drags a sibling into a batch. `fix` derives a `specParked` flag the same way (true when the issue carries **either** `debt:spec-pending` or `debt:spec-active`) and excludes every parked issue from the candidate pool and the clustering pass exactly as `in-progress` issues are excluded: this is the "leaves the re-offer pool" half of the parked-state contract (the debt-count half lives in `.gaia/scripts/debt-count-refresh.sh`). Nothing in `fix` branches on which park label is set. `fix` derives an `investigate` flag the same way (true when the issue carries `severity:investigate`) and excludes it from the candidate pool and the clustering pass on identical terms: the issue is open work, but it is research rather than a fix, and offering it as a fix candidate would ask the drain to repair something nobody has established is broken. `list` still shows in-progress, parked, and investigate issues and `why` still reports them, annotated `[spec pending]`, `[spec active]`, or `[investigate]` (see below); only `fix`'s candidate set narrows.

**When every candidate is excluded as investigate.** `fix` says so and names those issues with their open questions, rather than reporting an empty backlog. An investigate issue is resolved by answering its `gaia-investigate` block's question and then re-grading it, which returns it to the pool as an ordinary candidate. The grade and the block move together, in one call: `gh issue edit <n> --remove-label severity:investigate --add-label severity:<tier> --body-file <path>`, where the body carries the answer in its failure-mode prose and no `gaia-investigate` block. `.claude/skills/file-tech-debt/SKILL.md` step 5 owns that rule and says why a stranded block is worse than none. `/gaia-debt` does not do that research itself: no path through it answers an investigate question or re-grades an issue.

### Staleness probe (all subcommands)

An issue asserts things about the tree: the dedup key's `path=`, the `file:line` locations its body cites, and any count its suggested fix depends on. Nothing re-checks those when the backlog is read, so an issue whose subject was renamed, moved, or already fixed keeps offering itself and still reads as actionable. Draining one that way documents a change that is not the change the code needs.

Run the cheap half of that verification here, over every candidate, from the `key.path` the ordering query already emits. Pipe the ordering command in `## Read and order the backlog` above, run unchanged from the repository root, into the probe script:

```bash
<the ordering command above> | bash .gaia/scripts/debt-path-probe.sh
```

It prints one JSON array with a `{number, path, status}` entry per issue, in backlog order. `status` is `gone` when the path is not in the index, so an untracked build artifact sitting at the path does not read as a live source file; `tracked` when it is; and `keyless` when the emitted `key` is `null`. A non-zero exit means no report: say the probe could not run and annotate nothing, rather than marking every issue stale.

A `key.path` is text from an editable issue body, so never place it, or any other body text, in a command line yourself: not to re-run the probe on one issue, not to check a path by hand. The script reads every path as JSON data; read the `status` it prints.

This probe is **advisory, and annotates only**. A missing path is a strong signal and not a verdict: a finding can stay entirely real while the file it cites is renamed out from under the issue, and the correct repair is sometimes the issue and sometimes the code. So `list` marks the issue `[stale: path gone]`, `why` reports it, and `fix` still offers it with the annotation carried into the option description, which puts the choice in front of the fact instead of behind it. An issue whose emitted `key` is `null` has no path to probe and is annotated nothing: a missing key is not evidence of staleness.

What this probe deliberately does not do is re-resolve the body's cited `file:line` locations or re-derive its stated counts. Both need the body read closely against real code, one issue at a time, and paying that for every open issue on every `list` would make the cheapest subcommand the most expensive one. That half runs once, against the one issue about to be fixed, in `## Fix-time staleness screen` below. The two tiers are deliberately split on cost: cheap and total here, expensive and single-target there.

## Validate named numbers

Runs for every `numbers` result of `## Argument parsing` above, one number or several, after the backlog read above and before anything else the named flow does. Validation of every named number precedes the security pre-filter, the spec pre-filter, the branch-name dry-run, and the score in `## Fix a named set (two or more numbers)` below, and precedes the cluster offer in `## Fix a specific issue (direct-number path)` below. So a run naming a closed number alongside a spec-class or security-class member prints only the validation reasons.

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

Print the line of every ineligible number, then stop: any ineligible number ends the run with nothing claimed, no branch, no prompt, and no fall-through to the top of the backlog or to any other issue. (Run ends here; see `## Cost record (run end)`.) Only when every named number is eligible does the run continue: one number to `## Fix a specific issue (direct-number path)`, two or more to `## Fix a named set (two or more numbers)`.

## Fix a specific issue (direct-number path)

Runs only when Argument parsing above resolved exactly one issue number
(`numbers <N>`), from a bare `<issue-number>`, `#<issue-number>`, or
`fix <issue-number>`. It runs after the Backend probe, the
Read-and-order-the-backlog passes (reconcile, ordering, and clustering), and
`## Validate named numbers` above, and it replaces "## Recommend and present
(fix)" below for this invocation, except on the one operator-chosen
fall-through noted inline (option 3 of the cluster offer).

**Validate the target.** `## Validate named numbers` above decides whether
`#<N>` is drainable; its table owns the reasons and their precedence, and this
section restates neither.

**Ineligible** (any row of that table matches) → print that row's line and
stop. The run ends with nothing claimed, no branch, and no prompt; it never
offers or drains a different issue in place of the one named. (Run ends here;
see `## Cost record (run end)`.)

**Eligible** (open, `tech-debt`-labeled, not in-progress, not parked, not
investigate-graded) →
resolve which cluster, if any, anchors it, reusing the same clustering pass
and the same offer-time security read (`gh repo view --json visibility`) "##
Recommend and present (fix)" defines below (one read, never a second prompt):

- **Heads a public-batch-eligible cluster of 2 or more** → one `AskUserQuestion`
  prompt (header `Debt item`, single-select), same shape as the batch offer
  below, anchored on the passed issue:
  1. `Batch #<N> #<B> #<C> (Recommended)`: shared signal, member count,
     severity span, "one branch, one PR, all close on merge."
  2. `#<N> only`: fix just the passed issue, one at a time.
  3. `Next available highest-priority item(s) instead`: picking this falls
     through to "## Recommend and present (fix)" below, over the full
     backlog, exactly as if no argument had been passed.
  - The built-in **Other** entry still lets the human type any open
    `tech-debt` issue number to fix that one alone.
- **Singleton (no cluster), security-class on a non-PRIVATE repo, or
  spec-class (any repo)** → no prompt: the run claims only `#<N>` and
  proceeds straight to fixing it alone, the same nothing-to-decide rule
  "## Recommend and present (fix)" applies to a lone remaining candidate. A spec-class `#<N>` (emitted `footprint`
  equal to `"spec"`) is never anchored or batched, mirroring the
  security-class singleton rule. The Fix-time security screen below still
  screens and, if needed, diverts a security-class `#<N>` exactly as it would
  for any other selected issue, and it still proceeds to "## Claim the fix
  unit" so the Fix-time spec screen catches a spec-class `#<N>` and hands it
  off.

Whatever this section resolves to, hand off to "## Claim the fix unit" below
the same way "## Recommend and present (fix)" does. `#<N>` is a named
selection there: losing `#<N>` at the claim-time re-read (a peer session
claimed it, or it was parked on a SPEC, after validation) stops the run with
no re-present and no substitute issue, as `## Claim the fix unit` step 1
states. A cluster sibling that option 1 added and that is lost at the same
re-read follows the existing batch rule instead: it is dropped and the
surviving members proceed.

## Fix a named set (two or more numbers)

Runs only when `## Argument parsing` above resolved two or more issue numbers (`numbers <N1> <N2> ...`): a batch the operator chose. It replaces "## Recommend and present (fix)" and its clustering offer for this invocation; the named set is the batch, and no issue the operator did not name joins it. `## Validate named numbers` above has already run on every named number, and this section runs only when nothing failed validation. Its steps run in this order, and a step that stops the run stops it before every later step:

1. **Security pre-filter.** Read `gh repo view --json visibility` once. Anything but a confirmed `PRIVATE` (`PUBLIC`, `INTERNAL`, or a failed read) is non-private.
   - On a **confirmed-PRIVATE** repo nothing is filtered: a security-class member passes and batches normally.
   - On a non-private repo, classify each named member with the fail-safe content classification `## Fix-time security screen` below applies, read from the emitted `body`. A **benign member** passes. For each security-class member print exactly this line, and nothing else about it:

     `#<P> can't join a batch on a non-private repo; drain it alone.`

     Then stop when any member was rejected: no claim, no force, no hand-off, even when a spec-class member is also named. (Run ends here; see `## Cost record (run end)`.)

   **No disclosure.** The rule covers the run's printed messages: the text relayed or written to the operator, its prompts, and its cost lines. Local tool output, such as the backlog read's JSON, is not a printed message. No printed message names a security-class member's title, body, or path, which is why no step before this one prints a named member's title, and the staleness probe's annotation is never printed for a named set's security-class member.
2. **Spec pre-filter.** A named member whose emitted `footprint` is `spec` needs a SPEC and cannot be batched. Print that for each such member (`#<S> needs a SPEC and cannot be batched`), then ask one `AskUserQuestion` (header `Debt batch`, single-select) with exactly two options:
   - `Hand off #<S> [#<S2> ...] to /gaia-spec`
   - `Cancel`

   `Cancel`, anything typed into the built-in Other, or a declined or dismissed prompt prints `Cancelled; nothing was claimed. Re-run /gaia-debt <numbers> to choose again.` and ends the run with nothing claimed. (Run ends here; see `## Cost record (run end)`.)

   `Hand off` runs the spec member(s) alone as one selection: they go through `## Claim the fix unit` and the security, staleness, and spec screens below, and no other named member gains `in-progress` in that run. The outcomes:
   - A confirmed spec-class member is parked with `debt:spec-pending` and its `/gaia-spec` handoff block is printed exactly as `## Fix-time spec screen` prints it, one block per confirmed member (the sentinel touch is idempotent, so one touch suffices).
   - One downgraded member (the spec screen found it needs no SPEC) drains alone exactly as `/gaia-debt <S>` would.
   - With two or more downgraded members, the first downgraded member in backlog order drains alone exactly as `/gaia-debt <S>` would; every other downgraded member's claim is released (`gh issue edit <n> --remove-label in-progress`), the sentinel is touched (`mkdir -p .gaia/local/debt && : > .gaia/local/debt/refresh-requested`), and one line names them: `Released #<S2> [#<S3> ...]: the spec screen found no SPEC needed, and a hand-off drains one downgraded issue per run. Re-run /gaia-debt <S2> [<S3> ...] to drain them.` Downgraded members never drain together.

   This step runs before scoring, so a set that names a spec member shows the spec prompt and no scores, whether or not it would fit the budget.
3. **Branch-name dry-run.** Mint the batch name the claim would cut, before claiming anything:

   ```bash
   bash .gaia/scripts/branch-name-lib.sh name debt <every named number>
   ```

   Any non-zero exit prints `The batch branch name for <#A #B ...> would exceed the 64-byte branch-name limit; name fewer issues. Nothing was claimed.`, then the library's own stderr line, and ends the run: nothing claimed, no scoring. (Run ends here; see `## Cost record (run end)`.)
4. **Score.** Pipe the ordering command in `## Read and order the backlog` above, run unchanged, into the scorer:

   ```bash
   <the ordering command above> | bash .gaia/scripts/debt-batch-budget.sh <every named number>
   ```

   It prints one JSON document: `members` (each with `number`, `cost`, `base`, `surcharge`, `waived`, `difficulty`, `footprint`), `total`, `budget`, `verdict`, and `subsets`. The weights and the budget live in the scorer alone; print its numbers and never state one here. Overlap credit comes from the dedup-key path alone: a keyless member earns no shared-directory waiver even when its body cites a path in another member's directory, unlike the clustering pass's body fallback. The outcomes, named by meaning (the exit codes behind them live in the scorer's header):
   - **fits** → the named set is the confirmed selection, with no prompt.
   - **over** → first print each member's cost line, then the total line, built from the JSON:

     `#<N>: cost <cost> (<difficulty or ungraded>, <footprint or no footprint label><, surcharge waived: shared directory when waived>)`

     `Total <total> against a budget of <budget>: over budget.`

     Then ask one `AskUserQuestion` (header `Debt batch`, single-select) whose question text says to use Other to cancel. Its options, in order:
     - each of the scorer's `subsets`, in the order it lists them, labelled with its members (`#<A> #<B>`) and its total, the first suffixed `(Recommended)`;
     - `Force #<A> #<B> ...` last, naming every named member in backlog order.

     There is no separate Cancel option. A picked subset becomes the selection, and a one-member subset drains that issue alone, with no cluster prompt. Force selects every named member, over budget. Anything typed into Other, or a declined or dismissed prompt, prints `Cancelled; nothing was claimed. Re-run /gaia-debt <numbers> to choose again.` and ends the run with nothing claimed: it never forces and never drains. (Run ends here; see `## Cost record (run end)`.)
   - **usage or malformed input** → report the scorer's stderr line, claim nothing, and end the run. (Run ends here; see `## Cost record (run end)`.)
   - **unreadable input, jq missing included** → report it, claim nothing, and end the run. When the cause is a missing `jq`, say so in its own message: a named batch needs `jq`, and naming one number at a time still works. (Run ends here; see `## Cost record (run end)`.)
5. **Claim and drain.** The selection enters `## Claim the fix unit` below as a named selection, and everything after it runs unchanged. The branch is minted by `## Pre-flight isolation (branch vs worktree)` unchanged: the single-issue `--slug` form for a one-member selection, the batch form for two or more. The PR carries one `Closes #N` per selected member and no other.

## Recommend and present (fix)

Skipped when "## Fix a specific issue (direct-number path)" or "## Fix a named set (two or more numbers)" above already resolved the pick, or when `## Validate named numbers` stopped the run; runs otherwise, on a `top` parse or when the operator picks option 3 of the direct-number cluster offer. The top candidate is the first in the sorted list. Before building the prompt, resolve which cluster, if any, anchors the recommendation.

**Offer-time security read.** Clustering itself is security-blind, but a security-class issue can never share a public `Closes #N` PR, so the offer is not. Before presenting, read repo visibility once: `gh repo view --json visibility`. On a **confirmed-PRIVATE** repo every cluster is public-batch-eligible as-is. On any **non-PRIVATE** repo, apply the same fail-safe security classification the Fix-time security screen (below) defines, reading each candidate's content from the emitted `body`, to every candidate issue in the backlog, and treat any security-class issue as not public-batch-eligible: it never appears inside a batch option, only as its own single candidate. Reuse this one read for the Fix-time security screen after selection; it never becomes a second prompt.

**Offer-time spec read.** Detect each remaining candidate's spec routing from the emitted `footprint` field, spec-class when it equals `"spec"`. An unclassified issue emits `footprint: null`, which is not spec-class, the same treatment a fieldless human-filed issue gets today. Keylessness has no bearing on it: the class comes from the label, so a keyless issue carrying `footprint:spec` is spec-class like any other. Unlike the security read, this check is **unconditional**: no `gh repo view --json visibility` gate, because repo visibility has no bearing on whether a fix needs a SPEC. A spec-class issue is withheld from every batch option, on every repo, and offered only as its own single candidate. A single spec-class member never forces its batch to a SPEC handoff; its `narrow`/`wide` siblings still batch normally by the max-over-members rule.

The **recommended batch**, when one exists, is the top cluster all of whose members are public-batch-eligible: normally the cluster containing the top-ranked candidate, but a security-class top candidate is never public-batch-eligible on a non-PRIVATE repo, and a spec-class top candidate is never batch-eligible on any repo, so either anchors no batch and is offered only as its own single candidate. An eligible batch may span severities, a `severity:suggestion` in the same file as a `severity:important` is a cheap add-on.

How you present the choice depends on backlog size and cluster shape, counted over the **remaining candidates** (open issues after the in-progress exclusion above), not the raw open-issue count:

- **Zero remaining candidates** (every open `tech-debt` issue already carries `in-progress` or one of the two park labels) → do not prompt. State that every open `tech-debt` issue is already in progress or parked on a SPEC, and stop. (Run ends here; see `## Cost record (run end)`.)
- **Exactly one remaining candidate** → do not prompt. State the issue (number, title, severity band, age derived from `createdAt`) and fix it directly. This is also the peer-session case: two open issues, one already claimed, fixes the single remaining candidate with no prompt.
- **Top candidate heads a public-batch-eligible cluster of 2 or more** → a batch is recommended. Offer it with a single `AskUserQuestion` prompt (header `Debt item`, single-select), phrased around the batch, for example: `"Top item #<A> is related to <N> other issue(s) (<shared signal>). Fix them together, or one at a time?"`. Options, top option carrying `(Recommended)`:
  1. `Batch #<A> #<B> #<C> (Recommended)`, description: the shared signal (e.g. "all in app/foo/index.ts"), the member count, the severity span, and "one branch, one PR, all close on merge."
  2. `#<A> only`, description: fix just the top issue (its severity band and its age), one at a time.
  3. (optional) the next distinct candidate slot: a batch option when that candidate itself heads a >= 2 cluster, else a single option.
  - The tool's built-in **Other** entry lets the human type any open `tech-debt` issue number to fix that one alone.
- **Top candidate is a singleton (no cluster), or a security-class top candidate on a non-PRIVATE repo** → present exactly today's shape: the top three candidates as options (or both when only two exist), top candidate first and its label suffixed `(Recommended)`. Any shown candidate that itself heads a public-batch-eligible cluster of 2 or more is presented as a **batch** option rather than a single, which keeps one-at-a-time the default natural path.

Cap the option set at **4** (plus the built-in Other), the `AskUserQuestion` maximum. When the backlog is deeper than the shown options, first print the full ordered backlog (per issue: number, title, severity band, age), now annotated with cluster membership (e.g. `[batch with #B #C]`), so numbers beyond the shown options are visible before choosing.

**Opt-out guarantee.** One-at-a-time stays an explicit, always-available choice: the `#<A> only` option, the built-in Other (type any open issue number to fix it alone), and the unchanged singleton path together guarantee it. A batch is always a recommendation the human approves, never a default that skips the choice.

**Security-class members never appear inside a public batch option.** On a non-PRIVATE repo the offer-time read above already withholds them, they surface only as single candidates. On a confirmed-PRIVATE repo they may appear as batch members.

**Spec-class members never appear inside a batch option, on any repo.** The offer-time spec read above withholds them unconditionally; unlike the security peel, this hold never relaxes on a confirmed-PRIVATE repo.

Honor whatever the human picks or types into **Other**. If a typed value is not an open `tech-debt` issue number in the backlog, say so and re-prompt; do not fix an off-list issue. A typed value that **is** open and `tech-debt`-labeled but carries `debt:spec-pending` or `debt:spec-active` is parked: say so, naming the label actually set so the human can tell an untouched handoff from a running or held one (e.g. "#<N> is parked pending a SPEC handoff; remove the `debt:spec-pending` label to re-surface it", or "#<N> is parked with a SPEC underway or holding it open on a recorded trigger; remove the `debt:spec-active` label to re-surface it, unless the issue records a trigger it is held on"), and re-prompt; do not fix it. The skill never auto-advances past the human's choice.

## Claim the fix unit

This runs in `fix` only, as the **first** step after the pick above, before the Fix-time security, staleness, and spec screens and before Pre-flight isolation (branch/worktree) below. Claiming immediately after the pick, ahead of all of those steps, minimizes the window in which a peer session also picks the same ticket.

Reconcile the label via the registry, idempotently:

```bash
.gaia/cli/gaia labels sync 2>/dev/null || true
gh label list --json name --jq '.[].name' 2>/dev/null | grep -qx 'in-progress' \
  || gh label create 'in-progress' 2>/dev/null || true
```

The fallback create covers every case the sync leaves the label uncreated: a CLI predating the `labels` command, a token without label-write scope, and a resolved audience or feature set that does not reach the entry. A label that already exists is not an error. The registry is what makes the label gaia-owned, not a name prefix, so this **registry reconcile** never deletes a label a human created by hand: `labels sync` deletes only a deprecated entry under `--prune-deprecated` or one the registry blocks. That is a different operation from the **stale-claim reconcile** at `## Reconcile stale claims`, which does strip; no promise made about either one carries to the other.

Then, for a single issue or **every member of a confirmed batch**:

1. **Re-read each member's labels** (`gh issue view <n> --json labels`) before claiming. The order of re-read and claim depends on how the selection was made.

   **A named selection** is one the operator named by number: the issue a single-number run named, a fitting named set, a subset picked from the over-budget offer, a forced set, and a spec hand-off unit. For a named selection, re-read and claim each member in backlog order, interleaved: re-read `#A`'s labels, claim `#A`, re-read `#B`, claim `#B`, and so on, so this run's claims at any point are exactly the members before the one being re-read. If a member's re-read finds `in-progress` or either park label (`debt:spec-pending`, `debt:spec-active`), the named selection is lost:
   - release every claim this run already set (the members claimed before it), `gh issue edit <n> --remove-label in-progress` each;
   - touch the sentinel (`mkdir -p .gaia/local/debt && : > .gaia/local/debt/refresh-requested`);
   - print `#<N> was <claimed by another session | parked on a SPEC> before this run could claim it; released this run's claims and stopped. Re-run /gaia-debt with the numbers you still want.`, naming the lost member and why;
   - cut no branch, drain nothing, and end the run without re-presenting the backlog. A named selection never shrinks silently and never falls through to another issue. (Run ends here; see `## Cost record (run end)`.)

   When the direct-number cluster offer's batch option was picked, `#<N>` is the named member and is re-read and claimed first under this rule; the siblings the offer added then follow the rule for every other selection below.

   **Every other selection** (the no-argument flow's pick, a batch it recommended, a number typed into its Other, and the cluster siblings above): re-read every member first, then claim the survivors in step 2. If `in-progress` is already present, a peer session won the race:
   - **single issue** → report "issue #N was just claimed by another session" and re-present the refreshed backlog; do not fix it. (Run ends here; see `## Cost record (run end)`.)
   - **batch** → drop that member and proceed with the surviving members if 1 or more remain; if none remain, report the whole batch was claimed and re-present the refreshed backlog. (The none-remain case ends the run here; see `## Cost record (run end)`.)

   If either park label is present instead (`debt:spec-pending` or `debt:spec-active`), the member is parked on a SPEC, mirroring the `in-progress` branch above exactly:
   - **single issue** → report "#<N> is parked on a SPEC" and re-present the refreshed backlog; do not fix it. (Run ends here; see `## Cost record (run end)`.)
   - **batch** → drop that member and proceed with the surviving members if 1 or more remain; if none remain, report and re-present the refreshed backlog. (The none-remain case ends the run here; see `## Cost record (run end)`.)

   This re-read is the universal choke point every selection path (recommend, direct-number, named set, Other) reaches after the pick, so it backstops the offer-time spec read and the direct-number ineligible list the same way it backstops the offer-time security read and the in-progress exclusion: a parked issue is caught no matter how it was selected.
2. **Claim every surviving member**: `gh issue edit <n> --add-label in-progress`. A confirmed batch claims all of its members, not just the top one. A named selection's members are already claimed, one by one, by step 1's interleave.
3. **Touch the sentinel** (`mkdir -p .gaia/local/debt && : > .gaia/local/debt/refresh-requested`) so a peer session's next statusline tick recomputes the open count and drops it. This in-flow touch is best-effort; the `gh issue edit` PostToolUse hook is the deterministic backstop.

The label spelling is the same shared contract `.gaia/scripts/debt-count-refresh.sh` reads to exclude claimed issues from the open count.

Because the claim happens here, before the screens below, any member one of them later peels already carries `in-progress`; the peeling screen strips it.

## Fix-time security screen

Before opening any fix PR, screen **every member of the selected fix unit** (a single issue, or every issue in a confirmed batch). Apply the fail-safe security classification `.claude/agents/code-audit-frontend.md` (section B) defines, screening each member's **content**, read from the emitted `body`, machine-filed or human-filed: an issue is security-class if its content reads as a security concern (an exploitable weakness), it was a Critical, or it is secret-shaped. When in doubt, treat it as security-class.

**The screen reads content, never the dedup key's `class=` field.** `holistic/unclassified` is the expected class for most out-of-scope findings, not a security signal, so it is not a trigger; the agent definition's section B is the single source for that rule and this screen never restates a stricter one. A screen keyed on `class=holistic/unclassified` would peel the entire backlog on a public repo and leave `/gaia-debt` permanently unable to fix anything.

This screen is a backstop for exactly two cases: a **human-filed** issue that is security-sensitive, and a repo that **flipped PRIVATE → PUBLIC** while previously-filed security issues sat in its backlog. It is not a re-judgment of the machine-filed backlog: on a PUBLIC or INTERNAL repo the audit **never files a security-class finding as an issue** in the first place.

Re-read `gh repo view --json visibility` immediately before acting (a repo can flip from PRIVATE to PUBLIC), reusing the offer-time read above when it already ran; do not add a second prompt:

- **confirmed PRIVATE** → no member peels. The whole unit, single or batch, fixes as one private PR; fixing proceeds normally.
- **PUBLIC or INTERNAL** → any member that screens security-class is **peeled** from the unit and **diverted individually**: surface a count-only pointer to the operator and wait; never auto-disclose, never auto-draft an advisory, never open a public fix PR for it. Strip its claim (`gh issue edit <n> --remove-label in-progress`) and touch the sentinel so it re-enters the open count and a peer session's offer. The remaining non-security members proceed as the (possibly smaller) unit, keeping their claims. If every member peels, there is nothing left to open a public PR for: strip every member's claim the same way, report the diverts, and stop. (Run ends here; see `## Cost record (run end)`.) The label name is generic and non-disclosing, and machine-filed security-class issues only exist in the backlog on confirmed-PRIVATE repos, so a brief label is not a disclosure concern. On a public repo, opening a `Closes #N` PR for a security issue completes a coordinated-disclosure failure, which this screen exists to prevent.

This member-level screen is the **backstop** to the offer-time exclusion in "Recommend and present" above: on a non-PRIVATE repo a security-class issue is already withheld from the offered batch, so this screen mainly guarantees the invariant for a member reached via **Other**.

**Its position ahead of implementation is load-bearing, not incidental.** A member peeled here has no commits, so the peel is complete once its claim is stripped. Moving this screen after the commit step of "Resolve the selected unit" would put every peel on the drop path in `### Dropping a member after its commits are written` and owe each one that section's commit-message rewrite.

A security-class issue's detail never reaches a public PR, the PR comment, or the Actions log.

## Fix-time staleness screen

Runs after the pick, the claim, and the Fix-time security screen above, and **before** the Fix-time spec screen below. It screens **every member of the selected fix unit** (a single issue, or every surviving member after the security screen peels any security-class member) by reading each member's cited code and each member's comments. Reading either needs no branch, which is why this screen sits with the other pre-isolation screens: a unit that fails here stops before any branch or worktree exists.

**Why it runs before the spec screen.** The spec screen decides whether a fix needs a SPEC by reading the cited code. If the citations no longer resolve, that judgment is made against the wrong code, so the verification has to come first. Its position ahead of implementation is load-bearing for the same reason the security screen's and the spec screen's are: a unit stopped here has no commits, so the stop owes no commit-message rewrite.

**This screen blocks.** It is not an advisory note in the run's output. The failure it exists to prevent is a fix that faithfully implements an issue describing a tree that no longer exists, and the drainer is the same agent that would read its own advisory and rationalize past it. On any mismatch, do not drain: release the unit and hand the decision back, because the two repairs (correct the issue, or fix the code) are not the drainer's to choose between.

### 1. Re-verify the body's assertions against the tree

Per member, in order, and stop at the first mismatch:

1. **The dedup key's `path=` resolves.** The advisory probe in `### Staleness probe (all subcommands)` above already annotated this; here its `status` for the member is a verdict rather than an annotation.
2. **Every `file:line` the body cites resolves to a real line in the named file**, and the line still carries what the body says is there. Reading the surrounding lines is the point: a citation that resolves to a *different* statement is worse than one that does not resolve at all, because it looks correct. Open each cited file with the Read tool, never with a shell command that names it: a cited path is body text, held to the same rule as the probe's `key.path`.
3. **Every count the fix depends on re-derives.** A body that says "41 `unowned:` entries at `<path>:239-298`" is asserting a number and a range. Re-derive both. A count the suggested fix does not depend on is not worth stopping over; a count it is built around is the fix's premise.

**On a mismatch:** report it precisely, naming the member, the assertion, and what the tree says instead. Then release the unit exactly as a controlled stop does: strip `in-progress` from every claimed member (`gh issue edit <n> --remove-label in-progress`) and touch the sentinel (`mkdir -p .gaia/local/debt && : > .gaia/local/debt/refresh-requested`), so the issue re-enters the open count and a peer session's offer. Do not edit the issue to repair the drift and do not proceed on a re-derived premise: which of the issue and the code is wrong is the operator's call. (Run ends here; see `## Cost record (run end)`.)

**On a batch**, a single failing member does not condemn the unit: peel that member, release its claim alone, and proceed with the survivors, the same shape the security screen's peel takes. If every member fails, the run stops as above.

### 2. Read the issue's comments

The drain reads issue bodies and nothing else, while the established practice for "the suggested fix turned out to be wrong" is to post a correction comment and leave the body standing. Those two facts compose into a drainer that rebuilds work a comment already recorded as reverted. So the drain reads comments, here, for the selected members only:

```bash
gh issue view <n> --json comments
```

**Per member, not per backlog.** This call is deliberately absent from the backlog read in `## Read and order the backlog`, and that placement is the whole cost argument. Comments are unbounded text; the backlog read runs over every open issue on every `list`, `why`, and `fix`; and the corrections that matter only matter for the one unit about to be fixed. Paying for comments across the whole open set to serve a single-issue question is the trade this placement refuses. One extra call per selected member, once per run, is the honest price.

Classify what the comments say against the body, newest comment winning where two comments disagree:

- **Nothing that touches the body's claims** → the body governs; proceed.
- **A correction that supersedes part of the body** (a wrong suggested fix, a re-graded footprint class, a corrected citation) → the comment governs that part. State plainly, before implementing, which comment supersedes which part of the body, so the human sees the substitution rather than inferring it from the diff. A comment re-grading the footprint class feeds the Fix-time spec screen below as that member's footprint value, in place of the `footprint:` label. A comment is the weaker form for this one field, since re-labelling is a single `gh issue edit` that every reader sees, but a corrector who left a comment instead is still obeyed.
- **A comment reporting the fix as already implemented, already reverted, or unsafe as specified** → this is not a correction to apply, it is the issue's premise failing. Treat it exactly as a mismatch in part 1: peel or stop, release the claim, report. Rebuilding something a comment records as deliberately reverted is the single worst outcome this screen exists to prevent, and it is indistinguishable from ordinary progress in the resulting diff.

A comment is a durable correction channel, and this screen is what makes that true. Nothing here asks a corrector to duplicate the correction into the body; a body edit is still the stronger form because it reaches every reader, and both are read.

## Fix-time spec screen

Runs after the pick, the claim, the Fix-time security screen, and the Fix-time staleness screen above, and before "## Pre-flight isolation (branch vs worktree)" below. It screens **every member of the selected fix unit** (a single issue, or every surviving member of a confirmed batch) by reading each member's **cited code**. Reading cited code needs no branch, which is why this screen runs before isolation: a wholly spec-class unit hands off before any branch or worktree exists. Every surviving member reaching this point has had its citations verified and its comments read, so this screen grades against code the issue really describes, and against a footprint class a comment may already have re-graded.

**This screen owns the spec-versus-implement determination**, resolving the advisory footprint class **symmetrically**, exactly as the class is advisory for `narrow`/`wide`:

- A `footprint:spec` member the drainer judges to need **no** SPEC after reading the code → **downgrade** to `wide`/`narrow` and keep it in the unit to implement. A named set's spec hand-off keeps at most one downgraded member; `## Fix a named set (two or more numbers)` step 2 releases the rest.
- A `narrow`/`wide` member the drainer judges to **need** a SPEC → **upgrade**, **peel** it from the unit, and hand it off, mirroring the way the Fix-time security screen peels a security member reached via Other. The surviving members proceed as the smaller fix unit.

**For each confirmed spec-class member, do not implement.** Instead:

1. **No-orphan claim swap.** Reconcile the label via the registry idempotently (`.gaia/cli/gaia labels sync 2>/dev/null || true; gh label list --json name --jq '.[].name' 2>/dev/null | grep -qx 'debt:spec-pending' || gh label create 'debt:spec-pending' 2>/dev/null || true`), then **add `debt:spec-pending` before removing `in-progress`** (`gh issue edit <n> --add-label debt:spec-pending` then `gh issue edit <n> --remove-label in-progress`), so a mid-swap failure never strands the issue label-less. The registry reconcile leaves a hand-created label alone, for the reason given at the fallback create above.
2. **Touch the debt-count sentinel** (`mkdir -p .gaia/local/debt && : > .gaia/local/debt/refresh-requested`) so the count refreshes; the parked issue leaves `openCount`.
3. **Print a single copy-pasteable `/gaia-spec` handoff block**, carrying the originating issue number `#<N>` so the eventual implementation PR can `Closes #<N>`, and carrying the `debt:spec-pending` -> `debt:spec-active` swap the pasted session runs on arrival:

   ```
   /gaia-spec Design-first tech debt from issue #<N>: <one-line problem>. First run
   `gh issue edit <N> --remove-label debt:spec-pending --add-label debt:spec-active`
   (best-effort; do not block authoring on it). Author a SPEC for this fix; the
   implementation PR the resulting plan produces should carry `Closes #<N>` so the
   tech-debt issue closes on merge. If the SPEC resolves without an implementation
   PR that closes #<N>, settle the label yourself: when nothing remains to
   implement, run `gh issue edit <N> --remove-label debt:spec-active` and close #<N>;
   when the SPEC holds #<N> open on a recorded trigger, keep the label and comment
   on #<N> naming where the trigger is recorded.
   ```

   **Why the swap and the release ride the block rather than a skill.** `/gaia-debt` never invokes `/gaia-spec` (see Hard constraints below), so nothing with standing awareness of the issue is running when the pipeline starts; the block is the only channel that reaches the spec session, and it already directs downstream behavior through exactly this route (the `Closes #<N>` instruction). `/gaia-spec` and `/gaia-plan` gain no debt awareness of their own. The mechanism is deliberately **soft**: a session that skips the line leaves the label at `debt:spec-pending`, which parks the issue exactly as the handoff left it, so a miss degrades to a handoff that reads as un-started rather than to a worse state.

**Two park states, and what each one means.** `debt:spec-pending` means handed off and not yet started; `debt:spec-active` means the pipeline is running, the SPEC being authored, planned, or executed, or that the SPEC answered by holding the issue open on a recorded trigger. Both park the issue identically for every consumer (out of `openCount`, out of `fix`'s candidate pool and clustering pass), so nothing downstream branches on which one is set. What the split buys is that an un-started handoff stays **distinguishable** from one somebody is working, which is the whole point: under a single label a second person sees a marker that says "waiting for someone" and authors a second SPEC for the same debt.

**`debt:spec-active` has no automatic release; outside a closing merge it comes off by hand.** Nothing joins a SPEC to its originating issue, so no hook or reconcile can tell a SPEC that finished the work from one that deliberately left the issue open, and releasing on either signal alone would unpark an issue that should stay parked. Every consumer filters on open issues, so a label left on a closed issue is inert. The cases:

- **The implementation PR merges carrying `Closes #<N>`.** The issue closes and the label goes inert with it. No action.
- **The SPEC or its plan merges and nothing remains to implement.** No closing keyword fires, so nothing closes the issue. Strip the label (`gh issue edit <N> --remove-label debt:spec-active`) and close the issue by hand.
- **The SPEC answers by holding the issue open on a recorded trigger.** Keep the label: it is the hold. Unparked, a `footprint:spec` issue re-routes straight back into a second `/gaia-spec` handoff on the next drain. Comment on the issue naming where the trigger is recorded, so a reader of the label can find what would release it.
- **The SPEC is abandoned.** Strip the label and leave the issue open, per the next paragraph.

The handoff block above carries the second and third cases to the spec session, because it is the only channel that reaches it.

**Abandoning the SPEC strips the label and leaves the issue open.** When a human or agent decides to stop pursuing the SPEC, remove whichever park label is set (`gh issue edit <n> --remove-label debt:spec-pending` or `--remove-label debt:spec-active`) and touch the sentinel, so the issue returns to the candidate pool and re-offers on the next drain. **Do not close it.** Abandoning a spec means the fix was not attempted, not that the debt is gone, and closing it is worse than losing a backlog row: `.claude/skills/file-tech-debt/SKILL.md` step 2 reads a closed match carrying `wontfix`, or closed as not-planned, as *declined* and suppresses re-filing permanently, so a dropped spec would block an audit from ever re-filing that finding. Closing as `wontfix` stays a separate, deliberate "this should not be fixed" decision. This is the controlled-stop case only; the silent case, where the block is never pasted at all, is nobody's decision and nothing reaps it, which is exactly what keeping `pending` distinct from `active` leaves queryable.

**Stop conditions:**

- **Whole selected unit is spec-class** → the run **stops here**: no fix PR, no branch, no worktree. (Run ends here; see `## Cost record (run end)`.)
- **A member peeled out of a batch** → the surviving non-spec members proceed to "## Pre-flight isolation (branch vs worktree)" and a fix PR as the smaller unit.

**Hard constraints.** `/gaia-debt` never invokes `/gaia-spec`, never dispatches a spec author, and never reads the SPEC template or `plan.md`. Authoring or saving the SPEC does not close the issue, and this handoff issues **no** close call. A merge carrying `Closes #<N>` closes the issue on its own; any other close is by hand, per the hand-release cases for `debt:spec-active` above.

This screen mirrors the Fix-time security screen's mechanism but is **unconditional** (visibility-independent): repo visibility has no bearing on whether a fix needs a SPEC. Like the security screen, it sits before isolation for the same reason, a divert or handoff happens before any branch exists.

Its position ahead of implementation is **load-bearing** for the same reason the security screen's is: a member peeled here has no commits, so the handoff owes no commit-message rewrite.

## Pre-flight isolation (branch vs worktree)

This section runs once per fix, single issue or batch, after the security screen, the staleness screen, and the spec screen above, and before the fix unit's branch or worktree exists. Ordering rationale: each of those three can end the run before any branch exists, the security screen by diverting a security-class fix, the staleness screen by releasing a unit whose premise no longer holds, and the spec screen by handing off a spec-class fix, so isolation runs after all three and a diverted, released, or handed-off fix never creates a worktree.

**Branch naming.** Mint the name from `.gaia/scripts/branch-name-lib.sh`, which owns GAIA's branch-naming convention; never assemble it by hand. Single-issue fix, with `<slug>` a 2-4 word reduction of the issue title: `bash .gaia/scripts/branch-name-lib.sh name debt <issue-number> --slug "<slug>"`. Batch fix, every surviving member: `bash .gaia/scripts/branch-name-lib.sh name debt <n1> <n2> ...`. A batch name carries every member, which is what lets the stale-claim reconcile above protect a non-lowest batch member past branch-cut without leaning on the age grace. Whichever isolation mode runs, including the forced worktree, pass exactly this output as the branch or worktree name.

Then isolate the fix:

> Read `.claude/skills/gaia/references/isolation.md` and apply it now, with `{{SUBJECT}}` = "this debt fix", `{{WORKER}}` = "the fix", `{{OWNER}}` = "this fix", `{{SIBLING}}` = "another task".

The reference owns the decision order, the prompt, and the worktree-creation call; take the branch name it needs from the naming rule above. In worktree mode every later step, implementing the fix(es), the Quality Gate, commit, push, `gh pr create`, the Code Audit Team marker gate, and the merge, runs from inside the worktree.

## Resolve the selected unit

The **fix unit** is the selected member set as it stands after the pre-isolation screens above have peeled every member they peel: a single issue, or every surviving member of a confirmed batch. It is still **one fix unit per invocation**. This definition names no individual screen deliberately, so adding or reordering one is a change to that screen's own section and to nothing here.

1. **Confirm the footprint class for the unit.** Each member issue's emitted `footprint` field carries an advisory `narrow`, `wide`, or `spec`, or, for an unclassified human-filed issue, `null`; the full vocabulary is three-valued (`narrow` | `wide` | `spec`). The **spec-versus-implement** determination is owned by the Fix-time spec screen above, before isolation: by the time this step runs, every surviving member is `narrow`/`wide` (a spec-class member was either downgraded and kept, or peeled and handed off there). This step grades **narrow-versus-wide** the same way as today: `narrow` when confined to one file with no public-contract change and no cross-module ripple, `wide` otherwise. Both drain inline, through the same Quality Gate, PR, and audit gate; the class records how far the change reaches and routes nothing. The unit's effective class is the **maximum** over members: `wide` if any member is `wide` (or any fix is cross-module / contract-changing), else `narrow`. A multi-issue batch is usually `wide`. State the honest class before implementing so the human knows the scope, exactly as today's single-issue rule does.
2. **The unit is already isolated.** `## Pre-flight isolation (branch vs worktree)` above already cut the branch or created the worktree before this step, on the name `.gaia/scripts/branch-name-lib.sh` minted for it. This step does no branch creation of its own.
3. **Implement all fixes in the unit** on the one branch, following the project's normal conventions (TDD, surgical changes).
4. **Run the Quality Gate** (`.claude/rules/quality-gate.md`) once for the combined diff, then commit and push. The subject's type is what the fix changed (`fix`, `refactor`, `test`, `docs`, ...), never `debt`, which the `commit-msg` hook rejects; the `debt/` branch prefix already records the workflow (`wiki/decisions/Naming Conventions.md`). **No commit message on the branch carries a closing keyword against an issue number**, not `Closes #N`, and not the `fixes` / `resolves` spellings GitHub acts on identically; name a member as a bare `#N` where a message has to name one. A squash merge concatenates the branch's commit bodies into the merge commit message and GitHub reads closing keywords out of that message, so a trailer written here closes its issue on merge whatever the PR body says. Keeping it out of every commit is what leaves step 5's PR body the **sole carrier**, and only a sole carrier is correctable when a member is dropped.
5. **Open one PR** with `gh pr create`. The PR body includes **one `Closes #N` line per member issue** (GitHub's auto-close keyword) so the single merge closes every issue in the unit natively. Security-class detail still never reaches a public PR: a security-class issue is either withheld from the offered batch or peeled and diverted by the screen above, so no security-class member ever reaches a public `Closes #N` PR.

The PR is an ordinary in-scope source change: it passes the **same** Code Audit Team marker gate as any feature PR, one gate for the combined diff. Let the normal gate produce a real marker; do not bypass, fake, or pre-empt it. Getting that marker and completing the merge are covered under *Drive the PR to merge* below.

### Dropping a member after its commits are written

A member can leave the unit after step 4 has written commits, when its fix is reverted or its premise falls over mid-implementation. Three corrections, all of them required:

1. Strip its claim (`gh issue edit <n> --remove-label in-progress`) and touch the sentinel, so it re-enters the open count and a peer session's offer.
2. Remove its `Closes #N` line from the PR body.
3. **Rewrite every commit message on the branch that closes it**, `git commit --amend` for the tip commit and an interactive rewrite for an older one, then force-push. Step 4's rule means there is normally nothing to rewrite; read `git log --format=%B "refs/remotes/origin/<default>..HEAD"` and check anyway, because a surviving trailer reaches the squash-merge message and closes the issue as `COMPLETED` with nothing fixed, and no other step in this playbook reads commit bodies. `<default>` is the repository's default branch (`git symbolic-ref --quiet refs/remotes/origin/HEAD` with its `refs/remotes/origin/` prefix stripped, `main` when that is unset); the ref is spelled in full so a local branch or tag named `origin/<default>` cannot shadow it and hide commits from the range.

The **intended close set** is the unit as it stands after every drop: exactly the members whose `Closes #N` lines the PR body carries at merge time. *Drive the PR to merge* below verifies that the merge closed that set and nothing else.

## Touch the debt-count sentinel

After opening the PR, set the staleness sentinel **once per fix** (not once per member issue in a batch) so the statusline recomputes the open count on the next tick:

```bash
mkdir -p .gaia/local/debt && : > .gaia/local/debt/refresh-requested
```

**Create the parent dir first.** On a fresh clone or in CI no statusline tick has run, so `.gaia/local/debt/` may not exist and a bare `touch` would fail silently and leave the sentinel unset. The deterministic merge-event sentinel-set is owned by the `gh pr merge` PostToolUse hook; when the skill drives the merge that hook fires in-session, and on an open-PR-only run or a queued `--auto` merge the merge lands later, so this in-conversation touch is best-effort belt-and-suspenders.

## Drive the PR to merge

Once the PR is up, drive it straight to merge with no confirmation prompt: the fix unit (single issue or confirmed batch) was chosen up front, so this back half runs autonomously, exactly like `/update-deps` merging a dep-bump PR on a `main` run. The only things that stop the flow here are genuine blockers, a rejected push, a marker that never goes green, the audit gate's branch checkpoint or one of the fix round's stops, or any merge-wait arm other than `MERGED` or `CONFLICTING` (the arm list below states what each one does); those are reported, not worked around. On a controlled stop before merge, gate never green, rejected push, or another blocker/observable abort, strip `in-progress` from every claimed member (`gh issue edit <n> --remove-label in-progress`) and touch the sentinel, so the freed issue re-enters the offer and the count. (Run ends here; see `## Cost record (run end)`, passing `--github-*` only if the PR was already opened before the stop.)

Five endings look like that controlled stop and are not it. Each keeps its claim, because the work may still be going somewhere, and `## Cost record (run end)` covers when each one's record is written. The arm list below states what each of them reports, except the branch checkpoint and the fix round's stops, which have no arm of their own. Both of those depend on who is in the session. A run is **interactive** when a human invoked `/gaia-debt` in an interactive session and is there to answer; it is **unattended** when no human is in the session, as in a headless, scheduled, or `/loop` run:

- **A `--auto` merge still queued when the poll window closes** (the `TIMEOUT` arm, exit 5). It is still progressing toward merge, so the claim stays in place until it resolves.
- **A stop at the branch checkpoint** (`wiki/concepts/PR Merge Workflow.md`, `#### The branch checkpoint`). The round's fix is pushed, the PR stays open, and the `in-progress` claim stays in place. An interactive run asks the pinned question exactly as that section's interactive path prescribes, then continues the loop on the recorded answer; an answer that ends the loop instead (stop, a new session, or one the recorder declines) ends the run there with the claim kept. An unattended run asks nothing and prints no handoff prompt: it reports the verdict, the per-round evidence, a recommendation and the next step, relayed verbatim from `bash .gaia/scripts/audit-loop-eval.sh brief --root <root>` and never paraphrased. The next step is that a human types the printed grant or accept line (copied from the bound hook's deny message, which carries it) as the whole prompt in an interactive session on that branch, then re-runs the merge workflow. A drain never grants itself rounds.
- **A stop inside the fix round** (`wiki/concepts/PR Merge Workflow.md`, `#### The fix round: fixer, verifier, gate`): a third Quality Gate failure, a second verifier failure, a second consecutive fixer no-op, or the resume rule's baseline with no fixer result and drift. Push nothing uncommitted, leave the PR open, keep the `in-progress` claim, and report the stop reason plus the run-folder paths of the round's artifacts (dispositions, baseline, fixer result, verifier output, gate logs). An interactive run then asks the human what to do, as that section prescribes for each stop; an unattended run asks nothing and prints no handoff prompt.
- **A merge wait that refused (exit 2) rather than returning a verdict.** It read nothing, so it establishes neither that the merge landed nor that it did not, and the queued merge may land moments later. Assert no state for the pull request and leave the claim in place.
- **A `CHECK_FAILED` verdict.** The merge stays queued and lands once the failing check is fixed, so the claim stays in place.

A `CLOSED` verdict is not one of them: it is read from GitHub and it is terminal, so it releases the unit exactly as the controlled stop above does.

Resolve the PR to completion through `wiki/concepts/PR Merge Workflow.md`, read it, don't merge from memory. Follow its marker handshake; do **not** substitute a bare `gh pr merge`:

- **Get a real marker for HEAD.** The local merge hook denies `gh pr merge` until the marker exists, and `--auto` cannot skip this. Resolve the spawn set with `bash .gaia/scripts/resolve-audit-members.sh` and run each named member as the producer of its own marker, dispatched with the `RESOLVED_ROOT` the `## Pre-flight isolation (branch vs worktree)` section above already resolved, interpolated into the same self-checked Task template `wiki/concepts/PR Merge Workflow.md`'s "Spawn the dispatched Code Audit Team members" section defines; on a clean pass each writes its marker only; it does not post the `GAIA-Audit` success status itself. If the whole diff is out of audit scope (the resolver names no member), the workflow's out-of-scope bypass clears the merge with no marker. Never hand-write, fake, or pre-empt the marker, an in-scope debt fix earns its marker the same way every feature PR does.
- **Post the success status yourself.** Once `wiki/concepts/PR Merge Workflow.md` `#### Posting the status last` conditions hold, run `bash .claude/hooks/post-audit-status.sh <path to a current member marker>` before merging.
  <!-- gaia:maintainer-only:start -->
- **Clear the CHANGELOG gate.** The workflow's maintainer-only CHANGELOG gate applies to debt PRs too: decide whether the fix needs an `## [Unreleased]` entry and, if so, land it on the branch before merging (re-confirm the marker still covers HEAD after the extra commit). Scrubbed from adopter bundles, so adopters never run this step.
  <!-- gaia:maintainer-only:end -->
- **Merge, then verify before cleanup.** Run `gh pr merge <N> --squash --delete-branch`; if branch protection rejects with "base branch policy prohibits the merge", add `--auto` (never `--admin` without explicit permission) so GitHub queues the merge behind the repository's remaining required checks. Then run the merge wait, `bash .gaia/scripts/pr-wait-merge.sh --pr <N>`, the bounded poll (~2-3 minutes) `wiki/concepts/PR Merge Workflow.md` (`## Post-merge verification before cleanup`) prescribes. It issues no `gh pr merge` of its own, so nothing here re-merges. One arm per verdict plus one for the exit-2 refusal, and the script's `--help` is the authority on both:

  - On `MERGED` (exit 0), proceed to the confirmed-`MERGED` steps below.
  - On `CONFLICTING` (exit 3), repair it per that page's `### Conflict found mid-wait` and run the wait again; it is not a controlled stop and costs no audit round unless the merged content names a member again.
  - On `CHECK_FAILED` (exit 4), report the failing check and return **without** cleanup, the same way as a queued merge, and keep every member's claim.
  - On `TIMEOUT` (exit 5), the window closed with the pull request still open: report "merge queued via --auto; completes when checks pass" and return **without** cleanup, since deleting the local branch, or discarding the worktree, before `MERGED` strands it against an open PR, and keep every member's claim; close-on-merge and the next fix's reconcile settle it once the merge completes.
  - On `CLOSED` (exit 6), the pull request was closed without merging, so no wait can clear it and no `Closes #N` line will ever fire: report the closure, return without cleanup, and release the unit the way any controlled stop does, stripping `in-progress` from every claimed member and touching the sentinel.
  - On exit 2 the wait refused rather than answered: report what it could not read, return without cleanup, and assert **no** state for the pull request, since nothing about it was read. Keep every member's claim, because a claim stripped over an unread pull request hands a peer session an issue whose merge may be seconds from landing.

  On confirmed `MERGED`, each member's `Closes #N` already closed its issue, and a closed issue leaves the open backlog and the count on its own, so stripping `in-progress` here is best-effort/cosmetic: `gh issue edit <n> --remove-label in-progress` for each member, ignoring failure.

  On confirmed `MERGED`, also **verify the close set**, one `gh issue view <n> --json state` per issue: every member of the **intended close set**, the members whose `Closes #N` lines the PR body carries at merge time, must read `CLOSED`, and every member dropped from the unit **after its commits were written** (`### Dropping a member after its commits are written` above) must read `OPEN`. Report any mismatch loudly, naming the issue. Such a member reading `CLOSED` was closed by a stale trailer with nothing fixed, so reopen it (`gh issue reopen <n>`), strip `in-progress`, and touch the sentinel to return it to the backlog. This check is the only step that reads the outcome rather than the intent, and the failure it catches is silent in every other direction: a wrongly-closed issue is indistinguishable from a fixed one.

  **Every other kind of drop is out of this check's scope, and reopening one would be wrong.** A member released by a pre-isolation screen, dropped at claim time to a peer session, or parked on a SPEC with either park label never reached this PR's body, because the body is written after isolation, so no trailer of this run's can close it and there is nothing here to catch. Meanwhile each of those members is legitimately closable by something else while this PR is still open: a released member is back in the backlog where a peer session may fix and merge it, and a spec-parked member closes exactly as intended when its SPEC's implementation PR merges carrying `Closes #N`. Reading `CLOSED` is the success case for those, so reopening on it would undo a real fix and, for a parked member, fight the count rule that already removed it from `openCount`. Scope the check to the post-commit drops and leave the rest alone.

  On `MERGED`, run post-merge cleanup by isolation mode:
  - **Feature-branch isolation:** `git checkout main && git pull`, `git branch -D <branch>`, `git fetch --prune`. (Run ends here; see `## Cost record (run end)`.)
  - **Worktree mode:** run Post-merge worktree cleanup below instead. It removes the worktree first and deletes the branch afterward, since a worktree-held branch cannot be deleted while the worktree stands.

  Every arm above but `MERGED` and `CONFLICTING` ends the run there (the report above and the return without cleanup); see `## Cost record (run end)`.

Each `Closes #N` line in the PR body auto-closes its issue on merge, so on a batch, the single merge closes every member issue and no separate close call is needed for any of them.

### Post-merge worktree cleanup (worktree-mode fixes only)

1. Confirm merge via `gh pr view <N> --json state`; require `.state == "MERGED"`. If not merged, do not proceed; surface and stop.
2. **Isolation-context check** (below). If running inside an isolated subagent context, emit the continuation prompt and stop; do not call `ExitWorktree`.
3. Otherwise call `ExitWorktree({action: "remove", discard_changes: true})` directly. `discard_changes: true` is safe: the squash-merge absorbed every commit on the worktree branch, but those commits are not ancestors of `main`, so the runtime would otherwise refuse; the merged-state confirmation in step 1 proves the work is preserved.
4. Delete the renamed branch as `.claude/skills/gaia/references/isolation.md` (`### Post-merge removal`) prescribes.
5. Report one line: `worktree discarded; PR #<N> squash-merged as <short-sha>`.

Never call `ExitWorktree` first and treat its refusal as the discard trigger; the merged-state confirmation is the primary signal.

### Isolation-context detection (worktree-mode fixes only)

The runtime refuses `ExitWorktree` from an agent dispatched with `isolation: "worktree"` or a `cwd` override (refusal text: `ExitWorktree cannot be called from a subagent with a cwd override`). `/gaia-debt` normally runs on the user's own main thread, so the direct in-session `ExitWorktree` path above is the common case; still detect the automation case:

- **Primary signal:** the skill was invoked via `Agent(...)` with `isolation: "worktree"` (dispatch was a sub-agent task and cwd is a worktree path under `.claude/worktrees/`).
- **Fallback:** if uncertain, attempt `ExitWorktree({action: "remove", discard_changes: true})`; if the response contains `cannot be called from a subagent`, treat it as never-issued (a refusal, not a destructive action), branch into the continuation-prompt path, and stop.

When detected, emit this copy-paste continuation prompt to the user and stop:

    The worktree at <ABSOLUTE-PATH-TO-WORKTREE> is ready to discard.
    PR #<N> squash-merged as <short-sha>. From a shell at
    <ABSOLUTE-PATH-TO-MAIN-CHECKOUT>, run:

        git worktree remove --force <ABSOLUTE-PATH-TO-WORKTREE>
        git branch -D <branch-name>   # if it still exists

(Run ends here; see `## Cost record (run end)`.)

Do not emit an `ExitWorktree({...})` call in this continuation prompt. `ExitWorktree` only operates on a worktree created by `EnterWorktree` in the current session: from a fresh session it is a no-op on a prior-session worktree, and its schema requires `action` and rejects a `worktree` parameter. A plain `git worktree remove --force` is the correct session-independent cleanup. This matches `plan.md`'s Isolation-context detection block, whose continuation prompt emits the same session-independent shell cleanup.

## list subcommand

Run the ordering command above, then the clustering pass and the staleness probe, and print the backlog in sorted order: per issue, the number, title, severity band, age, cluster membership when it has any (e.g. `[batches with #B #C: same file app/foo/index.ts]`), `[in progress]` when the issue carries `in-progress`, `[needs spec]` when its emitted `footprint` field is `"spec"` and it carries neither park label, `[spec pending]` when it carries `debt:spec-pending`, `[spec active]` when it carries `debt:spec-active`, `[investigate]` when it carries `severity:investigate`, `[stale: path gone]` when the staleness probe found its dedup-key `path=` absent from the index, and `[difficulty: <grade>]` (e.g. `[difficulty: medium]`) from the emitted `difficulty` field when it is non-null; an issue whose `difficulty` is `null` gets no difficulty annotation at all. The three spec annotations key on distinct signals, the emitted `footprint` field versus which park label is set, so an un-drained spec-class issue, a handed-off one, and one whose pipeline is running or holding it open are each distinguishable from the other two. `list` shows every open issue, including in-progress and parked ones: it does not exclude them and it does not reconcile stale claims. Author nothing and prompt for nothing.

## why subcommand

Run the ordering command and the clustering pass, find the issue whose number matches the argument. Explain it: where it sits in the ordering (its severity band and its position among equal-severity issues by age), its recommended footprint class (the issue's emitted `footprint` field, or your on-the-fly classification for an unclassified issue where `footprint` is `null`), and the rationale. Also report its difficulty grade from the emitted `difficulty` field (e.g. `medium`) when it is non-null; when `difficulty` is `null`, `why` says nothing about difficulty rather than reporting a default grade. The footprint class is how far the change reaches, the grade is how much design the fix needs, a distinct axis. Also report whether it is part of a related cluster, which issue(s) it would batch with, and the shared signal (same `path`, or same `class` and dirname). Also report the issue's claim status: whether it currently carries `in-progress` (in progress) or not; `why` does not reconcile stale claims. For an issue carrying `severity:investigate`, report that it is not a fix candidate at all and why, quote its `gaia-investigate` block's `**Question:**` line from the emitted `body`, and say what resolves it: answering the question and re-grading the issue, not draining it. Report the staleness probe's result too: whether the dedup key's `path=` still resolves in the index, and, when it does not, that a `fix` run would verify the rest of the issue's assertions before draining it. `why` runs the cheap probe only, never the fix-time re-verification, so it stays a read of the backlog rather than a read of the code. For a spec-class issue (`footprint` equal to `"spec"`), also report its spec routing ("routes through /gaia-spec") and, symmetrically, which park state it is in: `debt:spec-pending` (handed off, not yet started), `debt:spec-active` (the SPEC is being authored, planned, or executed, or holds the issue open on a recorded trigger), or neither (not yet handed off). If no open `tech-debt` issue matches the number, say so and print the ordered backlog. Author nothing and prompt for nothing.

## Cost record (run end)

Every path that ends a `/gaia-debt` run appends exactly one cost record, the run-ending paths above:

- `list` and `why` printing their result.
- The argument parser's unrecognized-argument stop, or its misuse stop. This stop precedes the backend probe and the stale-claim reconcile, so the run read and wrote nothing before it.
- The backend probe's definitive-absent or transient/ambiguous stop.
- The validation stop: `## Validate named numbers` found a named number ineligible.
- The named-set security pre-filter rejecting a security-class member on a non-private repo.
- The named-set spec hand-off prompt cancelled (Cancel, Other, or a declined or dismissed prompt).
- The named-set branch-name dry-run stop: the batch branch name would exceed the branch-name limit.
- The named-set over-budget prompt cancelled (Other, or a declined or dismissed prompt).
- The named-set scorer stopping on usage or malformed input, or on unreadable input (a missing `jq` included).
- A named selection losing a member at the claim-time re-read.
- Zero remaining candidates.
- Claiming the fix unit losing the race to a peer session (single issue, or every batch member).
- The security screen diverting every member.
- The staleness screen releasing every member, whether on a body assertion that no longer holds or on a comment recording the fix as already implemented, reverted, or unsafe. This path opened no PR, so it passes no `--github-*` flags.
- The spec screen handing off: the whole-unit-spec-class case stops the run here (a per-member handoff within a surviving batch also records via this same run-end tally). This path opened no PR, so it passes no `--github-*` flags; the record correctly carries no artifact.
- Driving the PR to merge: `MERGED` cleanup, a still-queued `--auto` merge, a failed required check, a pull request closed without merging, a merge wait that refused because it read nothing, a stop at the audit gate's branch checkpoint, or a controlled stop before merge.
- Worktree mode's isolation-context continuation prompt.

The parser, validation, named-set, and named-selection claim-time stops above all end the run before a PR exists, so none of them passes `--github-*` flags.

Apply the shared tally machinery in `.claude/skills/gaia/references/cost-record.md` with `{{COMMAND}}` = `gaia-debt`. Pass-through is mode-agnostic: worktree mode reads the same URL from the same tool result, nothing about the worktree changes the call.

## Guardrails

- **One fix unit per invocation.** A single issue, a user-confirmed related batch, or an operator-named batch; the skill never auto-advances to an unrelated issue. Batching is always the user's choice: either a related batch the clustering pass recommends and the user confirms, or a batch the operator names by number, under the named-batch budget. One-at-a-time stays the explicit opt-out. Security-class issues never join a public batch, and spec-class members and, on a non-private repo, security-class members never join a named batch, forced or not.
- **A named number never drains a different issue without the operator choosing it.** There is no automatic fall-through: an unrecognized argument, an ineligible named number, and a named selection's claim-time loss each stop the run with a reason. The direct-number cluster offer's next-available option is the operator's choice, not a fall-through.
- **Deterministic ordering, never an LLM evaluator.** The order is the `--jq` sort above over severity labels and `createdAt`; no model ranks the backlog.
- **Within-band FIFO, severity-first.** Highest severity first, oldest first within a band. Cross-band fairness / anti-starvation is out of scope.
- **The skill drives the merge, never the gate.** The happy path runs start to finish with no merge-time confirmation: it resolves the fix PR to completion through the standard PR Merge Workflow's marker handshake, running `gh pr merge` only once a real marker exists for HEAD. Never bypass, fake, or pre-empt the marker, and never substitute a bare `gh pr merge` for the workflow's gate.
- **Security screen before any public PR.** A security-class selected issue diverts via the visibility gate on PUBLIC/INTERNAL; only a confirmed-PRIVATE repo fixes it as a normal fix PR.
- **Staleness screen before any implementation, and it blocks.** No member is drained on an assertion nobody re-checked. The cheap half (does the dedup key's `path=` still resolve) annotates every candidate at backlog-read time; the expensive half (do the cited `file:line` locations and the stated counts still hold, and do the issue's comments correct or retract the body) runs once, against the selected unit. A member whose premise no longer holds is released, never repaired in place and never drained on a re-derived premise: choosing between fixing the issue and fixing the code belongs to the operator.
- **Comments are read, for the selected unit only.** A correction posted as a comment reaches the drainer. The backlog read stays body-only on purpose, because comments are unbounded text and it runs over the whole open set.
- **Spec screen before any implementation.** A confirmed spec-class member never joins a fix PR: it hands off to `/gaia-spec` and parks with `debt:spec-pending`, which the pasted spec session swaps to `debt:spec-active` once the pipeline starts; the peel is unconditional, on every repo. `## Fix-time spec screen` above owns what each park state means, why the two are equivalent to every consumer, the hand-release cases, and the abandonment rule; this recap names the swap and restates none of the rules, so the two cannot disagree.
- **Claim before contest.** `/gaia-debt fix` claims each selected member with the gaia-owned `in-progress` label the instant a unit is picked, ahead of every pre-isolation screen and of isolation itself, which excludes it from the open count and a peer session's offer. `## Claim the fix unit` above states that order; this recap does not restate it, so the two cannot disagree. The claim releases on a controlled stop or on any screen's peel, is best-effort cleared on merge, and is recovered by the fix-start stale-claim reconcile after an ungraceful session death. A hand-set claim on a `tech-debt` issue is **not** exempt from that reconcile; `### Reconcile stale claims (fix only)` above states its scope and its liveness rule, and this recap does not restate either, so the two cannot disagree.
- **The PR body is the sole `Closes` carrier.** No commit message on the branch closes an issue, so dropping a member stays correctable by editing the PR body; a member dropped after its commits exist also gets those commit messages rewritten, and the post-merge close-set check catches a stale trailer that reaches the merge by any other route.
- **Difficulty feeds exactly one decision.** No `/gaia-debt` path requires a `difficulty:*` label to be present; the named-batch budget is difficulty's one consumer, and an ungraded issue scores as medium there.
- Use repo-relative paths only.
