# /gaia-spec

Socratic discovery wrapper around spec-kit. Produces an immutable SPEC artifact at `.gaia/local/specs/SPEC-NNN/SPEC.md` and prompts to chain into `/gaia-plan`. Do not implement anything, this skill produces an artifact and stops.

## Argument parsing

Tokenize the first whitespace-separated word of `$ARGUMENTS`:

- If it is `auto`, set `auto_mode = true`, strip the token, and treat the remainder as the feature description (which may be empty, see Auto mode below).
- Otherwise `auto_mode = false` and the entire `$ARGUMENTS` is the feature description.

`auto_mode` is referenced throughout the steps below; every user-facing prompt has an auto-mode branch.

## Auto mode

When `auto_mode = true` the agent answers the Socratic questions itself rather than asking the user. The flow is non-interactive end-to-end: no `AskUserQuestion` calls fire, no plain-prompt blocks wait for human reply. The agent makes best-judgment calls using the description, the draft state, and any research it dispatches.

Hard rules in auto mode:

1. **Description is required.** If the remainder of `$ARGUMENTS` after stripping `auto` is empty, abort with: `"/gaia-spec auto requires a description. Re-invoke as: /gaia-spec auto <description>"`. Do not prompt for one, the user opted out of interactivity.
2. **GitHub issue mirror is forced on.** Set `gh_mirror_optin = true` unconditionally. Do not ask the step-1 GH-mirror question. If `gh-mirror.sh` later skips for environment reasons (no `gh` auth, Issues disabled, no write permission), surface that in the final summary but do not abort, the SPEC is the artifact, the issue is a mirror.
3. **Resume vs start-new is automatic.** If the allocator reports an in-progress SPEC, **start new** without prompting. The user's `auto` invocation is itself the signal that they want a fresh artifact.
4. **Both gates auto-confirm.** Gate 1 and gate 2 do not present plain prompts to the user. The agent renders the draft to its own reasoning context, performs a self-check (is intent coherent? are UATs Given/When/Then? do UATs cover the intent?), and proceeds. If the self-check finds an issue, the agent revises in-place and re-checks once before proceeding, never blocks for human input.
5. **Closed-set Socratic questions pick the Recommended option.** For every step-5 `AskUserQuestion` that would normally fire, the agent selects the option that step 5a's spec marks "Recommended FIRST", the PO's best-judgment candidate. No `AskUserQuestion` tool call is made. The selected answer is folded into `clarifications.answered[]` exactly as if the user had picked it. Telemetry: append a `clarify_question` event with `kind: "auto"` (replacing the usual `closed`/`open`/`discuss`).
6. **Open-ended Socratic questions are answered by the agent.** Apply the same coach-tone judgment the human would receive, then commit the answer. Fold into `clarifications.answered[]`.
7. **Per-topic exhaustion + revisit checkpoints auto-advance.** Step 5d always picks "Move to <next topic>". The per-topic revisit counter still increments but the 3-revisit prompt auto-picks "Settle on the recommended option".
8. **Research subagents still dispatch.** Auto mode does not skip research, it skips human prompting. When step 5e would dispatch a `general-purpose` Agent, dispatch it normally. On `inconclusive`/`error`/`contradictory` outcomes that would normally re-prompt the user, the agent picks the most plausible candidate and folds it with a note in `research_summary` flagging the uncertainty.
9. **Self-review high findings auto-apply.** Step 6b's high-severity branch normally surfaces each finding to the user; in auto mode, apply the `suggested_fix` and append a note to `clarifications.deferred[]` summarizing the finding so a reviewer can audit later. Do NOT silently revert clarify-loop evolution, if the finding is `kind: "drift"` or `"scope_change"` and the change came from a clarify answer the agent itself just made, prefer keeping the clarify answer over reverting to gate-1 shape.
10. **Pending clarifications auto-defer.** Step 6c's per-item prompt always picks "Defer with rationale". The rationale is: `"Auto-mode session, defer for human review."` This unblocks save without forcing the agent to fabricate answers it does not have evidence for.
11. **Lint thrash escalates to defer, not step-back.** Step 9's cycle-3 prompt auto-picks "Defer remaining findings" so the SPEC saves with the deferred-clarifications block populated. Step-back-to-gate-2 in auto mode would loop indefinitely.
12. **Chain-trigger to `/gaia-plan` is automatic.** Step 11's `AskUserQuestion` is skipped, auto mode always picks "Yes, trigger /gaia-plan". Multi-plan loop (11b) is also skipped, author exactly one plan covering the full SPEC. Multi-slice planning is a human-judgment call; auto mode produces one plan.
13. **`Save partial and resume later` escapes are unreachable.** No prompt fires that would offer them. The session always proceeds to step 8 unless the agent itself decides to abort (e.g. missing description, hard tool failure).
14. **Telemetry distinguishes auto runs.** Every `clarify_question`, `gate1_confirmed`, `gate2_confirmed`, and `spec_saved` event in an auto session includes `"auto": true` in its JSON record. The `time_to_resolved_spec` mentorship emit at step 8 includes `--agent-type auto` instead of `--agent-type human`. Telemetry-derived metrics should be partitioned by `auto` so auto-mode runs do not pollute the human pacing baseline.

The rest of the skill, write-surface allowlist, no-machine-local-memory rule, working-draft cache primitives, hooks firing, immutable SPEC shape, `gh-mirror.sh` invocation, applies identically in auto mode.

## Profile-driven coaching preamble

Before composing the system prompt for this skill's agent context, fetch any active coaching adaptation:

```bash
COACHING=$(.gaia/cli/gaia _internal-fetch-coaching --agent-type human --area-tags spec)
```

If `$COACHING` is non-empty, prepend its contents to the system prompt as the first section. If empty (the v1.0.0 default, pattern detection ships wired-but-inert), the prompt is byte-identical to the non-mentorship path. The fetcher always exits 0 on a valid `--agent-type`, never blocks the flow, and writes `.gaia/cache/coaching-active.txt` only when a coaching block is actually returned (lights up the 🧭 statusline indicator).

