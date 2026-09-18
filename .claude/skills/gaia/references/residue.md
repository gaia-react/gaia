# /gaia-residue

A triage drain over the keyed audit residue recorded under the two canonical headings in merged pull-request bodies. It never fixes anything and never edits a file a residual cites; fixing is `/gaia-debt`'s job.

## Execution model, READ FIRST

Interactive and human-gated. Promote is one question per entry and never auto-advances. The agent never runs `git add`, `git commit`, or `git push` during the per-candidate loop; one end-of-run publish step runs after the last disposition.

## Naming disambiguation

This tree spends the word "residue" on a second meaning: orphaned machine-local state the janitor reaps, carried by the `residue` array in `.gaia/state-registry.json`. That is a different thing from what this command drains. The audit sense this command triages is always spelled "residual": a residual is one keyed entry recorded under a canonical heading in a merged pull request's body. The collision is confined to maintainer-internal registry vocabulary and shadows nothing a user types, but any prose where both senses could be read together disambiguates explicitly, the way this paragraph does.

## Argument parsing

Tokenize the first whitespace-separated word of `$ARGUMENTS`:

- `review` (or empty `$ARGUMENTS`) → the full interactive flow. This is the default an empty `$ARGUMENTS` resolves to.
- `list` → print the live candidates. No authoring, no prompts.
- `why <path>:<line>` → explain the one candidate at that coordinate. No authoring, no prompts.

When the first token is none of `review` / `list` / `why` and the whole string parses as a single `<path>:<line>` coordinate, treat it as a `why` target. Anything else defaults to `review`.

## Fetch the live candidate list (all subcommands)

Every subcommand reads the live list from the tally primitive. Re-run it; never trust a stale count.

```bash
.gaia/cli/gaia residue-tally
```

Bind to the top-level fields it prints: `gh_ok`, `count_approximate`, `candidate_count`, `remaining_count`, `aged_candidate_count`, `total_keyed_count`, `candidates`, `malformed`, `store_skipped`, and `window`. The four counts are four different populations and are not interchangeable:

- `total_keyed_count` is every keyed unit attributed, before any suppression. The corpus size. It never shrinks as the drain proceeds.
- `remaining_count` is the suppression survivors, before the cursor skip and before the cap. What is still open.
- `aged_candidate_count` is the subset of `remaining_count` whose age crosses the nudge's threshold. The nudge's numerator.
- `candidate_count` is this run's emitted batch, after the cursor skip and the cap.

`count_approximate: true` means the counts came from a mode that performed no line resolution, so a dismissal whose recorded line content no longer matches the current one may still be suppressed. The interactive run never sets it.

Then the three terminating reads:

- `gh_ok` is `false`: report, verbatim, `could not complete the GitHub reads; this is not an all-clear, re-run when \`gh\` is available`, then report the populations below and stop. Never claim no findings. Two independent reads set it, the merged-PR window and the tech-debt issue list, and the emit does not say which; naming one of them would send the operator to debug a call that succeeded.
- `gh_ok` is `true` and `candidate_count` is `0`: report the populations below, then that no keyed residual is currently open, and stop.
- Otherwise: proceed to the triage loop below.

Which populations a stop arm carries live differs by arm. The zero-candidate arm carries both, and it is the one that bites: announcing that nothing is open over a truncated corpus, or over a dismissal store some of whose lines could not be read, is exactly the false all-clear this section exists to prevent. The `gh_ok` is `false` arms carry `store_skipped` live, but their `malformed` is always emitted empty whether or not malformed keys exist, so an empty `malformed` there means **unknown**, never none; report it as unknown rather than reporting nothing.

These populations never reach the triage loop, so nothing else will mention them. Report each one that is non-empty, carrying the `reason` each entry gives rather than a summary of it; where the arm above says a population is unknown rather than empty, report it as unknown instead of staying silent. On `review` that is alongside the candidate list, before the first question; on `list` and `why`, alongside the printed result; and on either terminating stop above, alongside that stop's own report, before the run ends:

- `malformed` holds entry units whose key matched the gate's grammar but failed field validation. They are withheld from triage by design, and the reason is reported so the key can be repaired in its own pull-request body. A run that stays silent here leaves a residual no one can act on and no one knows about.
- `store_skipped` holds dismissal-store lines that could not be read. Each one is a disposition that has stopped suppressing, so a suppression a reviewer believes is in place is not.

`window` is different: the emit always carries it, and it holds no reason to relay. Report it, on the same terms and at the same point in each subcommand, only when `window.truncated` is `true`. That means the window read hit its own iteration bound, so the corpus may be incomplete and every count is a floor rather than a total. Say so; never present a truncated read as a whole one.

## Bounding the run

