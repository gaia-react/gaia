# /gaia-spec

Socratic discovery wrapper around spec-kit. Produces an immutable SPEC artifact at `.gaia/local/specs/SPEC-NNN/SPEC.md` and stops. Do not implement anything, and do not plan anything, this skill produces an artifact and ends. The `/gaia-plan` handoff is a prompt you print for the human (step 11), never a command you run. See Hard constraint 6.

## Argument parsing

Tokenize the first whitespace-separated word of `$ARGUMENTS`:

- If it is `auto`, set `auto_mode = true`, strip the token, and treat the remainder as the feature description (which may be empty, see Auto mode below).
- Otherwise `auto_mode = false` and the entire `$ARGUMENTS` is the feature description.

`auto_mode` is referenced throughout the steps below; every user-facing prompt has an auto-mode branch.

## Auto mode

When `auto_mode = true` the agent answers the Socratic questions itself rather than asking the user. **The Socratic loop's ceiling in auto mode is 5 substantive questions** (see "The question ceiling" in operational primitives). The flow is non-interactive end-to-end: no `AskUserQuestion` calls fire, no plain-prompt blocks wait for human reply. The agent makes best-judgment calls using the description, the draft state, and any research it dispatches.

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
12. **Adversarial audit runs at the gauged intensity, non-interactively.** Step 7 no longer prompts anyone for an audit decision (interactive and auto both gauge and run); auto mode gauges the draft and runs the audit at the gauged tier, never skipping. Gauge the draft's complexity, run the audit at that tier (Standard or Deep), and apply its dispositions without prompting: auto-apply plan-time directives into `AUDIT.md`, auto-apply unambiguous SPEC-contract-defect fixes into the draft pre-save (no reopen ceremony, the draft is unsaved), and for any contract defect with more than one defensible repair, record it in `clarifications.deferred[]` with rationale `"Auto-mode audit, defer for human review."` rather than guessing. Never block save; never revert intentional clarify-loop evolution. Throughout the audit and fold phase auto mode reads **no finding body** (a finding's `issue`/`evidence`/`recommendation`, or a self-review finding's `suggested_fix`/`excerpt`); the transcript carries only ids, severities, titles, verdicts, and dispositions. The two bounded exceptions where a finding body reaches main (6b high self-review findings, 7c material spec-defect survivors) are interactive-only; auto mode surfaces neither. If the Agent fan-out is unavailable, take step 7's fallback (note the skip, rely on the step-6 self-review) and continue.

The rest of the skill, write-surface allowlist, no-machine-local-memory rule, working-draft cache primitives, hooks firing, immutable SPEC shape, applies identically in auto mode.

## Hard constraints

1. **No machine-local memory for project decisions.** Never call any tool that writes to `~/.claude/projects/.../memory/`. Project-relevant decisions belong ONLY in the SPEC artifact, the wiki, or `.claude/rules/`. Personal preferences (tone, formatting) remain allowed in machine-local memory. This is the no-machine-local-memory rule and it is non-negotiable.
2. **Write-surface allowlist.** Every file write during a `/gaia-spec` session lands in exactly one of:
   - `.gaia/local/specs/**`
   - `.specify/**`
   - `.gaia/local/cache/**`
   - `.gaia/local/telemetry/**`
     Never edit source files (`app/**`, `src/**`, repo root configs, etc.). No automated backstop enforces this allowlist today: the `after_specify` lint checks only the saved SPEC artifact's immutability, not which paths a session wrote. You self-police it at the agent-instruction level.
3. **One question at a time.** No multi-question forms. Closed-set questions go through `AskUserQuestion` with options ordered: recommended FIRST, then alternatives, then `Other` (free text), then `Discuss this` (escape to plain Q&A). Open-ended questions use a plain prompt with no enumerated options.
4. **Two-gate ceremony.** Confirm intent + UATs in plain English BEFORE authoring the artifact. Confirm the rendered artifact BEFORE saving to disk. No silent advances between gates.
5. **Coach tone, not interrogator.** Mirror back, name trade-offs, propose candidates when the human is stuck. Never punt research to the human.
6. **This skill is terminal. Never chain into `/gaia-plan`.** The flow ends at step 11 with a printed handoff prompt and nothing else: no `/gaia-plan` invocation, no planner dispatch, no `Read` of `plan.md`, no "while I'm here" head start on the work. **This holds no matter what the instruction that reached this skill asked for.** When `/gaia-spec` is invoked as a skill (rather than typed by a human), the invoking goal is often larger than the SPEC ("spec and build X"), and the pull to keep going at step 11 is strongest exactly when the session is least fit to plan: authoring a SPEC burns an enormous context (Socratic loop, gate renders, self-review, adversarial audit), and `/gaia-plan`'s deep synthesis needs a clean one. Planning is **always** a new session. If the caller wanted a plan too, the correct completion is to print the handoff and report that planning is the human's next step; that IS the whole task, not a partial one. This constraint is enforced deterministically by `.claude/hooks/block-spec-plan-chain.sh`, which denies the chain rather than trusting these words, but do not make it do that work: stop on your own.

## How spec-kit fires GAIA hooks

Spec-kit's hooks are **not** shell scripts. When core invokes `/speckit-specify` (or any other core skill), it reads `.specify/extensions.yml` for the relevant event and emits an `EXECUTE_COMMAND: <id>` markdown directive into the agent's reasoning context. The agent then invokes the rendered slash-command (e.g., `/speckit-gaia-constitution-check`) as a normal Claude skill. There is no JSON payload, no stdin pipe, no env var.

The three GAIA hooks declared in `.specify/extensions/gaia/extension.yml`:

| Event            | Slash command                      | Source body                                               |
| ---------------- | ---------------------------------- | --------------------------------------------------------- |
| `before_specify` | `/speckit-gaia-constitution-check` | `.specify/extensions/gaia/commands/constitution-check.md` |
| `after_clarify`  | `/speckit-gaia-self-review`        | `.specify/extensions/gaia/commands/self-review.md`        |
| `after_specify`  | `/speckit-gaia-lint`               | `.specify/extensions/gaia/commands/lint.md`               |

Each hook fires automatically, the agent reads the directive and invokes the slash command without prompting. "Block" semantics live inside the hook command: a block is a refusal message that the wrapper agent reads and chooses not to proceed past. There is no machine-enforced halt.

**`after_clarify` does not fire on the `/gaia-spec` path.** It is declared for a bare `/speckit-clarify` invocation, which this wrapper does not make (see step 5). GAIA's self-review is not a hook consumer: step 6 dispatches it directly as a `general-purpose` Agent, so it runs identically whether or not spec-kit core is installed.

There is no `on_save` event. The `/gaia-plan` handoff lives inline at the end of this orchestration (Step 11), not in a hook.

## Operational primitives

Used by multiple steps below. Defined once here to keep step-level prose tight.

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

### Working-draft checkpoint (`draft-<spec_id>.md`)

After each clarify fold (step 5), each gate confirmation (steps 4 + 8), each research-result fold (step 5e), each self-review apply (step 6), and each audit-finding apply (step 7), persist the current in-flight draft to `.gaia/local/cache/draft-<spec_id>.md`. Step 9's canonical save deletes this cache as its final action.

**Single-`Write` rule.** Compose the full updated draft in working memory, then emit ONE `Write` tool call that overwrites the cache file. Never use a sequence of `Edit` calls for a single fold. The Q&A loop runs many turns per session and each `Edit` renders a full diff in the user's chat, multiple per-turn diffs are visual noise the user has flagged as unwanted.

The single-Write-per-fold discipline holds, but the writer depends on the checkpoint. For a **clarify-loop fold** (a step-5 Q&A turn, a gate confirmation), the per-turn budget is exactly: one `Write` for the fold from the main thread, one `Bash` for the `question_count` increment, nothing else. For a **delegated fold checkpoint** (an approved self-review high at 6b, the audit spec-defect fold at 7c, a gate-2 revision), the single Write is **owned by the applier subagent** (see "Audit cache + delegated fold" below), and the main thread's per-turn action at that checkpoint is the **applier dispatch** (an Agent call), not a `Write`. Do not emit a main-thread draft `Write` at a delegated fold checkpoint.

**Per-turn fold contents.** When folding a Q&A turn (closed-set selection, `Other` text, open-ended answer, or Discuss-this settlement): add to `clarifications.answered[]` as `{ q, a }`, remove the topic from `clarifications.pending[]`, and update any statusline fields the answer touches, all in the same `Write`.

This makes interrupted sessions resumable: step 2 reads the cache if it is newer than the canonical artifact.

### Audit cache + delegated fold

The self-review (step 6) and adversarial audit (step 7) route their finding, verdict, and draft bodies through a per-spec **audit cache** on disk and a **delegated-fold applier** subagent, so the main thread holds only thin lines (id, severity, title, verdict, disposition) plus a few applier summaries. Finding bodies, verdict bodies, refuter bodies, and full-draft folds do not flow back through main during a fold, with exactly two bounded interactive carve-outs (6b high self-review findings, 7c material spec-defect survivors).

**Audit cache directory** `.gaia/local/cache/audit-<spec_id>/`. Every file the self-review and audit produce lands here:

- `findings/<LENS>.json` — one per dispatched lens, written even when the findings array is empty (so the file count equals the dispatched-lens count deterministically).
- `findings/self-review.json` — the step-6 self-review (6a schema).
- `findings/completeness.json` — the Deep completeness critic (7a findings schema).
- `verdicts/<finding-id>.json` — a Standard single-refuter verdict.
- `verdicts/<finding-id>-<refuter-lens>.json` — a Deep verdict, one per refuter lens. The refuter lens is **slugified**: `correctness` stays `correctness`, `security/safety` maps to `security-safety`, `reproduces-as-described` stays as is. The completeness critic's single-refuter verdicts use the same naming.