`--area-tags` is `spec` for the pre-Gate-2 phase; once the SPEC's UAT clusters are known, downstream callers can re-fetch with the richer tag set. v1 wires only this `/gaia-spec` PO path; Lead → Senior/Junior dispatch wiring lands with Sequel features.

## Hard constraints

1. **No machine-local memory for project decisions.** Never call any tool that writes to `~/.claude/projects/.../memory/`. Project-relevant decisions belong ONLY in the SPEC artifact, the wiki, or `.claude/rules/`. Personal preferences (tone, formatting) remain allowed in machine-local memory. This is the no-machine-local-memory rule and it is non-negotiable.
2. **Write-surface allowlist.** Every file write during a `/gaia-spec` session lands in exactly one of:
   - `.gaia/local/specs/**`
   - `.specify/**`
   - `.gaia/local/cache/**`
   - `.gaia/local/telemetry/**`
     Never edit source files (`app/**`, `src/**`, repo root configs, etc.). The `after_specify` lint command audits this; you enforce it at the agent-instruction level.
3. **One question at a time.** No multi-question forms. Closed-set questions go through `AskUserQuestion` with options ordered: recommended FIRST, then alternatives, then `Other` (free text), then `Discuss this` (escape to plain Q&A). Open-ended questions use a plain prompt with no enumerated options.
4. **Two-gate ceremony.** Confirm intent + UATs in plain English BEFORE authoring the artifact. Confirm the rendered artifact BEFORE saving to disk. No silent advances between gates.
5. **Coach tone, not interrogator.** Mirror back, name trade-offs, propose candidates when the human is stuck. Never punt research to the human.

## How spec-kit fires GAIA hooks

Spec-kit's hooks are **not** shell scripts. When core invokes `/speckit-specify` (or any other core skill), it reads `.specify/extensions.yml` for the relevant event and emits an `EXECUTE_COMMAND: <id>` markdown directive into the agent's reasoning context. The agent then invokes the rendered slash-command (e.g., `/speckit-gaia-constitution-check`) as a normal Claude skill. There is no JSON payload, no stdin pipe, no env var.

The three GAIA hooks declared in `.specify/extensions/gaia/extension.yml`:

| Event            | Slash command                      | Source body                                               |
| ---------------- | ---------------------------------- | --------------------------------------------------------- |
| `before_specify` | `/speckit-gaia-constitution-check` | `.specify/extensions/gaia/commands/constitution-check.md` |
| `after_clarify`  | `/speckit-gaia-self-review`        | `.specify/extensions/gaia/commands/self-review.md`        |
| `after_specify`  | `/speckit-gaia-lint`               | `.specify/extensions/gaia/commands/lint.md`               |

Each hook fires automatically, the agent reads the directive and invokes the slash command without prompting. "Block" semantics live inside the hook command: a block is a refusal message that the wrapper agent reads and chooses not to proceed past. There is no machine-enforced halt.

There is no `on_save` event. The chain-trigger to `/gaia-plan` lives inline at the end of this orchestration (Step 11), not in a hook.

## Operational primitives

Used by multiple steps below. Defined once here to keep step-level prose tight.

### Pacing telemetry (`spec-pacing.jsonl`)

Append a JSON Lines record to `.gaia/local/telemetry/spec-pacing.jsonl` at each named event. Append-only; never read during the live session. The maintainer queries the log later to tune prompts and spot pacing problems.

Append via `printf '%s\n' '<json>' >> .gaia/local/telemetry/spec-pacing.jsonl`. Failure to append never blocks the flow.

### Session-shape cache (`spec-session-<spec_id>.json`)

Used for the `time_to_resolved_spec` mentorship emit at Gate-2 save and at abandoned-exit branches. The file lives at `.gaia/local/cache/spec-session-<spec_id>.json` and is the only place where elapsed-time and Q&A-count state are tracked across the multi-step flow. Schema:

    {
      "spec_id": "SPEC-NNN",
      "start_at": "2026-05-06T18:00:00.000Z",
      "question_count": 0
    }

Three operations:

- **Init.** At step 2 (`spec_started` telemetry append, both fresh and resumed paths), write the file if it does not exist with `start_at` = current ISO-8601 UTC ms, `question_count` = 0. On resume, leave any existing file untouched, its `start_at` is the original session start (one continuous wall-clock duration across resumes is the correct semantic for `time_to_resolved_spec`).
- **Increment.** At every site that appends a `clarify_question` telemetry event (steps 5a, 5b, 5c, 5d, and the per-topic revisit prompt), bump `question_count` by 1. Inline shell:

      jq '.question_count += 1' .gaia/local/cache/spec-session-<spec_id>.json \
        > .gaia/local/cache/spec-session-<spec_id>.json.tmp \
        && mv .gaia/local/cache/spec-session-<spec_id>.json.tmp \
           .gaia/local/cache/spec-session-<spec_id>.json || true

- **Read & delete.** At step 8 (after canonical save) and at every abandoned-exit branch (the `Save partial and resume later` escape). Read both fields, compute `duration_seconds = floor((now_ms - start_at_ms) / 1000)`, fire the emit, then `rm -f .gaia/local/cache/spec-session-<spec_id>.json`.

Failure of any cache read/write must never block the flow, the emit gracefully degrades to absent metrics or a skipped emit.

