# /gaia-harden

Human-gated hardening for the policy-memory loop. `/gaia-harden` is the ONLY code path that authors or activates anything in this loop, and it runs only under explicit human invocation. For each recurring finding it judges the lowest-context-weight form that fits, checks edit-vs-new first, recommends exactly one form with rationale, and presents an approve / decline / defer / redirect choice. Nothing is authored or activated unattended.

v1 owns prose-rule create/edit end to end. Skills and deterministic checks are recommended and scaffolded only (a skill-creator handoff; a hook+script sketch), never auto-authored or auto-activated.

## Execution model, READ FIRST

Execute the playbook yourself in the current conversation. This is an interactive, human-gated flow: each candidate's approve / decline / defer / redirect choice is the human's, never the agent's. Do not dispatch a subagent to make those calls and do not auto-advance past a candidate without a human answer.

The agent never runs `git add`, `git commit`, or `git push` anywhere in this flow. Approved work lands in the working tree only; it ships through normal PR review. A decline writes one bounded entry to the machine-local, gitignored ledger and nowhere else. A defer persists nothing.

## Argument parsing

Tokenize the first whitespace-separated word of `$ARGUMENTS`:

- `review` (or empty `$ARGUMENTS`) → the full interactive flow. This is the default the statusline nudge (`Run /gaia-harden review (N)`) points at.
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

Bind to these fields per candidate: `finding_class`, `distinct_pr_count`, `pr_numbers`, `area_tags`, `severity_max`. The tally already drops classes a promoted rule covers and classes the decline ledger suppresses, so every entry it returns is an open candidate. `harden-tally` is network-dependent and non-fatal: a `gh` failure yields an empty candidate list rather than an error. If `candidate_count` is `0`, report "no recurring findings crossed the threshold in the last 90 days" and stop.

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

- **Oracle-class finding** (the `finding_class` is a tool id: it starts with `react-doctor/`, `axe/`, `knip/`, or `cve/`). A deterministic check already exists for it. Recommend making that check BLOCKING or adding it to the quality gate, an enforcement edit, NOT a new prose rule. Point at `wiki/decisions/Quality Gate.md` and the tool's wiring (`.claude/rules/knip.md`, `.claude/rules/dep-audit.md`, the `code-review-audit` agent, or the relevant CI workflow). Never draft prose for an oracle class.

- **Mechanizable holistic/rule pattern** (the pattern can be caught by a lint rule, a hook, or a test). Recommend a DETERMINISTIC CHECK. v1 produces a hook+script SKETCH only; it activates nothing, writes no `.claude/rules/` file for it, and claims no prune lifecycle over it.

- **A correct procedure** (the lesson is "do these steps in this order"). Recommend a SKILL via skill-creator. v1 produces a skill-creator invocation/scaffold only; it activates nothing.

- **Judgment-based pattern** (a human-judgment anti-pattern with no reliable mechanization, e.g. a holistic/rule class about a design call). Recommend a PROSE RULE. v1 OWNS this end to end: it drafts the path-scoped rule with the provenance marker into the working tree.

When a pattern is mechanizable, the recommendation is the deterministic check, not a skill and not a prose rule.

### Present and act

For each candidate, present: the finding_class, its distinct-PR count and the PRs it recurred on, the recommended form, and the one-line rationale. Then offer the action set: **approve / decline / defer / redirect**.

`redirect` means the engineer overrides the form choice (e.g. "make it a prose rule even though you recommended a skill"). Honor the override and run that form's action handling.

## Per-form action handling

### approve, prose rule

Draft the rule file into the working tree using the template below. The rule is MANDATORILY path-scoped: a `paths:` frontmatter glob is always present, derived from the candidate's `area_tags`. Never write a frontmatter-less / always-loaded rule. Immediately after the frontmatter, write the provenance marker verbatim (see the frozen marker below). Then write present-tense body prose describing the anti-pattern and the correct pattern.

After writing, tell the engineer the rule is in the working tree and ships through normal PR review. NEVER `git add`, `git commit`, or `git push`.

### approve, deterministic check

Produce ONLY a hook+script SKETCH (a proposed hook entry and a script outline the engineer can finish). Activate nothing: do not wire it into `.claude/settings.json`, do not make any file executable, and write no `.claude/rules/` file for it. Make clear the loop claims no prune lifecycle over it. Hand the sketch to the engineer to finish and wire up themselves.

