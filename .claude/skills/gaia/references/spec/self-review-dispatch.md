# /gaia-spec: self-review dispatch

Step 6 of `/gaia-spec`: how the main thread dispatches the self-review agent and applies its findings. `spec/self-review.md` is that agent's own checklist; this file is its dispatcher. `spec.md` routes here at step 6, and step 10's lint routes back here to 6c. Control returns to `spec.md` step 7 at the end of 6c.

After the Socratic loop settles, run the GAIA self-review. Rather than running the audit in the wrapper's own context (which would re-load the full draft plus the gate-1 snapshot into wrapper memory), **dispatch it as a `general-purpose` Agent** so the heavy reads stay in fresh context and only structured findings flow back. This is the largest token saver in the spec flow.

The self-review is dispatched here, by this step.

Contents: 6a. Dispatch the self-review agent; 6b. Apply findings (severity-gated); 6c. Pending clarifications block-or-defer.

## 6a. Dispatch the self-review agent

First, create the audit cache's findings directory if absent, so `self-review.json` is never orphaned. The cache is created here, before the step-7 audit is even chosen:

```bash
mkdir -p .gaia/local/cache/audit-${SPEC_ID}/findings || true
```

Before dispatching, pre-clear the findings path:

```bash
rm -f .gaia/local/cache/audit-${SPEC_ID}/findings/self-review.json
```

Spawn a `general-purpose` Agent with this prompt (interpolate `<DRAFT_PATH>` and `<spec_id>`):

> Run the self-review audit defined in `.claude/skills/gaia/references/spec/self-review.md` over the draft at `<DRAFT_PATH>` against the gate-1 snapshot at `.gaia/local/cache/gate1-<spec_id>.json`.
>
> Lead with a tool call, not prose: your first action is a Read of the artifact under audit, and you emit your structured result before any prose. Read `<DRAFT_PATH>` first, before any other action.
>
> **Write** your full findings to `.gaia/local/cache/audit-<spec_id>/findings/self-review.json` (the fully-qualified path, never a bare `findings/self-review.json`, which from the repo-root cwd would resolve outside the cache and be orphaned, off the `.gaia/local/cache/**` allowlist). Each finding is one object under this schema, and every finding carries an `id` of the form `SR-NNN`, which you assign sequentially as you record each one:
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

Append one `coverage.jsonl` record (`phase: "self_review"`, `disposition: "first_pass"|"not_applicable"`) to `.gaia/local/cache/audit-<spec_id>/coverage.jsonl`.

**Fallback.** When subagent dispatch is unavailable, the main thread runs the self-review inline (parity with the step-7 audit fallback): it reads the draft, records the same findings, applies every `low` and `medium` `suggested_fix` itself in a single Write, and gates the highs at 6b.

## 6b. Apply findings (severity-gated)

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

  Wait for user direction. An **approved** high fix folds through the **delegated fold** (see "Audit cache + delegated fold" in `spec.md`), keyed by its `SR-NNN` id in the decision list; do not emit a main-thread draft `Write` for the fold. On `revise differently`, route the user's revision through the same delegated fold. On `keep`, fold nothing.

## 6c. Pending clarifications block-or-defer

For each item in `pending_clarifications[]`, surface via `AskUserQuestion`:

- options:
  - `{ label: "Answer now", description: "Resolve <topic> inline." }`
  - `{ label: "Defer with rationale", description: "Mark unresolved; capture rationale in clarifications.deferred[]." }`
  - `{ label: "Discuss this", description: "Drop to plain Q&A, then settle." }`

**Auto-mode exception per rule 9:** skip the `AskUserQuestion` and auto-defer every pending item with rationale `"Auto-mode session, defer for human review."` Save proceeds unblocked.

Save remains blocked while any pending item is unresolved. Once folded into `clarifications.deferred[]`, do not re-quote the raw Q&A in downstream prompts (see Operational primitives in `spec.md`).

After all findings are applied and pending items are resolved, write the draft cache and return to `spec.md` step 7 (the adversarial SPEC-audit).
