# /gaia-fitness

`/gaia-fitness` is the Claude-integration health check + auto-heal. One invocation, no flag required, calling `/gaia-fitness` is the statement of intent to be fit. It runs three phases in sequence: triage → heal → verify.

The check taxonomy, F-to-A+ grading rubric, and triage/heal orchestration protocol all live in `wiki/decisions/Claude Integration Fitness.md`. This file is the Orchestrator: it reads that page, runs its three phases, and owns the branch / repo-state harness layer described below. That harness layer, auto-branching, the unsafe-state guard, is `/gaia-fitness`-specific and is not part of the protocol in that page.

**Scope note:** the harness this file wraps around the protocol is minimal, no Orchestrator-above-Triager layer, no preserved per-cycle artifact directories, no escalation handoff. On loop exhaustion it reports the unresolved findings with the grade, period. v1 introduces no `gaia` CLI subcommand, the agent runs the checks the wiki page defines (greps / `jq` / `.gaia/cli/gaia wiki …` calls) inline.

---

## Path resolution (portable, no hardcoding)

All paths in this file are repo-relative or derived from `$PROJECT_ROOT`, never hardcoded.

```bash
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
GIT_DIR="$PROJECT_ROOT/.git"
```

All paths below are repo-relative or `$PROJECT_ROOT`-prefixed.

---

## Step 1, Read the protocol page

Read `wiki/decisions/Claude Integration Fitness.md` end-to-end before doing anything else.

That page defines:

- The seven graded check categories (hook integrity; skill / command / agent frontmatter; rule hygiene; `CLAUDE.md` hygiene; settings hygiene; GAIA-install fitness; wiki fitness).
- The bucket-and-model spec for triage Auditors (Haiku for mechanical checks, Sonnet for judgment-bearing checks and grade synthesis).
- The Fixer lanes for the heal phase (`claude-surface`, `settings`, `gitignore`, `manifest`).
- The bounded loop (default 3 cycles) and oscillation detection (fingerprint format: `{check-id}:{file}:{line}:{first-40-chars-of-match-text}`).
- The F-to-A+ grading rubric (A+ = zero findings; A = one or two info; A− = three or more info; B+ = one warning; B = two warnings; B− = three or more warnings; C+ = one error; C = two errors; C− = three errors; D+ = four errors; D = five errors; D− = six or more errors; F = structurally broken category, grade keys off the worst severity present, then the count at that severity).
- The findings schema (`{severity, file, remediation, fingerprint}`) and chat report format.
- The Decided / not findings section (skip the round-trips listed there).

Do not improvise around that page. Run exactly what it defines.

---

## Step 2, Repo-state pre-flight (harness layer)

Before any heal-phase mutation, determine whether the repo is in a safe state.

**Detect unsafe states:**

```bash
# Detached HEAD, returns empty when HEAD is symbolic; non-empty when attached
git -C "$PROJECT_ROOT" symbolic-ref -q HEAD

# In-progress operations
test -d "$GIT_DIR/rebase-merge"
test -d "$GIT_DIR/rebase-apply"
test -f "$GIT_DIR/MERGE_HEAD"
test -f "$GIT_DIR/CHERRY_PICK_HEAD"
test -f "$GIT_DIR/BISECT_LOG"
```

**If HEAD is detached OR any in-progress operation file/directory exists → triage-only path:**

1. Run Step 3 (triage) as normal.
2. Compute and print the grades.
3. State clearly that heal was skipped because the working state is not safe to mutate. Include the specific reason (e.g. "HEAD is detached" or "rebase in progress").
4. Give the resolution steps: e.g. "complete or abort the rebase (`git rebase --abort`), or check out a branch (`git checkout <branch>`), then re-run `/gaia-fitness`."
5. **STOP**: make no working-tree mutation, create no branch. Do not proceed to Steps 4–6.

**Otherwise (safe state):**

Determine the current branch and the repo's default branch:

```bash
CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" symbolic-ref --short HEAD)
DEFAULT_BRANCH=$(git -C "$PROJECT_ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
# Fallback if remote HEAD is not set
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
ON_DEFAULT_BRANCH=false
[[ "$CURRENT_BRANCH" == "$DEFAULT_BRANCH" ]] && ON_DEFAULT_BRANCH=true
```

Remember `CURRENT_BRANCH`, `DEFAULT_BRANCH`, and `ON_DEFAULT_BRANCH`, they govern the branch decision in Step 4.

---

## Step 3, Triage

Run the triage phase from `wiki/decisions/Claude Integration Fitness.md`.

Dispatch the seven category checks as **parallel subagents** (or parallel tool calls, the verifiable property is the structured findings artifact, not the dispatch mechanism) per the wiki page's bucket-and-model spec:

| Category                            | Model  |
| ----------------------------------- | ------ |
| Hook integrity                      | Haiku  |
| Settings hygiene                    | Haiku  |
| GAIA-install fitness                | Haiku  |
| Wiki fitness                        | Haiku  |
| Skill / command / agent frontmatter | Sonnet |
| Rule hygiene                        | Sonnet |
| `CLAUDE.md` hygiene                 | Sonnet |

