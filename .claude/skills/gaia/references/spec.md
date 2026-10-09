# /gaia-spec

GAIA's script-driven Socratic discovery workflow. Produces an immutable SPEC artifact at `.gaia/local/specs/SPEC-NNN/SPEC.md` and stops. Do not implement anything, and do not plan anything, this skill produces an artifact and ends. The `/gaia-plan` handoff is a prompt you print for the human (step 11), never a command you run. See Hard constraint 6.

The procedures only some runs or only one stage need live in sub-references under `.claude/skills/gaia/references/spec/`, each read whole at its branch point, where a line here says to Read it now. Never skip such a line: the procedure it names is not restated here.

Contents: Argument parsing; Auto mode; Hard constraints; Operational primitives (MAIN_ROOT contract, tool-choice contract, Session-shape cache, Session-lock, Working-draft checkpoint, Audit cache + delegated fold, Abandoned exit, Don't re-quote folded clarifications); Steps (model gate, 1 description, 2 resume-vs-start-new, 3 initial draft, 4 gate 1, 5 Socratic loop, 6 self-review, 7 adversarial SPEC-audit, 8 gate 2, 9 save and ledger and cost, 10 immutability lint, 11 /gaia-plan handoff, then STOP).

## Argument parsing

Tokenize the first whitespace-separated word of `$ARGUMENTS`:

- If it is `auto`, set `auto_mode = true`, strip the token, and treat the remainder as the feature description (which may be empty, see Auto mode below).
- Otherwise `auto_mode = false` and the entire `$ARGUMENTS` is the feature description.

`auto_mode` is referenced throughout the steps below; every user-facing prompt has an auto-mode branch.

## Auto mode

When `auto_mode = true` the agent answers the Socratic questions itself rather than asking the user. **The Socratic loop's ceiling in auto mode is 5 substantive questions** (see `## The question ceiling` in `spec/clarify-loop.md`). The flow is non-interactive end-to-end: no `AskUserQuestion` calls fire, no plain-prompt blocks wait for human reply. The agent makes best-judgment calls using the description, the draft state, and any research it dispatches.

Hard rules in auto mode:

1. **Description is required.** If the remainder of `$ARGUMENTS` after stripping `auto` is empty, abort with: `"/gaia-spec auto requires a description. Re-invoke as: /gaia-spec auto <description>"`. Do not prompt for one, the user opted out of interactivity.
2. **Resume vs start-new is automatic.** If the allocator reports an unfinalized draft SPEC, **start new** without prompting. The user's `auto` invocation is itself the signal that they want a fresh artifact.
3. **Both gates auto-confirm.** Gate 1 and gate 2 do not present plain prompts to the user. The agent renders the draft to its own reasoning context, performs a self-check (is intent coherent? are UATs Given/When/Then? do UATs cover the intent?), and proceeds. If the self-check finds an issue, the agent revises in-place and re-checks once before proceeding, never blocks for human input.
4. **Closed-set Socratic questions pick the Recommended option.** For every step-5 `AskUserQuestion` that would normally fire, the agent selects the option that step 5a's spec marks "Recommended FIRST", the PO's best-judgment candidate. No `AskUserQuestion` tool call is made. The selected answer is folded into `clarifications.answered[]` exactly as if the user had picked it.
5. **Open-ended Socratic questions are answered by the agent.** Apply the same coach-tone judgment the human would receive, then commit the answer. Fold into `clarifications.answered[]`.
6. **Per-topic exhaustion + revisit checkpoints auto-advance.** Step 5d always picks "Move to <next topic>". The per-topic revisit counter still increments but the 3-revisit prompt auto-picks "Settle on the recommended option".
7. **Research subagents still dispatch.** Auto mode does not skip research, it skips human prompting. When step 5e would dispatch a `general-purpose` Agent, dispatch it normally. On `inconclusive`/`error`/`contradictory` outcomes that would normally re-prompt the user, the agent picks the most plausible candidate and folds it with a note in `research_summary` flagging the uncertainty.
8. **Self-review high findings auto-apply.** Step 6b's high-severity branch normally surfaces each finding to the user; in auto mode, apply the `suggested_fix` and append a note to `clarifications.deferred[]` summarizing the finding so a reviewer can audit later. Do NOT silently revert clarify-loop evolution, if the finding is `kind: "drift"` or `"scope_change"` and the change came from a clarify answer the agent itself just made, prefer keeping the clarify answer over reverting to gate-1 shape.
9. **Pending clarifications auto-defer.** Step 6c's per-item prompt always picks "Defer with rationale". The rationale is: `"Auto-mode session, defer for human review."` This unblocks save without forcing the agent to fabricate answers it does not have evidence for.
10. **Lint thrash escalates to defer, not step-back.** Step 10's cycle-3 prompt auto-picks "Defer remaining findings" so the SPEC saves with the deferred-clarifications block populated. Step-back-to-gate-2 in auto mode would loop indefinitely.
11. **`Save partial and resume later` escapes are unreachable.** No prompt fires that would offer them. The session always proceeds to step 9 unless the agent itself decides to abort (e.g. missing description, hard tool failure).
12. **Adversarial audit runs at the gauged intensity, non-interactively.** Step 7 no longer prompts anyone for an audit decision (interactive and auto both gauge and run); auto mode gauges the draft and runs the audit at the gauged tier, never skipping. Gauge the draft's complexity, run the audit at that tier (Standard or Deep), and apply its dispositions without prompting: auto-apply plan-time directives into `AUDIT.md`, auto-apply unambiguous SPEC-contract-defect fixes into the draft pre-save (no reopen ceremony, the draft is unsaved), and for any contract defect with more than one defensible repair, record it in `clarifications.deferred[]` with rationale `"Auto-mode audit, defer for human review."` rather than guessing. Never block save; never revert intentional clarify-loop evolution. Throughout the audit and fold phase auto mode reads **no finding body** (a finding's `issue`/`evidence`/`recommendation`, or a self-review finding's `suggested_fix`/`excerpt`); the transcript carries only ids, severities, titles, verdicts, and dispositions. The two bounded exceptions where a finding body reaches main (6b high self-review findings, 7c material spec-defect survivors) are interactive-only; auto mode surfaces neither. The one other case, auto mode included, is a lens that went silent twice and ran inline on the main thread (the inline-lens exception in `spec/audit.md`). If the Agent fan-out is unavailable, take step 7's fallback (note the skip, rely on the step-6 self-review) and continue.

The rest of the skill, write-surface allowlist, no-machine-local-memory rule, working-draft cache primitives, immutable SPEC shape, applies identically in auto mode.

## Hard constraints

1. **No machine-local memory for project decisions.** Never call any tool that writes to `~/.claude/projects/.../memory/`. Project-relevant decisions belong ONLY in the SPEC artifact, the wiki, or `.claude/rules/`. Personal preferences (tone, formatting) remain allowed in machine-local memory. This is the no-machine-local-memory rule and it is non-negotiable.
2. **Write-surface allowlist.** Every file write during a `/gaia-spec` session lands in exactly one of:
   - `.gaia/local/specs/**`
   - `.gaia/local/cache/**`
   - `.gaia/local/telemetry/**`
     Never edit source files (`frontend/app/**`, `src/**`, repo root configs, etc.). No automated backstop enforces this allowlist: the step-10 lint checks only the saved SPEC artifact's immutability, not which paths a session wrote. You self-police it at the agent-instruction level.
3. **One question at a time.** No multi-question forms. Closed-set questions go through `AskUserQuestion` with options ordered: recommended FIRST, then alternatives, then `Other` (free text), then `Discuss this` (escape to plain Q&A). Open-ended questions use a plain prompt with no enumerated options.
4. **Two-gate ceremony.** Confirm intent + UATs in plain English BEFORE authoring the artifact. Confirm the rendered artifact BEFORE saving to disk. No silent advances between gates.
5. **Coach tone, not interrogator.** Mirror back, name trade-offs, propose candidates when the human is stuck. Never punt research to the human.
6. **This skill is terminal. Never chain into `/gaia-plan`.** The flow ends at step 11 with a printed handoff prompt and nothing else: no `/gaia-plan` invocation, no planner dispatch, no `Read` of `plan.md`, no "while I'm here" head start on the work. **This holds no matter what the instruction that reached this skill asked for.** When `/gaia-spec` is invoked as a skill (rather than typed by a human), the invoking goal is often larger than the SPEC ("spec and build X"), and the pull to keep going at step 11 is strongest exactly when the session is least fit to plan: authoring a SPEC burns an enormous context (Socratic loop, gate renders, self-review, adversarial audit), and `/gaia-plan`'s deep synthesis needs a clean one. Planning is **always** a new session. If the caller wanted a plan too, the correct completion is to print the handoff and report that planning is the human's next step; that IS the whole task, not a partial one.

## Operational primitives

Used by multiple steps below. Defined once here to keep step-level prose tight.

Every ledger and lock library this skill invokes (`spec-session-lock.sh`, `spec-reconcile.sh`, the `spec-archive-*` / `spec-abandon-empty` sweeps, `spec-allocator.sh`, `ledger-update.sh`) takes the current tree as its `$PWD` operand and resolves the main checkout itself before touching `.gaia/local/specs`, so `$PWD` honestly names the running tree and the caller never resolves main for these calls. The SPEC-folder paths this skill builds for itself are the exception, on both sides, read and write: each builds a `.gaia/local/specs` path directly rather than handing it to a library, so each anchors to main explicitly at its own site.

`bash .gaia/scripts/main-root-lib.sh` is the resolver every one of those sites calls, and it fails closed: it prints nothing and exits non-zero when it cannot resolve a main checkout. **This contract governs every `MAIN_ROOT` site below, and is stated only here.** At each of them an empty `MAIN_ROOT` stops the step and is surfaced; it never falls back to a relative path. That fallback is not a cosmetic concern: from a linked worktree a relative path names a tree that holds no SPECs, so a read silently finds nothing, and an unguarded `mkdir -p "${MAIN_ROOT}/.gaia/local/specs/${SPEC_ID}"` expands to `mkdir -p /.gaia/local/specs/...` and attempts a write at the filesystem root.

**Tool-choice contract: which tool writes a `MAIN_ROOT`-anchored path governs every write site below, and is stated only here.** From the main checkout the ordinary `Edit`/`Write` tools write it and nothing else applies. From inside a linked worktree they cannot reach it at all: the harness isolates the session to that worktree and refuses a `file_path` resolving to the shared checkout, and a linked worktree reaches `.gaia/local` through one symlink to the main checkout, so both spellings of the path land on the same refused target. Every write this skill directs into the resolved SPEC folder (`SPEC.md`, `AUDIT.md`, `SUMMARY.md`, and any sibling) takes the same fallback there: write it with `Bash` at its main-checkout absolute path, then read it back and confirm both its content and its location before continuing. The read-back is what makes the fallback safe rather than a dodge, since the failure the discipline exists to prevent is a write landing in the wrong tree, and it stays scoped to these main-anchored paths: a `Bash` redirect is never the way to write into another checkout where the edit tools already work. `.claude/skills/gaia/references/plan/planner.md` states the same rule for the plan ledger.

### Session-shape cache (`spec-session-<spec_id>.json`)

Tracks `start_at` and `question_count` across the multi-step flow. `question_count` enforces the Socratic question ceiling across a pause and resume, the sole counter for that ceiling. The file lives at `.gaia/local/cache/spec-session-<spec_id>.json`. Schema:

    {
      "spec_id": "SPEC-NNN",
      "start_at": "2026-05-06T18:00:00.000Z",
      "question_count": 0
    }

Three operations:

- **Init.** At step 2 (both fresh and resumed paths), write the file if it does not exist with `start_at` = current ISO-8601 UTC ms, `question_count` = 0. On resume, leave any existing file untouched: its `start_at` is the original session start, preserved across resumes so a resumed session does not get a fresh question budget.
- **Increment.** At the substantive-question sites (steps 5a, 5b, and 5c), bump `question_count` by 1. These are the substantive questions, and they are the only things that count against the ceiling. The loop's meta-prompts, 5d's exhaustion checkpoint, the 3-revisit settle prompt, and the research-outcome prompts never increment `question_count`. Inline shell:

      jq '.question_count += 1' .gaia/local/cache/spec-session-<spec_id>.json \
        > .gaia/local/cache/spec-session-<spec_id>.json.tmp \
        && mv .gaia/local/cache/spec-session-<spec_id>.json.tmp \
           .gaia/local/cache/spec-session-<spec_id>.json || true

- **Delete.** At step 9 (after canonical save) and at every abandoned-exit branch other than the `Save partial and resume later` escape (see "Abandoned exit" below), `rm -f .gaia/local/cache/spec-session-<spec_id>.json`.

Failure of any cache read/write must never block the flow.

### Session-lock (`spec-session-<spec_id>.lock`)

A per-draft liveness marker at `.gaia/local/cache/spec-session-<spec_id>.lock`, recording the session-host process authoring the draft. Its acquire and release sites are inline: acquire at step 3 (and on a resume), release at step 9, the `Save partial and resume later` escape, and the abandoned exit. It never blocks authoring: any lock-subsystem error fails open. `spec/resume.md` holds the liveness verdicts (`live`, `dormant`, `error`) and what step 2 does on each.

### Working-draft checkpoint (`draft-<spec_id>.md`)

After each clarify fold (step 5), each gate confirmation (steps 4 + 8), each research-result fold (step 5e), each self-review apply (step 6), and each audit-finding apply (step 7), persist the current in-flight draft to `.gaia/local/cache/draft-<spec_id>.md`. Step 9's canonical save deletes this cache as its final action.

**Single-`Write` rule.** Compose the full updated draft in working memory, then emit ONE `Write` tool call that overwrites the cache file. Never use a sequence of `Edit` calls for a single fold. The Q&A loop runs many turns per session and each `Edit` renders a full diff in the user's chat, multiple per-turn diffs are visual noise the user has flagged as unwanted.

The single-Write-per-fold discipline holds, but the writer depends on the checkpoint. For a **clarify-loop fold** (a step-5 Q&A turn, a gate confirmation), the per-turn budget is exactly: one `Write` for the fold from the main thread, one `Bash` for the `question_count` increment, nothing else. For a **delegated fold checkpoint** (an approved self-review high at 6b, the audit spec-defect fold at 7c, a gate-2 revision), the single Write is **owned by the applier subagent** (see "Audit cache + delegated fold" below), and the main thread's per-turn action at that checkpoint is the **applier dispatch** (an Agent call), not a `Write`. Do not emit a main-thread draft `Write` at a delegated fold checkpoint.

**Per-turn fold contents.** When folding a Q&A turn (closed-set selection, `Other` text, open-ended answer, or Discuss-this settlement): add to `clarifications.answered[]` as `{ q, a }`, remove the topic from `clarifications.pending[]`, and update any statusline fields the answer touches, all in the same `Write`.

This makes interrupted sessions resumable: step 2 reads the cache if it is newer than the canonical artifact.

### Audit cache + delegated fold

The self-review (step 6) and adversarial audit (step 7) route their finding, verdict, and draft bodies through a per-spec **audit cache** on disk and a **delegated-fold applier** subagent, so the main thread holds only thin lines (id, severity, title, verdict, disposition) plus a few applier summaries. Finding bodies, verdict bodies, refuter bodies, and full-draft folds do not flow back through main during a fold, with exactly two bounded interactive carve-outs (6b high self-review findings, 7c material spec-defect survivors).

**Audit cache directory** `.gaia/local/cache/audit-<spec_id>/`. Every file the self-review and audit produce lands here:

- `findings/<LENS>.json`: one per dispatched lens, written even when the findings array is empty (so the file count equals the dispatched-lens count deterministically).
- `findings/self-review.json`: the step-6 self-review (6a schema).
- `findings/completeness.json`: the Deep completeness critic (the findings file schema in `spec/lens-dispatch.md`).
- `verdicts/<finding-id>.json`: a Standard single-refuter verdict, or a batched refuter's verdict on either tier (7b-i, above the cap).
- `verdicts/<finding-id>-<refuter-lens>.json`: a Deep verdict, one per refuter lens. The refuter lens is **slugified**: `correctness` stays `correctness`, `security/safety` maps to `security-safety`, `reproduces-as-described` stays as is. The completeness critic's single-refuter verdicts use the same naming.

Per-lens and per-finding-plus-lens filenames avoid write collisions in the parallel fan-out: each agent owns exactly one path, so many agents write the cache concurrently without contending.

**Delegated fold.** At a delegated fold checkpoint the fold is performed by a single-writer subagent, not by main; it replaces an in-main fold at that checkpoint. Main dispatches a `general-purpose` Agent (the **applier**) with five inputs: the draft path (`.gaia/local/cache/draft-<spec_id>.md`), the audit-cache directory (`.gaia/local/cache/audit-<spec_id>/`), the main-anchored SPEC folder `${SPEC_DIR}` that main resolved for it (7c), the tool-choice contract from Operational primitives, which governs the applier's own write into that handed folder, and the thin **decision list**:

    [ { "id": "<finding-id>", "action": "apply"|"keep"|"revise", "revision": "<free text, optional>" } ]

An **id-less** entry carries its `revision` text inline (free-text revision mode); the applier applies it directly with no findings-file lookup (gate-2 free-form edits route this way).

The applier **reads every findings and verdict file in the cache** (not just the decision-list ids). For each id-carrying `apply`/`revise` entry it looks the fix up **by id in the findings files**; main never holds the recommendation text. For each id-less entry it applies the inline `revision` (free-text mode, no findings-file lookup). It folds every applicable fix into the draft cache in **one Write** and returns a one-line summary:

    { "folded": [<ids>], "directives": [<ids>]?, "revised": [<ids>]?, "counts": { "folded": <int>, "directives": <int>, "revised": <int> } }

`directives` is optional (absent for pure draft folds); it lists finding ids routed to `AUDIT.md` as plan-time directives. The `counts` object is the pinned **fold-outcome** schema that the applier's own reporting reads.

Reading the full cache (rather than only the listed ids) is what lets the applier both author `AUDIT.md` from the complete on-disk record (see 7d) and fold the **low-severity spec-defect fixes main never surfaced**: the decision list carries only the interactively-gated material survivors, and low spec-defects are folded silently by the applier from the on-disk findings files. When the fold routes any finding to a plan-time directive, the applier also writes `AUDIT.md`, at the `${SPEC_DIR}` path it was handed; it resolves no path of its own.

**Fallback.** If subagent dispatch is unavailable, the main thread folds inline itself, writing `AUDIT.md` at that same resolved path.

### Abandoned exit

For any branch that exits the wrapper without reaching step 9, other than the `Save partial and resume later` escape (`spec/clarify-loop.md`, `## Escape option`), which keeps its cache for a future resume:

```bash
rm -f .gaia/local/cache/spec-session-${SPEC_ID}.json
# Release the session lock (abandoned exit): the holder drops its own lock so
# an aborted-but-surviving-host session never leaves a false-live marker.
bash .gaia/scripts/spec/spec-session-lock.sh release "$PWD" "$SPEC_ID" || true
```

### Don't re-quote folded clarifications

Once a Q&A pair has been folded into the draft's `clarifications.answered[]` (step 5b) or `clarifications.deferred[]` (step 6c), it is canonical. Do NOT re-paste the raw question or answer text into downstream prompts (gate 2, self-review, gate 2 revisions). Reference the draft's structured arrays instead. This keeps wrapper context lean across the multi-step flow.

## Steps

### Model gate (pre-flight)

Runs on entry, before step 1, before any SPEC id is allocated or any file is written, so a "switch" outcome stops cleanly with nothing to clean up. **Auto-mode exception:** skip this section entirely. Auto mode is non-interactive; it neither prompts nor stops, it proceeds on whatever model the automation runs.

SPEC synthesis, the two-gate ceremony, the Socratic clarify loop, and the gate confirmations, runs on the **main thread**, so it uses your current session model. Unlike `/gaia-plan`, this skill cannot pin a subagent to a better model: its `AskUserQuestion` and plain-prompt steps do not work inside dispatched subagents, so there is no spec-writer subagent to spawn on Opus. The only way to synthesize on a top-tier model is to run the session itself on one. Opus and Fable are both top-tier.

- If you are on Opus or Fable, proceed to step 1 (no prompt).
- Otherwise (you are on Sonnet, Haiku, or another lesser model) call `AskUserQuestion` with:
  - question: `"You're on [model name]. SPEC synthesis runs on your session model. Switch to a top-tier model first?"`
  - header: `"Model"`
  - options:
    - `{ label: "Switch to Opus (Recommended)", description: "Highest-quality specs. Stops here so you can switch, then re-run /gaia-spec." }`
    - `{ label: "Switch to Fable", description: "Also a top-tier planning model. Stops here so you can switch, then re-run /gaia-spec." }`
    - `{ label: "Stay on [model name]", description: "Author the SPEC on the current model without switching." }`
  - If the user picks Opus or Fable: do **not** start the workflow. Print exactly one instruction and STOP: `"Switch with /model (pick <chosen model>), then re-run /gaia-spec <description>."` Interpolate `<chosen model>`; if a feature description was supplied as an argument, echo it in place of `<description>` so the re-run is a single paste, otherwise drop the `<description>` placeholder. Allocate no SPEC id, write no files, author nothing.
  - If the user picks "Stay": proceed to step 1 on the current model.

### 1. Get description

If `$ARGUMENTS` (the args after `spec`, with `auto` already stripped if present, see Argument parsing) is non-empty, use it as the feature description.

Otherwise, ask: **"What do you want to spec?"** and wait for the response before continuing. This is open-ended, use a plain prompt, not `AskUserQuestion`. **Auto-mode exception:** in auto mode an empty description is a hard abort per Auto-mode rule 1, never prompt.

### 2. Resume-vs-start-new prompt (pre-flight)

First, read `.claude/skills/gaia/references/spec/lifecycle.md` and run its `## Pre-flight sweep` now. It reconciles finalized rows whose PR has merged, cold-consolidates any merged folder whose layers were never consolidated, and reaps merged folders past the retention window. Its writes into a SPEC folder follow the tool-choice contract in Operational primitives.

Then delete any SPEC folder already at `abandoned` status past the same retention window (`GAIA_SPEC_RETENTION_DAYS`, default 30 days); no consolidation gate applies, since nothing about an abandoned draft is ever promoted. Then sweep any never-authored draft older than the guard age to the terminal `abandoned` status, so a ghost allocation (no SPEC.md, no draft cache, no gate-1 snapshot) stops re-surfacing on this very prompt. Both passes are best-effort and fail-open:

```bash
bash .gaia/scripts/spec/spec-archive-abandoned.sh "$PWD" 2>/dev/null || true
bash .gaia/scripts/spec/spec-abandon-empty.sh "$PWD" 2>/dev/null || true
# Best-effort sweep of stale audit caches left by "Start new" or abandoned exits.
# An audit-<id>/ cache is short-lived (created at 6a, deleted at the step-7 fallback, step 9
# save, or the step-2 discard); one untouched for over a day is orphaned. Fail-open,
# never blocks; the mtime guard cannot touch a dir an active session just wrote.
find .gaia/local/cache -maxdepth 1 -type d -name 'audit-*' -mtime +1 \
  -exec rm -rf {} + 2>/dev/null || true
```

Then run `bash .gaia/scripts/spec/spec-allocator.sh in_progress "$PWD"`. If the output is a `SPEC-NNN` id (not `none`), an unfinalized **draft** SPEC already exists, a prior authoring session that never reached the canonical save (step 9). The allocator reports only drafts; a finalized SPEC (`ready`/`merged`) is never surfaced here, because you resume a draft, not a frozen artifact.

The id may name a **draft-phase** session, a SPEC allocated in another terminal whose interactive loop has not yet reached the canonical save (step 9), so `.gaia/local/specs/SPEC-NNN/SPEC.md` may not exist yet and the live draft is at `.gaia/local/cache/draft-SPEC-NNN.md`. The `WORKING`-selection in `spec/resume.md` resolves this correctly, preferring the draft cache when the canonical file is absent or older.

**Auto-mode exception:** skip the resume prompt entirely. Always start new and proceed to step 3 with a fresh allocation. The draft SPEC (if any) remains untouched. Per Auto-mode rule 2 the user's `auto` invocation is the signal that they want a fresh artifact; resuming an existing draft into a non-interactive context risks silently overwriting work in progress.

If the allocator printed a `SPEC-NNN` id and the run is interactive, Read `.claude/skills/gaia/references/spec/resume.md` now, whole, and follow it; it returns here at step 3 or at the step its Resume branch picks. If it printed `none`, or the run is in auto mode, continue at step 3.

### 3. Initial draft (allocate, anchor, stamp)

Step 3 allocates the SPEC id, creates the main-anchored SPEC folder, and writes the first draft. Run its parts in this order.

**Subject.** The allocator subject is the step-1 description. If it is empty, first compose the draft's `# ` title in working memory and use that title. The subject is never empty.

**Allocate.** Run the allocator and capture its stdout `SPEC-NNN` token as `SPEC_ID`:

```bash
bash .gaia/scripts/spec/spec-allocator.sh next "$PWD" "<subject>"
```

On any non-zero exit, surface the allocator's stderr verbatim and halt the session: no folder, no draft, no lock. `GAIA_SPEC_FORCE_OFFLINE=1` makes the allocator skip remote reservation, which is useful for throwaway runs.

**Anchor the folder.** Create the SPEC folder in the main checkout, never in the current worktree. The block runs as-is with `SPEC_ID` already set and the cwd inside any checkout of the repo; an empty `MAIN_ROOT` stops the step and is surfaced, per the Operational primitives contract, with no relative fallback:

```bash
MAIN_ROOT="$(bash .gaia/scripts/main-root-lib.sh)"
if [ -z "$MAIN_ROOT" ]; then
  echo "gaia-spec: cannot resolve the main checkout; refusing to create the SPEC folder" >&2
  exit 1
fi
mkdir -p "${MAIN_ROOT}/.gaia/local/specs/${SPEC_ID}"
```

**Write the draft.** Read `.claude/skills/gaia/references/spec/spec-template.md`, substitute every `SPEC-NNN` with `SPEC_ID`, and stamp the GAIA frontmatter keys `spec_id`, `type`, `status`, `immutable`, `wiki_promote_default`, `chain_trigger`, `created`, and `updated` (the template carries them; `created` and `updated` become today's ISO date). Write the result with one `Write` to the working-draft checkpoint named in Operational primitives, `.gaia/local/cache/draft-<spec_id>.md`: the per-tree draft cache, not the SPEC folder. Step 9 owns the canonical save. Cache that draft path; you will read and re-render it across the rest of these steps.

Initialize the session-shape cache for the just-allocated SPEC id (no-op if it already exists from a resume):

```bash
CACHE=".gaia/local/cache/spec-session-${SPEC_ID}.json"
if [[ ! -f "$CACHE" ]]; then
  printf '{"spec_id":"%s","start_at":"%s","question_count":0}\n' \
    "$SPEC_ID" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" > "$CACHE" || true
fi
```

Acquire the session lock, right alongside the cache-init block above:

```bash
bash .gaia/scripts/spec/spec-session-lock.sh acquire "$PWD" "$SPEC_ID" || true
```

Both interactive and auto mode acquire at fresh allocation, satisfying auto-mode acquire.

### 4. Gate 1, shape confirmation

Before any Socratic clarify loop runs, present the draft's `intent` paragraph and the proposed UATs in plain English to the user. This is gate 1.

**Auto-mode exception:** skip the user-facing prompt. Read the draft's intent + UATs into the agent's reasoning context and self-check: (a) intent paragraph is coherent and matches the description; (b) every UAT follows Given/When/Then shape; (c) UATs collectively cover the intent. If any check fails, revise the draft once and re-check. Then jump to the "On confirmation" actions below (snapshot cache, draft cache). Per Auto-mode rule 3, never block for human input.

Use a plain prompt, not `AskUserQuestion`. The user reads, confirms, or revises. Suggested phrasing:

> Here's the shape I have so far:
>
> **Intent:** <intent paragraph>
>
> **UATs:**
>
> - UAT-NNN, Given … when … then …
> - UAT-NNN, Given … when … then …
>
> Does this match what you want, or should I revise before we go deeper?

If the user revises, fold revisions into the draft and re-present until they confirm.

On confirmation:

1. **Cache the gate-1 snapshot** to `.gaia/local/cache/gate1-<spec_id>.json`. The snapshot must include: the confirmed `intent`, the confirmed UAT list (with stable `UAT-NNN` IDs), and a timestamp. The step-6 self-review reads this cache to detect scope drift between gate 1 and gate 2. **Skip this write if the snapshot already exists for this `spec_id` (resumed session); its purpose is immutable drift detection.**
2. **Write the working-draft cache** per the operational primitive (`.gaia/local/cache/draft-<spec_id>.md`).

Only after gate-1 confirmation may you proceed to step 5.

### 5. Socratic loop

Read `.claude/skills/gaia/references/spec/clarify-loop.md`, `.claude/skills/gaia/references/spec/clarify-prompts.md` and `.claude/skills/gaia/references/spec/system-prompt.md` now, each whole, and run the loop. Read the two templates here and never earlier: they are reference templates, not preamble.

The coverage scan stops the loop; the question ceiling bounds it at 10 substantive questions interactive and 5 in auto mode. When the loop stops, continue at step 6.

### 6. Self-review

After the Socratic loop settles, dispatch the GAIA self-review as a `general-purpose` Agent, so the heavy reads stay in fresh context and only structured findings flow back. Read `.claude/skills/gaia/references/spec/self-review-dispatch.md` now, whole, and run 6a to 6c; it returns here at step 7.

### 7. Adversarial SPEC-audit

A multi-agent adversarial audit that hardens the draft against ground truth BEFORE gate 2 renders it. Low-overlap lenses verify the SPEC's checkable claims against the actual repo and `node_modules` (not on faith), a refutation pass keeps severity honest, and each surviving finding is routed to either a plan-time directive or a pre-save SPEC fix. Because it runs pre-save, contract fixes fold straight into the draft with no reopen ceremony, gate 2 then presents the hardened artifact.

Read `.claude/skills/gaia/references/spec/audit.md` and `.claude/skills/gaia/references/spec/lens-dispatch.md` now, each whole, and run the audit; `spec/audit.md` returns here at gate 2 (step 8).

### 8. Gate 2, artifact confirmation

Render the full draft artifact in markdown form (frontmatter plus body) and present it to the user. This is gate 2. Track `gate2_revisions = 0` in working memory.

**Auto-mode exception per rule 3:** skip the user prompt. Render the draft into the agent's reasoning context, run a self-check (frontmatter populated, every UAT has Given/When/Then, intent matches gate-1 snapshot modulo intentional clarify evolution, deferred clarifications block well-formed). Apply at most one revision pass if the self-check finds an issue, then jump to the "On confirmation" actions below.

While filling frontmatter, set `lineage:` to the research folder slug(s) under `.gaia/local/research/` (as `research:<slug>`) or issue number(s) (as `issue:<n>`) that discovery named as this SPEC's origin, and leave it `[]` when none. This is never a new question to the user, in auto mode or otherwise.

Use a plain prompt, not `AskUserQuestion`. Suggested phrasing:

> Here is the rendered SPEC. Review it and confirm before save, or tell me what to revise.
>
> ```markdown
> <full rendered artifact>
> ```

If the user revises:

1. Route the revision through the **delegated fold** (see "Audit cache + delegated fold") in **free-text revision mode**: the decision-list entry is id-less and carries the revision text inline; the applier applies it directly with no findings-file lookup, writes the draft cache in one Write, and returns its one-line summary. Main emits no draft-body `Write` for the gate-2 fold. This completes "no full-draft Write in the main thread at a fold checkpoint." **Fallback:** when subagent dispatch is unavailable, main folds the revision inline itself.
2. Increment `gate2_revisions`.
3. Re-present until they confirm. Do not re-quote raw clarify Q&A in revision prompts, reference the draft's `clarifications.answered[]` and `clarifications.deferred[]` arrays as canonical.

On confirmation:

1. Write the final draft cache.

Only after gate-2 confirmation may you proceed to step 9.

### 9. Save to .gaia/local/specs/SPEC-NNN/SPEC.md

Create the SPEC folder in the main checkout, then write the confirmed draft to its canonical inner file (using the `spec_id` allocated in step 3). The SPEC folder is main-anchored state (state registry `specs-main`), so a session inside a linked worktree writes the artifact where the ledger row (written to main by the anchored ledger libraries) indexes it. Resolve once here, guarded per the Operational-primitives contract, and reuse `SPEC_FOLDER` for every path this step builds; the read-back and the cost sidecar below both use it rather than re-resolving:

```bash
MAIN_ROOT="$(bash .gaia/scripts/main-root-lib.sh)"
if [ -z "$MAIN_ROOT" ]; then
  echo "gaia-spec: cannot resolve the main checkout; refusing to save the SPEC" >&2
  exit 1
fi
SPEC_FOLDER="${MAIN_ROOT}/.gaia/local/specs/${SPEC_ID}"
mkdir -p "$SPEC_FOLDER"
```

Write the confirmed draft to `SPEC.md` inside that folder, `${SPEC_FOLDER}/SPEC.md`, per the tool-choice contract in Operational primitives. This is the canonical save location, never anywhere else, never duplicate copies. The folder is the archival unit; sibling artifacts live beside `SPEC.md` in the same folder. A sibling's filename is the uppercased remainder of its flat form (`SPEC-NNN-<rest>.md` → `SPEC-NNN/<REST>.md`); any `SPEC-NNN-*` file is a sibling.

Update the frontmatter `updated` field to today's date.

After the canonical write succeeds:

1. **Delete the working-draft cache:** `rm -f .gaia/local/cache/draft-<spec_id>.md .gaia/local/cache/gate1-<spec_id>.json`, and remove the audit cache with `rm -rf .gaia/local/cache/audit-<spec_id>/`. The applier has already read the audit cache to derive `AUDIT.md` (which survives under `.gaia/local/specs/<spec_id>/`), so deleting it here is safe. The canonical artifact is the source of truth from this point forward; a stale cache would mislead step 2 of a future session.
2. **Update the ledger row:** flip the row in `.gaia/local/specs/ledger.json` from `status: draft` to `status: ready` and stamp the intent (the SPEC's `intent` field reduced to a full first sentence, or a word-safe bounded prefix + `...` when the first sentence runs long, via the shared title-normalize rule) for at-a-glance scanning. This is the finalize transition: the SPEC artifact is now frozen, so the authoring session is done and the allocator stops reporting it for resume-vs-start-new. Downstream (plan → implement → merge) owns the feature from here; the ledger's `merged` transition is reconciled from git by `spec-reconcile.sh`, not set here. Failure is non-blocking, log to stderr and continue. The remote `spec/*` tags are the cross-team allocation authority; `.gaia/local/specs/ledger.json` is a per-machine local cache; the SPEC artifact and git history remain authoritative.

```bash
# SPEC.md lives in the main checkout (saved above); read it back from there,
# reusing the guarded $SPEC_FOLDER resolved at the top of this step.
# ledger-update.sh below keeps its $PWD operand: it resolves main itself (see
# Operational primitives), so only this directly-built read path anchors to main.
SPEC_PATH="${SPEC_FOLDER}/SPEC.md"
INTENT_RAW=$(awk '
  /^intent:[[:space:]]*\|/ { in_block=1; next }
  /^intent:[[:space:]]*[^|[:space:]]/ {
    sub(/^intent:[[:space:]]*/, ""); print; exit
  }
  in_block && /^[a-zA-Z_]+:/ { exit }
  in_block && /^[[:space:]]+[^[:space:]]/ {
    sub(/^[[:space:]]+/, ""); print
  }
' "$SPEC_PATH" 2>/dev/null || echo "")
INTENT=$(printf '%s' "$INTENT_RAW" \
  | bash .gaia/scripts/spec/title-normalize.sh 2>/dev/null || echo "")
PATCH=$(jq -nc --arg intent "$INTENT" \
  '{status: "ready"} + (if $intent == "" then {} else {intent: $intent} end)')
bash .gaia/scripts/spec/ledger-update.sh "$PWD" "$SPEC_ID" "$PATCH" \
  || echo "ledger-update skipped (row missing or jq failure), non-blocking" >&2
```

3. **Delete the session-shape cache:** `rm -f .gaia/local/cache/spec-session-${SPEC_ID}.json`. The cache's job, tracking `question_count` against the ceiling across a pause and resume, ends once the SPEC is saved. **Release the session lock (canonical save):** `bash .gaia/scripts/spec/spec-session-lock.sh release "$PWD" "$SPEC_ID" || true`. The canonical save is the holder's own graceful exit, so it drops its own lock here, alongside the session-shape cache.
4. **Record the run (never blocks):** close the session's usage record and print its Cost line. This call never blocks or fails the save.

```bash
bash .gaia/scripts/usage.sh record spec:${SPEC_ID} --workflow gaia-spec
```

The command pairs this session's `gaia-spec` start with now, flushes the session's token usage into the usage ledger, and prints the Cost line as its last stdout line. Report that line verbatim and nothing else from the output: `Cost: ~<total> tokens, $<dollars>, <elapsed>`, with the suffixes the command adds when the figure is partial. Never compute or restate a figure yourself. On a non-zero exit, relay the command's one stderr line in place of the Cost line and continue; when start detection missed (the session was cleared or resumed), that line names the `--start <iso>` recovery, which runs outside a live `gaia-spec` run. This line reads identically to the `/gaia-plan` cost line (plan reference, step 5) and the orchestrator's full-cycle line; keep the three in sync.

5. **Lineage edges (never blocks):** materialize each `lineage:` entry as an edge in the usage links ledger now, because the SPEC folder is reaped later and nothing reads `SPEC.md` for edges at read time. Shell state does not survive between Bash calls, so this block re-derives its own paths. Substitute the literal SPEC id for `SPEC-NNN`:

```bash
MAIN_ROOT="$(bash .gaia/scripts/main-root-lib.sh)"
SPEC_PATH="${MAIN_ROOT}/.gaia/local/specs/SPEC-NNN/SPEC.md"
bash .gaia/scripts/usage.sh lineage "$SPEC_PATH" || true
```

A wrong path prints a `no SPEC file` line to stderr even behind `|| true`. A SPEC saved without `lineage:` links later with `bash .gaia/scripts/usage.sh link spec:SPEC-NNN <parent-ref>`.

**Auto-mode:** the record call fires identically in interactive and auto mode; it is a mechanical command, not a user prompt, so no auto-mode branch is needed. In auto mode the Cost line simply lands in the transcript, nothing to prompt.

### 10. Immutability lint

After the step-9 save, run `bash .gaia/scripts/spec/lint.sh <spec-path>` yourself against `${SPEC_FOLDER}/SPEC.md`, the file step 9 saved. Re-resolve `SPEC_FOLDER` through `bash .gaia/scripts/main-root-lib.sh`, since shell state does not persist between calls. This is an explicit agent step, not an event. The lint prints JSON (`{"ok":true,"findings":[]}` on pass); handle the result with the cycle rules below.

Track `lint_cycle = <count>` in working memory (initialize to 1 on the first attempt).

On lint pass: continue to step 11.

On lint fail (cycles 1–2): surface the failures verbatim. The user can fix and re-run the lint, or defer with rationale (which loops back to 6c's pending handling: Read `.claude/skills/gaia/references/spec/self-review-dispatch.md` now, whole, and run its 6c). For mutations of an already-saved SPEC, the helper enforces the explicit reopen ceremony, `## Reopen rationale` and `## UAT diff` sections required. Increment `lint_cycle` and continue.

**On lint fail at cycle 3 (3 failed cycles in a row):** **Auto-mode exception per rule 10:** skip the prompt and auto-pick "Defer remaining findings", capture each remaining finding as a deferred clarification with rationale `"Auto-mode session, lint thrash, defer for human review."` and continue to step 11. Step-back-to-gate-2 in auto mode would loop indefinitely.

Otherwise, surface via `AskUserQuestion`:

- question: `"Lint has failed 3 times. Step back to gate 2 to restructure the artifact, defer all remaining lint findings with rationale, or push another fix attempt?"`
- header: `"Lint thrash"`
- options:
  - `{ label: "Step back to gate 2 (Recommended)", description: "Repeated lint failures usually indicate the artifact is not shaped right. Re-render and revise." }`
  - `{ label: "Defer remaining findings", description: "Capture each finding as a deferred clarification with rationale; loop to step 6c." }`
  - `{ label: "Push another fix attempt", description: "Try once more, but this is the third escape." }`

Reset `lint_cycle = 0` on user choice. `Defer remaining findings` loops to 6c: Read `.claude/skills/gaia/references/spec/self-review-dispatch.md` now, whole, and run its 6c. Step-back-to-gate-2 returns to step 8 with the existing draft; the user can revise and re-save (steps 8→9→10 again).

### 11. /gaia-plan handoff, then STOP

The handoff lives here, inline, after the canonical save (step 9) and the immutability lint (step 10). `/gaia-spec` does not run `/gaia-plan` itself; it prints a copy-pasteable prompt and stops. Interactive and auto mode end identically, neither runs plan.

**Printing the block below is the last action of the session.** Per Hard constraint 6, this is a hard stop, not a suggested one, and it binds even when the instruction that invoked this skill asked for more (a plan, an implementation, a PR). Do not invoke `/gaia-plan`, do not read `plan.md`, do not dispatch a planner, do not start the work. A session that authored a SPEC is the worst-conditioned session in GAIA to plan it: its context is enormous and its judgment is anchored on authoring decisions the planner should meet fresh.

The handoff is complete work, not a partial answer. Say so plainly when you report: the SPEC is saved, and planning is the human's next move in a fresh session.

The handoff prompt is just the SPEC id, `plan.md`'s step 1a resolves `SPEC-NNN` to `.gaia/local/specs/SPEC-NNN/SPEC.md` (and a sibling `AUDIT.md`, if step 7 ran) itself, so no path or intent text needs to travel in the copy-paste.

Print the handoff to the user as one cohesive block and stop: the status line, a `/clear`-and-paste instruction, then a single fenced code block whose contents are the full `/gaia-plan` invocation (command prefix included). Prepending `/gaia-plan ` makes the block a runnable command, not a bare argument, so the user copies exactly one thing:

> SPEC-NNN saved to `.gaia/local/specs/SPEC-NNN/SPEC.md`.
>
> To plan it, /clear and paste this:
>
> ```
> /gaia-plan SPEC-NNN
> ```

This is the end of the `/gaia-spec` flow.
