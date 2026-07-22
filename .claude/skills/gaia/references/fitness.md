# /gaia-fitness

`/gaia-fitness` is the Claude-integration health check + auto-heal. One invocation, no flag required, calling `/gaia-fitness` is the statement of intent to be fit. It runs three phases in sequence: triage → heal → verify.

The check taxonomy, F-to-A+ grading rubric, and triage/heal orchestration protocol all live in `wiki/decisions/Claude Integration Fitness.md`. This file is the Orchestrator: it reads that page, runs its three phases, and owns the branch / repo-state / publish harness layer described below. That harness layer, auto-branching, the unsafe-state guard, and the post-report publish gate, is `/gaia-fitness`-specific and is not part of the protocol in that page.

**Scope note:** the harness this file wraps around the protocol is minimal, no Orchestrator-above-Triager layer, no preserved per-cycle artifact directories, no escalation handoff. On loop exhaustion it reports the unresolved findings with the grade, period. The agent runs the checks the wiki page defines (greps / `jq` / `.gaia/cli/gaia wiki …` calls) inline; the only fitness-specific `gaia` subcommand it calls is `gaia fitness render-card`, which renders the final report card from the findings JSON (presentation only, it runs no checks).

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
- The F-to-A+ grading rubric (grade keys off the worst severity present, then the count at that severity).
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

Dispatch the seven category checks per the model assignment in the table below (mirrored from `wiki/decisions/Claude Integration Fitness.md` for context; the wiki page stays canonical, if the two ever diverge the wiki wins). Prefer **parallel subagents** so each Auditor's raw command output stays isolated. The initial triage here runs on clean orchestrator context, so parallel tool calls inline are an acceptable substitute on this first pass, the verifiable property is the structured findings array, not the dispatch mechanism. Every Step 5 verify re-run, by contrast, happens after findings are already in the orchestrator's context, so those **require real subagents**, an inline re-run would fold raw output back in and risk contaminating the next grade.

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

**Dispatch each Sonnet auditor with an explicit coverage directive** in its prompt: surface every candidate, including uncertain or low-severity ones, and do not filter for importance or confidence; the adjudication step below is the filter. A literal-minded auditor left to self-filter under-reports the borderline judgment calls (frontmatter substantiveness, content-vs-glob coherence, size-vs-guidance) this triage depends on. The canonical directive text lives in the fitness page's Triage phase (`wiki/decisions/Claude Integration Fitness.md`).

Collect the findings arrays. **Adjudicate each finding against the repo before grading**, the auditors are recall-oriented and over-flag (an unfamiliar-but-valid hook event, a permission pair that only looks redundant). Drop a finding only when it matches the wiki page's "Decided / not findings" allowlist; every finding that does not match the allowlist survives to grading regardless of how minor or uncertain it looks. Don't rubber-stamp, and don't drop on a hunch. Then compute the per-category grade and the overall grade (= floor of the seven category grades) over the adjudicated set using the rubric from the wiki page.

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

The `manifest` Fixer preserves every top-level key it does not own (for example `regions`) and never rewrites `.gaia/manifest.json` wholesale from the `files` map alone.

If a finding's fix straddles multiple lanes, dispatch one Fixer with multi-lane scope.

Run inside the bounded heal loop. The cap and stop conditions below mirror `wiki/decisions/Claude Integration Fitness.md`, which stays canonical; the cycle cap is tunable there:

- After each heal cycle, run the verify phase (Step 5).
- **Oscillation stop.** Compare fingerprint sets across consecutive cycles (fingerprint format `{check-id}:{file}:{line}:{first-40-chars-of-match-text}`). Any fingerprint appearing in both the current and prior cycle's findings has survived a fix attempt unchanged, stop the loop for that finding and mark it unresolved.
- **Cycle cap.** Run at most the wiki page's cycle cap (default 3, tunable there). After the final cycle without an overall A+, exit the loop and report the remaining unresolved findings with their affected grades.

**Too-invasive fixes:** a Fixer that judges a fix too invasive to apply without product context leaves it unapplied and surfaces it in the report with a recommended approach. Never force an invasive edit.

