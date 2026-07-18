# /gaia-debt

Fix the `tech-debt` backlog the audit files. `/gaia-debt` reads the open `tech-debt` issues, orders them deterministically (highest severity then oldest first, no model call), recommends the top candidate, and resolves **one fix unit** per invocation, a single issue or a user-approved related batch of issues, on a fresh branch through the same Code Audit Team marker gate every feature PR passes, with one `Closes #N` per member issue in the PR body so the merge closes every issue in the unit natively.

The ordering is a pure, source-checkable sort over the issues' severity labels and `createdAt` timestamps. It never calls a model to rank the backlog, and it never resolves more than one fix unit per run.

## Execution model, READ FIRST

Execute the playbook yourself in the current conversation. The happy path runs start to finish without stopping, exactly like `/update-deps`: once the fix unit is chosen and isolated the skill implements the fix, runs the Quality Gate, commits, pushes, opens the PR, clears the marker gate, and merges, all in one invocation. There are **up to two** up-front interactive decisions, in order: (1) the candidate/batch pick, only when the backlog holds two or more issues, and (2) the isolation-mode pick (`## Pre-flight isolation (branch vs worktree)` below), resolved through the shared isolation reference: on `main`/`master` the team's isolation policy decides whether this surfaces a prompt at all, and on any other branch it is always a silent forced worktree with no prompt. After both, the flow does not pause for confirmation. Pause only when input is genuinely needed (those two picks) or something unexpected blocks the path (a security-class diversion, a rejected push, a gate that will not go green). Resolve **one fix unit** per invocation, a single issue or a user-confirmed related batch; the skill never auto-advances to an unrelated issue.

The skill drives a fix PR through the **full** PR Merge Workflow (cut a branch, implement, run the Quality Gate, commit, push, `gh pr create`, then the marker handshake and merge). Once the PR is up it drives straight through to merge with no second confirmation, resolving the PR to completion the standard way: the same Code Audit Team marker gate every feature PR passes, then `gh pr merge`. The gate is inviolate: never bypass, fake, or pre-empt the marker, and never substitute a bare `gh pr merge` for the workflow's handshake.

## Argument parsing

Tokenize the first whitespace-separated word of `$ARGUMENTS`. Accept an optional
leading `#` on any issue-number argument below (`why`'s, `fix`'s, or the bare
form) and strip it before parsing the remainder as an integer.

- `fix` with no further token (or empty `$ARGUMENTS`) → the full interactive
  flow, recommending the top-of-backlog candidate. This is the default the
  statusline nudge (`Run /gaia-debt (N issues)`) points at.
- `list` → print the ordered backlog and stop. No branch, no PR, no prompts.
  (Run ends here; see `## Cost record (run end)`.)
- `why <issue-number>` → explain where that issue sits in the ordering, its
  recommended handler class, and the rationale, then stop. No authoring, no
  prompts. (Run ends here; see `## Cost record (run end)`.)
