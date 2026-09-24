# /gaia-harden

Human-gated hardening for the policy-memory loop. `/gaia-harden` is the ONLY code path that authors or activates anything in this loop, and it runs only under explicit human invocation. For each recurring finding it judges the lowest-context-weight form that fits, checks edit-vs-new first, and recommends exactly one action with rationale. It explains every item in plain language, presents the whole recommended plan once, and asks the human to accept it, change some items, or stop. Nothing is authored or activated unattended.

v1 owns prose-rule create/edit end to end. Skills and deterministic checks are recommended and scaffolded only (a skill-creator handoff; a hook+script sketch), never auto-authored or auto-activated.

## Execution model, READ FIRST

Execute the playbook yourself in the current conversation. This is an interactive, human-gated flow. The invariant is **no disposition without an explicit human answer**: every candidate's approve / decline / defer / redirect outcome comes from the human, never the agent. Accepting the presented plan as a whole is one explicit answer and counts for every item it covers. Do not dispatch a subagent to make these calls, and do not apply any disposition before the human has answered.

The agent never runs `git add`, `git commit`, or `git push` *while dispositions are collected and applied*: each approve / decline / defer lands in the working tree or the ledger (or persists nothing), and the human owns every call. After the last candidate is dispositioned, one end-of-run publish step (`## Publish approved changes (end of run)`) carries any approved working-tree change through a PR, and merges only on the human's answer. A decline writes one bounded entry to the machine-local, gitignored ledger and nowhere else. A defer persists nothing of its own. Besides the decline ledger, a completed review writes one more machine-local file, the review snapshot, and clears the cached statusline nudge; see `## Record the review (end of run)`.

## Argument parsing

Tokenize the first whitespace-separated word of `$ARGUMENTS`:

- `review` (or empty `$ARGUMENTS`) → the full interactive flow. This is the default an empty `$ARGUMENTS` resolves to, so the statusline nudge points here without carrying a `review` token. The nudge text is today's count form (`Run /gaia-harden (N recurring pattern)` for one, `Run /gaia-harden (N recurring patterns)` for more) only on a clone with no review snapshot; after a completed review it instead names the trigger (`tally changed`, `N new pattern(s)`, `<class> rising` for up to two distinct labels (the last path segment of each class name, so classes sharing one render once), then `+N more`, `unclassified rising`), and it stays silent while nothing has changed since that review. See `wiki/concepts/Policy-Memory Loop.md` for the trigger model.
- `list` → print the live candidates with their distinct-PR counts and the recommended form. No authoring, no prompts.
- `why` → the remainder of `$ARGUMENTS` is a `finding_class`. Explain that one candidate: the PRs it recurred on, the recommended form, and the rationale. No authoring, no prompts.

If the first token is none of `review` / `list` / `why` and `$ARGUMENTS` is non-empty, treat the whole string as if it were a `why <finding_class>` target only when it parses as a single finding_class; otherwise default to `review`.

## Fetch the live candidate list (all subcommands)

Every subcommand reads the live list from the tally primitive. Re-run it; never trust a stale count.

In `review` mode, save the tally to a file and read it from there, since the end-of-run Record section needs the same run's tally:

```bash
mkdir -p .gaia/local/harden && .gaia/cli/gaia harden-tally > .gaia/local/harden/review-tally.json
```

`list` and `why` keep the plain call and write nothing:

```bash
.gaia/cli/gaia harden-tally
```