**Heal never commits.** Applied fixes stay in the working tree; the publish gate (Step 7) offers to commit, PR, and merge them.

---

## Step 5, Verify

After each heal cycle, re-dispatch the affected category checks as fresh subagents (the Auditors for the categories that had at least one finding addressed in that cycle; subagents are required here per Step 3, the orchestrator already holds findings). Recompute the affected category grades and the overall grade. If the overall grade reaches A+, the loop exits clean. On the **final** verify cycle, the one whose recomputed grade `/gaia-fitness` reports (the cycle that reaches A+ and exits, or the last cycle before loop-exhaustion reporting), re-dispatch **all seven** categories as fresh subagents, not just the affected ones: a fix in one lane can regress a check in a zero-finding category (a `claude-surface` edit pushing `CLAUDE.md` past its size budget, a `settings` edit breaking `settings.json` JSON validity), and an all-seven re-run catches that before the loop reports A+ instead of letting it escape.

---

## Cost record (run end)

Every path that ends the run appends exactly one cost record immediately before its final printed line, and relays the tally's `Cost:` line verbatim as the last line of the reply:

```bash
bash .gaia/scripts/token-tally.sh --action command --command gaia-fitness
```

**Pass-through.** When this run opened a pull request and the agent read the URL `gh pr create` printed in its own Bash tool result, append the artifact:

```bash
bash .gaia/scripts/token-tally.sh --action command --command gaia-fitness \
  --github-type pr --github-number <N> --github-repo '<owner>/<name>'
```

Never look the number up (`gh pr list`, `gh pr view`), never reuse one from an earlier run, a different branch, or a manually-run `gh`, and never guess. If this run did not itself print a creation URL, pass no `--github-*` flags; the record correctly omits `github`.

The tally never blocks, never fails, and never turns a failed run into a successful one. On a failure STOP, record the cost, then report the failure exactly as before; do not report success.

Every run-ending path records here:

- Step 6, post-heal routing, triage-only (unsafe state) STOP.
- Step 6, post-heal routing, zero findings (A+) STOP.
- Step 7, publish gate, Keep for review STOP.
- Step 7, publish gate, non-interactive fallback stop.
- Step 8, in-place heal (any other branch): no pass-through, no PR.
- Step 8, main-branch run, `MERGED`: pass-through.
- Step 8, main-branch run, still queued: pass-through.
- Step 8, publish failure STOP: pass-through only if `gh pr create` had already succeeded and printed its URL before the later command failed.

---

## Step 6, Report

Emit the report as a **single ASCII card** rendered by `gaia fitness render-card`, and paste the rendered card directly into your chat reply inside a fenced code block. Do not surface it as a tool result, the harness collapses long tool output; the card must be a first-class part of your message.

Build the report JSON from the adjudicated findings and the computed grades. List all seven categories with the grade you computed (the renderer sorts them alphabetically and derives the per-category note column from the findings, so order and counts are not your job):

```json
{
  "command": "/gaia-fitness",
  "overall": "<floor of the seven category grades>",
  "categories": [
    {"name": "Hook integrity", "grade": "<grade>"},
    {"name": "Skill / command / agent frontmatter", "grade": "<grade>"},
    {"name": "Rule hygiene", "grade": "<grade>"},
    {"name": "CLAUDE.md hygiene", "grade": "<grade>"},
    {"name": "Settings hygiene", "grade": "<grade>"},
    {"name": "GAIA-install fitness", "grade": "<grade>"},
    {"name": "Wiki fitness", "grade": "<grade>"}
  ],
  "findings": [
    {"category": "<category name>", "grade": "<category grade>",
     "severity": "error|warning|info", "file": "<repo-relative path[:line]>",
     "remediation": "<one-line fix or recommended approach>"}
  ]
}
```

Render it (the renderer self-sizes the box to `clamp(longest line, floor, min(terminal width, 120))` and wraps remediation text):

```bash
.gaia/cli/gaia fitness render-card \
  --cols "$(tput cols 2>/dev/null || echo 100)" <<'JSON'
{ ...the report JSON above... }
JSON
```

Paste the command's stdout verbatim into your reply as a fenced code block.

