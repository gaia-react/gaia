# SPEC and plan lifecycle procedures

The procedures a generated `ORCHESTRATOR.md` and both pre-flights point at. `.claude/skills/gaia/references/plan/planner.md` owns the order of the orchestrator's steps and the verbatim blocks a planner copies; this page owns what each step does. Every command runs from the directory each section names, with the placeholders the orchestrator holds: `<SPEC_PATH>` (the absolute, main-anchored `SPEC.md`), `<PLAN_DIR>` (the absolute, main-anchored plan folder), `<RESOLVED_ROOT>` (the working copy the isolation reference resolved) and `<N>` (the PR number).

Contents: Owning-phase UAT gate; Phase N, <title> (HALTED); Pre-audit UAT checks; Consolidation; Wiki promotion; Post-merge close; Pre-flight sweep.

## Owning-phase UAT gate

**When it runs.** For a spec-derived plan, after `pnpm typecheck && pnpm lint` pass for a phase whose number appears in an `e2e` row of the UAT routing table in `<PLAN_DIR>/README.md`, and before that phase commits. A phase that owns no `e2e` row skips it.

**Command**, from `<RESOLVED_ROOT>`:

```bash
bash .gaia/scripts/spec/uat-gate.sh <SPEC_PATH> --routing <PLAN_DIR>/README.md --phase <N>
```

Here `<N>` is the phase number.

**Prerequisites and cost.** Playwright's Chromium is installed and `pnpm storybook` is stopped (the run boots its own servers). Each run boots two webServers, so budget roughly a minute per owning phase.

**What it checks.** Per owned spec: the file exists and starts with its contract marker; no `test.fail`, `test.fixme`, `test.skip`, `.only` or skipped or fixme `describe` annotation remains; the deterministic floor holds (a `page.` call and an `expect(` on a real value); the contract comment still matches the SPEC UAT; no working-doc id appears in the e2e tree; and Playwright's JSON reporter records every test in the file as passed. Whether the test body still asserts the contract is not decided here: the pre-merge Code Audit Team audit judges it.

**Outcome.**

| Exit | Meaning | Action |
|---|---|---|
| 0 | every owned spec passed, or the phase owns none | continue to the phase commit |
| 1 | gate failure; stderr names each failing file and its comma-joined reasons | do not commit; append the block below to `<PLAN_DIR>/PROGRESS.md` and stop |
| 2 | invalid input (SPEC, routing table, arguments) | do not commit; append a `## Phase N, <title> (HALTED)` block with `Reason: UAT gate input invalid` and the stderr line, and stop |
| 4 | Playwright could not run (no browser, port held, server failed to boot) | do not commit; append a `## Phase N, <title> (HALTED)` block with `Reason: UAT gate prerequisite missing` naming the prerequisite from stderr, and stop |

```
## Phase N, <title> (HALTED)
Reason: UAT gate failed
Spec files: <each failing path and its reasons, from uat-gate.sh's stderr>
```

A HALTED phase block carries no `Commit:` line, so a resume re-runs the phase.

## Pre-audit UAT checks

For a spec-derived plan, after the last phase commits and before the final summary and the pre-merge Code Audit Team audit, from `<RESOLVED_ROOT>`:

```bash
bash .gaia/scripts/spec/uat-gate.sh <SPEC_PATH> --routing <PLAN_DIR>/README.md --all
```

`--all` runs the same checks over every `e2e` row, which includes the divergence check and the working-doc id scan across every rendered spec. A non-zero exit is a HALT: stop and surface stderr. It is never an audit finding to fix inside a fix round.

Then confirm the render landed before the first phase. When `<PLAN_DIR>/PROGRESS.md`'s first `## UAT render` block carries a `Commit: <short-sha>` (not `none`, not `Skipped:`), take the Phase 1 SHA from its `## Phase 1` block's `Commit:` line and run:

```bash
git -C <RESOLVED_ROOT> merge-base --is-ancestor <render sha> <Phase 1 sha>
```

A non-zero exit is a HALT naming both SHAs: Phase 1 was committed without the rendered red specs under it.

## Consolidation

The one consolidation recipe. Two callers run it: the orchestrator, after audit clearance and the human's ready-to-merge confirmation, and the pre-flight sweep's cold consolidation, against a folder whose PR already merged.