A structured `malformed_snapshot` error on stderr means the prior review snapshot is ignored for this run's triggers; the next completed review replaces it. It prints JSON to stdout:

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
      "severity_max": "warning",
      "is_oracle": false
    }
  ],
  "unclassified": {
    "distinct_pr_count": 3,
    "pr_numbers": [401, 405, 409],
    "area_tags": ["app/routes"],
    "severity_max": "suggestion"
  },
  "audited_pr_count": 400,
  "tally_schema_version": 1,
  "class_inventory": [
    {"finding_class": "holistic/a", "distinct_pr_count": 40}
  ],
  "unclassified_window_count": 120,
  "snapshot_present": true,
  "snapshot_reviewed_at": "2026-09-18T10:00:00.000Z",
  "triggers": [
    {"type": "schema_change"},
    {"type": "new_class", "finding_class": "holistic/c"},
    {"type": "rising_class", "finding_class": "holistic/drifting-duplicate"},
    {"type": "rising_unclassified"}
  ]
}
```

- `audited_pr_count`: the window's audited-PR denominator, the count decline and snapshot records bind as `--audited-pr-count`.
- `tally_schema_version`: the tally's counting-semantics version; a mismatch against the review snapshot is the `schema_change` trigger.
- `class_inventory`: every non-fallback class counted at least once in the window, below-threshold included.
- `unclassified_window_count`: the classless fallback count, even below its own signal threshold.
- `snapshot_present` / `snapshot_reviewed_at`: whether a schema-valid review snapshot was read, and when it was recorded.
- `triggers`: what changed against the last completed review's snapshot; empty when there is no snapshot or `gh_ok` is `false`.

`unclassified` is `null` when no classless cluster has crossed the recurrence threshold; otherwise it carries `distinct_pr_count`, `pr_numbers`, `area_tags`, and `severity_max` for that one cluster.

Bind to these fields per candidate: `finding_class`, `distinct_pr_count`, `pr_numbers`, `area_tags`, `severity_max`, `is_oracle`. Also bind the top-level `unclassified` field (an object or `null`, see below). The tally already drops classes a promoted rule covers and classes the decline ledger suppresses, so every entry it returns is an open candidate. Coverage detection is class-level and scope-blind in v1: a promoted rule suppresses its `finding_class` regardless of the rule's `paths:` glob, because coverage keys only on the provenance marker's `finding_class`, not on scope. `harden-tally` is network-dependent and non-fatal: it always exits 0, and the emitted `gh_ok` boolean separates a real all-clear from a window it did not fully read. Branch on the result:

- **`gh_ok` is `false`**: the merged-PR window could not be read (a `gh`/network outage), which is NOT an all-clear. Report "could not read the merged-PR window; this is not an all-clear, re-run when `gh` is available" and stop, never claim no findings. (Run ends here; see `## Cost record (run end)`.)
- **`gh_ok` is `true`, `candidate_count` is `0`, `unclassified` is `null`**: report "no recurring findings crossed the threshold in the last 90 days". In `review` mode, before stopping, run the combined record-and-clear block from `## Record the review (end of run)` as one Bash call: shell variables do not persist across separate calls, so the record and the clear must run together. On a non-zero `record_status`, report it the way that section says (quote the structured error code); either way this stop does not proceed to Publish. `list`/`why` stop as today, writing nothing. (Run ends here; see `## Cost record (run end)`.)
- **`gh_ok` is `true`, `candidate_count` is `0`, `unclassified` is non-null**: do NOT stop. Skip judging and the plan question (there is no candidate to disposition) and go straight to `## Unclassified recurrence signal (seed-a-class-or-investigate)` below, which in `review` mode flows on to `## Record the review (end of run)`.
- **Otherwise**: judge every candidate (below), then present the plan and ask once (`### Present the plan, then ask once`).

## Judge-the-form logic (the heart of the command)

For each candidate decide two axes and recommend EXACTLY ONE form with a one-line rationale. Bias to the lowest-context-weight form the pattern admits. Do not default to a prose rule without considering the alternatives.

### Axis 1, edit vs new (check this FIRST)

Before choosing a form, check whether an existing artifact already covers the class's territory. Grep the candidate surfaces:

```bash
grep -rln "<keywords derived from the finding_class>" .claude/rules .claude/skills .claude/hooks
```

Also check whether the quality gate (`wiki/decisions/Quality Gate.md`) already lists a step for it. If an existing rule, skill, or hook covers the territory, recommend EDITING that artifact, not creating a new one. Name the artifact to edit and what to add.

### Axis 2, which form (lowest context weight that fits)

Inspect the candidate's `is_oracle` flag and the pattern's nature:

