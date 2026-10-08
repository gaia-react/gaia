# /gaia-debt

Fix the `tech-debt` backlog the audit files. `/gaia-debt` reads the open `tech-debt` issues, orders them deterministically (highest severity then oldest first, no model call), recommends the top candidate, and resolves **one fix unit** per invocation, a single issue, a user-approved related batch of issues, or a batch the operator names by number, on a fresh branch through the same Code Audit Team marker gate every feature PR passes, with one `Closes #N` per member issue in the PR body so the merge closes every issue in the unit natively.

The ordering is a pure, source-checkable sort over the issues' severity labels and `createdAt` timestamps. It never calls a model to rank the backlog, and it never resolves more than one fix unit per run.

Contents: Execution model; Argument parsing; Backend probe; Read and order the backlog (stale-claim reconcile, backlog pass, staleness probe, offer-time reads, route by the parse); Claim the fix unit; Fix-time security, staleness, and spec screens; Pre-flight isolation; Resolve the selected unit; Drive the PR to merge; Cost record; Guardrails.

## Execution model, READ FIRST

Execute the playbook yourself in the current conversation. The happy path runs start to finish without stopping, exactly like `/update-deps`: once the fix unit is chosen and isolated the skill implements the fix, runs the Quality Gate, commits, pushes, opens the PR, clears the marker gate, and merges, all in one invocation. There are **up to two** up-front interactive decisions, in order: (1) the pick: with no issue number named, the candidate/batch pick, only when the backlog holds two or more issues; with one number named, the cluster offer, only when that issue heads a batchable cluster; with two or more numbers named, only the spec hand-off prompt or the over-budget prompt, when one applies (`## Fix a named set (two or more numbers)` in `debt/named.md`), and (2) the isolation-mode pick (`## Pre-flight isolation (branch vs worktree)` below), resolved through the shared isolation reference: on `main`/`master` the team's isolation policy decides whether this surfaces a prompt at all, and on any other branch it is always a silent forced worktree with no prompt. After both, the flow does not pause for confirmation. Pause only when input is genuinely needed (those two picks) or something stops the path: an unrecognized argument, a named number that cannot be drained, a named member that cannot join a batch, a named batch whose branch name would exceed the branch-name limit, or something unexpected that blocks it (a security-class diversion, an issue whose premise the staleness screen finds no longer holds, a member that must be fixed on a branch when this session cannot cut one, a rejected push, a gate that will not go green). Resolve **one fix unit** per invocation, a single issue, a user-confirmed related batch, or an operator-named batch; the skill never auto-advances to an unrelated issue.

The skill drives a fix PR through the **full** PR Merge Workflow (cut a branch, implement, run the Quality Gate, commit, push, `gh pr create`, then the marker handshake and merge). Once the PR is up it drives straight through to merge with no second confirmation, resolving the PR to completion the standard way: the same Code Audit Team marker gate every feature PR passes, then `gh pr merge`. The gate is inviolate: never bypass, fake, or pre-empt the marker, and never substitute a bare `gh pr merge` for the workflow's handshake.

The Workflow Doctrine (`wiki/concepts/Workflow Doctrine.md`) defines roles, git ownership, checkpoint and resume, and model choice. This playbook's own contract governs where it differs (for example it implements inline on the main thread and runs the Quality Gate once for the combined diff).

This file is the entry point every run reads. The procedures only some runs need live in sub-references under `.claude/skills/gaia/references/debt/`, and each is read at its branch point, where a line here says to Read it now. Never skip such a line: the procedure it names is not restated here.

## Argument parsing

Parse the argument first, before `## Backend probe` and the stale-claim reconcile, so an argument the grammar does not accept stops the run before anything is read or written. The grammar is executable, not prose to interpret: hand `$ARGUMENTS` to the parser verbatim, through a quoted heredoc so nothing in it is expanded by the shell:

```bash
bash .gaia/scripts/debt-parse-args.sh <<'GAIA_DEBT_ARGUMENTS'
<the $ARGUMENTS text, verbatim>
GAIA_DEBT_ARGUMENTS
```

The one accepted form is `/gaia-debt [<issue-number> ...] [[use] worktree|branch]`, and the parser's header owns the rest of the grammar. Its first stdout line is the result; map it:

- `top` (empty `$ARGUMENTS`, or a bare `[use] worktree|branch`) → the full interactive flow, recommending the top-of-backlog candidate. This is the default the statusline nudge (`Run /gaia-debt (N issues)`) points at, and these forms are the only ones that run it. After the backend probe and the backlog read below, `### Route by the parse` routes it: Read `.claude/skills/gaia/references/debt/recommend.md` there and follow its `## Recommend and present`.
- `numbers <N>` (one number) → after the backend probe and the backlog read below, `### Route by the parse` routes it: Read `.claude/skills/gaia/references/debt/named.md` there and follow its `## Validate named numbers`, then `## Fix a specific issue (direct-number path)` for `#<N>`.
- `numbers <N1> <N2> ...` (two or more numbers) → after the backend probe and the backlog read below, `### Route by the parse` routes it: Read `.claude/skills/gaia/references/debt/named.md` there and follow its `## Validate named numbers`, then `## Fix a named set (two or more numbers)`.
- `unrecognized <token>` (the parser refused the argument) → relay its two stderr lines verbatim (the unrecognized token, then the accepted form), claim nothing, run no backend probe and no reconcile, and end the run. (Run ends here; see `## Cost record (run end)`.)

