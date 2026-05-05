# /gaia spec

Socratic discovery wrapper around spec-kit. Produces an immutable SPEC artifact at `.gaia/local/specs/SPEC-NNN.md` and prompts to chain into `/gaia plan`. Do not implement anything — this skill produces an artifact and stops.

## Hard constraints

1. **No machine-local memory for project decisions.** Never call any tool that writes to `~/.claude/projects/.../memory/`. Project-relevant decisions belong ONLY in the SPEC artifact, the wiki, or `.claude/rules/`. Personal preferences (tone, formatting) remain allowed in machine-local memory. This is the no-machine-local-memory rule and it is non-negotiable.
2. **Write-surface allowlist.** Every file write during a `/gaia spec` session lands in exactly one of:
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

| Event           | Slash command                          | Source body                                     |
|-----------------|----------------------------------------|-------------------------------------------------|
| `before_specify` | `/speckit-gaia-constitution-check`     | `.specify/extensions/gaia/commands/constitution-check.md` |
| `after_clarify`  | `/speckit-gaia-self-review`            | `.specify/extensions/gaia/commands/self-review.md`        |
| `after_specify`  | `/speckit-gaia-lint`                   | `.specify/extensions/gaia/commands/lint.md`               |

Each hook fires automatically — the agent reads the directive and invokes the slash command without prompting. "Block" semantics live inside the hook command: a block is a refusal message that the wrapper agent reads and chooses not to proceed past. There is no machine-enforced halt.

There is no `on_save` event. The chain-trigger to `/gaia plan` lives inline at the end of this orchestration (Step 11), not in a hook.

## Steps

### 1. Get description

If `$ARGUMENTS` (the args after `spec`) is non-empty, use it as the feature description.

Otherwise, ask: **"What do you want to spec?"** and wait for the response before continuing. This is open-ended — use a plain prompt, not `AskUserQuestion`.

### 2. Resume-vs-start-new prompt (pre-flight)

Run `bash .specify/extensions/gaia/lib/spec-allocator.sh in_progress "$PWD"`. If the output is a `SPEC-NNN` id (not `none`), an in-progress SPEC already exists. Surface via `AskUserQuestion`:

- question: `"Resume SPEC-NNN, or start new (leaves SPEC-NNN open)?"`
- header: `"Existing SPEC"`
- options:
  - `{ label: "Resume SPEC-NNN (Recommended)", description: "Continue the existing in-progress SPEC." }`
  - `{ label: "Start new", description: "Begin a fresh SPEC; SPEC-NNN remains open." }`

Honor the user's choice. Never silently overwrite, never silently start new. If the user picks "Start new", continue with a fresh allocation; if "Resume", load the existing SPEC into the working draft and skip Step 3 (you are amending, not creating).

### 3. /speckit-specify (initial draft)

Invoke `/speckit-specify` with the description from step 1. The GAIA preset (registered via `specify preset add`) wraps core with `{CORE_TEMPLATE}` and replaces `spec-template`, so the artifact is GAIA-shaped (frontmatter, immutable flag, `SPEC-NNN` id) and lands at `.gaia/local/specs/SPEC-NNN.md`. The preset's body invokes `lib/spec-allocator.sh next "$PWD"` to allocate the SPEC id.

Spec-kit fires the `before_specify` hook (constitution + version-pin check) automatically before this step runs. If the hook blocks, surface its message and halt.

When core completes, `/speckit-gaia-spec`'s preset relocates the artifact to `.gaia/local/specs/SPEC-NNN.md`. Cache the working draft path; you will read and re-render it across the rest of these steps.

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

On confirmation, **cache the gate-1 snapshot** to `.gaia/local/cache/gate1-<spec_id>.json`. The snapshot must include: the confirmed `intent`, the confirmed UAT list (with stable `UAT-NNN` IDs), and a timestamp. The `after_clarify` hook (self-review) reads this cache to detect scope drift between gate 1 and gate 2 (UAT-016).

Only after gate-1 confirmation may you proceed to step 5.

### 5. /speckit-clarify (Socratic loop)