- **Oracle-class finding** (if `harden-tally` flags the candidate's `is_oracle` true, its `finding_class` is a tool id owned by a deterministic tool).

  A deterministic check already exists for it. Recommend making that check BLOCKING or adding it to the quality gate, an enforcement edit, NOT a new prose rule. Point at `wiki/decisions/Quality Gate.md` and the tool's wiring (`wiki/dependencies/knip.md`, `wiki/dependencies/pnpm-audit.md`, the `code-audit-frontend` agent, or the relevant CI workflow). A `knip/*` class is the exception to the quality-gate route: the developer Quality Gate intentionally omits knip (see `wiki/dependencies/knip.md`), so route knip enforcement to the `code-audit-frontend` agent or CI, never the dev gate. Never draft prose for an oracle class.

- **Mechanizable holistic/rule pattern** (the pattern can be caught by a lint rule, a hook, or a test). Recommend a DETERMINISTIC CHECK. v1 produces a hook+script SKETCH only; it activates nothing, writes no `.claude/rules/` file for it, and claims no prune lifecycle over it.

- **A correct procedure** (the lesson is "do these steps in this order"). Recommend a SKILL via skill-creator. v1 produces a skill-creator invocation/scaffold only; it activates nothing.

- **Judgment-based pattern** (a human-judgment anti-pattern with no reliable mechanization, e.g. a holistic/rule class about a design call). Recommend a PROSE RULE. v1 OWNS this end to end: it drafts the path-scoped rule with the provenance marker into the working tree.

A `workflow/*` class (GitHub Actions supply-chain: script injection, unsafe `pull_request_target`, unpinned actions, over-broad permissions) is a closed holistic-style bucket, not an oracle id, so a workflow candidate routes through the mechanizable or judgment branches above. GitHub Actions patterns are usually mechanizable by a workflow linter (actionlint, zizmor), so the deterministic-check sketch is the default form; the member's `.github/workflows` and `.github/actions` area tags give a valid path scope when a prose rule fits better.

A `prose/*` class (instruction-prose legibility: excessive reducible length, deep nesting, high cross-reference indirection, redundant instruction) is likewise a closed holistic-style bucket, not an oracle id, so a prose candidate routes through the mechanizable or judgment branches above. Prose complexity is usually a judgment call with no reliable mechanization, so a **prose rule** or a **skill** (the correct procedure form) is the typical recommendation, not a deterministic check; the finding's `area_tags` give a valid `.claude/skills/**` path scope when a prose rule fits.

When a pattern is mechanizable, the recommendation is the deterministic check, not a skill and not a prose rule.

### Axis 3, will it earn its weight (efficacy lens)

A recurring finding proves the problem is real, the cost of NOT acting. It does not prove the chosen guidance will fix it. Before presenting, ask one question: **what cheap evidence would show this form actually changes behavior, and can I get it?**

Prose is the weakest form on this axis: it advises rather than enforces, a capable agent may already honor it or may rationalize past it, and it costs context on every matching task. A deterministic check enforces. So the efficacy lens reinforces Axis 2: when the pattern is mechanizable, prefer the check.

The evidence bar is deliberately low, a couple of before/after task replays or a single reproduction of the agent ignoring vs following the guidance, never a benchmark. If the recommended form is prose and you cannot name even that cheap evidence (because it restates a principle a strong agent already honors, or the anti-pattern is judgment-laden and easy to talk past), say so in the rationale and make the recommended action **defer** (a snooze until the class rises materially or the tally changes) or **decline**, whichever the evidence supports. It stays a recommendation: nothing is declined or deferred until the human answers, and accepting the plan is that answer. The lens sharpens the recommendation and the rationale, nothing more.

### Explain each item in plain language

The human gate is only worth its cost if the human can judge what they are approving. A class slug, a PR list, and a rationale in this reference's own vocabulary (axis, oracle, efficacy lens, form, marker) are not judgeable by someone who did not write them. So every candidate, and the unclassified signal, is explained in plain terms first, and the taxonomy comes second. `review`, `list`, and `why` all use this rendering.

Per item, lead with:

- **What keeps going wrong.** One sentence, no class slug, no reference vocabulary. For example: "Docs and comments describe how a script behaves, and the description no longer matches what the script does."
- **One concrete example**: the file and what was wrong there. The findings block carries no prose, so the example comes from a `gaia-debt-key` comment (`<!-- gaia-debt-key: v1 class=<finding_class> path=<path> line=<int> -->`, `.claude/skills/file-tech-debt/SKILL.md` step 1) whose `class=` equals the item's class exactly. Do not use `gh`'s full-text search for this: it tokenizes on `/`, which every class contains (`file-tech-debt/SKILL.md` step 2). Parse the keys locally instead, and stop at the first exact match:
  1. The tech-debt issues, read once per run and reused for every item: `gh issue list --label tech-debt --state all --limit 1000 --json number,title,body`. A matching issue's title and body state the defect.
  2. The item's own PRs: `gh pr view <n> --json body` for up to the five most recent numbers in its `pr_numbers`. On a match, the bullet the key comment sits under states the defect.

  For the unclassified signal, match `class=holistic/unclassified`. When neither step finds a match, write "no recorded example" rather than guessing one from a PR title.
- **How often, as a share**: `distinct_pr_count` of `audited_pr_count` over the `window_days` window, with a rounded ratio, e.g. "on 106 of the last 394 audited PRs, about 1 in 4". Never a bare count.
- **What the recommendation would actually do**, in plain words:
  - new prose rule: "add a rule file that loads when editing `<paths>`"
  - edit existing prose rule: "add this guidance to `<file>`"
  - enforcement edit: "make the existing `<tool>` check block the merge"
  - deterministic check: "write an outline of an automated check for you to finish; nothing is switched on"
  - skill: "write an outline of a skill for you to finish; nothing is switched on"
  - decline: "record, on this machine only, that we are not acting on this; it comes back if it gets noticeably worse"
  - defer: "do nothing now; it comes back if it gets worse or the counting changes"
- **Why this recommendation**, in one sentence a non-author can check against the example and the frequency.

Then, as secondary detail: the `finding_class`, the `pr_numbers`, and `severity_max`.

### Present the plan, then ask once

Present the whole plan before asking anything. Print one summary table, one row per candidate in tally order, with columns: row number, what keeps going wrong, how often, recommended action (plain words), and why. When `unclassified` is non-null, add it as a final row marked **not a candidate**, with "record a suppression; the signal returns if it rises materially" as its action (`## Unclassified recurrence signal (seed-a-class-or-investigate)` below owns what that means). Print each row's example and secondary detail below the table, keyed by row number.

Then ask one question through an explicit user-question step (`AskUserQuestion`, header `Harden plan`, single-select), options in this order:

1. **Accept all recommendations (Recommended)**: every candidate takes its recommended action.
2. **Change some**: pick which rows to change, then choose their actions; every other row takes its recommendation.
3. **Stop without changes**: disposition nothing, author nothing, record nothing.

On **Change some**, ask which rows to change. Only candidate rows are selectable: the unclassified row carries no disposition, so it keeps its suppression unless the human chooses **Stop without changes**. With four or fewer candidates, use one multi-select `AskUserQuestion` naming each row; with more, ask the human to reply with the row numbers. Then, for each chosen row only, ask one single-select question with the action set **approve / decline / defer / redirect**, the recommended action first and marked `(Recommended)`. `AskUserQuestion` takes up to four questions per call, so group them in fours. Any row the human did not choose takes its recommendation.

On **Stop without changes**, apply nothing, write no ledger entry, skip the unclassified suppression, and do not reach `## Record the review (end of run)` or `## Publish approved changes (end of run)`. (Run ends here; see `## Cost record (run end)`.)

Once every candidate has a disposition, from the plan answer or a per-row answer, apply each one through `## Per-form action handling` below, in table order.

Accepting a recommended decline or defer is a decision, the same as choosing it row by row. The two persisting actions differ: `decline` writes a machine-local, evidence-gated ledger entry; `defer` persists nothing of its own, but the review snapshot a completed review writes still snoozes it until the class rises materially or the tally's counting changes, the same trigger rule that governs every other candidate; it still appears in `list` and in the next review.

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

Produce ONLY a hook+script SKETCH (a proposed hook entry and a script outline the engineer can finish). Activate nothing: do not wire it into `.claude/settings.json`, do not make any file executable, and write no `.claude/rules/` file for it. Make clear the loop claims no prune lifecycle over it. Hand the sketch to the engineer to finish and wire up themselves.

### approve, skill

Produce ONLY a skill scaffold; activate nothing and write no `.claude/rules/` file for it. LEAD with the plugin-free path: hand-write a `SKILL.md` scaffold, its name, description, trigger conditions, and the ordered steps, for the engineer to drop under `.claude/skills/<name>/`. The `skill-creator` skill is a convenience path only: it is plugin-provided and may be absent on an adopter machine (it is not bundled under `.claude/skills/` and neither `setup-gaia` nor `gaia-init` provisions it). When it IS present, invoke it with the captured intent (what the skill should enable, when it should trigger, the expected output) or print a ready-to-run scaffold invocation in place of hand-writing the file.

### approve, enforcement edit (oracle class)

Make the existing deterministic check blocking or add it to the quality gate. This is an edit to existing enforcement wiring (the tool's rule file, the `code-audit-frontend` agent, the quality gate doc, or the CI workflow), not a new prose rule. Land the edit in the working tree; the end-of-run publish step commits and PRs it (`## Publish approved changes (end of run)`).

**No provenance marker (deterministic-check / skill / enforcement-edit forms).** These three approve handlers author no `.claude/rules/` marker, but they no longer leave the statusline nudge persisting on their own: the completed review still snapshots the class the way it snapshots every other candidate, so the nudge returns only on a trigger (the class rises materially, or the tally's counting changes), not on every tally the way it used to. It is not silenced by a promoted-rule coverage marker the way a prose approval is, but the review snapshot governs it on the same terms as decline and defer.

### decline

Record one bounded entry to the machine-local ledger, passing the candidate's current distinct-PR count:

```bash
.gaia/cli/gaia harden-ledger record --finding-class "<finding_class>" --pr-count <distinct_pr_count> --audited-pr-count <audited_pr_count>
```

Check the `harden-ledger record` exit code before reporting the outcome. On exit `0` the entry is written: report the machine-local decline as described below. On any non-zero exit (notably `CONFIG_INVALID` 30 for a corrupt or version-skewed ledger, or `STORAGE_INACCESSIBLE` 20; `record` itself never exits `2`, that code is `is-suppressed`'s for a malformed call) the entry was NOT recorded: tell the engineer the decline did not persist and why, and do not claim success. Because nothing was suppressed, the candidate re-surfaces on the next tally. A failed decline write does not halt the review: the run continues to the next candidate and, after the last one, proceeds through the unclassified section to `## Record the review (end of run)`, so the snapshot still records; the declined-but-unsuppressed class simply reappears in the next review.

State that the decline is machine-local only (the ledger is gitignored) and never shared: a teammate still sees the nudge and can approve. The decline re-surfaces on evidence, the ledger handles that: the candidate returns once the rise from the count recorded at decline to the live count is material, the same share-based material-rise rule that governs every other trigger (see `wiki/concepts/Policy-Memory Loop.md`), with a floor requiring at least 3 more distinct PRs, and measured against the same tally schema version. An entry recorded before this rule existed, or under a different schema version, is a legacy entry and never suppresses; re-decline it to restore a suppression under the live rule. A mis-decline is reversible: re-record with a corrected count, or let `.gaia/cli/gaia harden-ledger prune` drop the entry once the class leaves the window, the undo and hygiene path for the ledger.

`.gaia/local` is shared across a clone's linked worktrees, so a sibling worktree still on an older GAIA reads the version-2 ledger as invalid: its `is-suppressed` fails the ledger load and exits `CONFIG_INVALID` 30 before it looks up any entry, and its bridge maps every exit other than `1` to suppressed. Every class is then suppressed in that worktree, not only the declined ones: the failure is closed (nothing is wrongly re-surfaced) but it is silent. `/gaia-harden` itself refuses to run inside a linked worktree (`gaia_refuse_if_worktree` in `.claude/commands/gaia-harden.md`), so no review ever runs there to report that all-clear; what actually happens in the worktree is the background refresher's own `harden-tally` call, filtered through the same suppressed-everything bridge, silently dropping every candidate from the statusline nudge until the worktree updates. A review reporting the all-clear only happens when the main checkout itself is the one still running the older GAIA. An older refresher (`.gaia/scripts/check-updates.sh`) running from such a worktree also rewrites the shared cache without the `hardenNudgeReason` key, so the statusline falls back to the count text until an updated refresher next runs.

### defer

Persist nothing of its own: do not write the ledger, do not draft a file. The review snapshot a completed review writes still snoozes the candidate on the same trigger rule as any other, until the class rises materially or the tally's counting changes. It never hides the candidate from `list` or from the next review; it only silences the statusline nudge until a trigger fires.

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
- **Body prose is present tense** and follows `.claude/rules/wiki-style.md`, which carries the authoritative ban list. Use repo-relative paths only.
- **Verify every path, script, and owner the rule cites before writing it.** Open each file and confirm it holds what the sentence says it holds. A rule that names the wrong owner teaches the wrong thing, and fixing it after the audit costs a whole extra round.
<!-- gaia:maintainer-only:start -->
- **Keep release-excluded citations inside a maintainer-only block** in any rule that ships (`.gaia/release-exclude` lists them, for example `.gaia/cli/src/**` and `.gaia/tests/**`). Visible, they dangle on an adopter clone and the release scrub's leak check flags them.
<!-- gaia:maintainer-only:end -->

### Frozen provenance marker (PROVENANCE-MARKER CONTRACT)

The marker is this exact line, with `<class>` substituted:

```
<!-- gaia-harden: promoted from recurring finding_class <class>; pruned by /gaia-audit on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->
```

`/gaia-audit` recognizes this marker only to apply its existing obsolescence / redundancy / supersession / duplication signals without a policy-memory exemption, and to explicitly NOT treat non-recurrence as a prune signal. The marker grants no special lifecycle. Do not alter its wording: multiple binders key on it. The `covered-classes.ts` `MARKER_RE` matches its prefix (`gaia-harden: promoted from recurring finding_class`) and is deliberately tail-agnostic. `/gaia-audit` (`.claude/skills/gaia/references/audit.md`) keys on the full text.

<!-- gaia:maintainer-only:start -->
The `marker.test.ts` guard asserts every doc copy reproduces `markerComment(...)` from `.gaia/cli/src/harden/marker.ts` byte for byte. A wording change that misses any copy silently breaks one binder or the other, so the marker text lives once in `marker.ts` and every copy tracks it.
<!-- gaia:maintainer-only:end -->

## Unclassified recurrence signal (seed-a-class-or-investigate)

Runs once in `review` mode, after the last candidate is dispositioned (or immediately, skipping straight here, when `candidate_count` was `0`). This section sits outside the approve/decline/defer/redirect dispositions above.

When `unclassified` is `null`, skip this section silently and proceed to `## Record the review (end of run)`.

When `unclassified` is non-null, present it to the engineer as a distinct signal, separate from any candidate: the closed finding_class vocabulary may be missing something, or the cluster warrants investigation on its own. Render it the way `### Explain each item in plain language` above renders an item; when there were candidates, the plan table already carried it as its final row, so refer back to that row rather than repeating it. State explicitly:

- It is NEVER placed in the draftable candidate set. `/gaia-harden` NEVER drafts a path-scoped rule, a deterministic-check sketch, a skill scaffold, or any other artifact for it.
- It carries no approve / decline / defer / redirect action; there is nothing to ask the engineer to disposition here.
- Seeding a class does **not** reclassify the cluster's findings. The tally buckets each finding on the literal class string its pull request recorded, so a finding written down as classless stays classless until it ages out of the window. Seeding reaches forward only, to what a member assigns next.
- Because of that, the signal carries a **suppression**, recorded the way a decline is: `.gaia/cli/gaia harden-ledger record --finding-class holistic/unclassified --pr-count <distinct_pr_count> --audited-pr-count <audited_pr_count>`, passing the count the signal currently carries. The signal falls silent, and it returns on the same share-based material-rise rule as every other trigger (see `wiki/concepts/Policy-Memory Loop.md`), with the same distinct-PR floor, measured against the same tally schema version. Only the baseline is a stored snapshot; the live count it is compared against is read from the rolling 90-day window each time, so window churn as old pull requests age out can lower the live share and thereby delay or indefinitely prevent the return. A baseline recorded at the wrong count is corrected by recording again with the right one, and the `### decline` prune undo reaches this entry on the same terms as any other: once the classless cluster stops recurring at the threshold, the prune drops the baseline with it, so the next unrelated classless cluster is measured from zero rather than from a high-water mark nothing in the window still supports.
- The suppression is machine-local: the ledger is gitignored and per-clone (the state registry shares one copy across a clone's worktrees), so it silences the nudge for the maintainer who records it while the change it discharges is committed and shared. Every other clone keeps seeing the nudge until the cluster ages out.
- The nudge is rendered by the statusline from the reason the refresher caches, which `## Record the review (end of run)` clears at once. To confirm the record landed without waiting, read the ledger directly: `.gaia/cli/gaia harden-ledger list`.

Then proceed to `## Record the review (end of run)`.

## Record the review (end of run)

Runs once, in `review` mode only, after the last candidate is dispositioned and `## Unclassified recurrence signal (seed-a-class-or-investigate)` has run. An abandoned run, one where a candidate was left without an answer or the human chose **Stop without changes**, never reaches this section and writes nothing. `list`, `why`, and a `gh_ok` false fetch never reach it either.

Record the snapshot from this run's own start-of-run tally (the file `## Fetch the live candidate list` saved), then, only on exit `0`, clear the cached nudge so the next statusline render stops showing it (model on `.claude/skills/gaia/references/audit.md`'s cache-bust, main-root-resolved, jq with an `rm -f` fallback). Run both as one Bash call: shell variables do not persist across separate calls.

```bash
.gaia/cli/gaia harden-ledger snapshot record --tally-file .gaia/local/harden/review-tally.json
record_status=$?
if [ "$record_status" -eq 0 ]; then
  CACHE_ROOT="$(bash .gaia/scripts/main-root-lib.sh 2>/dev/null || git rev-parse --show-toplevel)"
  CACHE="$CACHE_ROOT/.gaia/local/cache/shared/update-check.json"
  if [ -f "$CACHE" ]; then
    if command -v jq >/dev/null 2>&1; then
      tmp="$(mktemp)"
      jq '.hardenNudgeReason = "" | .checkedAt = 0' "$CACHE" > "$tmp" && mv "$tmp" "$CACHE"
    else
      rm -f "$CACHE"
    fi
  fi
fi
```

On a non-zero `record_status`, the snapshot did NOT record: report that the review is complete but its snapshot did not, quoting the structured error code (`PAYLOAD_VALIDATION_FAILED` 11 means the saved tally was refused, malformed or read from a `gh_ok: false` run; `STORAGE_INACCESSIBLE` 20 means the saved tally could not be read); the block above already skips the cache clear in that case. Either way, continue to `## Publish approved changes (end of run)` regardless. A failed record never blocks publishing, and a publish failure never undoes a snapshot that did record.

## Publish approved changes (end of run)

Runs once, in `review` mode only, after `## Record the review (end of run)`. `list` and `why` never reach it (they author nothing). It exists so an engineer who approved at least one change does not then have to ask for a branch and PR by hand.

**Precondition.** While applying the dispositions, track whether any candidate was approved through a handler that writes to the working tree: **new prose rule**, **edit existing prose rule**, or **enforcement edit**. The scaffold-only handlers (deterministic-check sketch, skill scaffold) write no file and never count, and decline / defer produce no change. If no approval produced a working-tree change, there is nothing to publish: say so briefly and stop. (Run ends here; see `## Cost record (run end)`.)

**Confirm there are real changes.** Before branching, verify the working tree actually carries the edits:

```bash
git status --porcelain
```

If it is empty, no-op (a redirect or an unapplied too-invasive edit can leave the approval count and the tree disagreeing); report that nothing landed and stop. (Run ends here; see `## Cost record (run end)`.)

**Repo-state safety.** Branching needs a safe state. If HEAD is detached or a rebase / merge / cherry-pick / bisect is in progress, do not branch: leave the approved changes in the working tree, tell the engineer they ship through normal PR review, and stop. (Run ends here; see `## Cost record (run end)`.)

**On the default branch (main/master):** publish runs to a terminal state, the way `/update-deps` does on a main-branch run: merged and cleaned up, left open because the human chose to, or stopped on a named failure. It never ends at "PR opened, audit pending", because nothing else ever dispatches the audit a harden PR owes.

**Create the branch, as its own Bash call.** The uncommitted approved edits follow the checkout. Mint the name first and carry its output as a literal, `<HARDEN_BRANCH>`, into every later call, since shell variables do not persist between calls:

```bash
bash .gaia/scripts/branch-name-lib.sh name chore gaia-harden
```

```bash
git checkout -b "<HARDEN_BRANCH>"
```

Never fold this into the commit call. The main-branch guard reads a whole command before any of it runs, so a `git checkout -b … && git commit …` call still looks like a commit on `main` and is refused.

<!-- gaia:maintainer-only:start -->
**Clear the obligations a rule file carries**, before `gh pr create`. Each is invisible in the diff. The first two apply only to a new rule file:
- **Tier it in the audit partition** per `.claude/rules/maintainers/hook-registration.md`. Nearly always merely-shared, which needs no entry; this is a judgment call no check enforces.
- **Answer distribution** through `/distribution-audit`, which regenerates `.gaia/manifest.json`. The distribution pre-flight refuses `gh pr create` for a newly-shipping file with no ship-or-withhold answer.
- **Keep release-excluded citations out of a shipped rule's visible body** (see `## The prose-rule template (fill in, then write)`, its filling rules).
<!-- gaia:maintainer-only:end -->

**Commit and push, then open the PR, as two calls.** Route the commit message through a file, never `-m`. Subject: `chore(harden): <the approved forms, e.g. "promote use-effect-derived-state rule">`.

```bash
git add -A && git commit -F <commit-message-file> && git push -u origin <HARDEN_BRANCH>
```

```bash
gh pr create --title "<commit subject>" --body-file <pr-body-file>
```

<!-- gaia:maintainer-only:start -->
**Clear the CHANGELOG gate** per `wiki/concepts/PR Merge Workflow.md` in a follow-up commit, now that the PR number exists for its `(#<PR>)` reference, and push it before any audit dispatch anchors on HEAD. A promoted policy rule that changes how the agent works usually warrants a `## [Unreleased]` entry.
<!-- gaia:maintainer-only:end -->

**Run the audit, on every path.** Read `wiki/concepts/PR Merge Workflow.md` and run its `#### Before the first dispatch: verify your own work` checks, then resolve the spawn set its Roster-first step prescribes, including its fallback when the oracle is absent. Do not assume a harden diff is out of audit scope: a rule file or enforcement wiring can sit in a member's remit. When members are named, complete the workflow's marker handshake (spawn, fix, re-audit, under its `#### The three-round session cap`); once that page's `#### Posting the status last` conditions hold, post the status yourself, `bash .claude/hooks/post-audit-status.sh <path to a current member marker>`, before the merge question below. When none are named, the out-of-scope bypass clears the merge with no marker. Reaching the round cap is a stop: emit the continuation prompt the workflow prescribes.

A fix to a drafted rule is a commit to a file in a member's remit, so it rotates that member's digest and buys a whole extra round. The citation check in the prose-rule template's filling rules is what keeps round one clean.

**Watch the checks.** Read the whole `gh pr checks <N>` output once per look, as a bounded series of single calls, until no required check is pending. Single reads rather than a shell loop: `.claude/hooks/block-handrolled-pr-poll.sh` denies a loop naming `gh pr checks` that reads no `mergeable`, and the merge wait it offers instead is the wrong instrument here: it has no arm that fires on the required checks merely going green, so on that path it can only spend its bound. A failing check is a named-failure stop: read its log, report which check failed and why, and stop with the PR open. A window that closes with checks still pending is not a failure: go on to the merge question, and `--auto` queues the merge behind them.

**Ask the merge question**, once, via `AskUserQuestion`, after the audit has cleared and the check watch ended without a failing check. A candidate the human declined or deferred is no reason to withhold the merge: the PR carries only what they approved.

- **header:** `"Merge harden PR?"`
- **question:** `"PR #<N> has cleared its audit. Merge it now, or leave it open for review?"`
- **options (this exact order):**
  1. `{ label: "Merge", description: "Squash-merge PR #<N> now and clean up the branch." }`
  2. `{ label: "Leave open", description: "Keep the PR open; you merge it after review." }`

**Leave open** → report the PR URL and stop.

**Merge, verify, clean up.** Run `gh pr merge <N> --squash --delete-branch --auto` directly, so a merge reached after the watch window closed with checks pending queues behind them rather than being refused by branch policy. Then run the merge wait, `bash .gaia/scripts/pr-wait-merge.sh --pr <N> --attempts 20`, with a 20-attempt bound in place of its default 5, since a full CI run outlasts the default. The merge above is already queued and the script issues no `gh pr merge` of its own, so nothing here re-merges. One arm per verdict plus one for the exit-2 refusal, and the script's `--help` is the authority on both:

- On `MERGED` (exit 0), clean up per the workflow's `## Post-merge verification before cleanup` (`git checkout main && git pull origin main`, `git branch -D <HARDEN_BRANCH>`, `git fetch --prune origin`).
- On `CONFLICTING` (exit 3), repair per `wiki/concepts/PR Merge Workflow.md`'s `### Conflict found mid-wait` and run the wait again.
- On `CHECK_FAILED` (exit 4), print the PR URL and the failing check, and leave the branch in place.
- On `TIMEOUT` (exit 5), the window closed with the pull request still open: print the PR URL, say the merge queued above has not landed yet, and leave the branch in place.
- On `CLOSED` (exit 6), the pull request was closed without merging: report that and leave the branch in place, since no wait can clear it.
- On exit 2 the wait refused rather than answered: report the refusal and the PR URL, leave the branch in place, and assert no state for the pull request itself, since nothing about it was read. The merge queued above may still land.

Every stop above ends the run; see `## Cost record (run end)`, which is written once, as the last thing printed.

**On any other branch:** do not branch, commit, or PR. Leave the approved changes in the working tree and tell the engineer they ride the current branch's own PR (today's behavior). The end-of-run automation targets only the main-branch case, where a branch has to be made. (Run ends here; see `## Cost record (run end)`.)

If any `git` or `gh` command above exits non-zero, print the error and STOP. Do not retry, force-push, or amend; a rejected push is the engineer's call to resolve. (Run ends here; see `## Cost record (run end)`, passing `--github-*` only if `gh pr create` already succeeded before the failure.)

## list subcommand

Run `harden-tally`, judge every candidate, and print the same summary table and per-row detail `### Present the plan, then ask once` prints, rendered per `### Explain each item in plain language`, including the unclassified row when `unclassified` is non-null, noting it awaits a seeded class or investigation. Author nothing and prompt for nothing. (Run ends here; see `## Cost record (run end)`.)

## why subcommand

Run `harden-tally`, find the candidate whose `finding_class` matches the argument. Explain it with the rendering `### Explain each item in plain language` defines, then add the fuller rationale (including whether an existing artifact should be edited instead). If no candidate matches, say so and list the open candidates. `unclassified` is never `why`-addressable: it carries no `finding_class`, so treat a `why` argument of `unclassified` (or similar) the same as no match, say so, and point at `list` to see it. Author nothing and prompt for nothing. (Run ends here; see `## Cost record (run end)`.)

## Cost record (run end)

Every path that ends a `/gaia-harden` run appends exactly one cost record, the run-ending paths above:

- `list` and `why` printing their result.
- The `gh_ok: false` and zero-candidate stops from the live candidate fetch.
- **Stop without changes** at the plan question.
- Publish's no-change stop (no approval touched the working tree, or `git status --porcelain` came back empty).
- Publish's unsafe-repo-state stop.
- Publish's other-branch no-op.
- Publish's terminal outcomes on the default branch: `MERGED` after cleanup, a merge still queued when the wait's window closes, a "Leave open" the human chose, a stop at the audit's three-round session cap, a failing check, a pull request closed without merging, a merge wait that refused because it read nothing, or a non-zero-exit STOP on a `git` or `gh` command.

On the default-branch publish path the record is written once, at one of those outcomes, and its `Cost:` line is the last thing the run prints. Opening the PR is not a run end: the audit, the checks, and the merge question still follow it.

Apply the shared tally machinery in `.claude/skills/gaia/references/cost-record.md` with `{{COMMAND}}` = `gaia-harden`.

## Guardrails

- `/gaia-harden` is the only writer in this loop, and only under explicit human invocation. The background refresher and the audit emit never author.
- Never `git add`, `git commit`, or `git push` while dispositions are collected and applied. The single end-of-run publish step (`## Publish approved changes (end of run)`) is the only writer to git, and it merges only on the human's answer to its merge prompt, never automatically.
- Never auto-activate a skill or a deterministic check. v1 owns only prose-rule create/edit end to end; the other two forms are scaffold-only.
- Every drafted prose rule is mandatorily path-scoped (`paths:` frontmatter), and carries the verbatim provenance marker.
- No disposition without an explicit human answer. Accepting the whole plan is one answer and covers every row it accepts; per-row questions are asked only for rows the human chose to change.
- Every item is explained in plain language (what goes wrong, a concrete example or "no recorded example", a share-based frequency, what the action does, why) before any taxonomy.
- A decline is machine-local only (gitignored ledger); it never vetoes the candidate for a teammate.
- A defer persists nothing of its own; the review snapshot snoozes it on the same trigger rule as any other candidate.
- Recommend exactly one form per candidate, with rationale; check edit-vs-new first; bias to the lowest-context-weight form. Never reflexively author a prose rule.
- Factor the efficacy lens (Axis 3) into the recommendation and rationale: a recurring finding proves the problem, not the fix. When the recommended form is prose and no cheap evidence shows it would change behavior, surface that as a defer/decline signal for the human, never as an auto-decline.
- This loop keys only on `finding_class` recurrence from the PR window.
- The review snapshot is written only by a completed review-mode run, from that run's own start-of-run tally, never by `list`, `why`, a `gh_ok` false fetch, or an interrupted (abandoned) review.
- The `unclassified` signal is never a draftable candidate and is never auto-drafted: it carries no approve/decline/defer/redirect action and authors no artifact. It carries a suppression instead, on the terms `## Unclassified recurrence signal (seed-a-class-or-investigate)` states, including its release by the prune. Relaxing this guardrail is deliberate: seeding provably cannot shrink the cluster it answers. What spares the maintainer the nudge is no longer the suppression alone, the review snapshot does that on the same trigger terms as every other candidate; the suppression's own job is narrower, it removes the unclassified section from a review until the signal rises materially, so a review that has already seen it is not asked to re-litigate an unchanged cluster. No later change widens this further without the same justification.