A `top` or `numbers` result may carry a second line, `isolation worktree` or `isolation branch`: the operator already chose the isolation mode. Carry it to `## Pre-flight isolation (branch vs worktree)` below as the **stated mode** and run everything else unchanged. No second line means no mode was stated, and the isolation question asks as usual.

If the parser reports that it was misused or could not read its input (no stdout line, one `debt-parse-args:` stderr line), report that line and end the run the same way: nothing claimed, no probe. (Run ends here; see `## Cost record (run end)`.)

## Backend probe

Probe the issue backend before reading the backlog. Three outcomes:

- **Definitive-absent** → report "no GitHub issues backend; /gaia-debt no-ops" and stop. Triggers: repo unresolvable, `gh` unauthenticated, Issues disabled (`gh repo view --json hasIssuesEnabled` false **or** a structurally-failing issue-list probe, **never** `gh repo view` resolution alone), or the viewer lacks write permission. (Run ends here; see `## Cost record (run end)`.)
- **Transient/ambiguous** (timeout, rate-limit, 5xx) → surface the failure and stop without action. Retrying later is safe; nothing was authored. (Run ends here; see `## Cost record (run end)`.)
- **Present** → proceed.

## Read and order the backlog (deterministic, no LLM evaluator)

Read the open backlog and order it with a pure sort. No model call ranks the backlog; the order is reproducible from this source.

### Reconcile stale claims

This reconcile runs on every `top` or `numbers` parse, **before** the backlog read below, so it recovers a claim leaked by a session that died ungracefully mid-fix before the ordering and the backlog pass below ever see the backlog.

Ask the verdict helper which claims are stale. It owns the whole liveness rule and computes it rather than leaving any part of it to judgment:

```bash
bash .gaia/scripts/debt-stale-claims.sh
```

It prints the number of every stale claim, one per line, and nothing else. A claim is **live** when a branch names the issue as a debt member (local or remote-tracking, in either the plain or the worktree spelling, every member of a batch branch counted), when an open pull request names it by head branch or by a closing keyword in its body, or when the issue was updated within the grace window; the script's header states each arm and the window. For each number printed, strip the claim (`gh issue edit <n> --remove-label in-progress`, best-effort). **On a non-zero exit, strip nothing:** the helper fails closed when any input it needs cannot be read, because stripping a live claim hands one issue to two sessions while leaving a stale one costs a single reconcile cycle. Report the reason it printed on stderr and continue to the backlog read.

The verdict is repo-wide over open `tech-debt` issues and carries no origin check, so a claim set by hand rather than by a drain is stripped on the same terms. `.claude/rules/issue-claim.md` sends a hand claim on a `tech-debt` issue through `/gaia-debt` for that reason.

The grace window covers a claim that has no branch yet, since the claim lands before any branch is cut (`## Claim the fix unit` below), and the branch arm reads names through the same naming library `## Pre-flight isolation (branch vs worktree)` mints them with.

This reconcile queries and strips only `in-progress`. `debt:spec-pending` and `debt:spec-active` are distinct, durable labels parking a spec-class issue, handed off and underway (or holding the issue open on a recorded trigger) respectively (`debt/spec-handoff.md` owns what each means); this reconcile never iterates either one and never strips either one, spared by construction.

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
- **`severity:investigate` sorts below every band and is excluded from candidacy** (the backlog pass below); the unlabelled `else` keeps rank 1, a sort position and never a label.
- **`createdAt` ascending within a band.** `sort_by([(-.sev), .createdAt])` sorts by negated rank first (highest severity first) then by `createdAt`. `gh` returns `createdAt` as a `Z`-normalized RFC 3339 string, so a lexicographic ascending sort is chronological ascending: of two equal-severity issues, the **older** one sorts first (FIFO within the band).
- **Every issue also carries `body`, `labels`, `key`, and `footprint`.** `labels` is the label name list; `body` is the raw issue body, populated unconditionally; `key` is the parsed dedup key (`class`, `path`, an integer `line`) or `null` when absent or malformed; `footprint` is the footprint class taken from the `footprint:<class>` label with its namespace prefix stripped (`narrow` | `wide` | `spec`), or `null` when the issue carries no `footprint:` label. These ride the sort but play no part in it; the passes below read them.

The entire ordering is this one `--jq` expression over fields GitHub returns. There is no judgment step, so anyone can reproduce the order by re-running the command.