The `findings` array drives both the per-category note column and the grouped FINDINGS block. Unresolved / unfixable findings are included with their recommended approach in the `remediation`. On a clean run (zero adjudicated findings, overall A+), pass an empty `findings` array, the card omits the FINDINGS block.

**Post-heal routing.** The card carries no footer. After pasting it, route by harness state (from Steps 2 and 4):

| State | Action |
| --- | --- |
| Branch created (fixes applied, main-branch run) | Proceed to Step 7 (publish gate). |
| In place on `CURRENT_BRANCH` (fixes applied, non-default branch) | Proceed to Step 7 (publish gate). |
| Triage-only (unsafe state) | Record cost (see **Cost record (run end)**, no pass-through), then print `Heal skipped, <reason>. Re-run /gaia-fitness after <resolution steps>.` and STOP. No gate. |
| Zero findings (A+) | Record cost (see **Cost record (run end)**, no pass-through), then print `No findings. Overall A+. No changes made, no branch created.` and STOP. No gate. |

Format, taxonomy, and grading rubric source of truth: `wiki/decisions/Claude Integration Fitness.md` (Chat Report Format, Grading Rubric, Severity Vocabulary).

---

## Step 7, Publish gate (reached only when Step 4 applied ≥1 fix)

Skipped entirely on the triage-only and zero-findings paths, they printed their line and stopped in Step 6. Reached only when heal applied at least one fix, so a branch exists (`chore/gaia-fitness-<timestamp>`, main-branch run) or the changes sit in place on `CURRENT_BRANCH` (non-default branch).

Ask once, via `AskUserQuestion`, after the card (the card is the information the user needs to decide):

- **header:** `"Publish fixes?"`
- **question (main-branch run):** `"Fitness healed {N} finding(s) on branch chore/gaia-fitness-<timestamp>. Commit, open a PR, and merge them?"`
- **question (non-default branch):** `"Fitness healed {N} finding(s) on <CURRENT_BRANCH>. Commit and push them?"`
- **options (this exact order):**
  1. `{ label: "Publish", description (main-branch run): "Commit the healed changes, open a PR, and merge it.", description (non-default branch): "Commit and push the healed changes to <CURRENT_BRANCH>." }`
  2. `{ label: "Keep for review", description: "Leave the healed changes in the working tree; commit nothing." }`

- **Publish** → run Step 8.
- **Keep for review** → record cost (see **Cost record (run end)**, no pass-through), then print the working-tree review line and STOP:
  - Branch created: `Changes applied on branch chore/gaia-fitness-<timestamp>. Review with git diff main; discard with git checkout main && git branch -D chore/gaia-fitness-<timestamp>.`
  - In place: `Changes applied on <CURRENT_BRANCH>. Review with git diff; discard with git checkout -- .`

**Non-interactive fallback.** In a context with no user to answer the gate (a headless or composed run), do not publish: leave the healed changes in the working tree, record cost (see **Cost record (run end)**, no pass-through), print the matching review line above, and stop. Publishing is the standalone, interactive `/gaia-fitness` harness; a composing audit harness owns its own publish (the branch / heal / publish harness layer is `/gaia-fitness`-specific, per the protocol page).

---

## Step 8, Publish (commit / PR / merge)

Reached only on **Publish** from Step 7. It does for fitness's heal diff what `/gaia-audit`'s Publish and `/update-deps` Phase 8 do: commit the working-tree changes and drive the PR to merge on a main-branch run, or commit and push on any other branch. The diff is expected to touch only out-of-audit-scope surfaces (`.claude/**`, `CLAUDE.md`, `.gitignore`, `.gaia/manifest.json`, `.claude/settings.json`), in which case the PR clears the merge gate through the PR Merge Workflow's out-of-scope bypass with no `code-audit-frontend` marker. Do not assume it: a heal fix can restore a framework surface the roster claims, and `.gitignore` itself is treated as in scope by the gate. Before `gh pr merge`, run

```bash
bash .gaia/scripts/resolve-audit-spawn.sh
```

