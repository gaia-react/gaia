# /gaia-harden

Human-gated hardening for the policy-memory loop. `/gaia-harden` is the ONLY code path that authors or activates anything in this loop, and it runs only under explicit human invocation. For each recurring finding it judges the lowest-context-weight form that fits, checks edit-vs-new first, recommends exactly one form with rationale, and presents an approve / decline / defer / redirect choice. Nothing is authored or activated unattended.

v1 owns prose-rule create/edit end to end. Skills and deterministic checks are recommended and scaffolded only (a skill-creator handoff; a hook+script sketch), never auto-authored or auto-activated.

## Execution model, READ FIRST

Execute the playbook yourself in the current conversation. This is an interactive, human-gated flow: each candidate's approve / decline / defer / redirect choice is the human's, never the agent's. Do not dispatch a subagent to make those calls and do not auto-advance past a candidate without a human answer.

The agent never runs `git add`, `git commit`, or `git push` *during* the per-candidate flow: each approve / decline / defer lands in the working tree or the ledger (or persists nothing), and the human owns every call. After the last candidate is dispositioned, one end-of-run publish step (`## Publish approved changes (end of run)`) runs on a **main-branch run only**: if at least one approval produced a working-tree change, it branches, commits, pushes, and opens a PR so the human does not have to ask for it. It then merges only when the human approved *every* candidate this run and answers a merge prompt (never automatically); on any selective run it leaves the PR open for review. It does nothing on a non-default branch (the changes ride that branch's own PR). A decline writes one bounded entry to the machine-local, gitignored ledger and nowhere else. A defer persists nothing.

## Argument parsing

Tokenize the first whitespace-separated word of `$ARGUMENTS`:

- `review` (or empty `$ARGUMENTS`) → the full interactive flow. This is the default an empty `$ARGUMENTS` resolves to, so the statusline nudge (`Run /gaia-harden (N recurring pattern)` for one, `Run /gaia-harden (N recurring patterns)` for more) points here without carrying a `review` token.
- `list` → print the live candidates with their distinct-PR counts and the recommended form. No authoring, no prompts.
- `why` → the remainder of `$ARGUMENTS` is a `finding_class`. Explain that one candidate: the PRs it recurred on, the recommended form, and the rationale. No authoring, no prompts.

If the first token is none of `review` / `list` / `why` and `$ARGUMENTS` is non-empty, treat the whole string as if it were a `why <finding_class>` target only when it parses as a single finding_class; otherwise default to `review`.

## Fetch the live candidate list (all subcommands)

Every subcommand reads the live list from the tally primitive. Re-run it; never trust a stale count.

```bash
.gaia/cli/gaia harden-tally
```

It prints JSON to stdout:

```jsonc
{
  "candidate_count": 2,
  "window_days": 90,
  "gh_ok": true,
  "candidates": [
    {
      "finding_class": "rule/use-effect-derived-state",
      "distinct_pr_count": 4,
      "pr_numbers": [311, 314, 318, 320],
      "area_tags": ["app/components"],
      "severity_max": "warning"
    }
  ]
}
```

Bind to these fields per candidate: `finding_class`, `distinct_pr_count`, `pr_numbers`, `area_tags`, `severity_max`. The tally already drops classes a promoted rule covers and classes the decline ledger suppresses, so every entry it returns is an open candidate. Coverage detection is class-level and scope-blind in v1: a promoted rule suppresses its `finding_class` regardless of the rule's `paths:` glob, because coverage keys only on the provenance marker's `finding_class`, not on scope. `harden-tally` is network-dependent and non-fatal: a `gh` failure yields an empty candidate list rather than an error, and it always exits 0. The emitted JSON carries a `gh_ok` boolean that separates a real all-clear from a failed window read. When `gh_ok` is `false`, the merged-PR window could not be read (a `gh`/network outage), which is NOT an all-clear: report "could not read the merged-PR window; this is not an all-clear, re-run when `gh` is available" and stop, never claim no findings. (Run ends here; see `## Cost record (run end)`.) When `gh_ok` is `true` and `candidate_count` is `0`, report "no recurring findings crossed the threshold in the last 90 days" and stop. (Run ends here; see `## Cost record (run end)`.)

## Judge-the-form logic (the heart of the command)

For each candidate decide two axes and recommend EXACTLY ONE form with a one-line rationale. Bias to the lowest-context-weight form the pattern admits. Do not default to a prose rule without considering the alternatives.

### Axis 1, edit vs new (check this FIRST)

Before choosing a form, check whether an existing artifact already covers the class's territory. Grep the candidate surfaces:

```bash
grep -rln "<keywords derived from the finding_class>" .claude/rules .claude/skills .claude/hooks
```

Also check whether the quality gate (`wiki/decisions/Quality Gate.md`) already lists a step for it. If an existing rule, skill, or hook covers the territory, recommend EDITING that artifact, not creating a new one. Name the artifact to edit and what to add.

### Axis 2, which form (lowest context weight that fits)

Inspect the `finding_class` prefix and the pattern's nature:

- **Oracle-class finding** (the `finding_class` is a tool id: it starts with `react-doctor/`, `axe/`, `knip/`, or `cve/`).

  <!-- gaia:maintainer-only:start -->
  This prefix list mirrors `ORACLE_PREFIXES` in `.gaia/cli/src/schemas/finding-class.ts`; keep the two in sync, a prefix added to the code but not here is misclassified as holistic/rule and mis-routed.
  <!-- gaia:maintainer-only:end -->

  A deterministic check already exists for it. Recommend making that check BLOCKING or adding it to the quality gate, an enforcement edit, NOT a new prose rule. Point at `wiki/decisions/Quality Gate.md` and the tool's wiring (`.claude/rules/knip.md`, `.claude/rules/dep-audit.md`, the `code-audit-frontend` agent, or the relevant CI workflow). A `knip/*` class is the exception to the quality-gate route: the developer Quality Gate intentionally omits knip (see `.claude/rules/knip.md`), so route knip enforcement to the `code-audit-frontend` agent or CI, never the dev gate. Never draft prose for an oracle class.

- **Mechanizable holistic/rule pattern** (the pattern can be caught by a lint rule, a hook, or a test). Recommend a DETERMINISTIC CHECK. v1 produces a hook+script SKETCH only; it activates nothing, writes no `.claude/rules/` file for it, and claims no prune lifecycle over it.

- **A correct procedure** (the lesson is "do these steps in this order"). Recommend a SKILL via skill-creator. v1 produces a skill-creator invocation/scaffold only; it activates nothing.

- **Judgment-based pattern** (a human-judgment anti-pattern with no reliable mechanization, e.g. a holistic/rule class about a design call). Recommend a PROSE RULE. v1 OWNS this end to end: it drafts the path-scoped rule with the provenance marker into the working tree.

A `workflow/*` class (GitHub Actions supply-chain: script injection, unsafe `pull_request_target`, unpinned actions, over-broad permissions) is a closed holistic-style bucket, not an oracle id, so a workflow candidate routes through the mechanizable or judgment branches above. GitHub Actions patterns are usually mechanizable by a workflow linter (actionlint, zizmor), so the deterministic-check sketch is the default form; the member's `.github/workflows` and `.github/actions` area tags give a valid path scope when a prose rule fits better.

A `prose/*` class (instruction-prose legibility: excessive reducible length, deep nesting, high cross-reference indirection, redundant instruction) is likewise a closed holistic-style bucket, not an oracle id, so a prose candidate routes through the mechanizable or judgment branches above. Prose complexity is usually a judgment call with no reliable mechanization, so a **prose rule** or a **skill** (the correct procedure form) is the typical recommendation, not a deterministic check; the finding's `area_tags` give a valid `.claude/skills/**` path scope when a prose rule fits.

When a pattern is mechanizable, the recommendation is the deterministic check, not a skill and not a prose rule.

### Axis 3, will it earn its weight (efficacy lens)

A recurring finding proves the problem is real, the cost of NOT acting. It does not prove the chosen guidance will fix it. Before presenting, ask one question: **what cheap evidence would show this form actually changes behavior, and can I get it?**

Prose is the weakest form on this axis: it advises rather than enforces, a capable agent may already honor it or may rationalize past it, and it costs context on every matching task. A deterministic check enforces. So the efficacy lens reinforces Axis 2: when the pattern is mechanizable, prefer the check.

The evidence bar is deliberately low, a couple of before/after task replays or a single reproduction of the agent ignoring vs following the guidance, never a benchmark. If the recommended form is prose and you cannot name even that cheap evidence (because it restates a principle a strong agent already honors, or the anti-pattern is judgment-laden and easy to talk past), say so in the rationale and surface **weak efficacy evidence, consider defer until it recurs again, or decline** in the action framing. Never auto-decline, the human owns the call; the lens sharpens the recommendation and the rationale, nothing more.

### Present and act

For each candidate, present: the finding_class, its distinct-PR count and the PRs it recurred on, the recommended form, and the one-line rationale. Then offer the action set: **approve / decline / defer / redirect**. Collect that choice through an explicit user-question step, one question per candidate, and never auto-advance past a candidate without a human answer, the same way `/gaia-spec` gates each of its questions. This reinforces the "Execution model, READ FIRST" note: the call is the human's, not the agent's. The two persisting actions differ: `decline` writes a machine-local, evidence-gated ledger entry; `defer` persists nothing and simply nudges again on the next tally.

`redirect` means the engineer overrides the form choice (e.g. "make it a prose rule even though you recommended a skill"). Honor the override and run that form's action handling. Axis-2 guardrails win over a redirect, though: a redirect cannot force a prose rule for an oracle class, and a redirect toward an enforcement-edit cannot manufacture one where no existing check or quality-gate step exists.

## Per-form action handling

### approve, prose rule

Draft the rule file into the working tree using the template below. The rule is MANDATORILY path-scoped: a `paths:` frontmatter glob is always present, derived from the candidate's `area_tags`. When `area_tags` is empty or holds non-path strings (holistic classes often carry semantic tags, not path globs), fall back: derive the glob from the finding's bucket/surface (e.g. a `rule/*` React class scopes to `app/**/*`) or ask the human for the intended scope. Never write a frontmatter-less / always-loaded rule, and never emit an unscoped `**/*` glob, that defeats the path-scoping invariant that bounds per-task context weight. Immediately after the frontmatter, write the provenance marker verbatim (see the frozen marker below). Then write present-tense body prose describing the anti-pattern and the correct pattern.

After writing, tell the engineer the rule is in the working tree. Do not commit or PR here; the end-of-run publish step handles that (`## Publish approved changes (end of run)`).

### approve, edit existing prose rule

Use this handler, not the new-file path above, when Axis 1 recommended EDITING an existing rule rather than creating one. The new-file template drafts a fresh file; an edit appends to the file Axis 1 named. Reach the new-file path only for a genuinely new rule.

- **Append the new guidance to the existing rule file** Axis 1 named, under the most relevant existing `## …` section or a new `## …` heading in that same file. Body prose is present tense and follows `.claude/rules/wiki-style.md`.
- **Append a provenance marker for the newly-approved `finding_class`.** The file already carries a marker, but it names the DIFFERENT class the rule was first promoted from; this candidate surfaced precisely because no marker for ITS class exists yet. Coverage keys per-class: `covered-classes.ts` scans every marker in the file (a whole-file `matchAll`) into a `Set` keyed on the captured class, and the tally drops a class only when a marker for that exact class is present. So the second marker is REQUIRED, not redundant, it is what suppresses the newly-covered class on the next tally and drops the candidate immediately, matching the prose-approval semantics. It does not double-count: the `Set` dedupes and each marker captures a distinct class. Write the same verbatim marker (see the frozen marker below) with `<class>` set to the newly-approved `finding_class`, placed adjacent to the appended guidance. The scan is whole-file, so the marker need not be the first line after the frontmatter, that first-line placement is the new-file template's convention, not a coverage requirement.
- **Do NOT write a second frontmatter block.** Reconcile the existing `paths:` instead: union the candidate's derived glob (same derivation and empty/non-path fallback as the new-file handler, never `**/*`) into the existing frontmatter `paths:` list, adding a line only when the glob is not already covered by an entry there.
- After editing, tell the engineer the rule change is in the working tree. Do not commit or PR here; the end-of-run publish step handles that (`## Publish approved changes (end of run)`).

### approve, deterministic check

Produce ONLY a hook+script SKETCH (a proposed hook entry and a script outline the engineer can finish). Activate nothing: do not wire it into `.claude/settings.json`, do not make any file executable, and write no `.claude/rules/` file for it. Make clear the loop claims no prune lifecycle over it. Hand the sketch to the engineer to finish and wire up themselves. Because this form writes no provenance marker, the statusline nudge persists until the pattern stops recurring and ages out of the window (or a promoted rule later covers the class); it is not silenced immediately the way a prose approval is.

### approve, skill

Produce ONLY a skill scaffold; activate nothing and write no `.claude/rules/` file for it. LEAD with the plugin-free path: hand-write a `SKILL.md` scaffold, its name, description, trigger conditions, and the ordered steps, for the engineer to drop under `.claude/skills/<name>/`. The `skill-creator` skill is a convenience path only: it is plugin-provided and may be absent on an adopter machine (it is not bundled under `.claude/skills/` and neither `setup-gaia` nor `gaia-init` provisions it). When it IS present, invoke it with the captured intent (what the skill should enable, when it should trigger, the expected output) or print a ready-to-run scaffold invocation in place of hand-writing the file. Because this form writes no provenance marker, the statusline nudge persists until the pattern stops recurring and ages out of the window (or a promoted rule later covers the class); it is not silenced immediately the way a prose approval is.

### approve, enforcement edit (oracle class)

Make the existing deterministic check blocking or add it to the quality gate. This is an edit to existing enforcement wiring (the tool's rule file, the `code-audit-frontend` agent, the quality gate doc, or the CI workflow), not a new prose rule. Land the edit in the working tree; the end-of-run publish step commits and PRs it (`## Publish approved changes (end of run)`). Because this form writes no provenance marker, the statusline nudge persists until the pattern stops recurring and ages out of the window (or a promoted rule later covers the class); it is not silenced immediately the way a prose approval is.

### decline

Record one bounded entry to the machine-local ledger, passing the candidate's current distinct-PR count:

```bash
.gaia/cli/gaia harden-ledger record --finding-class "<finding_class>" --pr-count <distinct_pr_count>
```

Check the `harden-ledger record` exit code before reporting the outcome. On exit `0` the entry is written: report the machine-local decline as described below. On any non-zero exit (notably `CONFIG_INVALID` 30 for a corrupt or version-skewed ledger, or `STORAGE_INACCESSIBLE` 20) the entry was NOT recorded: tell the engineer the decline did not persist and why, and do not claim success. Because nothing was suppressed, the candidate re-surfaces on the next tally.

State that the decline is machine-local only (the ledger is gitignored) and never shared: a teammate still sees the nudge and can approve. The decline re-surfaces on evidence, the ledger handles that: the candidate returns when the window's distinct-PR count for the class rises to at least 3 above its count at the time of decline. That count is a snapshot of the rolling 90-day window, not a monotonic tally of PRs merged since the decline, so window churn (old PRs aging out) can lower it and thereby delay or indefinitely prevent re-surface. A mis-decline is reversible: re-record with a corrected count, or let `.gaia/cli/gaia harden-ledger prune` drop the entry once the class leaves the window, the undo and hygiene path for the ledger.

### defer

Persist nothing. The candidate stays in the next tally pass and ages out of the rolling 90-day window if it stops recurring and no one acts. Do not write the ledger, do not draft a file.

## The prose-rule template (fill in, then write)

Write to `.claude/rules/<slug>.md`, where `<slug>` is a short kebab-case name derived from the finding_class (e.g. `use-effect-derived-state`). Use this exact shape:

```markdown
---
paths:
  - '<glob derived from area_tags, e.g. app/components/**/*>'
---
<!-- gaia-harden: promoted from recurring finding_class <class>; pruned by /gaia-audit on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->

# <Rule Title>

<Present-tense prose: name the anti-pattern, then state the correct pattern. Follows `.claude/rules/wiki-style.md`. Describe what the rule enforces and why.>

## Anti-pattern

<the wrong shape>

## Correct pattern

<the right shape>
```

Rules for filling it in:

- **`paths:` is mandatory.** Derive the glob from the candidate's `area_tags` (e.g. an `area_tags` of `["app/components"]` becomes `app/components/**/*`). When `area_tags` is empty or holds non-path strings, fall back: derive the glob from the finding's bucket/surface (e.g. a `rule/*` React class scopes to `app/**/*`) or ask the human for the intended scope. One or more single-quoted globs, one per line. A rule with no `paths:` frontmatter is never produced, and an unscoped `**/*` glob is never emitted; path-scoping is what bounds per-task context weight regardless of how many promoted rules accumulate.
- **The provenance marker is verbatim and single-line**, placed immediately after the closing `---` of the frontmatter, with `<class>` replaced by the actual finding_class. It references the `finding_class`, never a SPEC or UAT id.
- **Body prose is present tense** and follows `.claude/rules/wiki-style.md`, which carries the authoritative ban list. Use repo-relative paths only (`.claude/rules/instruction-files.md`).

### Frozen provenance marker (PROVENANCE-MARKER CONTRACT)

The marker is this exact line, with `<class>` substituted:

```
<!-- gaia-harden: promoted from recurring finding_class <class>; pruned by /gaia-audit on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->
```

`/gaia-audit` recognizes this marker only to apply its existing obsolescence / redundancy / supersession / duplication signals without a policy-memory exemption, and to explicitly NOT treat non-recurrence as a prune signal. The marker grants no special lifecycle. Do not alter its wording: multiple binders key on it. The `covered-classes.ts` `MARKER_RE` matches its prefix (`gaia-harden: promoted from recurring finding_class`) and is deliberately tail-agnostic. `/gaia-audit` (`.claude/skills/gaia/references/audit.md`) keys on the full text.

<!-- gaia:maintainer-only:start -->
The `marker.test.ts` guard asserts every doc copy reproduces `markerComment(...)` from `.gaia/cli/src/harden/marker.ts` byte for byte. A wording change that misses any copy silently breaks one binder or the other, so the marker text lives once in `marker.ts` and every copy tracks it.
<!-- gaia:maintainer-only:end -->

## Publish approved changes (end of run)

Runs once, in `review` mode only, after the last candidate is dispositioned. `list` and `why` never reach it (they author nothing). It exists so an engineer who approved at least one change does not then have to ask for a branch and PR by hand.

**Precondition.** During the per-candidate loop, track whether any candidate was approved through a handler that writes to the working tree: **new prose rule**, **edit existing prose rule**, or **enforcement edit**. The scaffold-only handlers (deterministic-check sketch, skill scaffold) write no file and never count, and decline / defer produce no change. If no approval produced a working-tree change, there is nothing to publish: say so briefly and stop. (Run ends here; see `## Cost record (run end)`.)

**Also track an `all-approved` flag:** true when **every candidate this run was approved** (approve or redirect; a single decline or defer breaks it). It does not affect whether to publish, it gates only the merge prompt below.

**Confirm there are real changes.** Before branching, verify the working tree actually carries the edits:

```bash
git status --porcelain
```

If it is empty, no-op (a redirect or an unapplied too-invasive edit can leave the approval count and the tree disagreeing); report that nothing landed and stop. (Run ends here; see `## Cost record (run end)`.)

**Repo-state safety.** Branching needs a safe state. If HEAD is detached or a rebase / merge / cherry-pick / bisect is in progress, do not branch: leave the approved changes in the working tree, tell the engineer they ship through normal PR review, and stop. (Run ends here; see `## Cost record (run end)`.)

**On the default branch (main/master):** create the branch (the uncommitted approved edits follow the checkout), commit, push, and open a PR.

```bash
TIMESTAMP=$(date +%Y-%m-%d-%H%M)
BRANCH="chore/gaia-harden-$TIMESTAMP"
git checkout -b "$BRANCH"
git add -A
git commit -F <commit-message-file>
git push -u origin "$BRANCH"
gh pr create --title "<commit subject>" --body-file <pr-body-file>
```

Route the commit message through a file, never `-m`. Subject: `chore(harden): <the approved forms, e.g. "promote use-effect-derived-state rule">`.

The diff is expected to touch only `.claude/rules/**` and enforcement wiring, in which case the PR clears the merge gate through the PR Merge Workflow's out-of-scope bypass with no marker. Do not assume it: the approved "deterministic check" form can edit enforcement wiring including the CI workflow, an audited surface. Before `gh pr merge`, run

```bash
bash .gaia/scripts/resolve-audit-spawn.sh
```

Empty output confirms the bypass applies and no marker is owed. If it names any member, this run's diff reached an audited surface: spawn each member it names and complete the marker handshake in `wiki/concepts/PR Merge Workflow.md` like any in-scope PR.

<!-- gaia:maintainer-only:start -->
Clear the **CHANGELOG gate** per `wiki/concepts/PR Merge Workflow.md` before `gh pr create`, so the PR carries it whether it merges now or after review: a promoted policy rule that changes how the agent works usually warrants a `## [Unreleased]` entry. Scrubbed from adopter bundles.
<!-- gaia:maintainer-only:end -->

**Merge decision.** Only when the `all-approved` flag from the precondition is true (every candidate this run was approved, no decline or defer), ask once via `AskUserQuestion` whether to merge:

- **header:** `"Merge harden PR?"`
- **question:** `"You approved every candidate. Merge PR #<N> now, or leave it open for review?"`
- **options (this exact order):**
  1. `{ label: "Merge", description: "Squash-merge PR #<N> now; the earlier oracle check confirmed whether the bypass applies." }`
  2. `{ label: "Leave open", description: "Keep the PR open; you merge it after review." }`

- **Merge** → drive it to merge through `wiki/concepts/PR Merge Workflow.md` (read it, don't merge from memory): `gh pr merge <N> --squash --delete-branch --auto` (`--auto` queues behind required checks; the oracle check before `gh pr create` already confirmed whether a marker is owed for this diff), bounded-poll `gh pr view <N> --json state` for `MERGED` (~2-3 minutes), and on `MERGED` clean up (`git checkout main && git pull origin main`, `git branch -D "$BRANCH"`, `git fetch --prune origin`); if it is still queued when the poll window closes, print the PR URL, note the merge is queued, and leave the branch in place. Either way, the run ends here; see `## Cost record (run end)`.
- **Leave open** → report the PR URL and stop. (Run ends here; see `## Cost record (run end)`.)

**If the `all-approved` flag is false** (any candidate was declined or deferred), do not prompt: report the PR URL, note it is open for review, and stop. Never run `gh pr merge` on this path. (Run ends here; see `## Cost record (run end)`.)

**On any other branch:** do not branch, commit, or PR. Leave the approved changes in the working tree and tell the engineer they ride the current branch's own PR (today's behavior). The end-of-run automation targets only the main-branch case, where a branch has to be made. (Run ends here; see `## Cost record (run end)`.)

If any `git` or `gh` command above exits non-zero, print the error and STOP. Do not retry, force-push, or amend; a rejected push is the engineer's call to resolve. (Run ends here; see `## Cost record (run end)`, passing `--github-*` only if `gh pr create` already succeeded before the failure.)

## list subcommand

Run `harden-tally`, then for each candidate print one line: `finding_class`, distinct-PR count, the PRs, and the recommended form (from judge-the-form, edit-vs-new + which-form). Author nothing and prompt for nothing. (Run ends here; see `## Cost record (run end)`.)

## why subcommand

Run `harden-tally`, find the candidate whose `finding_class` matches the argument. Explain it: what the finding is, the distinct PRs it recurred on (`pr_numbers`), its max severity, the recommended form, and the rationale (including whether an existing artifact should be edited instead). If no candidate matches, say so and list the open candidates. Author nothing and prompt for nothing. (Run ends here; see `## Cost record (run end)`.)

## Cost record (run end)

Every path that ends a `/gaia-harden` run appends exactly one cost record, the run-ending paths above:

- `list` and `why` printing their result.
- The `gh_ok: false` and zero-candidate stops from the live candidate fetch.
- Publish's no-change stop (no approval touched the working tree, or `git status --porcelain` came back empty).
- Publish's unsafe-repo-state stop.
- Publish's merge outcomes: `MERGED`, still queued, "Leave open", `all-approved` false, or any other-branch no-op.
- Publish's non-zero-exit STOP on a `git` or `gh` command.

Standalone final step, one call:

```bash
bash .gaia/scripts/token-tally.sh --action command --command gaia-harden
```

**Artifact pass-through.** When this run opened a pull request and the URL `gh pr create` printed appeared in this run's own Bash tool result, append:

```bash
  --github-type pr --github-number <N> --github-repo '<owner>/<name>'
```

Never look the number up (`gh pr list`, `gh pr view`), never reuse a number from an earlier run, a different branch, or a `gh` command run outside this workflow, and never guess. If this run did not itself print a creation URL, pass no `--github-*` flags at all; the record correctly carries no artifact, and that is not an error.

**Report the line verbatim.** The tally prints exactly one line on stdout, e.g. `Cost: ~5.2M tokens, $4.12, 6m39s`. Relay it as the last line of the run's report; do not reassemble, reformat, or re-derive it.

The tally never blocks, never fails, and never turns a failed run into a successful one: it runs as a bare call with no exit-status ceremony around it. On a path that ends in an error (a rejected push, a blocked merge), record the cost, then report the failure exactly as before; recording the cost never implies success.

## Guardrails

- `/gaia-harden` is the only writer in this loop, and only under explicit human invocation. The background refresher and the audit emit never author.
- Never `git add`, `git commit`, or `git push` during the per-candidate flow. The single end-of-run publish step is the only writer to git, and only on a main-branch run with at least one approved working-tree change: it branches, commits, pushes, and opens a PR. It merges only when every candidate this run was approved and the human answers the merge prompt (never automatically); on a selective run it leaves the PR open. On a non-default branch it does nothing (the changes ride that branch's PR).
- Never auto-activate a skill or a deterministic check. v1 owns only prose-rule create/edit end to end; the other two forms are scaffold-only.
- Every drafted prose rule is mandatorily path-scoped (`paths:` frontmatter), and carries the verbatim provenance marker.
- A decline is machine-local only (gitignored ledger); it never vetoes the candidate for a teammate.
- A defer persists nothing.
- Recommend exactly one form per candidate, with rationale; check edit-vs-new first; bias to the lowest-context-weight form. Never reflexively author a prose rule.
- Factor the efficacy lens (Axis 3) into the recommendation and rationale: a recurring finding proves the problem, not the fix. When the recommended form is prose and no cheap evidence shows it would change behavior, surface that as a defer/decline signal for the human, never as an auto-decline.
- This loop keys only on `finding_class` recurrence from the PR window.