Schema (one record per line, ISO-8601 UTC timestamps):

    { "event": "spec_started", "spec_id": "SPEC-NNN", "resumed": <bool>, "ts": "..." }
    { "event": "gate1_confirmed", "spec_id": "SPEC-NNN", "intent_words": <int>, "uat_count": <int>, "ts": "..." }
    { "event": "clarify_question", "spec_id": "SPEC-NNN", "topic": "<topic>", "kind": "closed|open|discuss", "ts": "..." }
    { "event": "topic_revisit", "spec_id": "SPEC-NNN", "topic": "<topic>", "revisit_count": <int>, "ts": "..." }
    { "event": "research_dispatched", "spec_id": "SPEC-NNN", "question": "<short>", "ts": "..." }
    { "event": "research_returned", "spec_id": "SPEC-NNN", "outcome": "found|inconclusive|error|contradictory", "ts": "..." }
    { "event": "self_review_findings", "spec_id": "SPEC-NNN", "low": <int>, "medium": <int>, "high": <int>, "ts": "..." }
    { "event": "gate2_confirmed", "spec_id": "SPEC-NNN", "revisions": <int>, "ts": "..." }
    { "event": "spec_saved", "spec_id": "SPEC-NNN", "ts": "..." }
    { "event": "lint_attempt", "spec_id": "SPEC-NNN", "outcome": "pass|fail", "cycle": <int>, "ts": "..." }
    { "event": "plan_dispatched", "spec_id": "SPEC-NNN", "plan_idx": <int>, "plan_dir": "<abs>", "ts": "..." }
    { "event": "session_paused", "spec_id": "SPEC-NNN", "step": "<step-id>", "ts": "..." }

### Working-draft checkpoint (`draft-<spec_id>.md`)

After each clarify fold (step 5), each gate confirmation (steps 4 + 7), each research-result fold (step 5e), and each self-review apply (step 6), persist the current in-flight draft to `.gaia/local/cache/draft-<spec_id>.md`. Step 8's canonical save deletes this cache as its final action.

**Single-`Write` rule.** Compose the full updated draft in working memory, then emit ONE `Write` tool call that overwrites the cache file. Never use a sequence of `Edit` calls for a single fold. The Q&A loop runs many turns per session and each `Edit` renders a full diff in the user's chat, multiple per-turn diffs are visual noise the user has flagged as unwanted. The per-turn budget is exactly: one `Write` for the fold, one `Bash` for telemetry. Nothing else.

**Per-turn fold contents.** When folding a Q&A turn (closed-set selection, `Other` text, open-ended answer, or Discuss-this settlement): add to `clarifications.answered[]` as `{ q, a }`, remove the topic from `clarifications.pending[]`, and update any statusline fields the answer touches, all in the same `Write`.

This makes interrupted sessions resumable: step 2 reads the cache if it is newer than the canonical artifact.

### Escape option (used in step 5 AskUserQuestion sets)

Closed-set `AskUserQuestion` calls during the clarify loop append a fifth option after `Discuss this`:

    { label: "Save partial and resume later", description: "Write the draft to cache and stop; re-invoke /gaia-spec to continue." }

Selection triggers: write draft cache (above), append `session_paused` telemetry, emit a `time_to_resolved_spec` mentorship event with `--abandoned true` per the abandoned-exit primitive below, print one-line resume hint (`SPEC-NNN saved as draft. Re-invoke /gaia-spec to resume.`), and exit gracefully.

The session-shape cache is NOT deleted on the `Save partial and resume later` path, a future resume reads it and continues counting questions against the same `start_at`. (Cache deletion happens only on canonical save at step 8, or on the `Discard SPEC-NNN draft cache` branch in step 2, see step 2 for the discard handler.)

#### Abandoned-exit emit

For the `Save partial and resume later` escape and any other branch that exits the wrapper without reaching step 8, fire a `time_to_resolved_spec` event with `--abandoned true`:

```bash
CACHE=".gaia/local/cache/spec-session-${SPEC_ID}.json"
if [[ -f "$CACHE" ]]; then
  START_AT="$(jq -r '.start_at' "$CACHE" 2>/dev/null || echo "")"
  Q_COUNT="$(jq -r '.question_count' "$CACHE" 2>/dev/null || echo 0)"
else
  START_AT=""
  Q_COUNT=0
fi
if [[ -n "$START_AT" ]]; then
  NOW_S=$(date -u +%s)
  START_S=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "${START_AT%.*}" +%s 2>/dev/null \
            || date -u -d "$START_AT" +%s 2>/dev/null || echo "$NOW_S")
  DURATION=$((NOW_S - START_S))
else
  DURATION=0
fi
.gaia/cli/gaia telemetry emit time_to_resolved_spec \
  --spec-id "$SPEC_ID" \
  --question-count "$Q_COUNT" \
  --duration-seconds "$DURATION" \
  --area-tags spec \
  --abandoned true \
  --agent-type human || true
```

Notes:

- On the `Save partial and resume later` path, the cache file remains so a future resume continues against the same `start_at`. Only canonical save (step 8) and the explicit cache-discard branch in step 2 delete it. The abandoned emit is a snapshot, not a teardown.
- `area-tags` is `spec` (v1.0.0 default) for abandoned exits, clusters can't be reliably extracted from a partial draft. Step 8 derives richer tags from the saved SPEC's UAT clusters.
- Failure of the emit must never block the user's exit, note the trailing `|| true`.

### Per-topic revisit counter

Track `push_deeper[<topic>] = <count>` in working memory. Increment on every "Push deeper on <topic>" selection at step 5d. When `count == 3` for any topic, replace the standard step 5d prompt with:

- question: `"<topic> has been revisited 3 times. Settle on a candidate, defer with rationale, or push deeper anyway?"`
- options:
  - `{ label: "Settle on the recommended option (Recommended)", description: "Accept the PO's best-judgment candidate and move on." }`
  - `{ label: "Defer <topic> with rationale", description: "Mark unresolved with a note for the planner." }`
  - `{ label: "Push deeper anyway", description: "Mine the topic further despite repeated revisits." }`
  - `{ label: "Save partial and resume later", description: "Write the draft to cache and stop." }`

Append a `topic_revisit` telemetry event with the count.

### Spec-kit's 5-question cap

Spec-kit's `/clarify` primitive is hard-capped at **5 total questions per session** (see `.specify/extensions/gaia/templates/clarify-prompts.md` and spec-kit's own `clarify.md` Behavior rules: "Maximum of 5 total questions"). The wrapper inherits this cap, the GAIA Socratic loop runs at most 5 turns. The per-topic revisit counter and escape option above fit inside that 5-question budget; never invoke `/clarify` twice in one session to extend the budget.