The per-run cap defaults to 10, overridden with `GAIA_RESIDUE_CAP`. Candidates are ordered oldest merge date first. The cursor at `.gaia/local/cache/residual-cursor.json` advances after each confirmed disposition, so an interrupted run resumes where it stopped rather than re-asking; `.gaia/cli/gaia residue-cursor clear` starts the list over.

```bash
.gaia/cli/gaia residue-cursor advance --token <the candidate's cursor_token>
```

Pass only the candidate's own `cursor_token` from the tally emit, never a path. A residual's path is text from a merged pull request, and this call is agent Bash, a shell; the token is closed over `[A-Za-z0-9_-]` by construction so it cannot carry a shell metacharacter, a space, or a leading dash, and there is no `--path` flag to reach for instead.

The cap means the candidate list is a batch, not the whole population. Report `remaining_count` as what is left when a human asks, never `total_keyed_count`.

## Present each candidate

For each candidate present: its canonical disposition (accept or waive), its failure mode, its cited path and line, its resolved line text, and its resolution class.

A candidate whose resolution is `gone` is labelled a likely-already-fixed dismiss candidate and still requires a human disposition; content vanishing is evidence of a fix, not proof of one, so it is never applied unattended. A candidate carrying a `previously_promoted_issue` is labelled as previously promoted to that issue, which closed as completed, and dismiss is presented as the default disposition for it.

## The three arms

State the default posture explicitly before offering them: dismiss or keep is the default, and promotion is the exception that needs a reason. A drainer whose happy path files issues is a migration wearing a drain's clothes, and promoting freely would grow the backlog rather than drain it.

### Promote

One human answer per residual, never batched, collected through an explicit user-question step, the same way `/gaia-harden` gates each candidate. It calls the existing recipe in `.claude/skills/file-tech-debt/SKILL.md` rather than reimplementing filing, and hands it:

- **The finding class is the residual's own.** Pass the `class` carried in the candidate's `raw_key` verbatim as the recipe's `<finding_class>`, so the filed issue's dedup key is byte-identical to the residual's own key. Never mint a fresh class.
- **`footprint:<class>`** comes from the recipe's own step 6 rubric, applied to the cited line the command has already read. It is a reach grade (`narrow`, `wide`, or `spec`), never the finding class above.
- **`severity:<tier>`** comes from the recipe's own severity vocabulary, chosen from the residual's failure-mode text and its canonical disposition, and it is a judgment asked of the human alongside the promote answer, not guessed by the command.
  <!-- gaia:maintainer-only:start -->
- **`audience:<side>`** comes from the cited path, per the recipe's own adopter/maintainer split. Maintainer repository only; scrubbed from adopter bundles.
  <!-- gaia:maintainer-only:end -->
- **`difficulty:<grade>`** is supplied: the command has already read the cited line to resolve it, so a promoted residual is graded using the recipe's own rubric.
- The provenance line's `changed` field is `unknown`: this run holds no fork-point changed-file set, and `unknown` is the honest value there, not `0`.

When the recipe refuses to file because the key matches one of its own dedup arms, append a `suppressed` record (see Record below), so no refusal is silent and no residual is offered forever.

### Dismiss

The safe arm, and the default. It may be offered in a batch, bounded by the same per-run cap, and the batch takes an explicit confirmation that lists every entry it will dismiss before anything is appended. Each dismissal appends one `dismissed` record.

### Keep

A snooze, not a permanent disposition. It appends a `kept` record; the tally suppresses the residual until the record ages past the keep window (14 days by default, `GAIA_RESIDUE_KEEP_DAYS`), then offers it again.

## Record

A promotion is recorded by the filed issue itself, which carries the residual's key; no second store entry is needed for it. A dismissal, a keep, and a filing refusal each append one record to `.gaia/audit-residual-dismissals.jsonl`, and the only way this command writes that file is the CLI:

```bash
printf '%s\n' "<the reason text>" > .gaia/local/audit/residue-reason-<unique>.txt
.gaia/cli/gaia residue-record --disposition dismissed \
  --token <the candidate's cursor_token> \
  --reason-file .gaia/local/audit/residue-reason-<unique>.txt
```

Delete the reason file in a **separate** tool call, for the same reason the filing recipe splits its own cleanup: one `PreToolUse` decision covers a whole Bash invocation, so a denied cleanup would take the write standing beside it. Batch dismissal passes one `--token` per entry in a single call, so one confirmation produces one append.

**Check the exit code before reporting anything.** Exit `0` means the record is written. Any non-zero means nothing was recorded: tell the maintainer the disposition did not persist and why, and do not claim success. The residual re-surfaces on the next tally, which is the honest consequence.

The store is append-only JSON Lines, carries a schema version, and is named above; point at the CLI rather than restating its fields. Never hand-write a line into the store.

## Publish approved changes (end of run)

Runs once, after the last disposition, only when the store was actually written this run. `list` and `why` never reach it.

