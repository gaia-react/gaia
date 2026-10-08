# /gaia-plan

Plan a complex feature using the task orchestration pattern. Do not implement anything.

This command is the plan-specific case of the Workflow Doctrine (`wiki/concepts/Workflow Doctrine.md`), which defines roles, git ownership, checkpoint and resume, and model choice. For plan runs, the plan contract in `.claude/skills/gaia/references/plan/planner.md` (per-phase commits and gates, `PROGRESS.md`, the orchestrator's executor pins) governs where the two differ.

Contents: `## Steps` (0 pre-flight sweep; 1 description, 1a SPEC reference; 2 planner model; 3 plan directory; 4 planning agent; 4.5 verify output; 4.6 decomposition audit; 4.7 token tally; 5 report and kickoff prompt).

## Steps

### 0. Pre-flight sweep

Read `.claude/skills/gaia/references/spec/lifecycle.md` and run its `## Pre-flight sweep` now. It is best-effort and never blocks planning.

### 1. Get description

If `$ARGUMENTS` (the args after `plan`) is non-empty, use it as the feature description.

Otherwise, ask: **"What do you want me to orchestrate?"** and wait for the response before continuing.

#### 1a. Detect SPEC reference

Check the description for a SPEC reference. Three forms are recognized:

1. **Bare id** (the canonical form `/gaia-spec` hands off): `$ARGUMENTS`, trimmed, is exactly `SPEC-\d+` and nothing else, e.g. `SPEC-026`.
2. **Path form**: a path matching `.gaia/local/specs/SPEC-\d+/SPEC\.md` appears anywhere in the description.
3. **Prefix form** (the older, verbose handoff shape, still accepted for pasted history): a `SPEC-\d+:` prefix at the start of the description.

If any form matched, extract the `SPEC-\d+` id from wherever it appeared (the bare token, the path segment, or the text before the colon), then resolve it against the actual filesystem, self-healing a zero-padding mismatch (e.g. `SPEC-026` also resolves from the bare `SPEC-26`):

```bash
# Main checkout root: SPEC folders are main-anchored state (state registry
# specs-main), reachable from a linked worktree only through main.
ROOT="$(bash .gaia/scripts/main-root-lib.sh)"
RAW="<the SPEC-\d+ id extracted above, e.g. SPEC-026 or SPEC-26>"
NUM="${RAW#SPEC-}"
PADDED="SPEC-$(printf '%03d' "$((10#$NUM))")"
SPEC_ID=""
for CANDIDATE in "$RAW" "$PADDED"; do
  if [[ -f "${ROOT}/.gaia/local/specs/${CANDIDATE}/SPEC.md" ]]; then
    SPEC_ID="$CANDIDATE"
    break
  fi
done
```

If `SPEC_ID` is still empty (no folder resolves), stop and surface: `"No SPEC found for <RAW>. Check the id and try again."` Do not fall back to a spec-less plan silently, a SPEC reference that resolves to nothing is a typo, not an intentional spec-less request.

Once `SPEC_ID` resolves:

1. Cache `SPEC_DIR="${ROOT}/.gaia/local/specs/${SPEC_ID}"` and the absolute `SPEC_PATH="${SPEC_DIR}/SPEC.md"` for use in the planner prompt (step 4), the planner will reference it in `README.md`.
2. Read `SPEC_PATH`. Its full content is the source-of-truth feature description; any dispatch summary in the original description is just a label.
3. Check for a sibling audit: if `${SPEC_DIR}/AUDIT.md` exists, cache its absolute path as `AUDIT_PATH` for use in step 4, the planner reads it too. If absent, `AUDIT_PATH` is unset.
4. Cache the lowercased SPEC id (`spec-005`) as `SPEC_SLUG_SEED` for use in step 4's branch-naming policy.

If no SPEC reference is detected, `SPEC_SLUG_SEED`, `SPEC_PATH`, and `AUDIT_PATH` are unset; step 3 allocates a `PLAN-NNN` id from the local ledger for the spec-less plan.

Colocated plans live inside the SPEC folder, so plan→SPEC discovery is structural and needs no `SPEC_SLUG_SEED` prefix on a `plans/` slug. `SPEC_SLUG_SEED` is retained for the branch-name marker (step 4's branch policy) and human-facing labels. `SPEC_PATH` additionally seeds `SPEC_DIR` (its parent directory) for plan-directory resolution in step 3.

### 2. Check model

The deep synthesis runs in the planner spawned at step 4, and the planner's model is pinned at spawn time, so it can be a top-tier model even when this orchestration runs on Sonnet. Opus and Fable are both top-tier planning models. Decide the planner's model:

- If you are on Opus or Fable, the planner inherits your current model; skip to step 3.
- If you are running non-interactively (a headless or automation context with no interactive user to prompt), default the planner to Opus: spawn it with `model: opus` at step 4. Skip to step 3.
- Otherwise (you are on Sonnet, Haiku, or another lesser model) call `AskUserQuestion` with:
  - question: `"You're on [model name]. Which model should plan?"`
  - header: `"Model"`
  - options:
    - `{ label: "Use Opus (Recommended)", description: "Spawn the planning agent on Opus for higher-quality plans." }`
    - `{ label: "Use Fable", description: "Spawn the planning agent on Fable, also a top-tier planning model." }`
    - `{ label: "Use [model name]", description: "Keep the current model." }`
  - If the user picks Opus: spawn the agent with `model: opus`.
  - If the user picks Fable: spawn the agent with `model: fable`.
  - If the user picks the current model: spawn without a model override (inherit current).

This decision governs the **planner** only. The plan's **execution** sub-agents are a separate decision: they default to Sonnet, pinned in the `ORCHESTRATOR.md`/`KICKOFF.md` the planner writes (see the Sub-agent invocation bullet in `.claude/skills/gaia/references/plan/planner.md`). Do not conflate the two.

### 3. Resolve plan directory

**Spec-derived plans colocate inside their SPEC folder**, at `<SPEC_DIR>/plan[-N]` where `SPEC_DIR` is the SPEC's parent directory (`.gaia/local/specs/<SPEC-ID>`); the plan basename is `plan`, not a slug. **Spec-less plans live under `plans/PLAN-NNN`, where `PLAN-NNN` is a monotonic id allocated from the local `plans/ledger.json` ledger** (the same treatment SPECs get). The description lives in the ledger `subject`, not the folder name.

Resolve the absolute plan directory, then create it. The spec-derived arm suffixes `-2`, `-3`, … if a colocated plan folder already exists; the spec-less arm allocates a fresh `PLAN-NNN`, so it never collides:

```bash
# Main checkout root: plan and SPEC folders are main-anchored state (state
# registry plans-main / specs-main), so PLAN_DIR and the allocator operand point
# at main even when /gaia-plan runs from a linked worktree.
ROOT="$(bash .gaia/scripts/main-root-lib.sh)"
if [[ -n "${SPEC_PATH:-}" ]]; then
  # Spec-derived: colocate the plan inside its SPEC folder.
  SPEC_DIR="$(dirname "$SPEC_PATH")"          # .../.gaia/local/specs/SPEC-NNN
  PLAN_DIR="${SPEC_DIR}/plan"
  n=2
  while ! mkdir "$PLAN_DIR" 2>/dev/null; do
    PLAN_DIR="${SPEC_DIR}/plan-${n}"
    n=$((n+1))
  done
else
  # Spec-less one-off: allocate a monotonic PLAN-NNN from the local ledger.
  # The allocator's union counts existing folders, so it always returns a fresh
  # number; no collision-suffix loop needed.
  DESCRIPTION="<feature description from step 1>"
  PLAN_ID="$(bash .gaia/scripts/spec/plan-allocator.sh next "$ROOT" "$DESCRIPTION")"
  PLAN_DIR="${ROOT}/.gaia/local/plans/${PLAN_ID}"
  mkdir -p "$PLAN_DIR"
fi
```

Cache the resolved absolute `PLAN_DIR`; pass it in step 4's dispatch and the kickoff prompt in step 5. The collision suffix lets parallel `/gaia-plan` invocations coexist on the spec-derived arm without overwriting each other; the spec-less arm does not collide, the allocator serializes concurrent callers under a mutex.

### 4. Spawn planning agent

The planner reads its own instructions from `.claude/skills/gaia/references/plan/planner.md`. Do not Read that file on this thread and do not paste it into the prompt: the dispatch carries only this plan's inputs. A planner that skipped the file writes a plan without the step sentinels, which step 4.5 rejects.

Read the checkout root with one plain `git rev-parse --show-toplevel` (a command substitution around `git` is refused inside a worktree). Then launch one `general-purpose` Agent with the step-2 model and this prompt, filling each `<...>`:

```
Your first action, before writing anything: Read <checkout root>/.claude/skills/gaia/references/plan/planner.md to its last line, paging with offset if one Read does not reach the end. Then follow it exactly, with these inputs:

PLAN_DIR: <absolute PLAN_DIR from step 3>
SPEC_PATH: <absolute SPEC_PATH from step 1a, or unset>
AUDIT_PATH: <absolute AUDIT_PATH from step 1a, or unset>
BRANCH_ID: <SPEC_SLUG_SEED when SPEC_PATH is set, else PLAN_ID>
Feature: <the feature description from step 1>
Correction: <path to the surviving findings under PLAN_DIR/audit/; omit this line unless re-spawning from step 4.6b>
```

### 4.5. Verify the planner's output

After the planner returns, read the checkout root with one plain command (`git rev-parse --show-toplevel`; a command substitution around `git` is refused inside a worktree) and carry the printed path as `ROOT`. Then confirm the required artifacts exist (and warn on any surviving scratch):

```bash
ROOT=<printed checkout root>
PLAN_REL="${PLAN_DIR#"$ROOT/"}"
# The planner deletes its own .work/ before returning; this is a verify-only
# backstop. If scratch survived (e.g. the planner crashed mid-run), warn instead
# of force-deleting: .gaia/local/plans/ is gitignored so leftover scratch is
# harmless clutter, and a verify-only step needs no rm-permission prompt on
# every run. Remove it manually if the warning fires.
[ -d "$PLAN_REL/.work" ] && echo "WARNING: planner scratch survived at $PLAN_REL/.work; remove it manually if unneeded."
test -f "$PLAN_DIR/README.md" \
  && test -f "$PLAN_DIR/ORCHESTRATOR.md" \
  && test -f "$PLAN_DIR/KICKOFF.md" \
  && ls "$PLAN_DIR"/task-*.md >/dev/null 2>&1
```

If any required file is missing, surface the failure to the user with the planner's return payload. Do not retry silently, the user decides whether to re-spawn or investigate. Never proceed to step 4.6 with an incomplete plan folder.

Then run the deterministic plan check. It confirms the generated `ORCHESTRATOR.md` carries every verbatim step sentinel the plan needs, in order, and for a spec-derived plan that the README's UAT routing table validates against the SPEC and every `story`-routed UAT has its criterion line in a task doc. It also rejects an unsubstituted `{PLAN_DIR}`, `{SPEC_PATH}` or `{AUDIT_PATH}` in any generated plan file (`ORCHESTRATOR.md`, `KICKOFF.md`, `README.md`, `task-*.md`):

```bash
if [[ -n "${SPEC_PATH:-}" ]]; then
  bash .gaia/scripts/spec/plan-verify.sh "$PLAN_DIR" --spec "$SPEC_PATH"
else
  bash .gaia/scripts/spec/plan-verify.sh "$PLAN_DIR"
fi
```

A non-zero exit is handled exactly like a missing file: surface its output to the user, do not retry silently, and do not proceed to step 4.6. `WARN:` lines on a passing run are surfaced too; they flag a UAT that may be misrouted. This check runs even when step 4.6 skips the decomposition audit.

### 4.6. Adversarial decomposition audit

A lightweight multi-agent audit of the **decomposition itself**, the one artifact neither the upstream SPEC audit nor the downstream pre-merge Code Audit Team audit can inspect: parallel lens agents check that the task graph is a sound factoring of the work, that the frozen interface contracts resolve against the real repo, and that the SPEC's binding criteria are all covered, before a cold orchestrator builds against a flawed plan.

**The audit runs automatically on a non-trivial plan; the gauge decides.** After step 4.5 confirms the artifacts exist, gauge the plan (below) and act on the gauge with no prompt: run the audit when the plan is non-trivial, skip it when the plan is trivial. There is no user choice; the gauge is the whole decision.

**Gauge the plan (this is the decision).** Read `README.md` and the `task-*.md` files once. A trivial plan (one or two tasks, a single phase, no cross-task interface contract) → **skip the audit** and proceed to step 4.7. Anything with parallel tasks in a phase, multiple phases, or a shared frozen contract → **run the audit**. A skipped trivial plan writes no audit-window breadcrumb; its absence is the correct signal to the step-4.7 tally that no decomposition audit ran.

**Auto-mode.** Identical to interactive: gauge the plan, run the audit if it is non-trivial, apply its dispositions non-interactively. Interactive and auto now differ only in how 4.6b surfaces findings, not in whether the audit runs.

**Fallback (never block).** If the parallel `general-purpose` Agent fan-out is unavailable (a restricted context that cannot spawn subagents), do NOT block the handoff: note the skip (`decomposition audit unavailable`) and proceed to step 4.7. The orchestrator's per-phase quality gates and the non-skippable pre-merge Code Audit Team audit remain the safety net. This path, like a trivial-plan skip, writes no audit-window breadcrumb.

To run the audit, read `.claude/skills/gaia/references/plan/decomposition-audit.md` and `.claude/skills/gaia/references/spec/lens-dispatch.md` now, each whole, and run the audit. A skipped or unavailable audit goes straight to step 4.7.

### 4.7. Token tally

The plan folder is written and verified, so every planner/auditor sub-agent this action spawned has
flushed its sidecar to disk. Tally the `/gaia-plan` session's ground-truth token cost before the
handoff. The call sums `message.usage` across the main transcript AND every sub-agent sidecar
(deduped by message id, so it equals what the API billed), appends one record keyed to the feature
identity to the durable ledger resolved to the main checkout (so it survives archival of the plan
folder and a linked worktree), writes the plan folder's `cost.json` sidecar (the `plan` record), and
prints the four billing buckets plus a total and the elapsed time. The KICKOFF execution phase
later adds an independent `execute` record to the same `cost.json` (via the git-op hook, on each
commit); the two records are tracked separately and never overwrite or sum each other. A spec-derived
plan passes its SPEC id via `--spec-id`; a SPEC-less plan passes its `PLAN-NNN` id via `--plan-id`
instead, exactly one of the two flags, never both, matching the ledger's `spec_id`-XOR-`plan_id`
contract:

```bash
PLAN_SLUG="$(basename "$PLAN_DIR")"
if [[ -n "${SPEC_PATH:-}" ]]; then
  TALLY_SPEC_ID="$(basename "$(dirname "$SPEC_PATH")")"   # -> SPEC-NNN
  bash .gaia/scripts/token-tally.sh \
    --action plan \
    --spec-id "$TALLY_SPEC_ID" \
    --plan-slug "$PLAN_SLUG" \
    --out-dir "$PLAN_DIR" || true
else
  # SPEC-less plan: PLAN_SLUG is the PLAN-NNN id allocated in step 3, so it
  # doubles as both the feature identity and the cost.json record's plan_slug field.
  bash .gaia/scripts/token-tally.sh \
    --action plan \
    --plan-id "$PLAN_SLUG" \
    --plan-slug "$PLAN_SLUG" \
    --out-dir "$PLAN_DIR" || true
fi
```

The helper always exits 0, and the trailing `|| true` is defense-in-depth: this **never blocks the
handoff**, and unreadable input degrades to a partial figure with a marker rather than a fabricated
number. It is a mechanical helper call, not a prompt, so it runs identically in interactive and auto
(`AskUserQuestion`-less) mode. The step-5 report surfaces the cost from this tally, using the pinned one-line format defined there. This same
call reads and deletes the step-4.6 audit-window breadcrumb (the feature-namespaced
`audit-window-<spec_id>-plan.json` or `audit-window-<plan-id>.json`) if present, nesting an
`audit.adversarial` annotation into this `plan` record when the window resolves.

### 5. Report to user

Output a short summary of what's in `$PLAN_DIR/`, then report the cost as exactly one line (do not restate the four-bucket tally block), then emit the copy-paste prompt the user drops into a fresh Claude Code session to start the orchestrator cold.

Cost line: `Cost: ~<total> tokens, $<dollars>, <elapsed>`, where `<total>` is the token count abbreviated to millions with one decimal and a `~` prefix (e.g. `~2.4M`), `<dollars>` is `$X.XX`, and `<elapsed>` is the `<N>h<M>m<S>s` figure. Source the figures by whether the plan derives from a SPEC:

- **Spec-derived** (`SPEC_PATH` set): the step-4.7 tally has already written the `plan` ledger row, so read the running spec+plan cycle from the roll-up reader, substituting the plan's `SPEC-NNN` id (the one derived in step 4.7):

  ```bash
  if [ -x .gaia/scripts/token-rollup.sh ]; then
    bash .gaia/scripts/token-rollup.sh --spec-id "<SPEC-NNN>" || true
  fi
  ```

  Take `<total>`, `<dollars>`, and `<elapsed>` from the reader's grand `Total` and `Est. cost (USD)` total lines, and append a stage breakdown `(spec $X.XX + plan $X.XX)` from its per-stage dollar rows.
- **Spec-less** (`--plan-id` path): take total and elapsed from the step-4.7 printed tally and read `<dollars>` from the `dollars` field of the `plan` record in `$PLAN_DIR/cost.json`; emit the line with no breakdown.

Never fabricate: if a dollar figure is null or unpriced write `cost unavailable` in its place; if elapsed is unavailable drop that term; if any figure is a partial lower bound append ` (partial: lower bound)`. This line reads identically to the `/gaia-spec` cost line (spec reference, step 9) and the orchestrator's full-cycle line; keep the three in sync.

The prompt is a single line, exactly:

```
Read <absolute-path-to-PLAN_DIR>/KICKOFF.md and execute it.
```

For example `.../.gaia/local/specs/SPEC-NNN/plan/KICKOFF.md` for a spec-derived plan, or `.../.gaia/local/plans/{slug}/KICKOFF.md` for a spec-less plan. Use `$PLAN_DIR/KICKOFF.md` (the absolute path resolved in step 3). The path MUST be absolute so the cold Claude session has no working-directory ambiguity. Do not include any other instruction, the orchestrator's behavior lives in `KICKOFF.md`.

**Print the prompt as a fenced code block** so the user can select and copy it manually.

Then print one trailing line: `Type /clear and paste the prompt above.`