### Don't re-quote folded clarifications

Once a Q&A pair has been folded into the draft's `clarifications.answered[]` (step 5b) or `clarifications.deferred[]` (step 6c), it is canonical. Do NOT re-paste the raw question or answer text into downstream prompts (gate 2, self-review, gate 2 revisions). Reference the draft's structured arrays instead. This keeps wrapper context lean across the multi-step flow.

### Lazy template loading

Read `.specify/extensions/gaia/templates/clarify-prompts.md` and `system-prompt.md` only at step 5's first invocation, not earlier. They are reference templates, not preamble.

## Steps

### 1. Get description

If `$ARGUMENTS` (the args after `spec`, with `auto` already stripped if present, see Argument parsing) is non-empty, use it as the feature description.

Otherwise, ask: **"What do you want to spec?"** and wait for the response before continuing. This is open-ended, use a plain prompt, not `AskUserQuestion`. **Auto-mode exception:** in auto mode an empty description is a hard abort per Auto-mode rule 1, never prompt.

After capturing the description, **on both the `$ARGUMENTS` fast-path and the interactive-prompt path**, ask the GitHub-issue preference via `AskUserQuestion`. The question fires regardless of how the description was sourced; users invoking `/gaia-spec "..."` should expect this single prompt before discovery proper begins. **Auto-mode exception:** skip the `AskUserQuestion` entirely and set `gh_mirror_optin = true` per Auto-mode rule 2.

- question: `"Mirror this SPEC to a GitHub issue on save?"`
- header: `"GH issue"`
- options:
  - `{ label: "No, skip GitHub issue (Recommended)", description: "Default. SPEC stays local under .gaia/local/specs/. Choose this for solo work or when the implementing PR will track the work directly." }`
  - `{ label: "Yes, create a GitHub issue", description: "After save, mirror the SPEC body to a new issue on the project's GitHub repo and stamp gh_issue_url into frontmatter. The implementing PR should then include 'Closes #<N>' in its body so the issue auto-closes on merge." }`

Persist the answer as `gh_mirror_optin: <bool>` in working memory for this session. Used at step 10 (gate the mirror invocation) and step 12 (PR-body closure wiring). On resume (step 2), if the loaded draft has no `gh_issue_url` in frontmatter, re-ask this question as part of the resume setup, the resumed session needs the same opt-in signal that the fresh session would have. If `gh_issue_url` is already present, a prior session already mirrored; treat opt-in as implicitly true and do not re-ask.

### 2. Resume-vs-start-new prompt (pre-flight)

Run `bash .specify/extensions/gaia/lib/spec-allocator.sh in_progress "$PWD"`. If the output is a `SPEC-NNN` id (not `none`), an in-progress SPEC already exists.

The id may name a **draft-phase** session, a SPEC allocated in another terminal whose interactive loop has not yet reached the canonical save (step 8), so `.gaia/local/specs/SPEC-NNN/SPEC.md` may not exist yet and the live draft is at `.gaia/local/cache/draft-SPEC-NNN.md`. The `WORKING`-selection below resolves this correctly, preferring the draft cache when the canonical file is absent or older.

**Auto-mode exception:** skip the resume prompt entirely. Always start new, append `spec_started` telemetry with `resumed: false, auto: true` and proceed to step 3 with a fresh allocation. The in-progress SPEC (if any) remains untouched. Per Auto-mode rule 3 the user's `auto` invocation is the signal that they want a fresh artifact; resuming an existing draft into a non-interactive context risks silently overwriting work in progress.

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

- **Resume:** load `$WORKING` into the working draft, append `spec_started` telemetry with `resumed: true`, initialize the session-shape cache per the operational primitive (write only if absent, the original `start_at` survives across resumes), and pick up at the right step (skip earlier steps that are already done):
  - If `.gaia/local/cache/gate1-<spec_id>.json` does NOT exist → resume at step 4 (gate 1).
  - If gate-1 cache exists AND the draft has any `clarifications.pending[]` entries → resume at step 6.
  - If gate-1 cache exists AND no pending clarifications → resume at step 7 (gate 2).
  - Step 3 (initial draft) is always skipped on resume.
  - Never re-snapshot the gate-1 cache; its purpose is immutable drift detection.
  - **GH-mirror opt-in on resume.** Inspect the loaded draft's frontmatter. If `gh_issue_url` is set, treat `gh_mirror_optin = true` (a prior session already mirrored). Otherwise, ask the GH-mirror `AskUserQuestion` from step 1 once now, `gh_mirror_optin` does not persist across resumes and silently defaulting it to `false` would lose the user's earlier intent.
- **Start new:** continue with a fresh allocation (Step 3 onward). The in-progress SPEC remains untouched. Append `spec_started` telemetry with `resumed: false`, then initialize the session-shape cache per the operational primitive once the new `spec_id` is known (step 3).
- **Discard SPEC-NNN draft cache:** confirm via a follow-up `AskUserQuestion` (`"Delete the draft cache for SPEC-NNN? (The canonical artifact remains.)"` with options `Yes, delete` / `Cancel`). On confirm, `rm -f "$DRAFT_PATH" .gaia/local/cache/spec-session-${SPEC_ID}.json`, then continue with a fresh allocation. Note: the canonical SPEC artifact is untouched; the allocator will continue to flag SPEC-NNN as in-progress until the artifact itself is renamed or relabeled (out of scope for this step).

### 3. /speckit-specify (initial draft)

Invoke `/speckit-specify` with the description from step 1. The GAIA preset (registered via `specify preset add`) wraps core with `{CORE_TEMPLATE}` and replaces `spec-template`, so the artifact is GAIA-shaped (frontmatter, immutable flag, `SPEC-NNN` id) and lands at `.gaia/local/specs/SPEC-NNN/SPEC.md`. The preset's body invokes `lib/spec-allocator.sh next "$PWD"` to allocate the SPEC id.