**Synthesis.** The caller (the warm orchestrator, or the session running the sweep; never a task sub-agent) writes `SUMMARY.md` by layered override-resolution: read the layers in precedence `SPEC.md`, then `AUDIT.md`, then the plan's `PROGRESS.md`; the top layer wins on conflict. A spec-less plan has no `SPEC.md` or `AUDIT.md`, so its `PROGRESS.md` is the only layer; a cold consolidation reads the plan's `PROGRESS.md` when one is present. Ground the result in the merged code and passing tests, write it present-tense as final-state prose, and surface any material narrowing between the stated intent and the shipped scope under an optional `## Divergence` section. This step is agent synthesis, not a template: a mechanical concatenation cannot resolve conflicts between the layers or judge what "materially narrower" means.

**Location.** A spec-colocated plan's `SUMMARY.md` sits beside `SPEC.md`, in the SPEC folder one level above the plan subfolder; a spec-less plan's sits in `<PLAN_DIR>`. Both folders are main-anchored. From a linked worktree, the write follows the tool-choice contract in `.claude/skills/gaia/references/spec.md` Operational primitives, which applies the same way to a spec-less plan folder.

**Shape.** Frontmatter with `wiki_promote_default` and `wiki_promote_targets`, a non-empty H1, a non-empty body, and an optional `## Divergence`.

- `wiki_promote_default` is exactly `yes`, `ask` or `no`. A spec-colocated plan copies the SPEC's value, normalizing a legacy `true` to `yes` and `false` to `no`; a spec-less plan stamps `ask`. Consolidation never writes `true` or `false` (`summary-verify.sh` accepts them only so an older `SUMMARY.md` still verifies).
- `wiki_promote_targets` is the SPEC's list, or `[decisions]` for a spec-less plan.

**Verify.**

```bash
bash .gaia/scripts/summary-verify.sh <SUMMARY.md path>
```

