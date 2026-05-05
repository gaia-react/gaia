# /gaia spec

Socratic discovery wrapper around spec-kit. Produces an immutable SPEC artifact at `.gaia/local/specs/SPEC-NNN.md` and prompts to chain into `/gaia plan`. Do not implement anything — this skill produces an artifact and stops.

## Hard constraints

1. **No machine-local memory for project decisions.** Never call any tool that writes to `~/.claude/projects/.../memory/`. Project-relevant decisions belong ONLY in the SPEC artifact, the wiki, or `.claude/rules/`. Personal preferences (tone, formatting) remain allowed in machine-local memory. This is the no-machine-local-memory rule and it is non-negotiable.
2. **Write-surface allowlist.** Every file write during a `/gaia spec` session lands in exactly one of:
   - `.gaia/local/specs/**`
   - `.specify/**`
   - `.gaia/local/cache/**`
   - `.gaia/local/telemetry/**`
   Never edit source files (`app/**`, `src/**`, repo root configs, etc.). The `after_specify` hook audits this; you enforce it at the agent-instruction level.
3. **One question at a time.** No multi-question forms. Closed-set questions go through `AskUserQuestion` with options ordered: recommended FIRST, then alternatives, then `Other` (free text), then `Discuss this` (escape to plain Q&A). Open-ended questions use a plain prompt with no enumerated options.
4. **Two-gate ceremony.** Confirm intent + UATs in plain English BEFORE authoring the artifact. Confirm the rendered artifact BEFORE saving to disk. No silent advances between gates.
5. **Coach tone, not interrogator.** Mirror back, name trade-offs, propose candidates when the human is stuck. Never punt research to the human.

## Steps

### 1. Get description

If `$ARGUMENTS` (the args after `spec`) is non-empty, use it as the feature description.

Otherwise, ask: **"What do you want to spec?"** and wait for the response before continuing. This is open-ended — use a plain prompt, not `AskUserQuestion`.

### 2. Pre-flight (before_specify hook)

Invoke the `before_specify` hook (registered by `.specify/extensions/gaia/extension.yml`). The hook performs two checks:

- **Constitution placeholder check.** If `.specify/memory/constitution.md` contains placeholder text from spec-kit's default template, the hook returns `{"action": "block", "reason": "..."}` or `{"action": "prompt", ...}` asking the user to run `/speckit.constitution` first. Do not proceed silently against an unpopulated constitution. Surface the hook's prompt or block message verbatim.
- **Resume-vs-start-new prompt.** If an in-progress SPEC already exists at `.gaia/local/specs/SPEC-NNN.md` (frontmatter `status: in-progress`), the hook returns a prompt. Surface it via `AskUserQuestion`:
  - question: `"Resume SPEC-NNN, or start new (leaves SPEC-NNN open)?"`
  - header: `"Existing SPEC"`
  - options:
    - `{ label: "Resume SPEC-NNN (Recommended)", description: "Continue the existing in-progress SPEC." }`
    - `{ label: "Start new", description: "Begin a fresh SPEC; SPEC-NNN remains open." }`
  - Honor the user's choice. Never silently overwrite, never silently start new.

If the hook returns `{"action": "proceed"}`, continue to step 3.

### 3. /speckit.specify (initial draft)

Invoke `/speckit.specify` with the description from step 1. spec-kit applies the GAIA preset overrides at template resolution time — coach-tone system prompt, AskUserQuestion-formatted Q&A copy, GAIA frontmatter fields (`spec_id`, `immutable`, `wiki_promote_default`, `chain_trigger`), and topic-exhaustion checkpoint phrasing. The output is an in-memory draft (not yet saved to disk) — written to `.specify/cache/draft.md` for downstream hooks to read.

Allocate the next SPEC ID via `.specify/extensions/gaia/lib/spec-allocator.sh` and stamp it into the draft frontmatter as `spec_id: SPEC-NNN` (zero-padded, monotonic).

### 4. Gate 1 — shape confirmation

Before any Socratic clarify loop runs, present the draft's `intent` paragraph and the proposed UATs in plain English to the user. This is gate 1.