Spec-kit fires the `before_specify` hook (constitution + version-pin check) automatically before this step runs. If the hook blocks, surface its message and halt.

When core completes, `/speckit-gaia-spec`'s preset relocates the artifact to `.gaia/local/specs/SPEC-NNN/SPEC.md`. Cache the working draft path; you will read and re-render it across the rest of these steps. (Step 2 already appended `spec_started` telemetry for both fresh and resumed flows.)

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

**Auto-mode exception:** skip the user-facing prompt. Read the draft's intent + UATs into the agent's reasoning context and self-check: (a) intent paragraph is coherent and matches the description; (b) every UAT follows Given/When/Then shape; (c) UATs collectively cover the intent. If any check fails, revise the draft once and re-check. Then jump to the "On confirmation" actions below (snapshot cache, draft cache, telemetry, telemetry includes `"auto": true`). Per Auto-mode rule 4, never block for human input.

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

1. **Cache the gate-1 snapshot** to `.gaia/local/cache/gate1-<spec_id>.json`. The snapshot must include: the confirmed `intent`, the confirmed UAT list (with stable `UAT-NNN` IDs), and a timestamp. The `after_clarify` hook (self-review) reads this cache to detect scope drift between gate 1 and gate 2. **Skip this write if the snapshot already exists for this `spec_id` (resumed session); its purpose is immutable drift detection.**
2. **Write the working-draft cache** per the operational primitive (`.gaia/local/cache/draft-<spec_id>.md`).
3. **Append telemetry**: `gate1_confirmed` event with `intent_words` + `uat_count`.

Only after gate-1 confirmation may you proceed to step 5.

### 5. /speckit-clarify (Socratic loop)

Invoke `/speckit-clarify`. Spec-kit's clarify primitive runs sequential, coverage-based questioning over the draft and is **hard-capped at 5 total questions** (see "Spec-kit's 5-question cap" in operational primitives). The GAIA tailoring (coach tone, AskUserQuestion mediation, exhaustion checkpoints, research dispatch) is enforced by the agent driving this skill, read the templates at `.specify/extensions/gaia/templates/clarify-prompts.md` and `system-prompt.md` only on entering this step (lazy-load, see operational primitives).

**Auto-mode exception:** the 5-question cap still applies, but the agent answers each question itself rather than mediating to the user. Per Auto-mode rules 5–8: closed-set questions auto-pick the Recommended option; open-ended questions get the agent's best-judgment answer; per-topic exhaustion auto-advances; research subagents still dispatch but uncertain outcomes pick the most plausible candidate with a flagged note in `research_summary`. No `AskUserQuestion` calls fire in this step. Each agent-chosen answer is folded into `clarifications.answered[]` exactly as a human selection would be, and a `clarify_question` telemetry event is appended with `kind: "auto"`. Skip sub-steps 5a–5d's `AskUserQuestion` mechanics and 5b's Discuss-this branch entirely; sub-step 5e (research dispatch) runs unmodified except for the uncertain-outcome fallback.

For every question asked, append a `clarify_question` telemetry event with `topic` and `kind` (`closed`, `open`, or `discuss`), and increment `question_count` in the session-shape cache per the operational primitive (`spec-session-<spec_id>.json`). The same per-question budget covers steps 5a, 5b, 5c, 5d, and the per-topic revisit prompt, every distinct user-facing prompt counts as one question for the `time_to_resolved_spec` emit.

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

When the natural well of follow-ups on a topic runs dry, announce explicitly via `AskUserQuestion`:

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

Append a `research_dispatched` telemetry event. Spawn a `general-purpose` Agent with a focused research prompt. Handle the return based on outcome:

- **Found (useful findings).** Fold into `research_summary` of the draft. Cite sources. Append `research_returned` telemetry with `outcome: "found"`. Write draft cache. Continue the loop.
- **Inconclusive (agent searched but found nothing definitive).** Fold the inconclusive note into `research_summary` as a known gap. Append `research_returned` telemetry with `outcome: "inconclusive"`. Re-prompt the original closed-set question with the research context attached as a footnote so the user can decide informed.
- **Error (agent did not return findings or returned an error).** Append `research_returned` telemetry with `outcome: "error"`. Surface to the user via plain prompt: `"Research agent did not return findings on \"<question>\". Answer manually, defer with rationale, or skip this question?"`. Wait for direction. Do not silently continue.
- **Contradictory (agent returned multiple plausible answers).** Append `research_returned` telemetry with `outcome: "contradictory"`. Surface both candidates via `AskUserQuestion` with each candidate as an option (plus `Other` and `Save partial and resume later`). Let the user pick.

If the user has selected `Discuss this` on a question that turns out to need research, dispatch the research subagent and surface findings in the discussion before requesting settlement.

### 6. after_clarify hook (self-review)

Spec-kit fires this hook automatically after `/speckit-clarify` completes. The agent receives an `EXECUTE_COMMAND: speckit.gaia.self-review` directive, but rather than running the audit in the wrapper's own context (which would re-load the full draft + gate-1 snapshot into wrapper memory), **dispatch the audit as a `general-purpose` Agent** so the heavy reads stay in fresh context and only structured findings flow back. This is the largest token saver in the spec flow.

#### 6a. Dispatch the self-review agent

Spawn a `general-purpose` Agent with this prompt (interpolate `<DRAFT_PATH>` and `<spec_id>`):