- `fix <issue-number>`, or a bare `<issue-number>` / `#<issue-number>` with no
  leading subcommand → fix that specific issue directly (see "## Fix a
  specific issue (direct-number path)" below).

If the first token is none of `fix` / `list` / `why` and does not parse (after
optional `#`-stripping) as a single integer, default to `fix` with no target,
the normal top-of-backlog flow.

## Backend probe

Probe the issue backend before reading the backlog. Three outcomes:

- **Definitive-absent** → report "no GitHub issues backend; /gaia-debt no-ops" and stop. Triggers: repo unresolvable, `gh` unauthenticated, Issues disabled (`gh repo view --json hasIssuesEnabled` false **or** a structurally-failing issue-list probe, **never** `gh repo view` resolution alone), or the viewer lacks write permission. (Run ends here; see `## Cost record (run end)`.)
- **Transient/ambiguous** (timeout, rate-limit, 5xx) → surface the failure and stop without action. Retrying later is safe; nothing was authored. (Run ends here; see `## Cost record (run end)`.)
- **Present** → proceed.

## Read and order the backlog (deterministic, no LLM evaluator)

Read the open backlog and order it with a pure sort. No model call ranks the backlog; the order is reproducible from this source.

### Reconcile stale claims (fix only)

This reconcile runs only in `fix`, never in `list`/`why`: it writes (it can strip a label), and those two subcommands never write. It runs **before** the backlog read below, so it recovers a claim leaked by a session that died ungracefully mid-fix before the ordering and clustering passes below ever see the backlog.

Read the current claims with a self-contained pre-pass query:

```bash
gh issue list --label tech-debt --state open --json number,labels,updatedAt
```

This query is self-contained: it runs before the backlog read below, so it does not consume that read's data, and it fetches `updatedAt`, which the backlog read's own `--json` set does not. For each returned issue carrying `debt:in-progress`, apply this liveness rule: the claim is **live** if (a) a `debt/…` branch names it (`git branch --list 'debt/*'`; the segment before a `-batch` suffix is dash-joined integers → those are all its members, else the leading integer after `debt/` is the member, so a batch branch names every member), OR (b) an open PR body contains `Closes #<n>` (`gh pr list`), OR (c) the issue's `updatedAt` is within roughly the last 30 minutes. Otherwise the claim is stale: strip it (`gh issue edit <n> --remove-label debt:in-progress`, best-effort) and touch the sentinel (`mkdir -p .gaia/local/debt && : > .gaia/local/debt/refresh-requested`).

The age grace exists because the claim lands *first*, before any branch is cut (`## Claim the fix unit` below): a just-locked issue has no branch yet, so "no branch ⇒ dead" alone would false-strip a fresh lock. A recent `updatedAt` protects that fresh lock; the branch check protects every active fix once past branch-cut, regardless of age.

This reconcile queries and strips only `debt:in-progress`. `debt:spec-pending` is a distinct, durable label parking a handed-off spec-class issue (see `## Fix-time spec screen`); this reconcile never iterates it and never strips it, spared by construction.

```bash
gh issue list --label tech-debt --state open \
  --json number,title,labels,createdAt,body \
  --jq '
    map({
      number, title, createdAt,
      sev: ([.labels[].name]
            | if   index("severity:critical")  then 3
              elif index("severity:important") then 2
              else 1 end)
    })
    | sort_by([(-.sev), .createdAt])
  '
```

How the sort works, and why it is deterministic:

- **Severity descending.** Each issue's one severity label maps to a rank: `severity:critical → 3`, `severity:important → 2`, `severity:suggestion → 1`. An issue with **no** severity label falls through the `else` branch to rank `1`, the **suggestion** band, so a human-filed fieldless issue is a valid candidate and sorts with the suggestions.
- **`createdAt` ascending within a band.** `sort_by([(-.sev), .createdAt])` sorts by negated rank first (highest severity first) then by `createdAt`. `gh` returns `createdAt` as a `Z`-normalized RFC 3339 string, so a lexicographic ascending sort is chronological ascending: of two equal-severity issues, the **older** one sorts first (FIFO within the band).

The entire ordering is this one `--jq` expression over fields GitHub returns. There is no judgment step, so `list`, `why`, and `fix` all agree on the order and anyone can reproduce it by re-running the command.

After the sort, run a second deterministic pass that clusters the ordered backlog into related groups. No model call ranks or clusters the backlog: clustering is a pure function of parsed fields, exactly like the sort. It never changes the sort order, it only groups issues within it, so `list`, `why`, and `fix` all agree on the clusters too. The clustering **function** is identical across all three; only `fix`'s **input** differs, because it filters in-progress issues out of the backlog before clustering (below), so its offered clusters can legitimately differ from what `list`/`why` display over the unfiltered backlog.

Parse each issue's dedup key from its `body`, the `<!-- gaia-debt-key: v1 class=<finding_class> path=<repo-relative-posix-path> line=<integer> -->` comment defined by `.claude/skills/file-tech-debt/SKILL.md` step 1, into `class` and `path`. A keyless human-filed issue falls back to the same `<path>:<line>` body scan `file-tech-debt/SKILL.md` step 2.3 uses to recover a `path`; if no path is parseable at all, the issue does not cluster and stands alone.

Two issues belong to the same cluster when either holds, strongest signal first:

1. **Same `path`.** Byte-identical dedup-key `path=` values. Fixing two defects in one file is the canonical case for fixing them together.
2. **Same seeded `class` and same directory.** Identical `class=` values whose `path` share the same `dirname` (immediate parent directory), the same root-cause pattern in one subsystem. The `class` must be a **real seeded class**: the fallback sentinel `holistic/unclassified` (`OUT_OF_SCOPE_FALLBACK_FINDING_CLASS`) never satisfies this rule. Two issues that both fall back to the sentinel share no root-cause signal, only the absence of one, so pairing it with a shared directory is just clustering on the directory, which the next paragraph rejects. A backlog whose issues all carry the sentinel therefore clusters on rule 1 alone, and rule 2 starts contributing on its own once real classes are seeded.

A shared directory alone is too weak to cluster on (a whole `app/services/` directory is not one fix); only same-`path` or same-seeded-`class`-plus-same-dirname cluster. A **cluster is a batch candidate only when it has 2 or more members**; a singleton fixes the normal one-issue way. Clustering is security-blind: it never looks at severity, security-classification, or repo visibility, those are handled where the batch is offered (below).

**In-progress exclusion (fix only).** `fix` derives an `inProgress` flag per issue from the `labels` field the ordering query above already fetches (true when the issue carries `debt:in-progress`) and excludes every in-progress issue from both the candidate pool and the clustering pass above: an in-progress issue neither offers itself as a candidate nor drags a sibling into a batch. `fix` derives a `specPending` flag the same way (true when the issue carries `debt:spec-pending`) and excludes every handed-off issue from the candidate pool and the clustering pass exactly as `debt:in-progress` issues are excluded: this is the "leaves the re-offer pool" half of the parked-state contract (the debt-count half lives in `.gaia/scripts/debt-count-refresh.sh`). `list` still shows in-progress and spec-pending issues and `why` still reports them, annotated `[spec pending]` (see below); only `fix`'s candidate set narrows.

## Fix a specific issue (direct-number path)

Runs only when Argument parsing above resolved a direct issue-number target:
bare `<issue-number>`, `#<issue-number>`, or `fix <issue-number>`. It runs
after the Backend probe and Read-and-order-the-backlog passes above (reconcile,
ordering, and clustering already ran), and it replaces "## Recommend and
present (fix)" below for this invocation, except on the two fall-through paths
noted inline.

**Validate the target.** Look up `<issue-number>` in the ordered, clustered
backlog already fetched above. If present there, its `inProgress` flag is
already derived from `labels`; skip to Eligible. If absent, disambiguate with
a single targeted call, `gh issue view <issue-number> --json state,labels,title`
(mirrors the claim-time re-check in "## Claim the fix unit" below), to tell
apart: the issue doesn't exist, it's CLOSED, or it's open but not
`tech-debt`-labeled.

**Ineligible** (doesn't exist, closed, not `tech-debt`-labeled, already
carries `debt:in-progress`, or already carries `debt:spec-pending`) → state
the specific reason in one line (e.g. `"#<N> is already closed"`, `"#<N>
doesn't carry the tech-debt label"`, `"#<N> is already being fixed by another
session"`, `"#<N> is parked pending a SPEC handoff"`), then fall through to
"## Recommend and present (fix)" below exactly as if no argument had been
passed.

**Eligible** (open, `tech-debt`-labeled, not in-progress, not parked) →
resolve which cluster, if any, anchors it, reusing the same clustering pass
and the same offer-time security read (`gh repo view --json visibility`) "##
Recommend and present (fix)" defines below (one read, never a second prompt):

- **Heads a public-batch-eligible cluster of 2 or more** → one `AskUserQuestion`
  prompt (header `Debt item`, single-select), same shape as the batch offer
  below, anchored on the passed issue:
  1. `Batch #<N> #<B> #<C> (Recommended)` — shared signal, member count,
     severity span, "one branch, one PR, all close on merge."
  2. `#<N> only` — fix just the passed issue, one at a time.
  3. `Next available highest-priority item(s) instead` — picking this falls
     through to "## Recommend and present (fix)" below, over the full
     backlog, exactly as if no argument had been passed.
  - The built-in **Other** entry still lets the human type any open
    `tech-debt` issue number to fix that one alone.
- **Singleton (no cluster), security-class on a non-PRIVATE repo, or
  spec-class (any repo)** → no prompt: proceed straight to fixing `#<N>`
  alone, the same nothing-to-decide rule "## Recommend and present (fix)"
  applies to a lone remaining candidate. A spec-class `#<N>` (from its body
  `Handler: spec` line) is never anchored or batched, mirroring the
  security-class singleton rule. The Fix-time security screen below still
  screens and, if needed, diverts a security-class `#<N>` exactly as it would
  for any other selected issue, and it still proceeds to "## Claim the fix
  unit" so the Fix-time spec screen catches a spec-class `#<N>` and hands it
  off.

Whatever this section resolves to, hand off to "## Claim the fix unit" below
the same way "## Recommend and present (fix)" does.

## Recommend and present (fix)

Skipped when "## Fix a specific issue (direct-number path)" above already resolved the pick; runs otherwise. The top candidate is the first in the sorted list. Before building the prompt, resolve which cluster, if any, anchors the recommendation.

**Offer-time security read.** Clustering itself is security-blind, but a security-class issue can never share a public `Closes #N` PR, so the offer is not. Before presenting, read repo visibility once: `gh repo view --json visibility`. On a **confirmed-PRIVATE** repo every cluster is public-batch-eligible as-is. On any **non-PRIVATE** repo, apply the same fail-safe security classification the Fix-time security screen (below) defines to every candidate issue in the backlog, and treat any security-class issue as not public-batch-eligible: it never appears inside a batch option, only as its own single candidate. Reuse this one read for the Fix-time security screen after selection; it never becomes a second prompt.

**Offer-time spec read.** Detect each remaining candidate's `Handler: spec` line from its `body` (already fetched). Unlike the security read, this check is **unconditional**: no `gh repo view --json visibility` gate, because repo visibility has no bearing on whether a fix needs a SPEC. A spec-class issue is withheld from every batch option, on every repo, and offered only as its own single candidate. A single spec-class member never forces its batch to a SPEC handoff; its `prompt`/`plan` siblings still batch normally by the max-over-members rule.

The **recommended batch**, when one exists, is the top cluster all of whose members are public-batch-eligible: normally the cluster containing the top-ranked candidate, but a security-class top candidate is never public-batch-eligible on a non-PRIVATE repo, and a spec-class top candidate is never batch-eligible on any repo, so either anchors no batch and is offered only as its own single candidate. An eligible batch may span severities, a `severity:suggestion` in the same file as a `severity:important` is a cheap add-on.

How you present the choice depends on backlog size and cluster shape, counted over the **remaining candidates** (open issues after the in-progress exclusion above), not the raw open-issue count:

- **Zero remaining candidates** (every open `tech-debt` issue already carries `debt:in-progress` or `debt:spec-pending`) → do not prompt. State that every open `tech-debt` issue is already in progress or parked pending a SPEC, and stop. (Run ends here; see `## Cost record (run end)`.)
- **Exactly one remaining candidate** → do not prompt. State the issue (number, title, severity band, age derived from `createdAt`) and fix it directly. This is also the peer-session case: two open issues, one already claimed, fixes the single remaining candidate with no prompt.
- **Top candidate heads a public-batch-eligible cluster of 2 or more** → a batch is recommended. Offer it with a single `AskUserQuestion` prompt (header `Debt item`, single-select), phrased around the batch, for example: `"Top item #<A> is related to <N> other issue(s) (<shared signal>). Fix them together, or one at a time?"`. Options, top option carrying `(Recommended)`:
  1. `Batch #<A> #<B> #<C> (Recommended)`, description: the shared signal (e.g. "all in app/foo/index.ts"), the member count, the severity span, and "one branch, one PR, all close on merge."
  2. `#<A> only`, description: fix just the top issue (its severity band, its age), one at a time.
  3. (optional) the next distinct candidate slot: a batch option when that candidate itself heads a >= 2 cluster, else a single option.
  - The tool's built-in **Other** entry lets the human type any open `tech-debt` issue number to fix that one alone.
- **Top candidate is a singleton (no cluster), or a security-class top candidate on a non-PRIVATE repo** → present exactly today's shape: the top three candidates as options (or both when only two exist), top candidate first and its label suffixed `(Recommended)`. Any shown candidate that itself heads a public-batch-eligible cluster of 2 or more is presented as a **batch** option rather than a single, which keeps one-at-a-time the default natural path.

Cap the option set at **4** (plus the built-in Other), the `AskUserQuestion` maximum. When the backlog is deeper than the shown options, first print the full ordered backlog (per issue: number, title, severity band, age), now annotated with cluster membership (e.g. `[batch with #B #C]`), so numbers beyond the shown options are visible before choosing.

**Opt-out guarantee.** One-at-a-time stays an explicit, always-available choice: the `#<A> only` option, the built-in Other (type any open issue number to fix it alone), and the unchanged singleton path together guarantee it. A batch is always a recommendation the human approves, never a default that skips the choice.

**Security-class members never appear inside a public batch option.** On a non-PRIVATE repo the offer-time read above already withholds them, they surface only as single candidates. On a confirmed-PRIVATE repo they may appear as batch members.

**Spec-class members never appear inside a batch option, on any repo.** The offer-time spec read above withholds them unconditionally; unlike the security peel, this hold never relaxes on a confirmed-PRIVATE repo.

Honor whatever the human picks or types into **Other**. If a typed value is not an open `tech-debt` issue number in the backlog, say so and re-prompt; do not fix an off-list issue. A typed value that **is** open and `tech-debt`-labeled but carries `debt:spec-pending` is parked: say so (e.g. "#<N> is parked pending a SPEC handoff; remove the `debt:spec-pending` label to re-surface it") and re-prompt; do not fix it. The skill never auto-advances past the human's choice.

## Claim the fix unit

This runs in `fix` only, as the **first** step after the pick above, before the Fix-time security screen and before Pre-flight isolation (branch/worktree) below. Claiming immediately after the pick, ahead of either of those steps, minimizes the window in which a peer session also picks the same ticket.

Ensure the label exists, idempotently:

```bash
gh label create debt:in-progress --color <hex> 2>/dev/null || true
```

The `debt:` namespace is load-bearing: a `debt:`-prefixed label is gaia-owned by convention, the same way `severity:critical` is, so the reconcile above never strips a label a human set by hand.

Then, for a single issue or **every member of a confirmed batch**:

1. **Re-read each member's labels** (`gh issue view <n> --json labels`) before claiming. If `debt:in-progress` is already present, a peer session won the race:
   - **single issue** → report "issue #N was just claimed by another session" and re-present the refreshed backlog; do not fix it. (Run ends here; see `## Cost record (run end)`.)
   - **batch** → drop that member and proceed with the surviving members if 1 or more remain; if none remain, report the whole batch was claimed and re-present the refreshed backlog. (The none-remain case ends the run here; see `## Cost record (run end)`.)

   If `debt:spec-pending` is present instead, the member is parked pending a SPEC handoff, mirroring the `debt:in-progress` branch above exactly:
   - **single issue** → report "#<N> is parked pending a SPEC handoff" and re-present the refreshed backlog; do not fix it. (Run ends here; see `## Cost record (run end)`.)
   - **batch** → drop that member and proceed with the surviving members if 1 or more remain; if none remain, report and re-present the refreshed backlog. (The none-remain case ends the run here; see `## Cost record (run end)`.)

   This re-read is the universal choke point every selection path (recommend, direct-number, Other) reaches after the pick, so it backstops the offer-time spec read and the direct-number ineligible list the same way it backstops the offer-time security read and the in-progress exclusion: a parked issue is caught no matter how it was selected.
2. **Claim every surviving member**: `gh issue edit <n> --add-label debt:in-progress`. A confirmed batch claims all of its members, not just the top one.
3. **Touch the sentinel** (`mkdir -p .gaia/local/debt && : > .gaia/local/debt/refresh-requested`) so a peer session's next statusline tick recomputes the open count and drops it. This in-flow touch is best-effort; the `gh issue edit` PostToolUse hook is the deterministic backstop.

The label spelling is the same shared contract `.gaia/scripts/debt-count-refresh.sh` reads to exclude claimed issues from the open count.

Because the claim happens here, before the security screen below, any member that screen later peels and diverts already carries `debt:in-progress`; that screen strips it.

## Fix-time security screen

Before opening any fix PR, screen **every member of the selected fix unit** (a single issue, or every issue in a confirmed batch). Apply the fail-safe security classification `.claude/agents/code-audit-frontend.md` (section B) defines, screening each member's **content**, machine-filed or human-filed: an issue is security-class if its content reads as a security concern (an exploitable weakness), it was a Critical, or it is secret-shaped. When in doubt, treat it as security-class.

**The screen reads content, never the dedup key's `class=` field.** `holistic/unclassified` is the expected class for most out-of-scope findings, not a security signal, so it is not a trigger; the agent definition's section B is the single source for that rule and this screen never restates a stricter one. A screen keyed on `class=holistic/unclassified` would peel the entire backlog on a public repo and leave `/gaia-debt` permanently unable to fix anything.

Because the audit's own filing screen already ran, the set of issues this screen can actually peel is small and well-defined: on a PUBLIC or INTERNAL repo the audit **never files a security-class finding as an issue** in the first place, so every machine-filed issue in a public backlog is non-security by construction. This screen is therefore a backstop for exactly two cases: a **human-filed** issue that is security-sensitive, and a repo that **flipped PRIVATE → PUBLIC** while previously-filed security issues sat in its backlog. It is not a re-judgment of the machine-filed backlog.

Re-read `gh repo view --json visibility` immediately before acting (a repo can flip from PRIVATE to PUBLIC), reusing the offer-time read above when it already ran; do not add a second prompt:

- **confirmed PRIVATE** → no member peels. The whole unit, single or batch, fixes as one private PR; fixing proceeds normally.
- **PUBLIC or INTERNAL** → any member that screens security-class is **peeled** from the unit and **diverted individually**: surface a count-only pointer to the operator and wait; never auto-disclose, never auto-draft an advisory, never open a public fix PR for it. Strip its claim (`gh issue edit <n> --remove-label debt:in-progress`) and touch the sentinel so it re-enters the open count and a peer session's offer. The remaining non-security members proceed as the (possibly smaller) unit, keeping their claims. If every member peels, there is nothing left to open a public PR for: strip every member's claim the same way, report the diverts, and stop. (Run ends here; see `## Cost record (run end)`.) The label name is generic and non-disclosing, and security-class issues only exist in the backlog on confirmed-PRIVATE repos, so a brief label is not a disclosure concern. On a public repo, opening a `Closes #N` PR for a security issue completes a coordinated-disclosure failure, which this screen exists to prevent.

This member-level screen is the **backstop** to the offer-time exclusion in "Recommend and present" above: on a non-PRIVATE repo a security-class issue is already withheld from the offered batch, so this screen mainly guarantees the invariant for a member reached via **Other**.

A security-class issue's detail never reaches a public PR, the PR comment, or the Actions log.

## Fix-time spec screen

Runs after the pick, the claim, and the Fix-time security screen above, and before "## Pre-flight isolation (branch vs worktree)" below. It screens **every member of the selected fix unit** (a single issue, or every surviving member of a confirmed batch) by reading each member's **cited code**. Reading cited code needs no branch, which is why this screen runs before isolation: a wholly spec-class unit hands off before any branch or worktree exists.

**This screen owns the spec-versus-implement determination**, resolving the advisory `Handler` line **symmetrically**, exactly as the Handler line is advisory for `prompt`/`plan`:

- A `Handler: spec` member the drainer judges to need **no** SPEC after reading the code → **downgrade** to `plan`/`prompt` and keep it in the unit to implement.
- A `prompt`/`plan` member the drainer judges to **need** a SPEC → **upgrade**, **peel** it from the unit, and hand it off, mirroring the way the Fix-time security screen peels a security member reached via Other. The surviving members proceed as the smaller fix unit.

**For each confirmed spec-class member, do not implement.** Instead:

1. **No-orphan claim swap (MIG-002).** Ensure the label exists idempotently (`gh label create debt:spec-pending --color <hex> 2>/dev/null || true`), then **add `debt:spec-pending` before removing `debt:in-progress`** (`gh issue edit <n> --add-label debt:spec-pending` then `gh issue edit <n> --remove-label debt:in-progress`), so a mid-swap failure never strands the issue label-less. The `debt:` namespace makes the label gaia-owned by convention, the same way `debt:in-progress` is, so the reconcile above never strips it.
2. **Touch the debt-count sentinel** (`mkdir -p .gaia/local/debt && : > .gaia/local/debt/refresh-requested`) so the count refreshes; the parked issue leaves `openCount`.
3. **Print a single copy-pasteable `/gaia-spec` handoff block**, carrying the originating issue number `#<N>` so the eventual implementation PR can `Closes #<N>`:

   ```
   /gaia-spec Design-first tech debt from issue #<N>: <one-line problem>. Author a
   SPEC for this fix; the implementation PR the resulting plan produces should carry
   `Closes #<N>` so the tech-debt issue closes on merge.
   ```

**Stop conditions:**

- **Whole selected unit is spec-class** → the run **stops here**: no fix PR, no branch, no worktree. (Run ends here; see `## Cost record (run end)`.)
- **A member peeled out of a batch** → the surviving non-spec members proceed to "## Pre-flight isolation (branch vs worktree)" and a fix PR as the smaller unit.

**Hard constraints.** `/gaia-debt` never invokes `/gaia-spec`, never dispatches a spec author, and never reads the SPEC template or `plan.md`. Authoring or saving the SPEC does not close the issue, and this handoff issues **no** close call; the issue closes only when the implementation the SPEC's plan produces merges (via `Closes #<N>` on that PR).

This screen mirrors the Fix-time security screen's mechanism but is **unconditional** (visibility-independent): repo visibility has no bearing on whether a fix needs a SPEC. Like the security screen, it sits before isolation for the same reason, a divert or handoff happens before any branch exists.

## Pre-flight isolation (branch vs worktree)

This section runs once per fix, single issue or batch, after the security screen and the spec screen above and before the fix unit's branch or worktree exists. Ordering rationale: the security screen can divert and stop a security-class fix, and the spec screen can hand off and stop a spec-class fix, before any branch exists, so isolation runs after both and a diverted or handed-off fix never creates a worktree.

**Branch naming.** Single-issue fix: `debt/<issue-number>-<slug>` (`<slug>` a 2-4 word kebab-case reduction of the issue title). Batch fix: `debt/<members-joined-by-dash>-batch`, members ascending, e.g. `debt/42-45-47-batch`: naming every member lets `git branch --list` (in the reconcile above) protect non-lowest batch members past branch-cut without leaning on the age grace. Whichever isolation mode runs, including the forced worktree, the branch carries this name.

Then isolate the fix:

> Read `.claude/skills/gaia/references/isolation.md` and apply it now, with `{{SUBJECT}}` = "this debt fix", `{{WORKER}}` = "the fix", `{{OWNER}}` = "this fix", `{{SIBLING}}` = "another task".

The reference owns the decision order, the prompt, and the worktree-creation call; take the branch name it needs from the naming rule above. In worktree mode every later step, implementing the fix(es), the Quality Gate, commit, push, `gh pr create`, the Code Audit Team marker gate, and the merge, runs from inside the worktree.

## Resolve the selected unit

The **fix unit** is the selected (non-diverted) member set: a single issue, or every surviving member of a confirmed batch after the security screen above peels any security-class member. It is still **one fix unit per invocation**.

1. **Confirm the handler class for the unit.** Each member issue carries an advisory `Handler: prompt`, `Handler: plan`, or `Handler: spec`, or, for a fieldless human-filed issue, no line at all; the full vocabulary is three-valued (`prompt` | `plan` | `spec`). The **spec-versus-implement** determination is owned by the Fix-time spec screen above, before isolation: by the time this step runs, every surviving member is `prompt`/`plan` (a spec-class member was either downgraded and kept, or peeled and handed off there). This step grades **prompt-versus-plan** the same way as today: `prompt` when confined to one file with no public-contract change and no cross-module ripple, `plan` otherwise. The unit's effective class is the **maximum** over members: `plan` if any member is `plan` (or any fix is cross-module / contract-changing), else `prompt`. A multi-issue batch is usually `plan`. State the honest class before implementing so the human knows the scope, exactly as today's single-issue rule does.
2. **The unit is already isolated.** `## Pre-flight isolation (branch vs worktree)` above already cut the branch or created the worktree before this step, on the frozen name (`debt/<issue-number>-<slug>` single, `debt/<members-joined-by-dash>-batch` batch). This step does no branch creation of its own.
3. **Implement all fixes in the unit** on the one branch, following the project's normal conventions (TDD, surgical changes).
4. **Run the Quality Gate** (`.claude/rules/quality-gate.md`) once for the combined diff, then commit and push.
5. **Open one PR** with `gh pr create`. The PR body includes **one `Closes #N` line per member issue** (GitHub's auto-close keyword) so the single merge closes every issue in the unit natively. Security-class detail still never reaches a public PR: a security-class issue is either withheld from the offered batch or peeled and diverted by the screen above, so no security-class member ever reaches a public `Closes #N` PR.

The PR is an ordinary in-scope source change: it passes the **same** Code Audit Team marker gate as any feature PR, one gate for the combined diff. Let the normal gate produce a real marker; do not bypass, fake, or pre-empt it. Getting that marker and completing the merge are covered under *Drive the PR to merge* below.

## Touch the debt-count sentinel

After opening the PR, set the staleness sentinel **once per fix** (not once per member issue in a batch) so the statusline recomputes the open count on the next tick:

```bash
mkdir -p .gaia/local/debt && : > .gaia/local/debt/refresh-requested
```

**Create the parent dir first.** On a fresh clone or in CI no statusline tick has run, so `.gaia/local/debt/` may not exist and a bare `touch` would fail silently and leave the sentinel unset. The deterministic merge-event sentinel-set is owned by the `gh pr merge` PostToolUse hook; when the skill drives the merge that hook fires in-session, and on an open-PR-only run or a queued `--auto` merge the merge lands later, so this in-conversation touch is best-effort belt-and-suspenders.

## Drive the PR to merge

Once the PR is up, drive it straight to merge with no confirmation prompt: the fix unit (single issue or confirmed batch) was chosen up front, so this back half runs autonomously, exactly like `/update-deps` merging a dep-bump PR on a `main` run. The only things that stop the flow here are genuine blockers, a rejected push, a marker that never goes green, or a `--auto` merge still queued when the poll window closes; those are reported, not worked around. On a controlled stop before merge, gate never green, rejected push, or another blocker/observable abort, strip `debt:in-progress` from every claimed member (`gh issue edit <n> --remove-label debt:in-progress`) and touch the sentinel, so the freed issue re-enters the offer and the count. (Run ends here; see `## Cost record (run end)`, passing `--github-*` only if the PR was already opened before the stop.) A `--auto` merge still queued when the poll window closes is not this case: it is still progressing toward merge, so its claim stays in place until it resolves (below).

Resolve the PR to completion through `wiki/concepts/PR Merge Workflow.md`, read it, don't merge from memory. Follow its marker handshake; do **not** substitute a bare `gh pr merge`:

- **Resolve the audit mode** for the PR author with the workflow's portable helper (`.gaia/scripts/read-audit-ci-config.sh --resolve-author <login>`). This reads the project's own `.gaia/audit-ci.yml` (team `default_mode` plus per-author overrides), so the flow obeys an adopter's config instead of assuming the maintainer's CI.
- **Get a real marker for HEAD.** In `ci` mode, wait for CI's `GAIA-Audit` success status (a `pending` status is not a marker, and `--auto` cannot skip this: the local merge hook denies `gh pr merge` until the marker exists). In `local` mode, or when the audit workflow is absent, resolve the spawn set with `bash .gaia/scripts/resolve-audit-spawn.sh` and run each named member as the producer of its own marker, dispatched with the `RESOLVED_ROOT` the `## Pre-flight isolation (branch vs worktree)` section above already resolved, interpolated into the same self-checked Task template `wiki/concepts/PR Merge Workflow.md`'s "Spawn the dispatched Code Audit Team members" section defines; on a clean pass each writes its marker and posts the success status. CI runs the default member only, so a diff that dispatches a specialized member always needs a local spawn for that member regardless of mode. If the whole diff is out of audit scope (the oracle names no member), the workflow's out-of-scope bypass clears the merge with no marker. Never hand-write, fake, or pre-empt the marker, an in-scope debt fix earns its marker the same way every feature PR does.
  <!-- gaia:maintainer-only:start -->
- **Clear the CHANGELOG gate.** The workflow's maintainer-only CHANGELOG gate applies to debt PRs too: decide whether the fix needs an `## [Unreleased]` entry and, if so, land it on the branch before merging (re-confirm the marker still covers HEAD after the extra commit). Scrubbed from adopter bundles, so adopters never run this step.
  <!-- gaia:maintainer-only:end -->
- **Merge, then verify before cleanup.** Run `gh pr merge <N> --squash --delete-branch`; if branch protection rejects with "base branch policy prohibits the merge", add `--auto` (never `--admin` without explicit permission) so GitHub queues the merge behind the remaining required checks (Tests, Chromatic). Bounded-poll `gh pr view <N> --json state` for `MERGED` (~2-3 minutes). If it is still queued when the poll window closes, report "merge queued via --auto; completes when checks pass" and return **without** cleanup: deleting the local branch, or discarding the worktree, before `MERGED` strands it against an open PR.

  On confirmed `MERGED`, each member's `Closes #N` already closed its issue, and a closed issue leaves the open backlog and the count on its own, so stripping `debt:in-progress` here is best-effort/cosmetic: `gh issue edit <n> --remove-label debt:in-progress` for each member, ignoring failure. A queued `--auto` merge that has not yet landed is still in progress: leave its claim in place; close-on-merge and the next fix's reconcile settle it once the merge completes.

  On `MERGED`, run post-merge cleanup by isolation mode:
  - **Feature-branch isolation:** unchanged. `git checkout main && git pull`, `git branch -D <branch>`, `git fetch --prune`. (Run ends here; see `## Cost record (run end)`.)
  - **Worktree mode:** run Post-merge worktree cleanup below instead. Do not `git branch -D` a worktree-held branch.

  If it is still queued when the poll window closes, the run also ends there (the report above and the return without cleanup); see `## Cost record (run end)`.

Each `Closes #N` line in the PR body auto-closes its issue on merge, so on a batch, the single merge closes every member issue and no separate close call is needed for any of them.

### Post-merge worktree cleanup (worktree-mode fixes only)

1. Confirm merge via `gh pr view <N> --json state`; require `.state == "MERGED"`. If not merged, do not proceed; surface and stop.
2. **Isolation-context check** (below). If running inside an isolated subagent context, emit the continuation prompt and stop; do not call `ExitWorktree`.
3. Otherwise call `ExitWorktree({action: "remove", discard_changes: true})` directly. `discard_changes: true` is safe: the squash-merge absorbed every commit on the worktree branch, but those commits are not ancestors of `main`, so the runtime would otherwise refuse; the merged-state confirmation in step 1 proves the work is preserved.
4. Report one line: `worktree discarded; PR #<N> squash-merged as <short-sha>`.

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
        git branch -D <branch-name>   # only if the merge did not already delete it

(Run ends here; see `## Cost record (run end)`.)

Do not emit an `ExitWorktree({...})` call in this continuation prompt. `ExitWorktree` only operates on a worktree created by `EnterWorktree` in the current session: from a fresh session it is a no-op on a prior-session worktree, and its schema requires `action` and rejects a `worktree` parameter. A plain `git worktree remove --force` is the correct session-independent cleanup. This matches `plan.md`'s Isolation-context detection block, whose continuation prompt emits the same session-independent shell cleanup.

## list subcommand

Run the ordering command above, then the clustering pass, and print the backlog in sorted order: per issue, the number, title, severity band, age, cluster membership when it has any (e.g. `[batches with #B #C: same file app/foo/index.ts]`), `[in progress]` when the issue carries `debt:in-progress`, `[needs spec]` when its body carries a `Handler: spec` line and it does not carry `debt:spec-pending`, and `[spec pending]` when it carries `debt:spec-pending`. The two spec annotations key on distinct signals, the body line versus the label, so an un-drained spec-class issue is never conflated with a handed-off one. `list` shows every open issue, including in-progress and spec-pending ones: it does not exclude them and it does not reconcile stale claims. Author nothing and prompt for nothing.

## why subcommand

Run the ordering command and the clustering pass, find the issue whose number matches the argument. Explain it: where it sits in the ordering (its severity band and its position among equal-severity issues by age), its recommended handler class (the issue's advisory `Handler:` line, or your on-the-fly classification for a fieldless issue), and the rationale. Also report whether it is part of a related cluster, which issue(s) it would batch with, and the shared signal (same `path`, or same `class` and dirname). Also report the issue's claim status: whether it currently carries `debt:in-progress` (in progress) or not; `why` does not reconcile stale claims. For a spec-class issue (body `Handler: spec`), also report its spec routing ("routes through /gaia-spec") and, symmetrically, whether it carries `debt:spec-pending` (already handed off) or not. If no open `tech-debt` issue matches the number, say so and print the ordered backlog. Author nothing and prompt for nothing.

## Cost record (run end)

Every path that ends a `/gaia-debt` run appends exactly one cost record, the run-ending paths above:

- `list` and `why` printing their result.
- The backend probe's definitive-absent or transient/ambiguous stop.
- Zero remaining candidates.
- Claiming the fix unit losing the race to a peer session (single issue, or every batch member).
- The security screen diverting every member.
- The spec screen handing off: the whole-unit-spec-class case stops the run here (a per-member handoff within a surviving batch also records via this same run-end tally). This path opened no PR, so it passes no `--github-*` flags; the record correctly carries no artifact.
- Driving the PR to merge: `MERGED` cleanup, a still-queued `--auto` merge, or a controlled stop before merge.
- Worktree mode's isolation-context continuation prompt.

Standalone final step, one call:

```bash
bash .gaia/scripts/token-tally.sh --action command --command gaia-debt
```

**Artifact pass-through.** When this run opened a pull request and the URL `gh pr create` printed appeared in this run's own Bash tool result, append:

```bash
  --github-type pr --github-number <N> --github-repo '<owner>/<name>'
```

Pass-through is mode-agnostic: worktree mode reads the same URL from the same tool result, nothing about the worktree changes the call.

Never look the number up (`gh pr list`, `gh pr view`), never reuse a number from an earlier run, a different branch, or a `gh` command run outside this workflow, and never guess. If this run did not itself print a creation URL, pass no `--github-*` flags at all; the record correctly carries no artifact, and that is not an error.

**Report the line verbatim.** The tally prints exactly one line on stdout, e.g. `Cost: ~5.2M tokens, $4.12, 6m39s`. Relay it as the last line of the run's report; do not reassemble, reformat, or re-derive it.

The tally never blocks, never fails, and never turns a failed run into a successful one: it runs as a bare call with no exit-status ceremony around it. On a path that ends in an error (a rejected push, a blocked merge), record the cost, then report the failure exactly as before; recording the cost never implies success.

## Guardrails

- **One fix unit per invocation.** A single issue, or a user-confirmed related batch; the skill never auto-advances to an unrelated issue and never batches unrelated issues. Batching is always a user-confirmed choice, with one-at-a-time preserved as the explicit opt-out. Security-class issues never join a public batch.
- **Deterministic ordering, never an LLM evaluator.** The order is the `--jq` sort above over severity labels and `createdAt`; no model ranks the backlog.
- **Within-band FIFO, severity-first.** Highest severity first, oldest first within a band. Cross-band fairness / anti-starvation is out of scope.
- **The skill drives the merge, never the gate.** The happy path runs start to finish with no merge-time confirmation: it resolves the fix PR to completion through the standard PR Merge Workflow's marker handshake, running `gh pr merge` only once a real marker exists for HEAD. Never bypass, fake, or pre-empt the marker, and never substitute a bare `gh pr merge` for the workflow's gate.
- **Security screen before any public PR.** A security-class selected issue diverts via the visibility gate on PUBLIC/INTERNAL; only a confirmed-PRIVATE repo fixes it as a normal fix PR.
- **Spec screen before any implementation.** A confirmed spec-class member never joins a fix PR: it hands off to `/gaia-spec` and parks with `debt:spec-pending`; the peel is unconditional, on every repo.
- **Claim before contest.** `/gaia-debt fix` claims each selected member with the gaia-owned `debt:in-progress` label the instant a unit is picked, before the security screen and isolation, which excludes it from the open count and a peer session's offer. The claim releases on a controlled stop or a security divert, is best-effort cleared on merge, and is recovered by the fix-start reconcile after an ungraceful session death. The `debt:`-namespaced label is gaia-owned, so reconcile only ever strips `debt:in-progress`, never a human-set label.
- Use repo-relative paths only.