Each Auditor returns an array of `{severity, file, remediation, fingerprint}` objects. Raw command output stays in subagent context; only the structured findings array flows back.

Collect the findings arrays. **Adjudicate each finding against the repo before grading**, the auditors are recall-oriented and over-flag (an unfamiliar-but-valid hook event, a permission pair that only looks redundant); drop the false positives per the wiki page's "Decided / not findings" section, don't rubber-stamp. Then compute the per-category grade and the overall grade (= floor of the seven category grades) over the adjudicated set using the rubric from the wiki page.

Classify each surviving finding as fixable or unfixable. A finding is fixable when a Fixer can apply it confidently without product context (mechanical edits: add a missing frontmatter field, fix a bad path, update `.gitignore`, etc.). A finding is unfixable when it requires product context or invasive restructuring (e.g. splitting an oversized `CLAUDE.md`, restructuring hook logic, rewriting a rule file's scope).

---

## Step 4, Heal (skipped if Step 2 routed to triage-only)

**If no fixable finding exists:** skip heal entirely. No branch is created. HEAD stays where it is. Proceed directly to Step 6 with the triage grades. A zero-findings run is overall A+; no changes, no branch.

**If ≥1 fixable finding AND `ON_DEFAULT_BRANCH` is true:**

Before applying the first fix, create and switch to a new branch:

```bash
TIMESTAMP=$(date +%Y-%m-%d-%H%M)
BRANCH="chore/gaia-fitness-$TIMESTAMP"
git -C "$PROJECT_ROOT" checkout -b "$BRANCH"
```

Apply fixes on this new branch. Never commit.

**If ≥1 fixable finding AND `ON_DEFAULT_BRANCH` is false:**

Heal in place on `CURRENT_BRANCH`. Create no new branch.

**In both cases, running the heal phase:**

Dispatch lane-aware Fixer subagents (Sonnet) in parallel per the wiki page's lane definitions:

| Lane             | Owns                                                                                                                 |
| ---------------- | -------------------------------------------------------------------------------------------------------------------- |
| `claude-surface` | `.claude/skills/**`, `.claude/commands/**`, `.claude/agents/**`, `.claude/hooks/**`, `CLAUDE.md`, `.claude/rules/**` |
| `settings`       | `.claude/settings.json`                                                                                              |
| `gitignore`      | `.gitignore`                                                                                                         |
| `manifest`       | `.gaia/manifest.json` (serialize, one Fixer at a time)                                                               |

If a finding's fix straddles multiple lanes, dispatch one Fixer with multi-lane scope.

Run inside the bounded loop (default 3 cycles) with oscillation detection as described in the wiki page:

- After each heal cycle, run the verify phase (Step 5).
- Compare fingerprint sets across consecutive cycles. Any fingerprint appearing in both the current and prior cycle's findings has survived a fix attempt unchanged, stop the loop for that finding and mark it unresolved.
- On loop exhaustion, report remaining unresolved findings with the affected grades.

**Too-invasive fixes:** a Fixer that judges a fix too invasive to apply without product context leaves it unapplied and surfaces it in the report with a recommended approach. Never force an invasive edit.

**Never commit.** The working tree is left for the user to review.

---

## Step 5, Verify

After each heal cycle, re-run the affected category checks (the Auditors for the categories that had at least one finding addressed in that cycle). Recompute the affected category grades and the overall grade. If the overall grade reaches A+, the loop exits clean.

---

## Step 6, Report

Print the following to chat:

### Findings section

Group findings by the seven taxonomy category names. For each finding:

```
- [severity] `file:line`, remediation
```

Unresolved / unfixable findings are included with their recommended approach. On a clean run (zero adjudicated findings, overall A+), omit the Findings section entirely, print only the grades table and the "no findings" post-heal line.

### Grades section

Print a grade table:

```
| Category | Grade | Findings |
|---|---|---|
| Hook integrity | <grade> | <count and severity summary> |
| Skill / command / agent frontmatter | <grade> | ... |
| Rule hygiene | <grade> | ... |
| CLAUDE.md hygiene | <grade> | ... |
| Settings hygiene | <grade> | ... |
| GAIA-install fitness | <grade> | ... |
| Wiki fitness | <grade> | ... |

**Overall grade: <grade>** (floor of category grades)
```

### Post-heal instructions

**If a `chore/gaia-fitness-<timestamp>` branch was created:**

> Changes applied on branch `chore/gaia-fitness-<timestamp>`. Review with `git diff main`, commit when satisfied, or discard with:
>
> ```
> git checkout main && git branch -D chore/gaia-fitness-<timestamp>
> ```

**If healing happened in place on an existing branch (`CURRENT_BRANCH`):**

> Changes applied on current branch `<CURRENT_BRANCH>`. Review with `git diff`, commit when satisfied, or discard with `git checkout -- .`

**If triage-only (unsafe repo state from Step 2):**

> Heal skipped, `<reason>` (e.g. HEAD is detached / rebase in progress). Re-run `/gaia-fitness` after `<resolution steps>`.

**If zero findings (overall A+):**

> No findings. Overall A+. No changes made, no branch created.