Consolidation removes nothing: `SPEC.md`, `AUDIT.md`, `PROGRESS.md` and the plan folder all stay until the post-merge close (or, for a cold consolidation, until the sweep's own removal below). On exit 0 the orchestrator continues to the wiki promotion step. On a non-zero exit the orchestrator records the outcome in the wiki promotion record and continues to the merge without promoting; the post-merge close then keeps the layers, fail-closed:

```
## Wiki promotion
Default: <the stamped value>   Choice: skipped-verify-failed
Pages: none   Commit: none
Reason: summary-verify.sh failed: <its first stderr line>
```

## Post-merge close

Runs after `gh pr merge`, in this order. Each step runs only after the one before it.

1. **Confirm the merge.** Run `bash .gaia/scripts/pr-wait-merge.sh --pr <N>`. Only exit 0 with stdout `MERGED` proceeds. On any other exit (`CONFLICTING`, `CHECK_FAILED`, `TIMEOUT`, `CLOSED`, or exit 2, a refusal and never a verdict) stop and surface the verdict: nothing below runs before `MERGED` is confirmed.
2. **Resolve the main checkout.** In worktree mode the cwd is the worktree, whose ledgers are not shared, so never pass `$PWD`:

   ```bash
   main_root="$(bash .gaia/scripts/main-root-lib.sh)"
   ```

3. **Reconcile the ledger.** Best-effort, never blocking:

   ```bash
   # spec-colocated plan (branch carries the SPEC marker)
   bash .gaia/scripts/spec/spec-reconcile.sh "$main_root" || true
   # spec-less plan: the third argument is the PR number step 1 confirmed MERGED
   bash .gaia/scripts/spec/plan-reconcile.sh "$main_root" "$PLAN_ID" "<N>" || true
   ```

   Passing the confirmed PR number stamps `pr_number` on the plans-ledger row, which the pre-flight sweep's reap reads.
4. **Exit the worktree** (worktree mode only), per the template's post-merge worktree cleanup and isolation-context detection bullets in `.claude/skills/gaia/references/plan/planner.md`. When the orchestrator cannot leave the worktree (an isolated sub-agent context), its continuation prompt carries steps 5 and 6 for the human to run from the main checkout.
5. **Verify, then remove the layers.** From the main checkout:

   ```bash
   bash .gaia/scripts/summary-verify.sh <SUMMARY.md path>
   ```

   On exit 0, for a spec-colocated plan, `rm <SPEC folder>/SPEC.md <SPEC folder>/AUDIT.md`; a spec-less plan has neither. On a non-zero exit keep both. Either way append to `<PLAN_DIR>/PROGRESS.md`:

   ```
   ## Post-merge close
   SUMMARY verify: <pass | fail: SPEC.md and AUDIT.md kept>
   ```

6. **Archive the plan folder.**

   ```bash
   bash .gaia/scripts/plan-archive.sh <PLAN_DIR>
   ```

   A spec-colocated plan subfolder is deleted; a spec-less plan folder is reduced to `SUMMARY.md` and `cost.json`, with its `RUNNING` sentinel cleared. Without a verified `SUMMARY.md` the helper leaves the folder untouched. It always exits 0.

**Retention.** The SPEC folder's `SUMMARY.md` and `cost.json`, and a reduced spec-less plan folder, stay for `GAIA_SPEC_RETENTION_DAYS` (default 30). Nothing reaps them early; the pre-flight sweep reaps them once past the window.

## Pre-flight sweep

The shared backstop for merges that happened outside an orchestrator, or a close that never finished. `/gaia-spec` step 2 and `/gaia-plan` step 0 both run it. Every pass is best-effort and never blocks the command that runs it. The order is load-bearing: pass 1's scan stamps the `pr_number` that pass 2's plan candidates and pass 3's confirmed reap read.

**1. Reconcile.** Flip finalized rows whose PR merged:

```bash
bash .gaia/scripts/spec/spec-reconcile.sh "$PWD" 2>/dev/null || true
bash .gaia/scripts/spec/plan-reconcile.sh "$PWD" 2>/dev/null || true
```

The plan call is the scan form (no id): it matches `ready` rows, and `merged` rows without a `pr_number`, to their merged PR and stamps `merged_at` and `pr_number`.

**2. Cold consolidation.** Find merged folders whose layers were never consolidated: merged spec rows whose folder holds `SPEC.md` or `AUDIT.md` without a verified `SUMMARY.md`, and merged plan rows carrying `pr_number` whose folder holds `PROGRESS.md` without a verified `SUMMARY.md`. The ledgers and folders are main-anchored, so the scan resolves the main checkout first:

```bash
MAIN_ROOT="$(bash .gaia/scripts/main-root-lib.sh)"
if [ -z "$MAIN_ROOT" ]; then
  echo "pre-flight sweep: cannot resolve the main checkout; skipping cold consolidation" >&2
else
  jq -r '.specs[] | select(.status == "merged") | .id' "${MAIN_ROOT}/.gaia/local/specs/ledger.json" 2>/dev/null | while read -r id; do
    folder="${MAIN_ROOT}/.gaia/local/specs/${id}"
    { [ -f "${folder}/SPEC.md" ] || [ -f "${folder}/AUDIT.md" ]; } || continue
    bash .gaia/scripts/summary-verify.sh "${folder}/SUMMARY.md" >/dev/null 2>&1 && continue
    echo "$folder"
  done
  jq -r '.plans[] | select(.status == "merged" and (.pr_number // null) != null) | .id' "${MAIN_ROOT}/.gaia/local/plans/ledger.json" 2>/dev/null | while read -r id; do
    folder="${MAIN_ROOT}/.gaia/local/plans/${id}"
    [ -f "${folder}/PROGRESS.md" ] || continue
    bash .gaia/scripts/summary-verify.sh "${folder}/SUMMARY.md" >/dev/null 2>&1 && continue
    echo "$folder"
  done
fi
```

An empty `MAIN_ROOT` skips this pass rather than falling back to a relative path, which would read a forked ledger inside a linked worktree.

For each printed folder, run `## Consolidation` above against it as a cold consolidation (for a SPEC folder, the layers include its `plan*/PROGRESS.md` when one is present). On a verify pass, a SPEC folder's PR is already merged, so remove its `SPEC.md` and `AUDIT.md`; a plan folder has no layers to remove. On a failed synthesis or verify, leave everything in place for a later pass. This pass never destroys a layer it failed to replace.

**3. Reap past retention.**

```bash
bash .gaia/scripts/spec/spec-archive-merged.sh "$PWD" 2>/dev/null || true
bash .gaia/scripts/spec/plan-archive-merged.sh "$PWD" 2>/dev/null || true
```

Both delete a merged folder once its `merged_at` is past `GAIA_SPEC_RETENTION_DAYS` (default 30), its layers are consolidated, and its cost is represented in the cost ledger; a folder still holding unconsolidated layers or an unrepresented cost is kept. The plan reap takes two kinds of row: rows confirmed against a merged PR (`pr_number`, stamped at the post-merge close or by pass 1's scan) and older merged rows without one, which age out on `merged_at` alone.