Run the ordering command on every parse and keep the array it prints: that array is **the ordered backlog** every later section and sub-reference reads (each issue's title, severity, age, body, labels, and footprint). The scripts below read the same array, so each one is fed by piping the same command, run unchanged from the repository root. On a `top` or single-number parse, pipe it into the backlog pass; a named set skips the backlog pass, and `## Validate named numbers` in `debt/named.md` reads the ordered backlog directly.

```bash
<the ordering command above> | bash .gaia/scripts/debt-backlog.sh
```

It prints one JSON object, and its header owns the rules it applies. `candidates` is the pool the offer draws from, in backlog order. `excluded` lists the issues set aside, each in exactly one of `in_progress`, `spec_parked` (either park label), and `investigate`; an excluded issue is open work that is not offered and never drags a sibling into a batch. `clusters` lists the related groups of 2 or more candidates, each with its `members`, its `paths`, and the `signal` that joined it (`path`, `class-dir`, or `mixed`); a candidate in no cluster fixes the normal one-issue way. `spec_class` lists the candidates whose `footprint` is `spec`. Every later section reads these fields and derives none of them by hand. The pass never changes the sort order, calls no model, and is security-blind: the offer applies the security and spec reads (`### Offer-time reads` below).

**A non-zero exit stops the run before anything is claimed.** Report the reason it printed on stderr: an exclusion that did not run could offer an issue another session holds. (Run ends here; see `## Cost record (run end)`.)

**When every candidate is excluded as investigate** (`candidates` is empty and `excluded.investigate` is not), say so and name those issues with their open questions, rather than reporting an empty backlog. An investigate issue returns to the pool once its question is answered and it is re-graded, the grade and the block moving together in one call: `gh issue edit <n> --remove-label severity:investigate --add-label severity:<tier> --body-file <path>`, where the body carries the answer in its failure-mode prose and no `gaia-investigate` block. `.claude/skills/file-tech-debt/SKILL.md` step 5 owns that rule, and `/gaia-debt` never answers an investigate question.

### Staleness probe

An issue asserts things about the tree: the dedup key's `path=`, the `file:line` locations its body cites, and any count its suggested fix depends on. Nothing re-checks those when the backlog is read, so an issue whose subject was renamed, moved, or already fixed keeps offering itself and still reads as actionable. Draining one that way documents a change that is not the change the code needs.

Run the cheap half of that verification here, over every candidate, from the `key.path` the ordering query already emits. Pipe the ordering command in `## Read and order the backlog` above, run unchanged from the repository root, into the probe script:

```bash
<the ordering command above> | bash .gaia/scripts/debt-path-probe.sh
```

It prints one JSON array with a `{number, path, status}` entry per issue, in backlog order. `status` is `gone` when the path is not in the index, so an untracked build artifact sitting at the path does not read as a live source file; `tracked` when it is; and `keyless` when the emitted `key` is `null`. A non-zero exit means no report: say the probe could not run and annotate nothing, rather than marking every issue stale.

A `key.path` is text from an editable issue body, so never place it, or any other body text, in a command line yourself: not to re-run the probe on one issue, not to check a path by hand. The script reads every path as JSON data; read the `status` it prints.

This probe is **advisory, and annotates only**: the drain still offers a `gone` issue, with `[stale: path gone]` carried into its option description, and annotates a `keyless` issue with nothing.

The cited `file:line` locations and stated counts are re-checked once, for the selected unit only, in `## Fix-time staleness screen` below.

### Offer-time reads

The no-argument offer (`debt/recommend.md`) and the direct-number cluster offer (`debt/named.md`) both apply these reads before presenting a batch, and both handle the pick the same way.

**Offer-time security read.** Clustering itself is security-blind, but a security-class issue can never share a public `Closes #N` PR, so the offer is not. Before presenting, read repo visibility once: `gh repo view --json visibility`. On a **confirmed-PRIVATE** repo every cluster is public-batch-eligible as-is. On any **non-PRIVATE** repo, apply the same fail-safe security classification the Fix-time security screen (below) defines, reading each candidate's content from the emitted `body`, to every candidate issue in the backlog, and treat any security-class issue as not public-batch-eligible: it never appears inside a batch option, only as its own single candidate. Reuse this one read for the Fix-time security screen after selection; it never becomes a second prompt.

**Offer-time spec read.** Detect each remaining candidate's spec routing from the backlog pass's `spec_class` list (the candidates whose emitted `footprint` equals `"spec"`). An unclassified issue emits `footprint: null`, which is not spec-class, the same treatment a fieldless human-filed issue gets today. Keylessness has no bearing on it: the class comes from the label, so a keyless issue carrying `footprint:spec` is spec-class like any other. Unlike the security read, this check is **unconditional**: no `gh repo view --json visibility` gate, because repo visibility has no bearing on whether a fix needs a SPEC. A spec-class issue is withheld from every batch option, on every repo, and offered only as its own single candidate. A single spec-class member never forces its batch to a SPEC handoff; its `narrow`/`wide` siblings still batch normally by the max-over-members rule.

Honor whatever the human picks or types into **Other**. If a typed value is not an open `tech-debt` issue number in the backlog, say so and re-prompt; do not fix an off-list issue. A typed value that **is** open and `tech-debt`-labeled but carries `debt:spec-pending` or `debt:spec-active` is parked: say so, naming the label actually set so the human can tell an untouched handoff from a running or held one (e.g. "#<N> is parked pending a SPEC handoff; remove the `debt:spec-pending` label to re-surface it", or "#<N> is parked with a SPEC underway or holding it open on a recorded trigger; remove the `debt:spec-active` label to re-surface it, unless the issue records a trigger it is held on"), and re-prompt; do not fix it. The skill never auto-advances past the human's choice.

### Route by the parse

The backlog read ends here. Route by the `## Argument parsing` result; every route returns to `## Claim the fix unit` below once the pick is made:

- `top` → Read `.claude/skills/gaia/references/debt/recommend.md` now and follow its `## Recommend and present`.
- `numbers`, one number or several → Read `.claude/skills/gaia/references/debt/named.md` now and follow its `## Validate named numbers`, then `## Fix a specific issue (direct-number path)` for one number or `## Fix a named set (two or more numbers)` for two or more.

## Claim the fix unit

This runs as the **first** step after the pick above, before the Fix-time security, staleness, and spec screens and before Pre-flight isolation (branch/worktree) below. Claiming immediately after the pick, ahead of all of those steps, minimizes the window in which a peer session also picks the same ticket.

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

The label spelling is the same shared contract `.gaia/scripts/debt-count-refresh.sh` reads to exclude claimed issues from the open count. The `gh issue edit` PostToolUse hook refreshes the statusline's debt count after every claim, release, and park, so the playbook never touches the count sentinel itself.

Because the claim happens here, before the screens below, any member one of them later peels already carries `in-progress`; the peeling screen strips it.

## Fix-time security screen

Before opening any fix PR, screen **every member of the selected fix unit** (a single issue, or every issue in a confirmed batch). Apply the fail-safe security classification `.claude/agents/code-audit-frontend.md` (section B) defines, screening each member's **content**, read from the emitted `body`, machine-filed or human-filed: an issue is security-class if its content reads as a security concern (an exploitable weakness), it was a Critical, or it is secret-shaped. When in doubt, treat it as security-class.

**The screen reads content, never the dedup key's `class=` field.** `holistic/unclassified` is the expected class for most out-of-scope findings, not a security signal, so it is not a trigger; the agent definition's section B is the single source for that rule and this screen never restates a stricter one.

This screen backstops a **human-filed** security-sensitive issue and a repo that **flipped PRIVATE → PUBLIC** with security issues in its backlog; it is not a re-judgment of the machine-filed backlog.

Re-read `gh repo view --json visibility` immediately before acting (a repo can flip from PRIVATE to PUBLIC), reusing the offer-time read above when it already ran; do not add a second prompt:

- **confirmed PRIVATE** → no member peels. The whole unit, single or batch, fixes as one private PR; fixing proceeds normally.
- **PUBLIC or INTERNAL** → any member that screens security-class is **peeled** from the unit and **diverted individually**: surface a count-only pointer to the operator and wait; never auto-disclose, never auto-draft an advisory, never open a public fix PR for it. Strip its claim (`gh issue edit <n> --remove-label in-progress`) so it re-enters the open count and a peer session's offer. The remaining non-security members proceed as the (possibly smaller) unit, keeping their claims. If every member peels, there is nothing left to open a public PR for: strip every member's claim the same way, report the diverts, and stop. (Run ends here; see `## Cost record (run end)`.) The label name is generic and non-disclosing, and machine-filed security-class issues only exist in the backlog on confirmed-PRIVATE repos, so a brief label is not a disclosure concern. On a public repo, opening a `Closes #N` PR for a security issue completes a coordinated-disclosure failure, which this screen exists to prevent.

This member-level screen is the **backstop** to the offer-time exclusion in `### Offer-time reads` above: on a non-PRIVATE repo a security-class issue is already withheld from the offered batch, so this screen mainly guarantees the invariant for a member reached via **Other**.

**Its position ahead of implementation is load-bearing, not incidental.** A member peeled here has no commits, so the peel is complete once its claim is stripped. Moving this screen after the commit step of "Resolve the selected unit" would put every peel on the drop path in `### Dropping a member after its commits are written` and owe each one that section's commit-message rewrite.

A security-class issue's detail never reaches a public PR, the PR comment, or the Actions log.

## Fix-time staleness screen

Runs after the pick, the claim, and the Fix-time security screen above, and **before** the Fix-time spec screen below. It screens **every member of the selected fix unit** (a single issue, or every surviving member after the security screen peels any security-class member) by reading each member's cited code and each member's comments. Reading either needs no branch, which is why this screen sits with the other pre-isolation screens: a unit that fails here stops before any branch or worktree exists.

It runs before the spec screen because the spec screen grades the cited code. Its position ahead of implementation is load-bearing for the same reason the security screen's and the spec screen's are: a unit stopped here has no commits, so the stop owes no commit-message rewrite.

**This screen blocks.** It is not an advisory note in the run's output. On any mismatch, do not drain: release the unit and hand the decision back to the operator.

### 1. Re-verify the body's assertions against the tree

Per member, in order, and stop at the first mismatch:

1. **The dedup key's `path=` resolves.** The advisory probe in `### Staleness probe` above already annotated this; here its `status` for the member is a verdict rather than an annotation.
2. **Every `file:line` the body cites resolves to a real line in the named file**, and the line still carries what the body says is there. Reading the surrounding lines is the point: a citation that resolves to a *different* statement is worse than one that does not resolve at all, because it looks correct. Open each cited file with the Read tool, never with a shell command that names it: a cited path is body text, held to the same rule as the probe's `key.path`.
3. **Every count the fix depends on re-derives.** A body that says "41 `unowned:` entries at `<path>:239-298`" is asserting a number and a range. Re-derive both. A count the suggested fix does not depend on is not worth stopping over; a count it is built around is the fix's premise.

**On a mismatch:** report it precisely, naming the member, the assertion, and what the tree says instead. Then release the unit exactly as a controlled stop does: strip `in-progress` from every claimed member (`gh issue edit <n> --remove-label in-progress`) so the issue re-enters the open count and a peer session's offer. Do not edit the issue to repair the drift and do not proceed on a re-derived premise: which of the issue and the code is wrong is the operator's call. (Run ends here; see `## Cost record (run end)`.)

**On a batch**, a single failing member does not condemn the unit: peel that member, release its claim alone, and proceed with the survivors, the same shape the security screen's peel takes. If every member fails, the run stops as above.

### 2. Read the issue's comments

A correction is often posted as a comment while the body stands, so read each selected member's comments, **per member, not per backlog**: one call per selected member, once per run; the backlog read in `## Read and order the backlog` never reads comments.

```bash
gh issue view <n> --json comments
```

Classify what the comments say against the body, newest comment winning where two comments disagree:

- **Nothing that touches the body's claims** → the body governs; proceed.
- **A correction that supersedes part of the body** (a wrong suggested fix, a re-graded footprint class, a corrected citation) → the comment governs that part. State plainly, before implementing, which comment supersedes which part of the body, so the human sees the substitution rather than inferring it from the diff. A comment re-grading the footprint class feeds the Fix-time spec screen below as that member's footprint value, in place of the `footprint:` label. A comment is the weaker form for this one field, since re-labelling is a single `gh issue edit` that every reader sees, but a corrector who left a comment instead is still obeyed.
- **A comment reporting the fix as already implemented, already reverted, or unsafe as specified** → this is not a correction to apply, it is the issue's premise failing. Treat it exactly as a mismatch in part 1: peel or stop, release the claim, report. Rebuilding something a comment records as deliberately reverted is the single worst outcome this screen exists to prevent, and it is indistinguishable from ordinary progress in the resulting diff.

## Fix-time spec screen

Runs after the pick, the claim, the Fix-time security screen, and the Fix-time staleness screen above, and before "## Pre-flight isolation (branch vs worktree)" below. It screens **every member of the selected fix unit** (a single issue, or every surviving member of a confirmed batch) by reading each member's **cited code**. Reading cited code needs no branch, which is why this screen runs before isolation: a wholly spec-class unit hands off before any branch or worktree exists. Every surviving member reaching this point has had its citations verified and its comments read, so this screen grades against code the issue really describes, and against a footprint class a comment may already have re-graded.

**This screen owns the spec-versus-implement determination**, resolving the advisory footprint class **symmetrically**, exactly as the class is advisory for `narrow`/`wide`:

- A `footprint:spec` member the drainer judges to need **no** SPEC after reading the code → **downgrade** to `wide`/`narrow` and keep it in the unit to implement. A named set's spec hand-off keeps at most one downgraded member; step 2 of `## Fix a named set (two or more numbers)` in `debt/named.md` releases the rest.
- A `narrow`/`wide` member the drainer judges to **need** a SPEC → **upgrade**, **peel** it from the unit, and hand it off, mirroring the way the Fix-time security screen peels a security member reached via Other. The surviving members proceed as the smaller fix unit.

**For each confirmed spec-class member, do not implement.** Read `.claude/skills/gaia/references/debt/spec-handoff.md` now and follow it for that member (claim swap, handoff block, park states, release cases), then apply the stop conditions below.

**Stop conditions:**

- **Whole selected unit is spec-class** → the run **stops here**: no fix PR, no branch, no worktree. (Run ends here; see `## Cost record (run end)`.)
- **A member peeled out of a batch** → the surviving non-spec members proceed to "## Pre-flight isolation (branch vs worktree)" and a fix PR as the smaller unit.

This screen mirrors the Fix-time security screen's mechanism but is **unconditional** (visibility-independent): repo visibility has no bearing on whether a fix needs a SPEC. Like the security screen, it sits before isolation for the same reason, a divert or handoff happens before any branch exists.

Its position ahead of implementation is **load-bearing** for the same reason the security screen's is: a member peeled here has no commits, so the handoff owes no commit-message rewrite.

## Pre-flight isolation (branch vs worktree)

This section runs once per fix, single issue or batch, after the security screen, the staleness screen, and the spec screen above, and before the fix unit's branch or worktree exists. Ordering rationale: each of those three can end the run before any branch exists, the security screen by diverting a security-class fix, the staleness screen by releasing a unit whose premise no longer holds, and the spec screen by handing off a spec-class fix, so isolation runs after all three and a diverted, released, or handed-off fix never creates a worktree.

**Branch naming.** Mint the name from `.gaia/scripts/branch-name-lib.sh`, which owns GAIA's branch-naming convention; never assemble it by hand. Single-issue fix, with `<slug>` a 2-4 word reduction of the issue title: `bash .gaia/scripts/branch-name-lib.sh name debt <issue-number> --slug "<slug>"`. Batch fix, every surviving member: `bash .gaia/scripts/branch-name-lib.sh name debt <n1> <n2> ...`. A batch name carries every member, which is what lets the stale-claim reconcile above protect a non-lowest batch member past branch-cut without leaning on the age grace. Whichever isolation mode runs, including the forced worktree, pass exactly this output as the branch or worktree name.

Then isolate the fix:

> Read `.claude/skills/gaia/references/isolation.md` and apply it now, with `{{SUBJECT}}` = "this debt fix", `{{WORKER}}` = "the fix", `{{OWNER}}` = "this fix", `{{SIBLING}}` = "another task".

When `## Argument parsing` carried a stated mode, pass it as the reference's stated answer (`worktree` → the worktree answer, `branch` → the feature-branch answer): it answers the isolation question without asking. A stated mode is the operator's preference, and the logic of the run outranks it: the reference's arms that precede the question still win (a stated `branch` while HEAD is off `main` becomes a worktree), and so does the requirement below.

**An issue that must be fixed on a branch.** When any surviving member's body, or a comment the Fix-time staleness screen read, states that its fix must run on a feature branch in the main checkout rather than in a worktree, pass the reference a **required** feature-branch answer in place of any stated mode, and name the member when that overrides a stated `worktree`. When the reference returns `RESOLVED_MODE=blocked` (this session is inside a worktree, or HEAD is not on `main`), stop: release every member's claim (`gh issue edit <n> --remove-label in-progress` each), then print `#<N> must be fixed on a branch in the main checkout, which this session cannot cut from here (<the condition the reference named>); released this run's claims and stopped. Re-run /gaia-debt from the main checkout on main.` (Run ends here; see `## Cost record (run end)`.) The reference owns the decision order, the prompt, and the worktree-creation call; take the branch name it needs from the naming rule above. In worktree mode every later step, implementing the fix(es), the Quality Gate, commit, push, `gh pr create`, the Code Audit Team marker gate, and the merge, runs from inside the worktree.

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

1. Strip its claim (`gh issue edit <n> --remove-label in-progress`), so it re-enters the open count and a peer session's offer.
2. Remove its `Closes #N` line from the PR body.
3. **Rewrite every commit message on the branch that closes it**, `git commit --amend` for the tip commit and an interactive rewrite for an older one, then force-push. Step 4's rule means there is normally nothing to rewrite; read `git log --format=%B "refs/remotes/origin/<default>..HEAD"` and check anyway, because a surviving trailer reaches the squash-merge message and closes the issue as `COMPLETED` with nothing fixed, and no other step in this playbook reads commit bodies. `<default>` is the repository's default branch (`git symbolic-ref --quiet refs/remotes/origin/HEAD` with its `refs/remotes/origin/` prefix stripped, `main` when that is unset); the ref is spelled in full so a local branch or tag named `origin/<default>` cannot shadow it and hide commits from the range.

The **intended close set** is the unit as it stands after every drop: exactly the members whose `Closes #N` lines the PR body carries at merge time. *Drive the PR to merge* below verifies that the merge closed that set and nothing else.

## Drive the PR to merge

Once the PR is up, drive it straight to merge with no confirmation prompt: the fix unit (single issue or confirmed batch) was chosen up front, so this back half runs autonomously, exactly like `/update-deps` merging a dep-bump PR on a `main` run. The only things that stop the flow here are genuine blockers, a rejected push, a marker that never goes green, the audit gate's branch checkpoint or one of the fix round's stops, or any merge-wait arm other than `MERGED` or `CONFLICTING` (the arm list below states what each one does); those are reported, not worked around. On a controlled stop before merge, gate never green, rejected push, or another blocker/observable abort, strip `in-progress` from every claimed member (`gh issue edit <n> --remove-label in-progress`) so the freed issue re-enters the offer and the count. (Run ends here; see `## Cost record (run end)`, passing `--github-*` only if the PR was already opened before the stop.)

Five endings look like that controlled stop and are not it. Each keeps its claim, because the work may still be going somewhere, and `## Cost record (run end)` covers when each one's record is written. The arm list below states what each of them reports, except the branch checkpoint and the fix round's stops, which have no arm of their own. Both of those depend on who is in the session. A run is **interactive** when a human invoked `/gaia-debt` in an interactive session and is there to answer; it is **unattended** when no human is in the session, as in a headless, scheduled, or `/loop` run:

- **A `--auto` merge still queued when the poll window closes** (the `TIMEOUT` arm, exit 5). It is still progressing toward merge, so the claim stays in place until it resolves.
- **A stop at the branch checkpoint** (`wiki/concepts/PR Merge Workflow.md`, `#### The branch checkpoint`). The round's fix is pushed, the PR stays open, and the `in-progress` claim stays in place. An interactive run asks the pinned question exactly as that section's interactive path prescribes, then continues the loop on the recorded answer; an answer that ends the loop instead (stop, a new session, or one the recorder declines) ends the run there with the claim kept. An unattended run asks nothing and prints no handoff prompt: it reports the verdict, the per-round evidence, a recommendation and the next step, relayed verbatim from `bash .gaia/scripts/audit-loop-eval.sh brief --root <root>` and never paraphrased. The next step is that a human types the printed grant or accept line (copied from the bound hook's deny message, which carries it) as the whole prompt in an interactive session on that branch, then re-runs the merge workflow. A drain never grants itself rounds.
- **A stop inside the fix round** (`wiki/concepts/PR Merge Workflow.md`, `#### The fix round: fixer, verifier, gate`): a third Quality Gate failure, a second verifier failure, a second consecutive fixer no-op, or the resume rule's baseline with no fixer result and drift. Push nothing uncommitted, leave the PR open, keep the `in-progress` claim, and report the stop reason plus the run-folder paths of the round's artifacts (dispositions, baseline, fixer result, verifier output, gate logs). An interactive run then asks the human what to do, as that section prescribes for each stop; an unattended run asks nothing and prints no handoff prompt.
- **A merge wait that refused (exit 2) rather than returning a verdict.** It read nothing, so it establishes neither that the merge landed nor that it did not, and the queued merge may land moments later. Assert no state for the pull request and leave the claim in place.
- **A `CHECK_FAILED` verdict.** The merge stays queued and lands once the failing check is fixed, so the claim stays in place.

A `CLOSED` verdict is not one of them: it is read from GitHub and it is terminal, so it releases the unit exactly as the controlled stop above does.

Resolve the PR to completion through `wiki/concepts/PR Merge Workflow.md`, read it, don't merge from memory. Follow its marker handshake; do **not** substitute a bare `gh pr merge`:

- **Get a real marker for HEAD.** The local merge hook denies `gh pr merge` until the marker exists, and `--auto` cannot skip this. Run the audit loop per `wiki/concepts/PR Merge Workflow.md` `#### The audit loop unit`, with `Working root:` set to the `RESOLVED_ROOT` the `## Pre-flight isolation (branch vs worktree)` section above resolved. While subagent nesting is available the main thread dispatches `audit-loop-unit` and never spawns members itself; that page owns the member dispatch for the nesting-unavailable case and the out-of-scope bypass when the resolver names no member. Never hand-write, fake, or pre-empt the marker, an in-scope debt fix earns its marker the same way every feature PR does.
- **Post the success status yourself.** Once `wiki/concepts/PR Merge Workflow.md` `#### Posting the status last` conditions hold, run `bash .claude/hooks/post-audit-status.sh <path to a current member marker>` before merging.
  <!-- gaia:maintainer-only:start -->
- **Clear the CHANGELOG gate.** The workflow's maintainer-only CHANGELOG gate applies to debt PRs too: decide whether the fix needs an `## [Unreleased]` entry and, if so, land it on the branch before merging (re-confirm the marker still covers HEAD after the extra commit). Scrubbed from adopter bundles, so adopters never run this step.
  <!-- gaia:maintainer-only:end -->
- **Merge, then verify before cleanup.** Run `gh pr merge <N> --squash --delete-branch`; if branch protection rejects with "base branch policy prohibits the merge", add `--auto` (never `--admin` without explicit permission) so GitHub queues the merge behind the repository's remaining required checks. Then run the merge wait, `bash .gaia/scripts/pr-wait-merge.sh --pr <N>`, the bounded poll (~2-3 minutes) `wiki/concepts/PR Merge Workflow.md` (`## Post-merge verification before cleanup`) prescribes. It issues no `gh pr merge` of its own, so nothing here re-merges. One arm per verdict plus one for the exit-2 refusal, and the script's `--help` is the authority on both:

  - On `MERGED` (exit 0), proceed to the confirmed-`MERGED` steps below.
  - On `CONFLICTING` (exit 3), repair it per that page's `### Conflict found mid-wait` and run the wait again; it is not a controlled stop and costs no audit round unless the merged content names a member again.
  - On `CHECK_FAILED` (exit 4), report the failing check and return **without** cleanup, the same way as a queued merge, and keep every member's claim.
  - On `TIMEOUT` (exit 5), the window closed with the pull request still open: report "merge queued via --auto; completes when checks pass" and return **without** cleanup, since deleting the local branch, or discarding the worktree, before `MERGED` strands it against an open PR, and keep every member's claim; close-on-merge and the next fix's reconcile settle it once the merge completes.
  - On `CLOSED` (exit 6), the pull request was closed without merging, so no wait can clear it and no `Closes #N` line will ever fire: report the closure, return without cleanup, and release the unit the way any controlled stop does, stripping `in-progress` from every claimed member.
  - On exit 2 the wait refused rather than answered: report what it could not read, return without cleanup, and assert **no** state for the pull request, since nothing about it was read. Keep every member's claim, because a claim stripped over an unread pull request hands a peer session an issue whose merge may be seconds from landing.

  On confirmed `MERGED`, each member's `Closes #N` already closed its issue, and a closed issue leaves the open backlog and the count on its own, so stripping `in-progress` here is best-effort/cosmetic: `gh issue edit <n> --remove-label in-progress` for each member, ignoring failure.

  On confirmed `MERGED`, also **verify the close set**, one `gh issue view <n> --json state` per issue: every member of the **intended close set**, the members whose `Closes #N` lines the PR body carries at merge time, must read `CLOSED`, and every member dropped from the unit **after its commits were written** (`### Dropping a member after its commits are written` above) must read `OPEN`. Report any mismatch loudly, naming the issue. Such a member reading `CLOSED` was closed by a stale trailer with nothing fixed, so reopen it (`gh issue reopen <n>`), and strip `in-progress` to return it to the backlog. This check is the only step that reads the outcome rather than the intent, and the failure it catches is silent in every other direction: a wrongly-closed issue is indistinguishable from a fixed one.

  **Every other kind of drop is out of this check's scope, and reopening one would be wrong.** A member released by a pre-isolation screen, dropped at claim time to a peer session, or parked on a SPEC with either park label never reached this PR's body, because the body is written after isolation, so no trailer of this run's can close it and there is nothing here to catch. Meanwhile each of those members is legitimately closable by something else while this PR is still open: a released member is back in the backlog where a peer session may fix and merge it, and a spec-parked member closes exactly as intended when its SPEC's implementation PR merges carrying `Closes #N`. Reading `CLOSED` is the success case for those, so reopening on it would undo a real fix and, for a parked member, fight the count rule that already removed it from `openCount`. Scope the check to the post-commit drops and leave the rest alone.

  On `MERGED`, run post-merge cleanup by isolation mode:
  - **Feature-branch isolation:** `git checkout main && git pull`, `git branch -D <branch>`, `git fetch --prune`. (Run ends here; see `## Cost record (run end)`.)
  - **Worktree mode:** Read `.claude/skills/gaia/references/debt/worktree-cleanup.md` now and follow its `### Post-merge worktree cleanup (worktree-mode fixes only)` instead. It removes the worktree first and deletes the branch afterward, since a worktree-held branch cannot be deleted while the worktree stands.

  Every arm above but `MERGED` and `CONFLICTING` ends the run there (the report above and the return without cleanup); see `## Cost record (run end)`.

Each `Closes #N` line in the PR body auto-closes its issue on merge, so on a batch, the single merge closes every member issue and no separate close call is needed for any of them.

## Cost record (run end)

Every path that ends a `/gaia-debt` run appends exactly one cost record, the run-ending paths above:

- The argument parser's unrecognized-argument stop, or its misuse stop. This stop precedes the backend probe and the stale-claim reconcile, so the run read and wrote nothing before it.
- The backend probe's definitive-absent or transient/ambiguous stop.
- The validation stop: `## Validate named numbers` (`debt/named.md`) found a named number ineligible.
- The named-set security pre-filter rejecting a security-class member on a non-private repo.
- The named-set spec hand-off prompt cancelled (Cancel, Other, or a declined or dismissed prompt).
- The named-set branch-name dry-run stop: the batch branch name would exceed the branch-name limit.
- The named-set over-budget prompt cancelled (Other, or a declined or dismissed prompt).
- The named-set scorer stopping on usage or malformed input, or on unreadable input (a missing `jq` included).
- A named selection losing a member at the claim-time re-read.
- Zero remaining candidates.
- The backlog pass exiting non-zero.
- Claiming the fix unit losing the race to a peer session (single issue, or every batch member).
- The security screen diverting every member.
- The staleness screen releasing every member, whether on a body assertion that no longer holds or on a comment recording the fix as already implemented, reverted, or unsafe. This path opened no PR, so it passes no `--github-*` flags.
- Pre-flight isolation blocked: a member must be fixed on a branch in the main checkout and the session cannot cut one. This path opened no PR, so it passes no `--github-*` flags.
- The spec screen handing off: the whole-unit-spec-class case stops the run here (a per-member handoff within a surviving batch also records via this same run-end tally). This path opened no PR, so it passes no `--github-*` flags; the record correctly carries no artifact.
- Driving the PR to merge: `MERGED` cleanup, a still-queued `--auto` merge, a failed required check, a pull request closed without merging, a merge wait that refused because it read nothing, a stop at the audit gate's branch checkpoint, or a controlled stop before merge.
- Worktree mode's isolation-context continuation prompt (`debt/worktree-cleanup.md`).

The parser, validation, named-set, and named-selection claim-time stops above all end the run before a PR exists, so none of them passes `--github-*` flags.

Apply the shared tally machinery in `.claude/skills/gaia/references/cost-record.md` with `{{COMMAND}}` = `gaia-debt`. Pass-through is mode-agnostic: worktree mode reads the same URL from the same tool result, nothing about the worktree changes the call.

## Guardrails

- **One fix unit per invocation.** A single issue, a user-confirmed related batch, or an operator-named batch; the skill never auto-advances to an unrelated issue. Batching is always the user's choice: either a related batch the clustering pass recommends and the user confirms, or a batch the operator names by number, under the named-batch budget. One-at-a-time stays the explicit opt-out. Security-class issues never join a public batch, and spec-class members and, on a non-private repo, security-class members never join a named batch, forced or not.
- **A named number never drains a different issue without the operator choosing it.** There is no automatic fall-through: an unrecognized argument, an ineligible named number, and a named selection's claim-time loss each stop the run with a reason. The direct-number cluster offer's next-available option is the operator's choice, not a fall-through.
- **Deterministic ordering, never an LLM evaluator.** The order is the `--jq` sort above over severity labels and `createdAt`; no model ranks the backlog.
- **Within-band FIFO, severity-first.** Highest severity first, oldest first within a band. Cross-band fairness / anti-starvation is out of scope.
- **The skill drives the merge, never the gate.** The happy path runs start to finish with no merge-time confirmation: it resolves the fix PR to completion through the standard PR Merge Workflow's marker handshake, running `gh pr merge` only once a real marker exists for HEAD. Never bypass, fake, or pre-empt the marker, and never substitute a bare `gh pr merge` for the workflow's gate.
- **Security screen before any public PR.** A security-class selected issue diverts via the visibility gate on PUBLIC/INTERNAL; only a confirmed-PRIVATE repo fixes it as a normal fix PR.
- **Staleness screen before any implementation, and it blocks.** No member is drained on an assertion nobody re-checked, and comments are read for the selected unit only. A member whose premise no longer holds is released, never repaired in place and never drained on a re-derived premise. `## Fix-time staleness screen` above owns the checks; this recap does not restate them.
- **Spec screen before any implementation.** A confirmed spec-class member never joins a fix PR: it hands off to `/gaia-spec` and parks with `debt:spec-pending`, which the pasted spec session swaps to `debt:spec-active` once the pipeline starts; the peel is unconditional, on every repo. `debt/spec-handoff.md` owns what each park state means, why the two are equivalent to every consumer, the hand-release cases, and the abandonment rule; this recap names the swap and restates none of the rules, so the two cannot disagree.
- **Claim before contest.** `/gaia-debt` claims each selected member with the gaia-owned `in-progress` label the instant a unit is picked, ahead of every pre-isolation screen and of isolation itself, which excludes it from the open count and a peer session's offer. `## Claim the fix unit` above states that order; this recap does not restate it, so the two cannot disagree. The claim releases on a controlled stop or on any screen's peel, is best-effort cleared on merge, and is recovered by the fix-start stale-claim reconcile after an ungraceful session death. A hand-set claim on a `tech-debt` issue is **not** exempt from that reconcile; `### Reconcile stale claims` above states its scope and its liveness rule, and this recap does not restate either, so the two cannot disagree.
- **The PR body is the sole `Closes` carrier.** No commit message on the branch closes an issue, so dropping a member stays correctable by editing the PR body; a member dropped after its commits exist also gets those commit messages rewritten, and the post-merge close-set check catches a stale trailer that reaches the merge by any other route.
- **Difficulty feeds exactly one decision.** No `/gaia-debt` path requires a `difficulty:*` label to be present; the named-batch budget is difficulty's one consumer, and an ungraded issue scores as medium there.
- Use repo-relative paths only.