Per-lens and per-finding-plus-lens filenames avoid write collisions in the parallel fan-out: each agent owns exactly one path, so many agents write the cache concurrently without contending.

**Delegated fold.** At a delegated fold checkpoint the fold is performed by a single-writer subagent, not by main; it replaces an in-main fold at that checkpoint. Main dispatches a `general-purpose` Agent (the **applier**) with three inputs: the draft path (`.gaia/local/cache/draft-<spec_id>.md`), the audit-cache directory (`.gaia/local/cache/audit-<spec_id>/`), and the thin **decision list**:

    [ { "id": "<finding-id>", "action": "apply"|"keep"|"revise", "revision": "<free text, optional>" } ]

An **id-less** entry carries its `revision` text inline (free-text revision mode); the applier applies it directly with no findings-file lookup (gate-2 free-form edits route this way).

The applier **reads every findings and verdict file in the cache** (not just the decision-list ids). For each id-carrying `apply`/`revise` entry it looks the fix up **by id in the findings files** — main never holds the recommendation text. For each id-less entry it applies the inline `revision` (free-text mode, no findings-file lookup). It folds every applicable fix into the draft cache in **one Write** and returns a one-line summary:

    { "folded": [<ids>], "directives": [<ids>]?, "revised": [<ids>]?, "counts": { "folded": <int>, "directives": <int>, "revised": <int> } }

`directives` is optional (absent for pure draft folds); it lists finding ids routed to `AUDIT.md` as plan-time directives. The `counts` object is the pinned **fold-outcome** schema that the applier's own reporting reads.

Reading the full cache (rather than only the listed ids) is what lets the applier both author `AUDIT.md` from the complete on-disk record (see 7d) and fold the **low-severity spec-defect fixes main never surfaced** — the decision list carries only the interactively-gated material survivors, and low spec-defects are folded silently by the applier from the on-disk findings files, preserving the current flow. When the fold routes any finding to a plan-time directive, the applier also writes `AUDIT.md`.

**Fallback.** If subagent dispatch is unavailable, the main thread folds inline exactly as today.

### No-op guard (detection, retry, inline fallback)

Every in-scope self-review/audit dispatch below (6a self-review, 7a lens fan-out, 7b-i refuter, 7b-ii completeness critic, 7b-iii completeness-critic refuter, 7c applier) is followed by this guard, so a dispatched agent that no-ops (a harness-reminder-echo, an output-style fragment, or an empty return, zero tool uses) never silently counts as "found nothing" or "clean":

1. **Detect.** Classify the dispatch with `bash .gaia/scripts/audit-noop-detect.sh --shape <SHAPE> --path <PATH>` (exit 0 = a real result, exit 1 = a no-op, exit 2 = usage error). The helper reads only the file or captured return already on disk, so no finding/verdict/draft body enters main's reasoning context from this check. File-backed shapes pre-clear `<PATH>` (`rm -f`) before the dispatch and again before any retry, so its presence afterward is a fresh-write signal.
2. **Retry (best-effort, exactly one).** On a no-op, re-dispatch the same unit **exactly one** time, prepending this hardened prefix to the original prompt (`<target>` = the concrete artifact that dispatch reads):

       RETRY (hardened, one attempt only): Your very first action MUST be a Read of <target>. Emit no prose before that Read. Produce your structured output (the findings or verdict file this prompt names, or your returned digest if it names none) before any returned prose. Then perform the original task below exactly as written.

   Never a third dispatch.
3. **Inline fallback (guaranteed).** If the retry also no-ops, do not re-dispatch again: run the unit inline instead (main performs the task itself), record its disposition as `inline_fallback`, and route any recovered findings into the same on-disk path a dispatched agent would have used, so they re-enter the normal pipeline rather than vanishing. A dispatch that was scope-gated and never issued (e.g. a specialist lens the gauge did not select) is recorded `not_applicable` and is never treated as a no-op.

Each in-scope dispatch appends one thin coverage record `{ "phase": ..., "lens": ..., "disposition": "first_pass"|"retried_recovered"|"inline_fallback"|"not_applicable" }` to `.gaia/local/cache/audit-<spec_id>/coverage.jsonl` as main resolves it (7d renders `## Coverage` in `AUDIT.md` from this file).

**Mutating units** (6a self-review, 7c applier) detect on their **output artifact**, not on their return alone, so a unit that actually wrote is a real result even if its return was malformed. Because `.gaia/local/cache/draft-<spec_id>.md` is the single live working draft these units mutate in place (it is NOT itself a checkpoint), main **snapshots** it before dispatch to `.gaia/local/cache/draft-<spec_id>.pre-<site>.md` (`.pre-6a.md` / `.pre-7c.md`); a retry **restores the live draft from that snapshot first**, then re-dispatches, so the retry is a clean redo against pristine pre-dispatch state and can never double-apply. The snapshot is deleted once the unit resolves.

### Escape option (used in step 5 AskUserQuestion sets)

Closed-set `AskUserQuestion` calls during the clarify loop append a fifth option after `Discuss this`:

    { label: "Save partial and resume later", description: "Write the draft to cache and stop; re-invoke /gaia-spec to continue." }

Selection triggers: write draft cache (above), print one-line resume hint (`SPEC-NNN saved as draft. Re-invoke /gaia-spec to resume.`), and exit gracefully.

The session-shape cache is NOT deleted on the `Save partial and resume later` path, a future resume reads it and continues counting questions against the same `start_at`. (Cache deletion happens only on canonical save at step 9, or on the `Discard SPEC-NNN draft cache` branch in step 2, see step 2 for the discard handler, or on an abandoned-exit branch other than this one, see below.)

#### Abandoned exit

For any branch that exits the wrapper without reaching step 9, other than the `Save partial and resume later` escape above (which keeps its cache for a future resume):

```bash
rm -f .gaia/local/cache/spec-session-${SPEC_ID}.json
```

### Per-topic revisit counter

Track `push_deeper[<topic>] = <count>` in working memory. Increment on every "Push deeper on <topic>" selection at step 5d. When `count == 3` for any topic, replace the standard step 5d prompt with:

- question: `"<topic> has been revisited 3 times. Settle on a candidate, defer with rationale, or push deeper anyway?"`
- options:
  - `{ label: "Settle on the recommended option (Recommended)", description: "Accept the PO's best-judgment candidate and move on." }`
  - `{ label: "Defer <topic> with rationale", description: "Mark unresolved with a note for the planner." }`
  - `{ label: "Push deeper anyway", description: "Mine the topic further despite repeated revisits." }`
  - `{ label: "Save partial and resume later", description: "Write the draft to cache and stop." }`

### The question ceiling

The interactive Socratic loop asks **at most 10 substantive questions**. Auto mode asks **at most 5**. Both numbers are GAIA's own, not spec-kit's (see step 5).

**Substantive** means a closed-set question (5a), a Discuss-this settlement (5b), or an open-ended question (5c), counted once on first surfacing. Nothing that merely re-surfaces or resolves an already-counted question spends a second unit, and the loop's own meta-prompts, 5d's exhaustion checkpoint, the 3-revisit settle prompt, and the research-outcome prompts, never count.

There is exactly one counter and it needs no new storage: `question_count` in the session-shape cache (`.gaia/local/cache/spec-session-<spec_id>.json`, see above) already counts substantive questions and already survives a pause and resume. The ceiling is therefore enforced against the **total across all sittings** of a session; a resumed session does not get a fresh budget.

**The ceiling is a bound, not a goal.** The loop's normal termination is the coverage scan in `.specify/extensions/gaia/templates/clarify-prompts.md` (Rule 8): ask until no topic is Partial or Missing, then stop. On a simple feature that fires after 2 to 4 questions and the ceiling is never felt. Do not pad toward it, and do not treat an unspent budget as work left undone.

**When the ceiling is reached with coverage incomplete**, the loop stops asking. Every topic still marked Partial or Missing is written to `clarifications.deferred[]` with a rationale naming it as ceiling-truncated (for example: `"Ceiling-truncated: 10 substantive questions asked; <topic> remained Partial."`). The loop does not push past the ceiling, and it does not advance to gate 2 as though coverage were complete.

The per-topic revisit counter and the escape option above both fit inside this budget.

### Don't re-quote folded clarifications

Once a Q&A pair has been folded into the draft's `clarifications.answered[]` (step 5b) or `clarifications.deferred[]` (step 6c), it is canonical. Do NOT re-paste the raw question or answer text into downstream prompts (gate 2, self-review, gate 2 revisions). Reference the draft's structured arrays instead. This keeps wrapper context lean across the multi-step flow.

### Lazy template loading

Read `.specify/extensions/gaia/templates/clarify-prompts.md` and `system-prompt.md` only at step 5's first invocation, not earlier. They are reference templates, not preamble.

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

First, best-effort reconcile any finalized-but-open SPEC against git, so a SPEC whose implementing PR has already merged is recorded as `merged` rather than lingering. This never blocks and is a no-op when nothing is reconcilable (no `gh` call unless the ledger holds a finalized-unmerged row).

```bash
bash .specify/extensions/gaia/lib/spec-reconcile.sh "$PWD" 2>/dev/null || true
```

Then, for any merged row whose folder still holds `SPEC.md` or `AUDIT.md` with no well-formed consolidated `SUMMARY.md`, an out-of-band merge that never ran the close flow's consolidation, cold-consolidate it before the delete sweep below runs. This pass is the producer for `spec-archive-merged.sh`'s consolidation gate, which keeps any folder still holding unconsolidated layers; without this pass those folders would never clear that gate. Identify candidates:

```bash
jq -r '.specs[] | select(.status == "merged") | .id' .gaia/local/specs/ledger.json 2>/dev/null | while read -r id; do
  folder=".gaia/local/specs/${id}"
  { [ -f "${folder}/SPEC.md" ] || [ -f "${folder}/AUDIT.md" ]; } || continue
  bash .gaia/scripts/summary-verify.sh "${folder}/SUMMARY.md" >/dev/null 2>&1 && continue
  echo "$id"
done
```

For each candidate id, run a cold consolidation (agent synthesis, not a script): read the layers in precedence `SPEC.md` → `AUDIT.md` → plan `PROGRESS.md` (top wins), grounded in the merged code and passing tests, and write `.gaia/local/specs/<id>/SUMMARY.md` in the pinned shape (present-tense body, `wiki_promote_default` + `wiki_promote_targets` frontmatter, non-empty H1, optional `## Divergence`). Then gate the layer removal on the verify script: `bash .gaia/scripts/summary-verify.sh .gaia/local/specs/<id>/SUMMARY.md`; on exit 0, `rm .gaia/local/specs/<id>/SPEC.md .gaia/local/specs/<id>/AUDIT.md`; on exit 1, leave the layers in place and move to the next candidate. This pass never destroys a layer it failed to replace, and a candidate whose synthesis or verify fails is simply left for a future pass, never blocking this prompt.