> Run the self-review audit defined in `.specify/extensions/gaia/commands/self-review.md` over the draft at `<DRAFT_PATH>` against the gate-1 snapshot at `.gaia/local/cache/gate1-<spec_id>.json`.
>
> Return a structured JSON payload, no narrative, no draft excerpts beyond what each finding's `excerpt` field needs:
>
>     {
>       "findings": [
>         {
>           "severity": "low" | "medium" | "high",
>           "kind": "placeholder" | "ambiguity" | "inconsistency" | "drift" | "scope_change" | "missing_uat" | "other",
>           "location": "<section heading or UAT-NNN>",
>           "excerpt": "<short verbatim excerpt, keep under 200 chars>",
>           "issue": "<one sentence, what is wrong>",
>           "suggested_fix": "<one sentence, what to change to resolve>"
>         }
>       ],
>       "pending_clarifications": [
>         { "topic": "<topic>", "question": "<verbatim>" }
>       ]
>     }
>
> Severity guidance:
>
> - **low**, placeholder text ("TODO", vague adjectives), terminology inconsistency
> - **medium**, internal inconsistency, ambiguous UAT phrasing
> - **high**, drift from gate-1 snapshot, scope change, removed UAT, added UAT not present at gate 1

Append a `self_review_findings` telemetry event with the counts (`low`, `medium`, `high`) once the agent returns.

#### 6b. Apply findings (severity-gated)

- **low + medium findings:** apply ALL `suggested_fix`es to the draft in working memory, then persist via a single `Write` per the operational primitive, never one Write per finding.
- **high findings:** surface to the user before applying. Never silently revert intentional clarify-loop evolution. **Auto-mode exception per rule 9:** apply the `suggested_fix` and append a one-line note to `clarifications.deferred[]` recording the finding (kind, location, issue) so a reviewer can audit. If the finding is `kind: "drift"` or `"scope_change"` and the change came from a clarify answer the agent itself just made in step 5, prefer keeping the clarify answer over reverting, append the note but skip the fix. Use a plain prompt per finding:

  > Self-review flagged a scope-level concern in `<location>`:
  >
  > **Issue:** <issue>
  >
  > **Excerpt:** "<excerpt>"
  >
  > **Suggested fix:** <suggested_fix>
  >
  > Apply the fix, keep the current draft, or revise differently?

  Wait for user direction. Apply or skip per the answer; if `revise differently`, fold the user's revision and re-cache.

#### 6c. Pending clarifications block-or-defer

For each item in `pending_clarifications[]`, surface via `AskUserQuestion`:

- options:
  - `{ label: "Answer now", description: "Resolve <topic> inline." }`
  - `{ label: "Defer with rationale", description: "Mark unresolved; capture rationale in clarifications.deferred[]." }`
  - `{ label: "Discuss this", description: "Drop to plain Q&A, then settle." }`

**Auto-mode exception per rule 10:** skip the `AskUserQuestion` and auto-defer every pending item with rationale `"Auto-mode session, defer for human review."` Save proceeds unblocked.

Save remains blocked while any pending item is unresolved. Once folded into `clarifications.deferred[]`, do not re-quote the raw Q&A in downstream prompts (see operational primitives).

After all findings are applied and pending items are resolved, write the draft cache and proceed to gate 2.

### 7. Gate 2, artifact confirmation

Render the full draft artifact in markdown form (frontmatter plus body) and present it to the user. This is gate 2. Track `gate2_revisions = 0` in working memory.

**Auto-mode exception per rule 4:** skip the user prompt. Render the draft into the agent's reasoning context, run a self-check (frontmatter populated, every UAT has Given/When/Then, intent matches gate-1 snapshot modulo intentional clarify evolution, deferred clarifications block well-formed). Apply at most one revision pass if the self-check finds an issue, then jump to the "On confirmation" actions below. Telemetry records `gate2_confirmed` with `revisions: <gate2_revisions>, auto: true`.

Use a plain prompt, not `AskUserQuestion`. Suggested phrasing:

> Here is the rendered SPEC. Review it and confirm before save, or tell me what to revise.
>
> ```markdown
> <full rendered artifact>
> ```

If the user revises:

1. Fold revisions into the draft.
2. Increment `gate2_revisions`.
3. Write the draft cache (operational primitive).
4. Re-present until they confirm. Do not re-quote raw clarify Q&A in revision prompts, reference the draft's `clarifications.answered[]` and `clarifications.deferred[]` arrays as canonical.

On confirmation:

1. Write the final draft cache.
2. Append `gate2_confirmed` telemetry with `revisions: <gate2_revisions>`.

Only after gate-2 confirmation may you proceed to step 8.

### 8. Save to .gaia/local/specs/SPEC-NNN/SPEC.md

Create the SPEC folder, then write the confirmed draft to its canonical inner file (using the `spec_id` allocated in step 3):

```bash
mkdir -p .gaia/local/specs/${SPEC_ID}
```

Write to `.gaia/local/specs/SPEC-NNN/SPEC.md`. This is the canonical save location, never anywhere else, never duplicate copies. The folder is the archival unit; sibling artifacts live beside `SPEC.md` in the same folder. A sibling's filename is the uppercased remainder of its flat form (`SPEC-NNN-<rest>.md` → `SPEC-NNN/<REST>.md`); any `SPEC-NNN-*` file is a sibling. `lib/spec-folderize.sh` applies this mapping for any legacy flat files.

Update the frontmatter `updated` field to today's date.

After the canonical write succeeds:

1. **Delete the working-draft cache:** `rm -f .gaia/local/cache/draft-<spec_id>.md`. The canonical artifact is the source of truth from this point forward; a stale cache would mislead step 2 of a future session.
2. **Update the ledger row:** flip the row in `.gaia/specs.json` from `status: draft` to `status: in-progress` and stamp the intent (first prose line of the SPEC's `intent` field) for at-a-glance scanning. Failure is non-blocking, log to stderr and continue. The ledger is a fast index over git; the SPEC artifact and git history remain authoritative.

```bash
SPEC_PATH=".gaia/local/specs/${SPEC_ID}/SPEC.md"
INTENT=$(awk '
  /^intent:[[:space:]]*\|/ { in_block=1; next }
  /^intent:[[:space:]]*[^|[:space:]]/ {
    sub(/^intent:[[:space:]]*/, ""); print; exit
  }
  in_block && /^[a-zA-Z_]+:/ { exit }
  in_block && /^[[:space:]]+[^[:space:]]/ {
    sub(/^[[:space:]]+/, ""); print; exit
  }
' "$SPEC_PATH" 2>/dev/null || echo "")
PATCH=$(jq -nc --arg intent "$INTENT" \
  '{status: "in-progress"} + (if $intent == "" then {} else {intent: $intent} end)')
bash .specify/extensions/gaia/lib/ledger-update.sh "$PWD" "$SPEC_ID" "$PATCH" \
  || echo "ledger-update skipped (row missing or jq failure), non-blocking" >&2
```

3. **Append telemetry:** `spec_saved` event.
4. **Emit `time_to_resolved_spec`:** read the session-shape cache, derive `area_tags` from the SPEC's UAT clusters, fire one mentorship event, then delete the cache. Failure to emit must NEVER block the save:

```bash
SPEC_PATH=".gaia/local/specs/${SPEC_ID}/SPEC.md"
CACHE=".gaia/local/cache/spec-session-${SPEC_ID}.json"
if [[ -f "$CACHE" ]]; then
  START_AT="$(jq -r '.start_at' "$CACHE" 2>/dev/null || echo "")"
  Q_COUNT="$(jq -r '.question_count' "$CACHE" 2>/dev/null || echo 0)"
else
  START_AT=""
  Q_COUNT=0
fi
if [[ -n "$START_AT" ]]; then
  NOW_S=$(date -u +%s)
  START_S=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "${START_AT%.*}" +%s 2>/dev/null \
            || date -u -d "$START_AT" +%s 2>/dev/null || echo "$NOW_S")
  DURATION=$((NOW_S - START_S))
else
  DURATION=0
fi
# Derive area_tags from the SPEC YAML's per-UAT area_tags or required_skills,
# deduped + comma-separated. Fall back to "spec" if nothing parses cleanly.
AREA_TAGS=$(awk '
  /^uats:/ {in_uats=1; next}
  in_uats && /^[a-zA-Z_]+:/ {in_uats=0}
  in_uats && /area_tags:|required_skills:/ {
    sub(/.*:[[:space:]]*/, "")
    gsub(/[][\047"]/, "")
    gsub(/,/, " ")
    print
  }
' "$SPEC_PATH" 2>/dev/null \
  | tr ' ' '\n' | grep -v '^$' | sort -u | paste -sd, -)
if [[ -z "$AREA_TAGS" ]]; then
  AREA_TAGS="spec"
fi
.gaia/cli/gaia telemetry emit time_to_resolved_spec \
  --spec-id "$SPEC_ID" \
  --question-count "$Q_COUNT" \
  --duration-seconds "$DURATION" \
  --area-tags "$AREA_TAGS" \
  --abandoned false \
  --agent-type human || true
rm -f "$CACHE"
```

The emit is the strongest signal for the intent-clarity-gap pattern; the `|| true` guard ensures emit failures never block the save. The cache file is deleted unconditionally after the emit attempt so a re-saved SPEC starts a fresh session window.

### 9. after_specify hook (immutability lint)

Spec-kit fires this hook automatically after the spec is written. The agent receives an `EXECUTE_COMMAND: speckit.gaia.lint` directive and invokes `/speckit-gaia-lint`, which runs `bash .specify/extensions/gaia/lib/lint.sh <spec-path>` and surfaces findings.

Track `lint_cycle = <count>` in working memory (initialize to 1 on the first attempt). Append a `lint_attempt` telemetry event per cycle with `outcome` and `cycle`.

On lint pass: continue to step 10.

On lint fail (cycles 1–2): surface the failures verbatim. The user can fix and re-run the lint, or defer with rationale (which loops back to step 6's pending handling). For mutations of an already-saved SPEC, the helper enforces the explicit reopen ceremony, `## Reopen rationale` and `## UAT diff` sections required. Increment `lint_cycle` and continue.

**On lint fail at cycle 3 (3 failed cycles in a row):** **Auto-mode exception per rule 11:** skip the prompt and auto-pick "Defer remaining findings", capture each remaining finding as a deferred clarification with rationale `"Auto-mode session, lint thrash, defer for human review."` and continue to step 10. Step-back-to-gate-2 in auto mode would loop indefinitely.

Otherwise, surface via `AskUserQuestion`:

- question: `"Lint has failed 3 times. Step back to gate 2 to restructure the artifact, defer all remaining lint findings with rationale, or push another fix attempt?"`
- header: `"Lint thrash"`
- options:
  - `{ label: "Step back to gate 2 (Recommended)", description: "Repeated lint failures usually indicate the artifact is not shaped right. Re-render and revise." }`
  - `{ label: "Defer remaining findings", description: "Capture each finding as a deferred clarification with rationale; loop to step 6c." }`
  - `{ label: "Push another fix attempt", description: "Try once more, but this is the third escape." }`

Reset `lint_cycle = 0` on user choice. Step-back-to-gate-2 returns to step 7 with the existing draft; the user can revise and re-save (steps 7→8→9 again).

### 10. Optional GH Issue mirror

If `gh_mirror_optin` (captured at step 1) is `false`, **skip this step entirely**. No mirror invocation, no telemetry write, the user opted out at the top of the session.

If `gh_mirror_optin` is `true`, run:

```bash
bash .specify/extensions/gaia/lib/gh-mirror.sh "$PWD" "<spec-id>" ".gaia/local/specs/<spec-id>/SPEC.md"
```

The script handles the conditional logic without intervention:

- If `gh auth status` succeeds AND `gh api repos/{owner}/{repo}` reports Issues enabled AND the viewer has write or admin permission, it creates a GitHub Issue titled `"<spec-id>: <intent first line>"` with the SPEC body, then stamps the issue URL into the SPEC frontmatter as `gh_issue_url`.
- Otherwise, it appends a skip record to `.gaia/local/telemetry/gh-mirror.jsonl`, exits 0, and does not modify the SPEC. Absence does not block save and never propagates as an error.

If the project uses non-GitHub remote tracking (GitLab, Bitbucket, none), the mirror step is a no-op. Do not prompt to mirror to alternative trackers, that is `ask_first` territory and out of scope for this skill.

### 11. Inline chain-trigger to /gaia-plan

There is no `on_save` hook in spec-kit. The chain-trigger lives here, inline, after save and after the optional GH mirror. Surface via `AskUserQuestion`:

- question: `"SPEC-NNN saved. Trigger /gaia-plan now?"`
- header: `"Chain"`
- options:
  - `{ label: "Yes, trigger /gaia-plan (Recommended)", description: "Run the autonomous downstream pipeline starting with /gaia-plan." }`
  - `{ label: "No, defer", description: "Stop here; the human can invoke /gaia-plan later." }`

**Auto-mode exception per rule 12:** skip the `AskUserQuestion` and proceed directly to 11a (first plan dispatch). After the first plan returns, skip 11b's multi-plan loop and jump to 11c. Auto mode produces exactly one plan covering the full SPEC; multi-slice planning is a human-judgment call.

On `No`, stop and report to the user that the SPEC is saved and `/gaia-plan` can be invoked when ready. On `Yes`, enter the plan-dispatch loop. All plans dispatched through the loop share the slug prefix `spec-NNN-*`, so `ls .gaia/local/plans/ | grep ^spec-NNN-` discovers them as a group.

**Each `/gaia-plan` invocation runs in its own `general-purpose` Agent**, not in-session. The wrapper's context stays bounded regardless of plan count, each Agent reads the SPEC, runs the plan skill end-to-end, and returns only the resolved `PLAN_DIR` and the kickoff prompt. The wrapper never sees the planner's investigation, the per-task docs, or any intermediate output.

#### 11a. First plan dispatch

Construct the dispatch input string in this exact form (literal interpolation, no quotes around the result):

    SPEC-NNN: <intent first line>, see <absolute path to .gaia/local/specs/SPEC-NNN/SPEC.md>

where:

- `SPEC-NNN` is the allocated SPEC id
- `<intent first line>` is the first sentence of the SPEC's `intent` paragraph (truncated at the first period or newline)
- `<absolute path…>` is the absolute path to the saved SPEC artifact

Spawn a `general-purpose` Agent with this prompt (interpolate the dispatch input):

> Read `.claude/skills/gaia/references/plan.md` and follow its steps using this feature description as `$ARGUMENTS`:
>
>     <dispatch input>
>
> Run the entire plan skill end-to-end, including spawning the planner sub-Agent at its step 4. When complete, return ONLY this two-field payload, no narrative, no file lists, no recap of the plan contents:
>
>     PLAN_DIR: <absolute path>
>     KICKOFF_PROMPT: <verbatim copy of the kickoff prompt the plan skill printed to its user>

When the Agent returns, parse the two fields. Append the `PLAN_DIR` to a running `PLAN_DIRS[]`. Print the kickoff prompt to the user as a fenced code block. Append `plan_dispatched` telemetry with `plan_idx: 1` and the `PLAN_DIR`.

#### 11b. Subsequent plans (multi-plan loop)

**Auto-mode exception:** skip this sub-step entirely. After 11a returns, jump straight to 11c.

After each `/gaia-plan` Agent completes, surface via `AskUserQuestion`:

- question: `"Plan another slice of SPEC-NNN, or done?"`
- header: `"Plans"`
- options:
  - `{ label: "Done (Recommended)", description: "All plan slices for this SPEC have been authored." }`
  - `{ label: "Plan another slice", description: "Author another plan covering a different part of the SPEC." }`

On `Plan another slice`, ask via plain prompt (open-ended, not `AskUserQuestion`): `"What slice of SPEC-NNN should this plan cover?"`. Use the answer to construct a fresh dispatch input:

    SPEC-NNN: <user's slice description>, see <absolute path to SPEC>

Spawn a fresh Agent with the same template as 11a. Parse its return, append the resolved `PLAN_DIR` to `PLAN_DIRS[]`, print the kickoff prompt as a fenced block, append `plan_dispatched` telemetry with `plan_idx: <next>`. Loop until the user picks `Done`.

**Output note.** The plan skill prints each kickoff prompt only into its own Agent's context, which the user never sees. The wrapper-printed fenced blocks are the authoritative source the user copies from.

#### 11c. Final confirmation

Print a single summary block after the loop exits:

> SPEC-NNN saved to `.gaia/local/specs/SPEC-NNN/SPEC.md`.
> Plans authored: <count>
>
> - <PLAN_DIRS[0]>
> - <PLAN_DIRS[1]>
>   …
>
> Discover later with: `ls .gaia/local/plans/ | grep ^spec-nnn-`

If the saved SPEC carries a `gh_issue_url` frontmatter field (i.e. step 10 mirrored successfully), append one line to the summary:

> Implementing PR body should include `Closes #<N>` (extracted from `gh_issue_url`) so merge auto-closes the upstream issue.

### 12. PR-body closure wiring (only when mirrored)

This step is documentation, not action, but it is load-bearing for issue lifecycle.

When the SPEC has a `gh_issue_url` set (step 10 mirrored), every PR opened in service of this SPEC's implementation must reference the issue with GitHub's [auto-close keywords](https://docs.github.com/en/issues/tracking-your-work-with-issues/linking-a-pull-request-to-an-issue) in the PR body. Use `Closes #<N>` where `<N>` is the integer at the tail of `gh_issue_url`.

Concrete shape for the PR body:

```markdown
## Summary

<brief description of changes>

## Test plan

<bulleted checklist>

Closes #<N>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

Multi-PR SPECs (where `/gaia-plan` produced multiple plan slices) should reference the same issue from each PR, GitHub closes the issue on the merge of the first PR that contains the keyword. The remaining PRs' references are inert but harmless and signal the lineage.

If the SPEC has no `gh_issue_url` (step 10 was skipped), this step is a no-op.