Use a plain prompt — not `AskUserQuestion`. The user reads, confirms, or revises. Suggested phrasing:

> Here's the shape I have so far:
>
> **Intent:** <intent paragraph>
>
> **UATs:**
> - UAT-001 — Given … when … then …
> - UAT-002 — Given … when … then …
>
> Does this match what you want, or should I revise before we go deeper?

If the user revises, fold revisions into the draft and re-present until they confirm.

On confirmation, **cache the gate-1 snapshot** to `.gaia/local/cache/gate1-<spec_id>.json`. The snapshot must include: the confirmed `intent`, the confirmed UAT list (with stable `UAT-NNN` IDs), and a timestamp. The `after_clarify` hook reads this cache to detect scope drift between gate 1 and gate 2 (UAT-016).

Only after gate-1 confirmation may you proceed to step 5.

### 5. /speckit.clarify (Socratic loop)

Invoke `/speckit.clarify`. spec-kit's clarify primitive runs sequential, coverage-based questioning over the draft. The GAIA preset tailors the loop with the rules below — follow them strictly.

#### 5a. AskUserQuestion mediation (closed-set questions)

For every question with discrete possible answers, surface it via `AskUserQuestion` with options ordered exactly:

1. **Recommended option FIRST** — labeled `"<option text> (Recommended)"`. Use the PO's best judgment; the recommendation is annotated with code-context where helpful (e.g. `"Cards (reuses existing Card component)"`).
2. **Alternatives** — remaining viable options, in descending order of plausibility.
3. **`Other`** — free-text escape for an answer not in the list.
4. **`Discuss this`** — escape to plain Q&A (see 5b).

Ask exactly one question per turn. No multi-question forms. No silent stacking.

#### 5b. Discuss-this escape (UAT-004)

When the user picks `Discuss this`, drop the structured loop and engage in plain Q&A on that single topic. Mirror, name trade-offs, propose candidates. When the user signals settlement (an explicit "ok, that one" or equivalent), do two things:

1. Record the discussion outcome in `clarifications.answered[]` of the in-progress draft as `{ q: "<original question>", a: "<settled outcome from discussion>" }`.
2. Resume the structured loop on the next topic.

Do not loop back to the same closed-set options after a Discuss-this settlement. The discussion replaces the structured choice for that topic.

#### 5c. Open-ended questions

For genuinely open-ended questions (no clean discrete option set), use a plain prompt — not `AskUserQuestion`. Coach tone, never interrogator. Ask one at a time.

#### 5d. Per-topic exhaustion checkpoint (UAT-005)

When the natural well of follow-ups on a topic runs dry, announce explicitly via `AskUserQuestion`:

- question: `"Out of questions on <topic>. Move to <next topic>, or push deeper?"`
- header: `"Topic"`
- options:
  - `{ label: "Move to <next topic> (Recommended)", description: "Advance to the next discovery area." }`
  - `{ label: "Push deeper on <topic>", description: "Mine the current topic further." }`
  - `{ label: "Other", description: "Free-text alternative." }`

Silent topic advance is forbidden.

#### 5e. Research subagent dispatch (UAT-014)

For any question that requires prior-art lookup, repo-convention investigation, or competitive analysis, dispatch a research subagent — never punt the research to the user.

**Announce the dispatch BEFORE dispatching**, verbatim:

> Dispatching research agent for `<question>`

Then spawn a `general-purpose` Agent with a focused research prompt. When findings return, fold them into `research_summary` of the draft. Cite sources where the agent provided them.

If the user has selected `Discuss this` on a question that turns out to need research, dispatch the research subagent and surface findings in the discussion before requesting settlement.

### 6. after_clarify hook

Invoke the `after_clarify` hook. It performs:

- **Self-review pass (UAT-016).** Reads the draft and the gate-1 cache at `.gaia/local/cache/gate1-<spec_id>.json`. Checks for placeholder text, scope drift relative to gate-1 confirmation (intent diverged, UAT IDs renumbered, success_criteria added/removed without clarification), internal inconsistency between fields, and ambiguous UAT phrasing. The hook returns issues via `{"action": "prompt", ...}` and you fix them in the draft before gate 2.
- **clarifications.pending block-or-defer (UAT-017).** For each item in `clarifications.pending[]`, surface via `AskUserQuestion`:
  - question: `"Pending clarification: <item>. Answer now, or defer with rationale?"`
  - header: `"Pending"`
  - options:
    - `{ label: "Answer now", description: "Resolve the clarification before save." }`
    - `{ label: "Defer with rationale", description: "Record a rationale and proceed; item remains pending." }`
    - `{ label: "Discuss this", description: "Drop to plain Q&A on this clarification." }`
  - On `Answer now`: collect the answer and move the item to `clarifications.answered[]`.
  - On `Defer with rationale`: collect the rationale via plain prompt and record it alongside the pending item.
  - Save is blocked while any pending item is unresolved (neither answered nor explicitly deferred).

### 7. Gate 2 — artifact confirmation

Render the full draft artifact in markdown form (frontmatter plus body) and present it to the user. This is gate 2.

Use a plain prompt — not `AskUserQuestion`. Suggested phrasing:

> Here is the rendered SPEC. Review it and confirm before save, or tell me what to revise.
>
> ```markdown
> <full rendered artifact>
> ```

If the user revises, fold revisions into the draft and re-present until they confirm.

Only after gate-2 confirmation may you proceed to step 8.

### 8. after_specify hook (immutability lint)

Invoke the `after_specify` hook. It lints frontmatter for:

- `immutable: true` present
- `status: in-progress` present
- All `UAT-NNN` IDs present, well-formed, and (if amending an existing SPEC) frozen relative to the prior version
- No placeholder text anywhere in the draft
- All required schema fields populated (`spec_id`, `intent`, `success_criteria`, `uats`, `scope_boundaries`, `clarifications`, `research_summary`, `created`, `updated`)
- Every write target during the session was inside the allowlist (path-allowlist audit)

On lint pass: the hook returns `{"action": "proceed"}` and you continue to step 9.

On lint fail: surface the failure reason verbatim. The user can fix and re-run, or defer with rationale (which loops back to step 6's pending handling).

For mutations of an already-saved SPEC: the hook enforces the explicit reopen ceremony — rationale recorded in the SPEC body, status flipped to `reopened`, UAT diff captured before the mutation is allowed (UAT-011). Do not bypass this.

### 9. Save to .gaia/local/specs/SPEC-NNN.md

Write the confirmed, lint-clean artifact to `.gaia/local/specs/SPEC-NNN.md` (using the `spec_id` allocated in step 3). This is the canonical save location — never anywhere else, never duplicate copies.

Update the frontmatter `updated` field to today's date.

### 10. Optional GH Issue mirror

Invoke `.specify/extensions/gaia/lib/gh-mirror.sh` (created by `task-integration`). The script handles the conditional logic:

- If `gh auth status` succeeds AND `gh api repos/{owner}/{repo}` reports Issues enabled AND the user has write permission, the script mirrors the SPEC body to a GitHub Issue.
- Otherwise, no mirror, no error, no degradation. Absence does not block save.

If the project uses non-GitHub remote tracking (GitLab, Bitbucket, none), the mirror step is a no-op. Do not prompt to mirror to alternative trackers — that is `ask_first` territory and out of SPEC-001 scope.

### 11. on_save hook (chain prompt to /gaia plan)

Invoke the `on_save` hook. It surfaces a chain-trigger prompt via `AskUserQuestion`:

- question: `"SPEC-NNN saved. Trigger /gaia plan now?"`
- header: `"Chain"`
- options:
  - `{ label: "Yes, trigger /gaia plan (Recommended)", description: "Run the autonomous downstream pipeline starting with /gaia plan." }`
  - `{ label: "No, defer", description: "Stop here; the human can invoke /gaia plan later." }`

The chain only fires on explicit confirmation. On `Yes`, dispatch `/gaia plan` with the SPEC path as input. On `No`, stop and report to the user that the SPEC is saved and `/gaia plan` can be invoked when ready.

Print a final confirmation line:

> SPEC-NNN saved to `.gaia/local/specs/SPEC-NNN.md`.