### approve, skill

Produce ONLY a skill-creator handoff. Invoke the `skill-creator` skill (the scaffolding tool) with the captured intent (what the skill should enable, when it should trigger, the expected output), or print a ready-to-run scaffold invocation. Activate nothing and write no `.claude/rules/` file for it.

### approve, enforcement edit (oracle class)

Make the existing deterministic check blocking or add it to the quality gate. This is an edit to existing enforcement wiring (the tool's rule file, the `code-review-audit` agent, the quality gate doc, or the CI workflow), not a new prose rule. Land the edit in the working tree only; never commit.

### decline

Record one bounded entry to the machine-local ledger, passing the candidate's current distinct-PR count:

```bash
.gaia/cli/gaia harden-ledger record --finding-class "<finding_class>" --pr-count <distinct_pr_count>
```

State that the decline is machine-local only (the ledger is gitignored) and never shared: a teammate still sees the nudge and can approve. The decline re-surfaces on evidence, the ledger handles that; once at least 3 more distinct PRs carrying the class merge, the candidate returns.

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

<Present-tense prose: name the anti-pattern, then state the correct pattern. No UAT/SPEC IDs, no PR/commit/date references. Describe what the rule enforces and why.>

## Anti-pattern

<the wrong shape>

## Correct pattern

<the right shape>
```

Rules for filling it in:

- **`paths:` is mandatory.** Derive the glob from the candidate's `area_tags` (e.g. an `area_tags` of `["app/components"]` becomes `app/components/**/*`). One or more single-quoted globs, one per line. A rule with no `paths:` frontmatter is never produced; path-scoping is what bounds per-task context weight regardless of how many promoted rules accumulate.
- **The provenance marker is verbatim and single-line**, placed immediately after the closing `---` of the frontmatter, with `<class>` replaced by the actual finding_class. It references the `finding_class`, never a SPEC or UAT id.
- **Body prose is present tense** and follows `.claude/rules/wiki-style.md`: no UAT/SPEC references, no inline PR/commit/date references. Use repo-relative paths only (`.claude/rules/coding-guidelines.md`).

### Frozen provenance marker (PROVENANCE-MARKER CONTRACT)

The marker is this exact line, with `<class>` substituted:

```
<!-- gaia-harden: promoted from recurring finding_class <class>; pruned by /gaia-audit on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->
```

`/gaia-audit` recognizes this marker only to apply its existing obsolescence / redundancy / supersession / duplication signals without a policy-memory exemption, and to explicitly NOT treat non-recurrence as a prune signal. The marker grants no special lifecycle. Do not alter its wording: `/gaia-audit` binds to this string.

## list subcommand

Run `harden-tally`, then for each candidate print one line: `finding_class`, distinct-PR count, the PRs, and the recommended form (from judge-the-form, edit-vs-new + which-form). Author nothing and prompt for nothing.

## why subcommand

Run `harden-tally`, find the candidate whose `finding_class` matches the argument. Explain it: what the finding is, the distinct PRs it recurred on (`pr_numbers`), its max severity, the recommended form, and the rationale (including whether an existing artifact should be edited instead). If no candidate matches, say so and list the open candidates. Author nothing and prompt for nothing.

## Guardrails

- `/gaia-harden` is the only writer in this loop, and only under explicit human invocation. The background refresher and the audit emit never author.
- Never `git add`, `git commit`, or `git push`. Approved work lands in the working tree for human review and ships through normal PR review.
- Never auto-activate a skill or a deterministic check. v1 owns only prose-rule create/edit end to end; the other two forms are scaffold-only.
- Every drafted prose rule is mandatorily path-scoped (`paths:` frontmatter), and carries the verbatim provenance marker.
- A decline is machine-local only (gitignored ledger); it never vetoes the candidate for a teammate.
- A defer persists nothing.
- Recommend exactly one form per candidate, with rationale; check edit-vs-new first; bias to the lowest-context-weight form. Never reflexively author a prose rule.
- Do not read the privacy-sealed mentorship event store to make any of these decisions; this loop keys only on `finding_class` recurrence from the PR window.