Invoke `/speckit-clarify`. Spec-kit's clarify primitive runs sequential, coverage-based questioning over the draft. The GAIA tailoring (coach tone, AskUserQuestion mediation, exhaustion checkpoints, research dispatch) is enforced by the agent driving this skill — see the templates at `.specify/extensions/gaia/templates/clarify-prompts.md` and `system-prompt.md` for the canonical phrasing.

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

### 6. after_clarify hook (self-review)

Spec-kit fires this hook automatically after `/speckit-clarify` completes. The agent receives an `EXECUTE_COMMAND: speckit.gaia.self-review` directive and invokes `/speckit-gaia-self-review`, which:

- Audits the draft for placeholders, scope drift relative to the gate-1 snapshot, internal inconsistency, and ambiguous UAT phrasing. Surfaces findings; the wrapper folds fixes back in before gate 2.
- For each item in `clarifications.pending[]`, surfaces a block-or-defer prompt via `AskUserQuestion` (UAT-017) with the three options: Answer now / Defer with rationale / Discuss this. Save remains blocked while any pending item is unresolved.

Read the self-review report. Apply fixes to the draft for any drift, ambiguity, or inconsistency findings before proceeding to gate 2.

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

### 8. Save to .gaia/local/specs/SPEC-NNN.md

Write the confirmed draft to `.gaia/local/specs/SPEC-NNN.md` (using the `spec_id` allocated in step 3). This is the canonical save location — never anywhere else, never duplicate copies.

Update the frontmatter `updated` field to today's date.

### 9. after_specify hook (immutability lint)

Spec-kit fires this hook automatically after the spec is written. The agent receives an `EXECUTE_COMMAND: speckit.gaia.lint` directive and invokes `/speckit-gaia-lint`, which runs `bash .specify/extensions/gaia/lib/lint.sh <spec-path>` and surfaces findings.

On lint pass: continue to step 10.

On lint fail: surface the failures verbatim. The user can fix and re-run the lint, or defer with rationale (which loops back to step 6's pending handling). For mutations of an already-saved SPEC, the helper enforces the explicit reopen ceremony — `## Reopen rationale` and `## UAT diff` sections required (UAT-011).

### 10. Optional GH Issue mirror

After save, run:

```bash
bash .specify/extensions/gaia/lib/gh-mirror.sh "$PWD" "<spec-id>" ".gaia/local/specs/<spec-id>.md"
```

The script handles the conditional logic without intervention:

- If `gh auth status` succeeds AND `gh api repos/{owner}/{repo}` reports Issues enabled AND the viewer has write or admin permission, it creates a GitHub Issue titled `"<spec-id>: <intent first line>"` with the SPEC body, then stamps the issue URL into the SPEC frontmatter as `gh_issue_url`.
- Otherwise, it appends a skip record to `.gaia/local/telemetry/gh-mirror.jsonl`, exits 0, and does not modify the SPEC. Absence does not block save and never propagates as an error.

If the project uses non-GitHub remote tracking (GitLab, Bitbucket, none), the mirror step is a no-op. Do not prompt to mirror to alternative trackers — that is `ask_first` territory and out of SPEC-001 scope.

### 11. Inline chain-trigger to /gaia plan

There is no `on_save` hook in spec-kit. The chain-trigger lives here, inline, after save and after the optional GH mirror. Surface via `AskUserQuestion`:

- question: `"SPEC-NNN saved. Trigger /gaia plan now?"`
- header: `"Chain"`
- options:
  - `{ label: "Yes, trigger /gaia plan (Recommended)", description: "Run the autonomous downstream pipeline starting with /gaia plan." }`
  - `{ label: "No, defer", description: "Stop here; the human can invoke /gaia plan later." }`

The chain only fires on explicit confirmation. On `Yes`, dispatch `/gaia plan` with the SPEC path as input. On `No`, stop and report to the user that the SPEC is saved and `/gaia plan` can be invoked when ready.

Print a final confirmation line:

> SPEC-NNN saved to `.gaia/local/specs/SPEC-NNN.md`.