Empty output confirms the bypass applies and no marker is owed. If it names any member, this run's heal diff reached an audited surface: spawn each member it names and complete the marker handshake in `wiki/concepts/PR Merge Workflow.md` like any in-scope PR.

Run the Quality Gate (`.claude/rules/quality-gate.md`) first **only** if the applied diff touched a gate-affecting file (`.ts|tsx|js|jsx|mjs|cjs|css` or gate config); a config/docs-only heal has nothing for it to check.

### Main-branch run (branch already created in Step 4)

Heal already cut and switched to `chore/gaia-fitness-<timestamp>` (the `$BRANCH` from Step 4), so the changes are on it. Do not create a second branch.

1. **Commit.** `.gaia/local/` is gitignored. Route the message through a file, never `-m`:

   ```bash
   git -C "$PROJECT_ROOT" add -A
   git -C "$PROJECT_ROOT" commit -F <commit-message-file>
   ```

   Subject: `chore(fitness): <concise summary of the fixes applied>`.
   <!-- gaia:maintainer-only:start -->
   Then clear the **CHANGELOG gate** per `wiki/concepts/PR Merge Workflow.md`: a pure config/hygiene heal is usually an internal, no-entry change; land a `## [Unreleased]` entry only if the heal changed adopter-relevant behavior, and re-confirm any bypass/marker still covers the new HEAD. Scrubbed from adopter bundles.
   <!-- gaia:maintainer-only:end -->

2. **Open the PR and drive it to merge** through `wiki/concepts/PR Merge Workflow.md` (read it, don't merge from memory):

   ```bash
   git -C "$PROJECT_ROOT" push -u origin "$BRANCH"
   gh pr create --title "<commit subject>" --body-file <pr-body-file>
   gh pr merge <N> --squash --delete-branch --auto
   ```

   `--auto` queues the merge behind required checks (the oracle check above already confirmed whether a marker is owed for this diff). Bounded-poll `gh pr view <N> --json state` for `MERGED` (~2-3 minutes):

   - **`MERGED`** → clean up, record cost (pass-through: `gh pr create` above already printed the URL), then print the merged PR URL:

     ```bash
     git -C "$PROJECT_ROOT" checkout main && git -C "$PROJECT_ROOT" pull origin main
     git -C "$PROJECT_ROOT" branch -D "$BRANCH"
     git -C "$PROJECT_ROOT" fetch --prune origin
     bash .gaia/scripts/token-tally.sh --action command --command gaia-fitness \
       --github-type pr --github-number <N> --github-repo '<owner>/<name>'
     ```

     Relay the tally's `Cost:` line as the last line of the reply, after the merged PR URL.

   - **still queued** → record cost (pass-through: `gh pr create` above already printed the URL), print the PR URL, note auto-merge is queued and lands when checks pass, and do **not** delete the local branch or switch off it.

     ```bash
     bash .gaia/scripts/token-tally.sh --action command --command gaia-fitness \
       --github-type pr --github-number <N> --github-repo '<owner>/<name>'
     ```

   Caveat: the oracle check above already covers this. A heal edit to a nested `CLAUDE.md` under an in-scope path such as `app/` is exactly the kind of reached-an-audited-surface diff the oracle detects; if it named a member, the marker handshake ran before this PR was even opened.

### Any other branch (in-place heal)

```bash
git -C "$PROJECT_ROOT" add -A
git -C "$PROJECT_ROOT" commit -F <commit-message-file>
git -C "$PROJECT_ROOT" push
bash .gaia/scripts/token-tally.sh --action command --command gaia-fitness
```

Relay the tally's `Cost:` line as the last line of the reply. Do not open a PR and do not merge; the branch owner drives it from here.

If any `git push`, `gh pr create`, or `gh pr merge` above exits non-zero, record cost, then print the command's error and STOP. Pass the pass-through flags only if `gh pr create` had already succeeded and printed its URL before the later command failed; otherwise pass none:

```bash
bash .gaia/scripts/token-tally.sh --action command --command gaia-fitness
```

Do not retry, force-push, or amend, a rejected push or blocked merge is the user's call to resolve. The tally never blocks, never fails, and never turns this failed run into a successful one.