Then delete any merged SPEC folder that is past the retention window (`GAIA_SPEC_RETENTION_DAYS`, default 30 days), whose layers are consolidated (the pass above), and whose cost is fully represented in `cost.jsonl`, the safety net for a PR that merged out-of-band or a close that never ran (an unparseable or unrepresented cost sidecar phase blocks that folder's deletion rather than risking an unrecoverable loss; a folder still within the window is kept regardless of representation). Then sweep any never-authored draft older than the guard age to the terminal `abandoned` status, so a ghost allocation (no SPEC.md, no draft cache, no gate-1 snapshot) stops re-surfacing on this very prompt. Both passes are best-effort and fail-open:

```bash
bash .specify/extensions/gaia/lib/spec-archive-merged.sh "$PWD" 2>/dev/null || true
bash .specify/extensions/gaia/lib/spec-abandon-empty.sh "$PWD" 2>/dev/null || true
# Best-effort sweep of stale audit caches left by "Start new" or abandoned exits.
# An audit-<id>/ cache is short-lived (created at 6a, deleted at the step-7 fallback, step 9
# save, or the step-2 discard); one untouched for over a day is orphaned. Fail-open,
# never blocks; the mtime guard cannot touch a dir an active session just wrote.
find .gaia/local/cache -maxdepth 1 -type d -name 'audit-*' -mtime +1 \
  -exec rm -rf {} + 2>/dev/null || true
```

Then run `bash .specify/extensions/gaia/lib/spec-allocator.sh in_progress "$PWD"`. If the output is a `SPEC-NNN` id (not `none`), an unfinalized **draft** SPEC already exists, a prior authoring session that never reached the canonical save (step 9). The allocator reports only drafts; a finalized SPEC (`ready`/`merged`) is never surfaced here, because you resume a draft, not a frozen artifact.

The id may name a **draft-phase** session, a SPEC allocated in another terminal whose interactive loop has not yet reached the canonical save (step 9), so `.gaia/local/specs/SPEC-NNN/SPEC.md` may not exist yet and the live draft is at `.gaia/local/cache/draft-SPEC-NNN.md`. The `WORKING`-selection below resolves this correctly, preferring the draft cache when the canonical file is absent or older.

**Auto-mode exception:** skip the resume prompt entirely. Always start new and proceed to step 3 with a fresh allocation. The draft SPEC (if any) remains untouched. Per Auto-mode rule 2 the user's `auto` invocation is the signal that they want a fresh artifact; resuming an existing draft into a non-interactive context risks silently overwriting work in progress.

Before prompting, gather context for an informed choice. The newer of the canonical artifact and the working-draft cache is the actual resume point:

```bash
SPEC_ID="<from allocator>"
SPEC_PATH=".gaia/local/specs/${SPEC_ID}/SPEC.md"
DRAFT_PATH=".gaia/local/cache/draft-${SPEC_ID}.md"
if [[ -f "$DRAFT_PATH" && "$DRAFT_PATH" -nt "$SPEC_PATH" ]]; then
  WORKING="$DRAFT_PATH"
else
  WORKING="$SPEC_PATH"
fi
```

Read `$WORKING` and extract: intent first line, UAT count, frontmatter `updated` timestamp (or filesystem mtime if absent). Surface via `AskUserQuestion`:

- question: `"SPEC-NNN in progress (last touched <updated>, <UAT count> UATs drafted): \"<intent first line>\". Resume, start new, or discard?"`
- header: `"Existing SPEC"`
- options:
  - `{ label: "Resume SPEC-NNN (Recommended)", description: "Continue from the latest draft (working cache preferred over canonical if newer)." }`
  - `{ label: "Start new", description: "Begin a fresh SPEC; SPEC-NNN remains open." }`
  - `{ label: "Discard SPEC-NNN draft cache", description: "Remove the working-draft cache (the canonical artifact remains). Confirm before deleting." }`

Honor the user's choice. Never silently overwrite, never silently start new.

- **Resume:** load `$WORKING` into the working draft, initialize the session-shape cache per the operational primitive (write only if absent, the original `start_at` survives across resumes), and pick up at the right step (skip earlier steps that are already done):
  - If `.gaia/local/cache/gate1-<spec_id>.json` does NOT exist → resume at step 4 (gate 1).
  - If gate-1 cache exists AND the draft has any `clarifications.pending[]` entries → resume at step 6.
  - If gate-1 cache exists AND no pending clarifications → resume at step 8 (gate 2).
  - Step 3 (initial draft) is always skipped on resume.
  - Never re-snapshot the gate-1 cache; its purpose is immutable drift detection.
- **Start new:** continue with a fresh allocation (Step 3 onward). The draft SPEC remains untouched. Initialize the session-shape cache per the operational primitive once the new `spec_id` is known (step 3).
- **Discard SPEC-NNN draft cache:** confirm via a follow-up `AskUserQuestion` (`"Delete the draft cache for SPEC-NNN? (The canonical artifact remains.)"` with options `Yes, delete` / `Cancel`). On confirm, `rm -f "$DRAFT_PATH" .gaia/local/cache/spec-session-${SPEC_ID}.json .gaia/local/cache/gate1-${SPEC_ID}.json` and, separately (an `rm -f` cannot delete a directory), `rm -rf .gaia/local/cache/audit-${SPEC_ID}/`, then continue with a fresh allocation. Note: this deletes only the draft cache; the SPEC's ledger row stays `status: draft`, so the allocator keeps flagging SPEC-NNN for resume until that row reaches a finalized status (out of scope for this step).

### 3. /speckit-specify (initial draft)

Invoke `/speckit-specify` with the description from step 1. The GAIA preset (registered via `specify preset add`) wraps core with `{CORE_TEMPLATE}` and replaces `spec-template`, so the artifact is GAIA-shaped (frontmatter, immutable flag, `SPEC-NNN` id) and lands at `.gaia/local/specs/SPEC-NNN/SPEC.md`. The preset's body invokes `lib/spec-allocator.sh next "$PWD"` to allocate the SPEC id.

Spec-kit fires the `before_specify` hook (constitution + version-pin check) automatically before this step runs. If the hook blocks, surface its message and halt.

When core completes, `/speckit-gaia-spec`'s preset relocates the artifact to `.gaia/local/specs/SPEC-NNN/SPEC.md`. Cache the working draft path; you will read and re-render it across the rest of these steps.

Initialize the session-shape cache for the just-allocated SPEC id (no-op if it already exists from a resume):

```bash
CACHE=".gaia/local/cache/spec-session-${SPEC_ID}.json"
if [[ ! -f "$CACHE" ]]; then
  printf '{"spec_id":"%s","start_at":"%s","question_count":0}\n' \
    "$SPEC_ID" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" > "$CACHE" || true
fi
```

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

This is GAIA's own loop. It does not invoke spec-kit's clarify primitive, and no spec-kit-authored question budget reaches your context during it. Read the templates at `.specify/extensions/gaia/templates/clarify-prompts.md` and `system-prompt.md` only on entering this step (lazy-load, see operational primitives); they carry the coach-tone persona, the Q&A copy, the topic bank, and the coverage scan.

Run sequential, coverage-based questioning over the draft. One question per turn. The mechanics are 5a through 5e below: `AskUserQuestion` mediation for closed-set questions with the recommended option first, plain prompts for open-ended ones, the Discuss-this escape, the per-topic exhaustion checkpoint, and research-subagent dispatch.

**The stop rule is the coverage scan, not the ceiling.** Maintain the scan defined in `.specify/extensions/gaia/templates/clarify-prompts.md` (Rule 8) over the topic bank: mark every topic Clear, Partial, or Missing, and prioritize what remains. Ask until no topic is Partial or Missing, then stop. That is the normal termination condition, and on a simple feature it fires after 2 to 4 questions.

**The ceiling bounds the loop:** at most 10 substantive questions (see "The question ceiling" in operational primitives, which also defines what happens if the loop reaches it with topics still uncovered).

**Auto-mode exception:** the ceiling in auto mode is **5 substantive questions**, and the agent answers each question itself rather than mediating to the user, per Auto-mode rules 5 to 8. No `AskUserQuestion` calls fire in this step. Each agent-chosen answer is folded into `clarifications.answered[]` exactly as a human selection would be. Skip sub-steps 5a to 5d's `AskUserQuestion` mechanics and 5b's Discuss-this branch entirely; sub-step 5e (research dispatch) runs unmodified except for the uncertain-outcome fallback. The coverage scan still governs the stop.

For every **substantive** question asked (5a, 5b, 5c), increment `question_count` in the session-shape cache per the operational primitive (`spec-session-<spec_id>.json`). That counter is the ceiling counter. The loop's meta-prompts, 5d's exhaustion checkpoint, the 3-revisit settle prompt, and the research-outcome prompts do not increment it.

#### 5a. AskUserQuestion mediation (closed-set questions)

For every question with discrete possible answers, surface it via `AskUserQuestion` with options ordered exactly:

1. **Recommended option FIRST**: labeled `"<option text> (Recommended)"`. Use the PO's best judgment; the recommendation is annotated with code-context where helpful (e.g. `"Cards (reuses existing Card component)"`).
2. **Alternatives**: remaining viable options, in descending order of plausibility.
3. **`Other`**: free-text escape for an answer not in the list.
4. **`Discuss this`**: escape to plain Q&A (see 5b).
5. **`Save partial and resume later`**: escape per the operational primitive.

Ask exactly one question per turn. No multi-question forms. No silent stacking.

After the user selects an option (or supplies `Other` text), persist the fold via a single `Write` per the working-draft checkpoint primitive (answer into `clarifications.answered[]`, topic removed from `clarifications.pending[]`, statusline updated, all in one call). `Discuss this` and `Save partial and resume later` follow their own paths (5b and the escape primitive respectively).

#### 5b. Discuss-this escape

When the user picks `Discuss this`, drop the structured loop and engage in plain Q&A on that single topic. Mirror, name trade-offs, propose candidates. When the user signals settlement (an explicit "ok, that one" or equivalent):

1. Persist the fold per the working-draft checkpoint primitive, single `Write` covering: discussion outcome appended to `clarifications.answered[]` as `{ q: "<original question>", a: "<settled outcome from discussion>" }`, topic removed from `clarifications.pending[]`, statusline updated. Once folded, **do not re-quote the raw Q&A** in downstream prompts.
2. Resume the structured loop on the next topic.

Do not loop back to the same closed-set options after a Discuss-this settlement. The discussion replaces the structured choice for that topic.

#### 5c. Open-ended questions

For genuinely open-ended questions (no clean discrete option set), use a plain prompt, not `AskUserQuestion`. Coach tone, never interrogator. Ask one at a time. After each answer, persist the fold via a single `Write` per the working-draft checkpoint primitive (answer into `clarifications.answered[]`, topic removed from `clarifications.pending[]`, statusline updated, all in one call).

#### 5d. Per-topic exhaustion checkpoint

When the loop is about to leave the current topic, whether because its coverage mark has reached **Clear** or because the coverage scan's prioritization now ranks a different topic above it (see the coverage scan, Rule 8, in `.specify/extensions/gaia/templates/clarify-prompts.md`), announce explicitly via `AskUserQuestion`:

- question: `"Out of questions on <topic>. Move to <next topic>, or push deeper?"`
- header: `"Topic"`
- options:
  - `{ label: "Move to <next topic> (Recommended)", description: "Advance to the next discovery area." }`
  - `{ label: "Push deeper on <topic>", description: "Mine the current topic further." }`
  - `{ label: "Other", description: "Free-text alternative." }`
  - `{ label: "Save partial and resume later", description: "Write the draft to cache and stop." }`

Silent topic advance is forbidden. On `Push deeper on <topic>`, increment `push_deeper[<topic>]`. When that counter reaches 3 for any topic, switch to the revisit-counter prompt (see operational primitives) instead of repeating this checkpoint.

#### 5e. Research subagent dispatch

For any question that requires prior-art lookup, repo-convention investigation, or competitive analysis, dispatch a research subagent, never punt the research to the user.

**Announce the dispatch BEFORE dispatching**, verbatim:

> Dispatching research agent for `<question>`

Spawn a `general-purpose` Agent with a focused research prompt. Handle the return based on outcome:

- **Found (useful findings).** Fold into `research_summary` of the draft. Cite sources. Write draft cache. Continue the loop.
- **Inconclusive (agent searched but found nothing definitive).** Fold the inconclusive note into `research_summary` as a known gap. Re-prompt the original closed-set question with the research context attached as a footnote so the user can decide informed.
- **Error (agent did not return findings or returned an error).** Surface to the user via plain prompt: `"Research agent did not return findings on \"<question>\". Answer manually, defer with rationale, or skip this question?"`. Wait for direction. Do not silently continue.
- **Contradictory (agent returned multiple plausible answers).** Surface both candidates via `AskUserQuestion` with each candidate as an option (plus `Other` and `Save partial and resume later`). Let the user pick.

If the user has selected `Discuss this` on a question that turns out to need research, dispatch the research subagent and surface findings in the discussion before requesting settlement.

### 6. Self-review

After the Socratic loop settles, run the GAIA self-review. Rather than running the audit in the wrapper's own context (which would re-load the full draft plus the gate-1 snapshot into wrapper memory), **dispatch it as a `general-purpose` Agent** so the heavy reads stay in fresh context and only structured findings flow back. This is the largest token saver in the spec flow.

The self-review is dispatched here, by this step, and does not depend on any spec-kit hook firing. It runs identically on a project with spec-kit core installed and on one without.

#### 6a. Dispatch the self-review agent

First, create the audit cache's findings directory if absent, so `self-review.json` is never orphaned. The cache is created here, before the step-7 audit is even chosen:

```bash
mkdir -p .gaia/local/cache/audit-${SPEC_ID}/findings || true
```

This is a **mutating unit** (the self-review agent applies low/medium fixes directly to the live draft), so before dispatching, pre-clear the findings path and snapshot the live draft to a pre-dispatch checkpoint (see "No-op guard" in Operational primitives):

```bash
rm -f .gaia/local/cache/audit-${SPEC_ID}/findings/self-review.json
cp .gaia/local/cache/draft-${SPEC_ID}.md .gaia/local/cache/draft-${SPEC_ID}.pre-6a.md
```

Spawn a `general-purpose` Agent with this prompt (interpolate `<DRAFT_PATH>` and `<spec_id>`):

> Run the self-review audit defined in `.specify/extensions/gaia/commands/self-review.md` over the draft at `<DRAFT_PATH>` against the gate-1 snapshot at `.gaia/local/cache/gate1-<spec_id>.json`.
>
> Lead with a tool call, not prose: your first action is a Read of the artifact under audit, and you emit your structured result before any prose. Read `<DRAFT_PATH>` first, before any other action.
>
> **Write** your full findings to `.gaia/local/cache/audit-<spec_id>/findings/self-review.json` (the fully-qualified path — never a bare `findings/self-review.json`, which from the repo-root cwd would resolve outside the cache and be orphaned, off the `.gaia/local/cache/**` allowlist). Each finding is one object under this schema, and every finding carries an `id` of the form `SR-NNN`, which you assign sequentially as you record each one:
>
>     {
>       "id": "SR-NNN",
>       "severity": "low" | "medium" | "high",
>       "kind": "placeholder" | "ambiguity" | "inconsistency" | "drift" | "scope_change" | "missing_uat" | "other",
>       "location": "<section heading or UAT-NNN>",
>       "excerpt": "<short verbatim excerpt, keep under 200 chars>",
>       "issue": "<one sentence, what is wrong>",
>       "suggested_fix": "<one sentence, what to change to resolve>"
>     }
>
> **Apply** every `low` and `medium` `suggested_fix` yourself to the draft at `<DRAFT_PATH>` in a single `Write` (you have already read the whole draft). Do NOT apply the `high` findings; the wrapper gates those.
>
> **Return** only this thin digest, no finding bodies beyond the `high_findings` fields below:
>
>     { "counts": { "low": <int>, "medium": <int>, "high": <int> },
>       "applied": [<ids>],
>       "high_findings": [ { "id": "SR-NNN", "kind": "...", "location": "...", "issue": "...", "excerpt": "...", "suggested_fix": "..." } ],
>       "pending_clarifications": [ { "topic": "...", "question": "..." } ] }
>
> Severity guidance:
>
> - **low**, placeholder text ("TODO", vague adjectives), terminology inconsistency
> - **medium**, internal inconsistency, ambiguous UAT phrasing
> - **high**, drift from gate-1 snapshot, scope change, removed UAT, added UAT not present at gate 1

The digest is thin: `counts` gives the low/medium/high split, `applied` lists the folded ids, and each `high_findings` entry carries `kind`, `excerpt`, and `suggested_fix` (aligned with the 6a schema) so 6b's auto-branch and auto-mode rule 8 can gate and render the prompt without re-reading the draft.

**No-op guard (site #1).** Classify the return with `bash .gaia/scripts/audit-noop-detect.sh --shape spec-selfreview-file --path .gaia/local/cache/audit-<spec_id>/findings/self-review.json` (exit 0 = real, exit 1 = no-op; see "No-op guard" in Operational primitives). On a no-op: restore the live draft from `.gaia/local/cache/draft-<spec_id>.pre-6a.md` first, re-clear the findings path, then re-dispatch the same unit **exactly one** time, prepending the hardened retry prefix with `<target>` = `<DRAFT_PATH>`. A second consecutive no-op does not re-dispatch a third time; instead run the self-review inline as the **inline fallback** below (the same terminal action the fan-out-unavailable case takes), and record the unit as degraded rather than clean or empty. Delete `draft-<spec_id>.pre-6a.md` once the unit resolves (recovered, retried, or fallen back). Append one `coverage.jsonl` record (`phase: "self_review"`, `disposition: "first_pass"|"retried_recovered"|"inline_fallback"`) to `.gaia/local/cache/audit-<spec_id>/coverage.jsonl`.

**Fallback.** When subagent dispatch is unavailable, the main thread runs the self-review inline (parity with the step-7 audit fallback): it reads the draft, records the same findings, applies every `low` and `medium` `suggested_fix` itself in a single Write, and gates the highs at 6b. This is also the terminal **inline fallback** action for a double no-op above.

#### 6b. Apply findings (severity-gated)

The self-review agent already applied every `low` and `medium` `suggested_fix` (6a); main gates only the **high** findings, rendered from the digest's `high_findings` entries (`issue`, `excerpt`, `suggested_fix`). This is one of the two bounded interactive carve-outs where a finding body legitimately reaches main; keep it, do not extend it.

- **high findings:** surface to the user before applying. Never silently revert intentional clarify-loop evolution. **Auto-mode exception per rule 8:** apply the `suggested_fix` and append a one-line note to `clarifications.deferred[]` recording the finding (kind, location, issue) so a reviewer can audit. If the finding is `kind: "drift"` or `"scope_change"` and the change came from a clarify answer the agent itself just made in step 5, prefer keeping the clarify answer over reverting, append the note but skip the fix. Use a plain prompt per finding:

  > Self-review flagged a scope-level concern in `<location>`:
  >
  > **Issue:** <issue>
  >
  > **Excerpt:** "<excerpt>"
  >
  > **Suggested fix:** <suggested_fix>
  >
  > Apply the fix, keep the current draft, or revise differently?

  Wait for user direction. An **approved** high fix folds through the **delegated fold** (see "Audit cache + delegated fold"), keyed by its `SR-NNN` id in the decision list; do not emit a main-thread draft `Write` for the fold. On `revise differently`, route the user's revision through the same delegated fold. On `keep`, fold nothing.

#### 6c. Pending clarifications block-or-defer

For each item in `pending_clarifications[]`, surface via `AskUserQuestion`:

- options:
  - `{ label: "Answer now", description: "Resolve <topic> inline." }`
  - `{ label: "Defer with rationale", description: "Mark unresolved; capture rationale in clarifications.deferred[]." }`
  - `{ label: "Discuss this", description: "Drop to plain Q&A, then settle." }`

**Auto-mode exception per rule 9:** skip the `AskUserQuestion` and auto-defer every pending item with rationale `"Auto-mode session, defer for human review."` Save proceeds unblocked.

Save remains blocked while any pending item is unresolved. Once folded into `clarifications.deferred[]`, do not re-quote the raw Q&A in downstream prompts (see operational primitives).

After all findings are applied and pending items are resolved, write the draft cache and proceed to step 7 (the adversarial SPEC-audit).

### 7. Adversarial SPEC-audit

A multi-agent adversarial audit that hardens the draft against ground truth BEFORE gate 2 renders it. Low-overlap lenses verify the SPEC's checkable claims against the actual repo and `node_modules` (not on faith), a refutation pass keeps severity honest, and each surviving finding is routed to either a plan-time directive or a pre-save SPEC fix. Because it runs pre-save, contract fixes fold straight into the draft with no reopen ceremony, gate 2 then presents the hardened artifact.

This phase complements, never replaces, step 6: the single-agent self-review is the always-on baseline; the audit is the heavyweight, ground-truth pass that runs on every spec. It dispatches the skill's own parallel `general-purpose` Agent fan-out (the same dispatch primitive step 6a uses), not the Workflow tool, so it is available in every context including headless and auto-mode runs.

**The audit always runs; the gauge sets its intensity.** After step 6 completes, gauge the draft (below) and run the audit at the gauged tier with no prompt. Auditing is always worth it, so there is no skip option and no user choice: interactive and auto mode both proceed straight into the fan-out. The one exception is the fan-out-unavailable Fallback below, a capability limit rather than a choice.

**Gauge the draft (this sets the tier and lens set).** Read the draft once and decide two independent things:

- **Rigor tier**, by stakes: weigh reversibility cost (an immutable artifact bound for autonomous downstream implementation is higher), blast radius (files and consumers the change touches), ground-truth claim density, and whether any risk surface is present. Low stakes with narrow scope and few claims → **Standard**; high stakes, or any security or migration surface → **Deep**.
- **Specialist lens set**, by content: scan `intent`, `scope_boundaries`, `success_criteria`, the required-reading list, and the touched paths against the specialist trigger column in 7a, and select every specialist whose trigger fires. The four core lenses always run; specialists are additive.

Record the gauged tier as `audit_intensity` (`standard` | `deep`) and the selected lens set; 7a records both in the cost-ledger breadcrumb. **Standard** verifies every checkable claim against ground truth with one refuter per material finding (7b-i); **Deep** adds perspective-diverse refuters (correctness, security, reproducibility) per material finding plus a completeness critic (7b-ii).

**Auto-mode.** Auto mode gauges and runs the audit exactly as interactive does; the prompt is gone from both. The two auto-specific differences (Auto-mode rule 12) are in the fold, not the run: auto mode reads **no finding body** during the audit and fold phase (the transcript carries only ids, severities, titles, verdicts, and dispositions), and it applies every disposition non-interactively at 7c. It never skips the audit.

**Fallback (never block).** If the parallel `general-purpose` Agent fan-out is unavailable (a restricted context that cannot spawn subagents), do NOT block save: note the skip (`adversarial audit unavailable, relying on step-6 self-review`), remove the audit cache with `rm -rf .gaia/local/cache/audit-<spec_id>/` (so the step-6 `self-review.json` is not orphaned), and proceed to gate 2. The step-6 self-review already ran and is the safety net. This path writes no `audit-window-<spec_id>.json` breadcrumb; its absence is the step-9 tally's signal that no adversarial audit ran.

#### 7a. Dispatch the lens auditors (parallel fan-out)

Announce once, verbatim, naming each lens in full with its id code in parentheses (e.g. `factual grounding (FG)`), never the bare code:

> Dispatching adversarial SPEC-audit (<audit_intensity>): lenses <selected lens names, each with its id in parentheses>, then refutation (typically a dozen-plus agents, several minutes).

Capture the audit window start for the cost-ledger breadcrumb: `AUDIT_WINDOW_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"`. Then spawn **one `general-purpose` Agent per selected lens, all in parallel** (one message, one Agent tool call per lens): the four core lenses always, plus each specialist the gauge selected. Each agent audits the working-draft cache (`.gaia/local/cache/draft-<spec_id>.md`, the post-self-review draft, NOT the step-3 canonical file), **writes its findings JSON to `.gaia/local/cache/audit-<spec_id>/findings/<LENS>.json`** (writing the file even when its findings array is empty), then returns only the thin digest below, no finding bodies.

Shared preamble (interpolate `<DRAFT_PATH>` = the working-draft cache, `<spec_id>`, `<repo_root>` = `$PWD`, and `<LENS>` = the agent's lens id prefix):

> You are an ADVERSARIAL auditor of a GAIA SPEC draft at `<DRAFT_PATH>` (spec `<spec_id>`). Repo root is `<repo_root>`; you may read any file under it, including `node_modules`. Read the full draft first. Your job is to find DEFECTS that would cause a flawed plan or implementation downstream, not to praise it.
>
> Lead with a tool call, not prose: your first action is a Read of the artifact under audit, and you emit your structured result before any prose. Read `<DRAFT_PATH>` before anything else.
>
> - Verify EVERY checkable claim against the actual repository and `node_modules`. Do not take the draft's assertions on faith; when a claim is about code, open the file and confirm.
> - Cite evidence: SPEC section / UAT id, and `file:line` for any ground-truth check.
> - Severity: `blocker` = the SPEC is factually wrong or will produce broken/misleading work; `high` = a significant gap or ambiguity a planner is forced to guess on; `medium` = should fix; `low` = nit.
> - Give each finding a stable id prefixed with your lens code.
> - Be concrete and falsifiable. A finding a verifier can refute by reading one file is a good finding; vague "could be clearer" is not.
> - **Write** your full findings to `.gaia/local/cache/audit-<spec_id>/findings/<LENS>.json` (the fully-qualified path) under the file schema below; write the file even if your findings array is empty.
> - **Return** only the thin digest, no finding bodies. It lists EVERY finding (material and low) as `{ id, severity, title }`, so the wrapper holds ids, severities, and titles for all of them while the full body stays on disk:
>
>     { "dimension": "<lens>", "counts": { "blocker": <int>, "high": <int>, "medium": <int>, "low": <int> },
>       "findings": [ { "id": "<lens>-NNN", "severity": "...", "title": "..." } ] }

The four core lenses (always dispatched; the set is chosen for low overlap, each reliably finds defects the others miss):

- **Factual grounding (id prefix `FG`).** Treat the SPEC as a set of factual claims and verify each load-bearing claim true or false against ground truth. For every claim about code, an installed dependency, an export subpath, a file path, or an existing convention, open the artifact and confirm it resolves, including whether any newly added dependency is justified and version-pinned. Any claim that is false or overstated is at least `high`, likely `blocker`.
- **UAT testability (id prefix `TST`).** Attack each UAT for falsifiability and GAMEABILITY. For each weak UAT, describe the concrete scenario where it passes while the feature is still broken or useless (e.g. a "points to X" UAT that passes on a bare path drop), and propose a tighter, doc-grep- or test-checkable `then`. Flag any UAT with no obvious verification method.
- **Coverage & consistency (id prefix `COV`).** Build the cross-matrix intent ↔ `success_criteria` ↔ UATs ↔ `scope_boundaries` and find the holes: orphan success criteria with no covering UAT; promises in the intent no UAT covers; UATs the SPEC needs but lacks; contradictions between `always`/`never`/`ask_first` and the UATs or intent; `scope_boundaries` entries that are not enforceable or observable; and whether the SPEC respects the project's established conventions (its `CLAUDE.md` rules, coding guidelines, naming).
- **Red-team & feasibility (id prefix `RT`).** Actively try to BREAK the SPEC. Construct the strongest scenario where ALL UATs pass yet the feature is not actually delivered or its core value claim is unmet. Attack acceptance-gate feasibility (is each gate concretely runnable and deterministic?), durability and over-claims, blast-radius completeness (any consumer or site the SPEC missed), and any circular justification or unstated assumption a planner would inherit as fact.

**Specialist lenses** (dispatch only the ones the gauge selected; build each agent's prompt from the shared preamble plus a `LENS: <name> (id prefix <ID>)` line and the "hunts for" focus from its row):

| ID | Fires when the spec touches | Hunts for |
| --- | --- | --- |
| `SEC` | auth, tokens or secrets, CSRF, redirects, uploads, permissions, PII, raw user input, headers, cookies | injection, SSRF, open redirect, token or secret leakage, missing authorization, unsafe deserialization; whether the SPEC's security claim holds and its acceptance gate is adversarial |
| `MIG` | schema, format, or ledger changes; renamed, removed, or added fields; breaking API or serialization changes; config-vocabulary changes | existing-data handling, reversibility and rollback, dual-read or dual-write windows, version skew, what breaks for legacy or in-flight records |
| `A11Y` | UI components, routes, pages, anything that renders DOM | UATs that pass an axe rule yet fail real assistive tech; missing keyboard, focus-order, label, contrast, or landmark criteria; aria misuse |
| `DOC` | wiki or docs deliverables, "points to X" pointer UATs, README or section-title citations | duplication of an authoritative source, rot-resistance, dead cross-references, pointer UATs satisfiable by a bare path drop |
| `PERF` | data volume, loops over collections, network fan-out, caching, render or hydration paths | speculative-versus-real cost, N+1, unbounded growth, flaky warm/cold performance gates |

Findings **file** schema (what each agent writes to `findings/<LENS>.json`; NOT a return contract, the thin digest above is what flows back to main):

    {
      "dimension": "<lens name>",
      "findings": [
        {
          "id": "<lens-prefix>-NNN",
          "severity": "blocker" | "high" | "medium" | "low",
          "title": "<short>",
          "location": "<SPEC section or UAT-NNN>",
          "issue": "<one sentence: what is wrong>",
          "evidence": "<file:line or SPEC quote actually checked>",
          "recommendation": "<one sentence: the fix>"
        }
      ]
    }

**No-op guard (site #2).** Before dispatching the fan-out, pre-clear each `findings/<LENS>.json` (`rm -f`) for every lens about to be dispatched, and re-clear before any retry, so presence afterward is a fresh-write signal. After the fan-out returns, classify each lens with `bash .gaia/scripts/audit-noop-detect.sh --shape spec-findings-file --path .gaia/local/cache/audit-<spec_id>/findings/<LENS>.json` (an empty `findings: []` is still real). On a no-op, re-dispatch that one lens **exactly one** time with the hardened retry prefix (`<target>` = `<DRAFT_PATH>`); a second no-op runs the **inline fallback**: main runs that lens's audit inline and writes to the SAME `findings/<LENS>.json` so the recovered findings re-enter 7b/7c exactly like a dispatched lens's, recorded degraded rather than clean or empty. A specialist lens the gauge did not select for this dispatch is never issued and is recorded `not_applicable`, never treated as a no-op. Append one `coverage.jsonl` record (`phase: "lens"`, `lens: "<LENS>"`, `disposition: "..."`) per in-scope lens.

#### 7b. Refutation pass (severity discipline)

This heading covers three distinct dispatch sites, delimited below by their own `#####` sub-headings: the refuter (7b-i), the Deep-only completeness critic (7b-ii), and the completeness critic's own refuter (7b-iii).

##### 7b-i. Refutation

From the 7a thin digests, main selects every **material** finding id (severity ≠ `low`) across all selected lenses; low-severity findings skip refutation and carry forward unchanged. Each refuter defaults to "refuted" unless it can substantiate the defect from ground truth, so this pass is severity discipline as much as false-positive killing (in the pilot it refuted none outright but correctly downgraded every `high` to `medium`). The refuter count scales with `audit_intensity`:

- **Standard:** one refuter per material finding, all in parallel.
- **Deep:** three refuters per material finding, all in parallel, each given a distinct verification lens, prepend one of `correctness`, `security/safety`, or `reproduces-as-described` to the refuter prompt below. A finding is refuted only on a ≥2-of-3 majority; its corrected severity is the median of the non-refuting refuters.

Main dispatches each refuter keyed by `{ finding_id, findings_file, refuter_lens? }` — **no finding fields interpolated** — where `findings_file` is the lens's `.gaia/local/cache/audit-<spec_id>/findings/<LENS>.json` and `verdict_file` is the refuter's output path (`verdicts/<finding-id>.json` for Standard, `verdicts/<finding-id>-<slug-lens>.json` for Deep, slug per the frozen mapping). The refuter reads the finding body from the file itself. Before dispatch, and again before any retry, pre-clear `<verdict_file>` (`rm -f`) so its presence is a fresh-write signal.

Refuter prompt (interpolate `<finding_id>`, `<findings_file>`, `<verdict_file>`, `<DRAFT_PATH>`, `<repo_root>` — no finding fields inline):

> Verify finding `<finding_id>`, recorded in `<findings_file>`, against the SPEC draft at `<DRAFT_PATH>` (repo root `<repo_root>`). Read the finding there; its severity, location, issue, evidence, and recommendation all live in that file.
>
> Lead with a tool call, not prose: your first action is a Read of the artifact under audit, and you emit your structured result before any prose. Read `<findings_file>` first.
>
> Open the cited SPEC section and any cited file yourself and try to REFUTE it: did the auditor misread the SPEC or the code, or overstate severity? For a finding you do NOT refute, also classify its DISPOSITION: is the SPEC's binding contract (its UATs + intent) already correct and only the implementation needs steering (`plan_directive`), or is a UAT or the intent itself wrong, gameable, or missing (`spec_defect`)? Default to `refuted` if you cannot substantiate the finding from ground truth.
>
> **Write** your verdict to `<verdict_file>` under the verdict schema below, then **return** only the thin verdict line `{ "id": "<finding_id>", "verdict": "confirmed"|"partial"|"refuted", "corrected_severity": "...", "disposition": "plan_directive"|"spec_defect" }`.

Verdict schema — the **file** the refuter writes to `verdicts/<finding-id>.json` (Standard) or `verdicts/<finding-id>-<slug-lens>.json` (Deep). `disposition` is consulted only for surviving findings:

    {
      "verdict": "confirmed" | "partial" | "refuted",
      "corrected_severity": "blocker" | "high" | "medium" | "low" | "none",
      "disposition": "plan_directive" | "spec_defect",
      "reasoning": "<one or two sentences>",
      "evidence": "<file:line or SPEC quote actually checked>"
    }

Main computes the Deep ≥2/3 majority and the median severity **from the returned thin verdict lines only** and **never opens the per-refuter verdict files**, so verdict reasoning bodies never reach main. Surviving findings = the low-severity findings (carried forward) plus every material finding not refuted (Standard: a single `refuted` verdict kills it; Deep: a ≥2-of-3 majority kills it), each stamped with its `corrected_severity` and `disposition`.

**No-op guard (site #3).** This shape is file-backed (not a captured return): after each refuter returns, classify it with `bash .gaia/scripts/audit-noop-detect.sh --shape spec-verdict-file --path <verdict_file>` (it re-reads the same `<verdict_file>` the refuter wrote; exit 0 = real, exit 1 = no-op). On a no-op, re-dispatch that one refuter **exactly one** time with the hardened retry prefix (`<target>` = `<findings_file>`); a second no-op runs the **inline fallback**: main refutes that one finding inline (reads `<findings_file>` and `<DRAFT_PATH>` itself, writes `<verdict_file>` with its own verdict), recorded degraded. Append one `coverage.jsonl` record (`phase: "refuter"`, `disposition: "..."`) per material finding refuted.

##### 7b-ii. Completeness critic

**Deep only.** After the refutation pass, dispatch one more `general-purpose` Agent over the draft plus the surviving findings, and ask what the lenses missed: an unverified load-bearing claim, an untested UAT, a `success_criteria` with no covering UAT, a consumer or blast-radius site the SPEC overlooked. Before dispatch, and again before any retry, pre-clear `.gaia/local/cache/audit-<spec_id>/findings/completeness.json`.

Dispatch prompt (interpolate `<DRAFT_PATH>`, `<spec_id>`, `<surviving_findings>` = the 7b-i survivor ids/severities/titles, no bodies):

> You are the completeness critic for a GAIA SPEC draft at `<DRAFT_PATH>` (spec `<spec_id>`). The surviving findings so far are `<surviving_findings>`; do not re-raise them. Hunt for what the lenses missed: an unverified load-bearing claim, an untested UAT, a `success_criteria` entry with no covering UAT, a consumer or blast-radius site the SPEC overlooked.
>
> Lead with a tool call, not prose: your first action is a Read of the artifact under audit, and you emit your structured result before any prose. Read `<DRAFT_PATH>` first.
>
> **Write** your fresh findings to `.gaia/local/cache/audit-<spec_id>/findings/completeness.json` under the 7a findings-file schema (`{ "dimension": "completeness", "findings": [...] }`), writing the file even if your findings array is empty.
>
> **Return** only the thin digest, no finding bodies: `{ "dimension": "completeness", "counts": { "blocker": <int>, "high": <int>, "medium": <int>, "low": <int> }, "findings": [ { "id": "CPL-NNN", "severity": "...", "title": "..." } ] }`.

It **writes its fresh findings to `.gaia/local/cache/audit-<spec_id>/findings/completeness.json`** (7a findings schema) and returns the thin digest above; its bodies never flow into main.

**No-op guard (site #4).** After the agent returns, classify with `bash .gaia/scripts/audit-noop-detect.sh --shape spec-findings-file --path .gaia/local/cache/audit-<spec_id>/findings/completeness.json` (exit 0 = real, exit 1 = no-op). On a no-op, re-dispatch **exactly one** time with the hardened retry prefix (`<target>` = `<DRAFT_PATH>`); a second no-op runs the **inline fallback**: main runs the completeness critic inline (reads the draft and surviving findings itself, writes `findings/completeness.json`), recorded degraded. Append one `coverage.jsonl` record (`phase: "completeness"`, `disposition: "..."`).

##### 7b-iii. Completeness-critic refuter

Any fresh findings from 7b-ii run through a single-refuter round under the **same** refuter prompt, verdict schema, and naming contracts as 7b-i (its verdicts write to `verdicts/<finding-id>.json`); merge the survivors. This refuter is **file-backed** like 7b-i, not a distinct return-conformance shape: pre-clear `verdicts/<finding-id>.json` before dispatch and before any retry.

**No-op guard (site #5).** Classify with `bash .gaia/scripts/audit-noop-detect.sh --shape spec-verdict-file --path .gaia/local/cache/audit-<spec_id>/verdicts/<finding-id>.json` (exit 0 = real, exit 1 = no-op). On a no-op, re-dispatch that one refuter **exactly one** time with the hardened retry prefix (`<target>` = `.gaia/local/cache/audit-<spec_id>/findings/completeness.json`); a second no-op runs the **inline fallback**: main refutes that fresh finding inline and writes its verdict file itself, recorded degraded. Append one `coverage.jsonl` record (`phase: "refuter"`, `disposition: "..."`).

Its bodies never flow into main.

#### 7c. Disposition routing + apply

Route each surviving finding by its `disposition`, read from the **thin verdict lines** (main never opens the verdict files):

- **Plan-time directive** (the SPEC's contract is already satisfied; the fix is an implementation instruction). No change folds into the draft — it stays byte-identical — but the finding gains a plan-time-directive entry in `AUDIT.md` (7d) so `/gaia-plan` and the implementer honor it.
- **SPEC contract defect** (a UAT or the intent is itself wrong, gameable, or missing). The draft is not yet saved, so the fix folds straight into the draft cache with NO reopen ceremony.

**Interactive.** Main reads only the handful of **material** (severity ≠ `low`) spec-defect survivors from the findings files to surface them to the user, mirroring step 6b's high-finding prompt (issue, evidence, recommendation; apply / keep / revise). No numeric cap or paging. This is the second bounded interactive carve-out where a finding body legitimately reaches main. Collect the user's apply/keep/revise decisions into the delegated-fold decision list. **Low** spec-defect fixes are never read into main; the applier folds them directly from the on-disk findings files (it reads the full cache), and refuter verdict text is never read into main. (Low findings skip refutation and carry no verdict line, so the sourcing of a low finding's `disposition` is a pre-existing question the audit's logic leaves unchanged here; the applier only folds the low spec-defects the current flow would have folded.)

**Auto-mode per rule 12.** No reads; **no finding body reaches main**. The transcript carries ids, severities, titles, verdicts, and dispositions only. Unambiguous spec-defect ids apply (added to the decision list as `apply`); a defect with more than one defensible repair becomes a deferred-clarification note in `clarifications.deferred[]` with rationale `"Auto-mode audit, defer for human review."` and is not applied. Never revert intentional clarify-loop evolution.

**Fold through the delegated applier.** Dispatch the applier (see "Audit cache + delegated fold") with the draft path, the audit-cache directory, and the decision list. It reads the draft plus every findings and verdict file plus the decision list, folds every spec-defect fix in **one Write**, and **writes `AUDIT.md` itself** (7d) from the on-disk findings and verdicts — main never loads a finding body to produce `AUDIT.md`. **Fallback:** if subagent dispatch is unavailable, main folds inline as today.

**No-op guard (site #6).** This is a **mutating unit**: the applier's draft-cache write pre-exists, so a no-op is judged on its returned summary's shape, not on file-absence. Before dispatching, snapshot the live draft to `.gaia/local/cache/draft-<spec_id>.pre-7c.md`, and finalize `.gaia/local/cache/audit-<spec_id>/coverage.jsonl`, one thin JSON-Lines record per in-scope dispatch resolved so far, `{ "phase": ..., "lens": ..., "disposition": "first_pass"|"retried_recovered"|"inline_fallback"|"not_applicable" }`, carrying no finding body (this is the applier's data source for `## Coverage` in 7d; the findings/verdict files cannot encode a disposition). Capture the applier's returned summary to a temp file and classify it with `bash .gaia/scripts/audit-noop-detect.sh --shape applier-summary --path <summary_file>` (add `--audit-md .gaia/local/specs/<spec_id>/AUDIT.md` at the 7c-with-directives dispatch, when the fold routes any finding to a plan-time directive, so AUDIT.md presence is also required; exit 0 = real, exit 1 = no-op). On a no-op: restore the live draft from `draft-<spec_id>.pre-7c.md` first, then re-dispatch the applier **exactly one** time with the hardened retry prefix (`<target>` = the audit-cache directory). A second no-op runs the **inline fallback**, which reuses the pre-existing applier inline-fold above (main folds inline as today), recorded degraded. Delete `draft-<spec_id>.pre-7c.md` once the unit resolves.

#### 7d. Persist AUDIT.md

The **applier** writes a sibling report to `.gaia/local/specs/<spec_id>/AUDIT.md` from the on-disk findings and verdicts (it already holds the complete record, so main never loads a finding body to produce it). The SPEC folder already exists from step 3, and `.gaia/local/specs/**` is on the write-surface allowlist. Keep it lean:

```markdown
# <spec_id> Adversarial Audit

<one line: N lenses, R findings raised, S survived verification, X refuted; severity counts>

## Verdict

<plannable? blockers? premise sound? one short paragraph>

## Plan-time directives (no SPEC change)

These satisfy the SPEC's binding contracts; the plan and implementation must honor them.

1. <directive, with finding id and file:line evidence>

## SPEC contract fixes (folded into the draft pre-save)

- <finding id>: <what was wrong> → <fix folded into the draft>

## Refuted / downgraded (for the record)

- <finding id>: <verdict + corrected severity + one-line reason>

## Coverage

<one line per in-scope dispatch (self-review, each lens, each refuter, the completeness critic on Deep)>

- **<phase>** (`<lens>`): `<disposition>`
```

The `## Coverage` section is sourced from `.gaia/local/cache/audit-<spec_id>/coverage.jsonl` (the thin phase/lens/disposition record main appends per dispatch, see "No-op guard" in Operational primitives), not from the findings/verdict files (which cannot encode a disposition). Each line's `<disposition>` is one of `first_pass` / `retried_recovered` / `inline_fallback` / `not_applicable`, so a reader can distinguish a clean unit from a degraded one at a glance.

When a sibling `AUDIT.md` exists, the step-11 `/gaia-plan` handoff names it so its plan-time directives are discoverable.

**Close the audit window (cost-ledger breadcrumb).** The audit unit is now complete, the 7c applier has returned. Capture the end and write the FC-1 breadcrumb by sourcing the FC-5 lib and calling its single breadcrumb writer. Do not inline `jq -n` here, the write goes through `gaia_audit_window_write` so the same code path a unit test exercises is the one production runs:

```bash
AUDIT_WINDOW_END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
. .gaia/scripts/audit-window-lib.sh 2>/dev/null || true
audit_common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"
case "$audit_common_dir" in /*) audit_abs="$audit_common_dir" ;; *) audit_abs="$PWD/$audit_common_dir" ;; esac
AUDIT_CACHE_DIR="$(cd "$(dirname "$audit_abs")" 2>/dev/null && pwd)/.gaia/local/cache"
gaia_audit_window_write \
  "$AUDIT_CACHE_DIR/audit-window-$SPEC_ID.json" \
  "${CLAUDE_CODE_SESSION_ID}" \
  "$AUDIT_WINDOW_START" "$AUDIT_WINDOW_END" \
  "<lenses-json-array>" \
  "<audit_intensity>" || true
```

`<lenses-json-array>` is a JSON array of the dispatched lens-id set, e.g. built with `jq -cn '$ARGS.positional' --args FG TST COV RT`. `<audit_intensity>` is the tier recorded at the top of step 7 (`standard` | `deep`); passing it as the 6th argument makes the writer include the `intensity` key. `$AUDIT_CACHE_DIR` resolves to the main checkout's cache root the same way `token-tally.sh` derives it, so the breadcrumb lands there even when authoring runs inside a linked worktree; it never sits inside `.gaia/local/cache/audit-<spec_id>/`, so the step-9.1 teardown does not remove it. The call is best-effort (`|| true`) and never blocks the handoff to gate 2.

After the report is written, any folds are cached, and the breadcrumb is written, proceed to gate 2 (step 8), which renders the hardened draft.

### 8. Gate 2, artifact confirmation

Render the full draft artifact in markdown form (frontmatter plus body) and present it to the user. This is gate 2. Track `gate2_revisions = 0` in working memory.

**Auto-mode exception per rule 3:** skip the user prompt. Render the draft into the agent's reasoning context, run a self-check (frontmatter populated, every UAT has Given/When/Then, intent matches gate-1 snapshot modulo intentional clarify evolution, deferred clarifications block well-formed). Apply at most one revision pass if the self-check finds an issue, then jump to the "On confirmation" actions below.

Use a plain prompt, not `AskUserQuestion`. Suggested phrasing:

> Here is the rendered SPEC. Review it and confirm before save, or tell me what to revise.
>
> ```markdown
> <full rendered artifact>
> ```

If the user revises:

1. Route the revision through the **delegated fold** (see "Audit cache + delegated fold") in **free-text revision mode**: the decision-list entry is id-less and carries the revision text inline; the applier applies it directly with no findings-file lookup, writes the draft cache in one Write, and returns its one-line summary. Main emits no draft-body `Write` for the gate-2 fold. This completes "no full-draft Write in the main thread at a fold checkpoint." **Fallback:** when subagent dispatch is unavailable, main folds the revision inline as today.
2. Increment `gate2_revisions`.
3. Re-present until they confirm. Do not re-quote raw clarify Q&A in revision prompts, reference the draft's `clarifications.answered[]` and `clarifications.deferred[]` arrays as canonical.

On confirmation:

1. Write the final draft cache.

Only after gate-2 confirmation may you proceed to step 9.

### 9. Save to .gaia/local/specs/SPEC-NNN/SPEC.md

Create the SPEC folder, then write the confirmed draft to its canonical inner file (using the `spec_id` allocated in step 3):

```bash
mkdir -p .gaia/local/specs/${SPEC_ID}
```

Write to `.gaia/local/specs/SPEC-NNN/SPEC.md`. This is the canonical save location, never anywhere else, never duplicate copies. The folder is the archival unit; sibling artifacts live beside `SPEC.md` in the same folder. A sibling's filename is the uppercased remainder of its flat form (`SPEC-NNN-<rest>.md` → `SPEC-NNN/<REST>.md`); any `SPEC-NNN-*` file is a sibling. `lib/spec-folderize.sh` applies this mapping for any legacy flat files.

Update the frontmatter `updated` field to today's date.

After the canonical write succeeds:

1. **Delete the working-draft cache:** `rm -f .gaia/local/cache/draft-<spec_id>.md .gaia/local/cache/gate1-<spec_id>.json`, and remove the audit cache with `rm -rf .gaia/local/cache/audit-<spec_id>/`. The applier has already read the audit cache to derive `AUDIT.md` (which survives under `.gaia/local/specs/<spec_id>/`), so deleting it here is safe. The canonical artifact is the source of truth from this point forward; a stale cache would mislead step 2 of a future session.
2. **Update the ledger row:** flip the row in `.gaia/local/specs/ledger.json` from `status: draft` to `status: ready` and stamp the intent (the SPEC's `intent` field reduced to a full first sentence, or a word-safe bounded prefix + `...` when the first sentence runs long, via the shared title-normalize rule) for at-a-glance scanning. This is the finalize transition: the SPEC artifact is now frozen, so the authoring session is done and the allocator stops reporting it for resume-vs-start-new. Downstream (plan → implement → merge) owns the feature from here; the ledger's `merged` transition is reconciled from git by `spec-reconcile.sh`, not set here. Failure is non-blocking, log to stderr and continue. The remote `spec/*` tags are the cross-team allocation authority; `.gaia/local/specs/ledger.json` is a per-machine local cache; the SPEC artifact and git history remain authoritative.

```bash
SPEC_PATH=".gaia/local/specs/${SPEC_ID}/SPEC.md"
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
  | bash .specify/extensions/gaia/lib/title-normalize.sh 2>/dev/null || echo "")
PATCH=$(jq -nc --arg intent "$INTENT" \
  '{status: "ready"} + (if $intent == "" then {} else {intent: $intent} end)')
bash .specify/extensions/gaia/lib/ledger-update.sh "$PWD" "$SPEC_ID" "$PATCH" \
  || echo "ledger-update skipped (row missing or jq failure), non-blocking" >&2
```

3. **Delete the session-shape cache:** `rm -f .gaia/local/cache/spec-session-${SPEC_ID}.json`. The cache's job, tracking `question_count` against the ceiling across a pause and resume, ends once the SPEC is saved.
4. **Token tally (never blocks):** tally the session's ground-truth token cost and record it. `${SPEC_ID}`'s folder already exists from the canonical save, so the `cost.json` sidecar (the `spec` record) lands beside `SPEC.md`. This call never blocks or fails the save; on unreadable input it degrades to a partial figure with a marker, never a fabricated number.

```bash
bash .gaia/scripts/token-tally.sh \
  --action spec \
  --spec-id "$SPEC_ID" \
  --out-dir ".gaia/local/specs/${SPEC_ID}" || true
```

The helper reads `CLAUDE_CODE_SESSION_ID` from the environment, sums `message.usage` across the main transcript and every sub-agent sidecar (deduped to ground truth), appends one record keyed to `SPEC_ID` to the durable ledger (`.gaia/local/telemetry/cost.jsonl`, resolved to the main checkout so a worktree run still records there), writes the `cost.json` sidecar (the `spec` record) into the SPEC folder, and prints the four-bucket tally, total, and elapsed time. The dollar cost it computes lands in the ledger and the `cost.json` sidecar, not in that printed block. Do not restate the four-bucket block to the user; instead report the cost as exactly one line: `Cost: ~<total> tokens, $<dollars>, <elapsed>`. Take `<total>` (the total token count abbreviated to millions with one decimal and a `~` prefix, e.g. `~2.4M`) and `<elapsed>` (the helper's own `<N>h<M>m<S>s` figure) from the printed tally, and read `<dollars>` (formatted `$X.XX`) from the `dollars` field of the `spec` record in `.gaia/local/specs/${SPEC_ID}/cost.json`. Never fabricate: if `dollars` is null or unpriced write `cost unavailable` in its place; if elapsed is unavailable drop that term; if the figure is a partial lower bound append ` (partial: lower bound)`. This line reads identically to the `/gaia-plan` cost line (plan reference, step 5) and the orchestrator's full-cycle line; keep the three in sync. This same call reads and deletes the step-7 audit-window breadcrumb (`.gaia/local/cache/audit-window-<spec_id>.json`) if present, nesting an `audit.adversarial` annotation into this `spec` record when the window resolves; the step-9.1 `rm -rf .gaia/local/cache/audit-<spec_id>/` above does not touch this breadcrumb, since it lives outside that directory.

**Auto-mode:** the tally fires identically in interactive and auto mode; it is a mechanical helper call, not a user prompt, so no auto-mode branch is needed. In auto mode the printed tally simply lands in the transcript, nothing to prompt.

### 10. after_specify hook (immutability lint)

Spec-kit fires this hook automatically after the spec is written. The agent receives an `EXECUTE_COMMAND: speckit.gaia.lint` directive and invokes `/speckit-gaia-lint`, which runs `bash .specify/extensions/gaia/lib/lint.sh <spec-path>` and surfaces findings.

Track `lint_cycle = <count>` in working memory (initialize to 1 on the first attempt).

On lint pass: continue to step 11.

On lint fail (cycles 1–2): surface the failures verbatim. The user can fix and re-run the lint, or defer with rationale (which loops back to step 6's pending handling). For mutations of an already-saved SPEC, the helper enforces the explicit reopen ceremony, `## Reopen rationale` and `## UAT diff` sections required. Increment `lint_cycle` and continue.

**On lint fail at cycle 3 (3 failed cycles in a row):** **Auto-mode exception per rule 10:** skip the prompt and auto-pick "Defer remaining findings", capture each remaining finding as a deferred clarification with rationale `"Auto-mode session, lint thrash, defer for human review."` and continue to step 11. Step-back-to-gate-2 in auto mode would loop indefinitely.

Otherwise, surface via `AskUserQuestion`:

- question: `"Lint has failed 3 times. Step back to gate 2 to restructure the artifact, defer all remaining lint findings with rationale, or push another fix attempt?"`
- header: `"Lint thrash"`
- options:
  - `{ label: "Step back to gate 2 (Recommended)", description: "Repeated lint failures usually indicate the artifact is not shaped right. Re-render and revise." }`
  - `{ label: "Defer remaining findings", description: "Capture each finding as a deferred clarification with rationale; loop to step 6c." }`
  - `{ label: "Push another fix attempt", description: "Try once more, but this is the third escape." }`

Reset `lint_cycle = 0` on user choice. Step-back-to-gate-2 returns to step 8 with the existing draft; the user can revise and re-save (steps 8→9→10 again).

### 11. /gaia-plan handoff, then STOP

There is no `on_save` hook in spec-kit, so the handoff lives here, inline, after the canonical save (step 9) and the immutability lint (step 10). `/gaia-spec` does not run `/gaia-plan` itself; it prints a copy-pasteable prompt and stops. Interactive and auto mode end identically, neither runs plan.

**Printing the block below is the last action of the session.** Per Hard constraint 6, this is a hard stop, not a suggested one, and it binds even when the instruction that invoked this skill asked for more (a plan, an implementation, a PR). Do not invoke `/gaia-plan`, do not read `plan.md`, do not dispatch a planner, do not start the work. A session that authored a SPEC is the worst-conditioned session in GAIA to plan it: its context is enormous and its judgment is anchored on authoring decisions the planner should meet fresh. `.claude/hooks/block-spec-plan-chain.sh` denies the chain deterministically if you attempt it anyway; reaching that deny means you have already failed to stop, so stop here instead.

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