**Confirm there are real changes.**

```bash
git status --porcelain
```

If it is empty, nothing landed; say so and stop.

**Repo-state safety.** If HEAD is detached or a rebase / merge / cherry-pick / bisect is in progress, do not branch: leave the changes in the working tree, tell the engineer they ship through normal PR review, and stop.

**On the default branch (main/master):** branch, commit through a message file (never `-m`), push, and open a PR.

```bash
TIMESTAMP=$(date +%Y-%m-%d-%H%M)
BRANCH="chore/gaia-residue-$TIMESTAMP"
git checkout -b "$BRANCH"
git add -A
git commit -F <commit-message-file>
git push -u origin "$BRANCH"
gh pr create --title "<commit subject>" --body-file <pr-body-file>
```

Before any `gh pr merge`:

```bash
bash .gaia/scripts/resolve-audit-spawn.sh
```

Empty output confirms no marker is owed. If it names any member, spawn each member it names and complete the marker handshake in `wiki/concepts/PR Merge Workflow.md` like any in-scope PR.

**Merge decision.** Ask once via `AskUserQuestion` whether to merge:

- **header:** `"Merge residue PR?"`
- **question:** `"Merge PR #<N> now, or leave it open for review?"`
- **options (this exact order):**
  1. `{ label: "Merge", description: "Squash-merge PR #<N> now." }`
  2. `{ label: "Leave open", description: "Keep the PR open; you merge it after review." }`

**Merge** → drive it to merge through `wiki/concepts/PR Merge Workflow.md` (read it, don't merge from memory): `gh pr merge <N> --squash --delete-branch --auto`, bounded-poll `gh pr view <N> --json state` for `MERGED`, and on `MERGED` capture the branch (the literal `$BRANCH` value) for the cost record's `--branch-name` (`## Cost record (run end)`) and then clean up (`git checkout main && git pull origin main`, `git branch -D "$BRANCH"`, `git fetch --prune origin`); if still queued when the poll window closes, print the PR URL and note the merge is queued.

**Leave open** → report the PR URL and stop.

**On any other branch:** do not branch, commit, or PR. Leave the changes in the working tree; they ride the current branch's own PR.

If any `git` or `gh` command above exits non-zero, print the error and STOP. Do not retry, force-push, or amend.

## list subcommand

Run `residue-tally`, then print every candidate, one line each. Author nothing, prompt for nothing, resolve nothing beyond what the tally already emitted.

## why subcommand

Run `residue-tally`, then find the candidate whose cited coordinate matches the `<path>:<line>` argument. Explain it: its failure mode, its canonical disposition, its source pull request, its resolved line, and its resolution class. When the coordinate matches no candidate, say so and point at `list`. Author nothing, prompt for nothing. Match the coordinate against the tally's already-emitted JSON; do not pass it to a command.

## Cost record (run end)

Every path that ends a `/gaia-residue` run appends exactly one cost record, the run-ending paths above:

- `list` and `why` printing their result.
- The `gh_ok: false` and zero-candidate stops from the live candidate fetch.
- Publish's no-change stop (nothing landed in the working tree).
- Publish's unsafe-repo-state stop.
- Publish's merge outcomes: `MERGED`, still queued, or "Leave open".
- Publish's non-zero-exit STOP on a `git` or `gh` command.
- Any other-branch no-op.

Apply the shared tally machinery in `.claude/skills/gaia/references/cost-record.md` with `{{COMMAND}}` = `gaia-residue`.

## Guardrails

- Never edit a file a residual cites.
- Never file a tech-debt issue without a human answer for that specific residual.
- Never widen the recognizer beyond the two canonical headings.
- Never sweep keyless entries into the candidate list.
- Never change the merge gate's attribution logic.
- Never ship the store's contents to adopters.
- Never record a keep that does not expire, or any suppression that leaves no tracked record a reviewer can remove.
- Never interpolate a residual's path, or any other residual-derived text, into a shell command.

**The complete set of files a run may write:**

- `.gaia/audit-residual-dismissals.jsonl`, the dismissal store;
- `.gaia/local/cache/residual-attribution.json`, the derived read cache;
- `.gaia/local/cache/residual-cursor.json`, the resumable cursor;
- the transient reason file under `.gaia/local/audit/`, deleted in its own tool call;
- the filing recipe's own transient issue-body file under `.gaia/local/audit/`, and the debt-count staleness sentinel that recipe touches;
- `.gaia/local/telemetry/cost.jsonl`, the shared machine-local telemetry ledger the mandatory cost record appends to. Not this workflow's own file, and its shape is owned by `.gaia/scripts/token-tally.sh`, but a run does write it, so a self-check against this list has to expect it.

Nothing else. Not a source file, not a configuration file, and above all not a file any residual cites.
