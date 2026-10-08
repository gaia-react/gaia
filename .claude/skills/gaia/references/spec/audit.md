# /gaia-spec: adversarial SPEC-audit

Step 7 of `/gaia-spec`: gauge the draft, fan out the lens auditors, refute, route each survivor, persist `AUDIT.md`, and close the audit window. `spec.md` routes here at step 7 together with `spec/lens-dispatch.md`, which owns the lens preamble, the findings file schema, the thin digest, and the pre-clear, classify, and re-dispatch rule; this file owns lens selection, refutation, and disposition. Control returns to `spec.md` step 8 (gate 2) at the end of this file.

Contents: Gauge; 7a. Dispatch the lens auditors; 7b. Refutation pass (7b-i. Refutation, 7b-ii. Completeness critic, 7b-iii. Completeness-critic refuter); 7c. Disposition routing + apply; 7d. Persist AUDIT.md; Close the audit window.

## Gauge

This phase complements, never replaces, step 6: the single-agent self-review is the always-on baseline; the audit is the heavyweight, ground-truth pass that runs on every spec. It dispatches the skill's own parallel `general-purpose` Agent fan-out (the same dispatch primitive step 6a uses), not the Workflow tool, so it is available in every context including headless and auto-mode runs.

**The audit always runs; the gauge sets its intensity.** After step 6 completes, gauge the draft (below) and run the audit at the gauged tier with no prompt. Auditing is always worth it, so there is no skip option and no user choice: interactive and auto mode both proceed straight into the fan-out. The one exception is the fan-out-unavailable Fallback below, a capability limit rather than a choice.

**Gauge the draft (this sets the tier and lens set).** Read the draft once and decide two independent things:

- **Rigor tier**, by stakes: weigh reversibility cost (an immutable artifact bound for autonomous downstream implementation is higher), blast radius (files and consumers the change touches), ground-truth claim density, and whether any risk surface is present. Low stakes with narrow scope and few claims → **Standard**; high stakes, or any security or migration surface → **Deep**.
- **Specialist lens set**, by content: scan `intent`, `scope_boundaries`, `success_criteria`, the required-reading list, and the touched paths against the specialist trigger column in 7a, and select every specialist whose trigger fires. The four core lenses always run; specialists are additive.

Record the gauged tier as `audit_intensity` (`standard` | `deep`) and the selected lens set; 7a records both in the cost-ledger breadcrumb. **Standard** verifies every checkable claim against ground truth with one refuter per material finding (7b-i); **Deep** adds perspective-diverse refuters (correctness, security, reproducibility) per material finding plus a completeness critic (7b-ii). Above the 7b-i refuter cap, either tier refutes with one batched refuter per lens and Deep skips the critic.

**Auto-mode.** Auto mode gauges and runs the audit exactly as interactive does; the prompt is gone from both. The two auto-specific differences (Auto-mode rule 12) are in the fold, not the run: auto mode reads **no finding body** during the audit and fold phase (the transcript carries only ids, severities, titles, verdicts, and dispositions), and it applies every disposition non-interactively at 7c. It never skips the audit.

**Fallback (never block).** If the parallel `general-purpose` Agent fan-out is unavailable (a restricted context that cannot spawn subagents), do NOT block save: note the skip (`adversarial audit unavailable, relying on step-6 self-review`), remove the audit cache with `rm -rf .gaia/local/cache/audit-<spec_id>/` (so the step-6 `self-review.json` is not orphaned), and proceed to gate 2. The step-6 self-review already ran and is the safety net. This path writes no `audit-window-<spec_id>.json` breadcrumb; its absence is the step-9 tally's signal that no adversarial audit ran.

## 7a. Dispatch the lens auditors (parallel fan-out)

Announce once, verbatim, naming each lens in full with its id code in parentheses (e.g. `factual grounding (FG)`), never the bare code:

> Dispatching adversarial SPEC-audit (<audit_intensity>): lenses <selected lens names, each with its id in parentheses>, then refutation (typically a dozen-plus agents, several minutes).

Capture the audit window start for the cost-ledger breadcrumb: `AUDIT_WINDOW_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"`. Then spawn **one `general-purpose` Agent per selected lens, all in parallel** (one message, one Agent tool call per lens): the four core lenses always, plus each specialist the gauge selected. Each agent audits the working-draft cache (`.gaia/local/cache/draft-<spec_id>.md`, the post-self-review working draft) and is dispatched per `spec/lens-dispatch.md` with the spec column of its caller slots (`<DRAFT_PATH>` = the working-draft cache, `<spec_id>`, `<repo_root>` = `$PWD`, `<LENS>` = the lens id prefix): the shared preamble, then a `LENS: <name> (id prefix <ID>)` line and the lens's focus text below. It **writes its findings to `.gaia/local/cache/audit-<spec_id>/findings/<LENS>.json`** under the findings file schema in `spec/lens-dispatch.md` (writing the file even when its findings array is empty), then returns only the contract's thin digest, no finding bodies.

The four core lenses (always dispatched; the set is chosen for low overlap, each reliably finds defects the others miss):

- **Factual grounding (id prefix `FG`).** Treat the SPEC as a set of factual claims and verify each load-bearing claim true or false against ground truth. For every claim about code, an installed dependency, an export subpath, a file path, or an existing convention, open the artifact and confirm it resolves, including whether any newly added dependency is justified and version-pinned. Any claim that is false or overstated is at least `high`, likely `blocker`.
- **UAT testability (id prefix `TST`).** Attack each UAT for falsifiability and GAMEABILITY. For each weak UAT, describe the concrete scenario where it passes while the feature is still broken or useless (e.g. a "points to X" UAT that passes on a bare path drop), and propose a tighter, doc-grep- or test-checkable `then`. Flag any UAT with no obvious verification method.
- **Coverage & consistency (id prefix `COV`).** Build the cross-matrix intent ↔ `success_criteria` ↔ UATs ↔ `scope_boundaries` and find the holes: orphan success criteria with no covering UAT; promises in the intent no UAT covers; UATs the SPEC needs but lacks; contradictions between `always`/`never`/`ask_first` and the UATs or intent; `scope_boundaries` entries that are not enforceable or observable; and whether the SPEC respects the project's established conventions (its `CLAUDE.md` rules, coding guidelines, naming).
- **Red-team & feasibility (id prefix `RT`).** Actively try to BREAK the SPEC. Construct the strongest scenario where ALL UATs pass yet the feature is not actually delivered or its core value claim is unmet. Attack acceptance-gate feasibility (is each gate concretely runnable and deterministic?), durability and over-claims, blast-radius completeness (any consumer or site the SPEC missed), and any circular justification or unstated assumption a planner would inherit as fact.

**Specialist lenses** (dispatch only the ones the gauge selected; build each agent's prompt from the shared preamble in `spec/lens-dispatch.md` plus a `LENS: <name> (id prefix <ID>)` line and the "hunts for" focus from its row):

| ID | Fires when the spec touches | Hunts for |
| --- | --- | --- |
| `SEC` | auth, tokens or secrets, CSRF, redirects, uploads, permissions, PII, raw user input, headers, cookies | injection, SSRF, open redirect, token or secret leakage, missing authorization, unsafe deserialization; whether the SPEC's security claim holds and its acceptance gate is adversarial |
| `MIG` | schema, format, or ledger changes; renamed, removed, or added fields; breaking API or serialization changes; config-vocabulary changes | existing-data handling, reversibility and rollback, dual-read or dual-write windows, version skew, what breaks for legacy or in-flight records |
| `A11Y` | UI components, routes, pages, anything that renders DOM | UATs that pass an axe rule yet fail real assistive tech; missing keyboard, focus-order, label, contrast, or landmark criteria; aria misuse |
| `DOC` | wiki or docs deliverables, "points to X" pointer UATs, README or section-title citations | duplication of an authoritative source, rot-resistance, dead cross-references, pointer UATs satisfiable by a bare path drop |
| `PERF` | data volume, loops over collections, network fan-out, caching, render or hydration paths | speculative-versus-real cost, N+1, unbounded growth, flaky warm/cold performance gates |

Before dispatching the fan-out, pre-clear each `findings/<LENS>.json` (`rm -f`) for every lens about to be dispatched. After each lens finishes, never at the moment its dispatch call returns, classify its file per `## Pre-clear, classify, re-dispatch` in `spec/lens-dispatch.md`: a no-op lens is re-cleared and re-dispatched once, and a second consecutive no-op runs that lens inline on the main thread. A specialist lens the gauge did not select for this dispatch is never issued and is recorded `not_applicable`. Append one `coverage.jsonl` record (`phase: "lens"`, `lens: "<LENS>"`, `disposition: "first_pass"|"not_applicable"`) per in-scope lens.

**The inline-lens exception.** A lens that ran inline on a second no-op produced its finding bodies on the main thread, auto mode included. It is the one place a finding body reaches main outside the two interactive carve-outs (6b, 7c); write that lens's file and carry on with only its ids, severities, and titles, exactly as for a dispatched lens.

## 7b. Refutation pass (severity discipline)

This heading covers three distinct dispatch sites, delimited below by their own `###` sub-headings: the refuter (7b-i), the Deep-only completeness critic (7b-ii), and the completeness critic's own refuter (7b-iii).

### 7b-i. Refutation

From the 7a thin digests, main selects every **material** finding id (severity ≠ `low`) across all selected lenses; low-severity findings skip refutation and carry forward unchanged. Each refuter defaults to "refuted" unless it can substantiate the defect from ground truth, so this pass is severity discipline as much as false-positive killing. The refuter count scales with `audit_intensity`, up to a cap:

- **Standard:** one refuter per material finding, all in parallel.
- **Deep:** three refuters per material finding, all in parallel, each given a distinct verification lens, prepend one of `correctness`, `security/safety`, or `reproduces-as-described` to the refuter prompt below. A finding is refuted only on a ≥2-of-3 majority; its corrected severity is the median of the non-refuting refuters.
- **Batched (either tier, above the cap):** when the shape above would dispatch more than **24** refuters (Standard: more than 24 material findings; Deep: more than 8), dispatch instead **one refuter per lens** that raised a material finding, all in parallel, each covering every material finding in that lens's findings file. On Deep, prepend all three verification lenses to that one refuter's prompt; its single verdict decides each finding, with no majority.

The cap exists because the per-finding shapes grow with finding volume: a broad Deep audit that raises 87 material findings would pay 261 refuters. High volume is also where per-finding refutation buys least, since a defect several lenses raised independently already carries the cross-check the extra refuters add. Batched, the dispatch count is bounded by the lens count however many findings the lenses raise.

Main dispatches each refuter keyed by `{ finding_id, findings_file, refuter_lens? }`, **no finding fields interpolated**, where `findings_file` is the lens's `.gaia/local/cache/audit-<spec_id>/findings/<LENS>.json` and `verdict_file` is the refuter's output path (`verdicts/<finding-id>.json` for Standard, `verdicts/<finding-id>-<slug-lens>.json` for Deep, slug per the frozen mapping). The refuter reads the finding body from the file itself. Before dispatch, pre-clear `<verdict_file>` (`rm -f`) so its presence is a fresh-write signal.

Refuter prompt (interpolate `<finding_id>`, `<findings_file>`, `<verdict_file>`, `<DRAFT_PATH>`, `<repo_root>`; no finding fields inline):

> Verify finding `<finding_id>`, recorded in `<findings_file>`, against the SPEC draft at `<DRAFT_PATH>` (repo root `<repo_root>`). Read the finding there; its severity, location, issue, evidence, and recommendation all live in that file.
>
> Lead with a tool call, not prose: your first action is a Read of the artifact under audit, and you emit your structured result before any prose. Read `<findings_file>` first.
>
> Open the cited SPEC section and any cited file yourself and try to REFUTE it: did the auditor misread the SPEC or the code, or overstate severity? For a finding you do NOT refute, also classify its DISPOSITION: is the SPEC's binding contract (its UATs + intent) already correct and only the implementation needs steering (`plan_directive`), or is a UAT or the intent itself wrong, gameable, or missing (`spec_defect`)? Default to `refuted` if you cannot substantiate the finding from ground truth.
>
> **Write** your verdict to `<verdict_file>` under the verdict schema below, then **return** only the thin verdict line `{ "id": "<finding_id>", "verdict": "confirmed"|"partial"|"refuted", "corrected_severity": "...", "disposition": "plan_directive"|"spec_defect" }`.

A batched refuter is keyed by `{ finding_ids, findings_file }` and uses the same prompt with three substitutions: it verifies every id in `<finding_ids>` rather than one, it writes one verdict file per id to `verdicts/<finding-id>.json` (the Standard naming, on either tier), and it returns a JSON array of thin verdict lines, one per id. Pre-clear every one of those verdict files before dispatch. Main counts the returned lines against the batch's ids, re-dispatches the batch once for any id missing a line, and carries an id still missing one forward unrefuted at its auditor severity.

Verdict schema: the **file** the refuter writes to `verdicts/<finding-id>.json` (Standard) or `verdicts/<finding-id>-<slug-lens>.json` (Deep). `disposition` is consulted only for surviving findings:

    {
      "verdict": "confirmed" | "partial" | "refuted",
      "corrected_severity": "blocker" | "high" | "medium" | "low" | "none",
      "disposition": "plan_directive" | "spec_defect",
      "reasoning": "<one or two sentences>",
      "evidence": "<file:line or SPEC quote actually checked>"
    }

Main computes the Deep ≥2/3 majority and the median severity **from the returned thin verdict lines only** and **never opens the per-refuter verdict files**, so verdict reasoning bodies never reach main. Surviving findings = the low-severity findings (carried forward) plus every material finding not refuted (Standard and batched: a single `refuted` verdict kills it; Deep: a ≥2-of-3 majority kills it), each stamped with its `corrected_severity` and `disposition`.

Append one `coverage.jsonl` record (`phase: "refuter"`, `disposition: "first_pass"|"not_applicable"`) per material finding refuted, or, batched, one per lens batch carrying `lens: "<LENS>"`, so the report's `## Coverage` shows which shape ran.

### 7b-ii. Completeness critic

**Deep only, and skipped when 7b-i ran batched.** The cap fires on finding volume, and that much volume across low-overlap lenses already supplies the gap-hunting the critic adds; when skipped, append its coverage record with `disposition: "not_applicable"` and do not run 7b-iii. Otherwise, after the refutation pass, dispatch one more `general-purpose` Agent over the draft plus the surviving findings, and ask what the lenses missed: an unverified load-bearing claim, an untested UAT, a `success_criteria` with no covering UAT, a consumer or blast-radius site the SPEC overlooked. Before dispatch, pre-clear `.gaia/local/cache/audit-<spec_id>/findings/completeness.json`.

Dispatch prompt (interpolate `<DRAFT_PATH>`, `<spec_id>`, `<surviving_findings>` = the 7b-i survivor ids/severities/titles, no bodies):

> You are the completeness critic for a GAIA SPEC draft at `<DRAFT_PATH>` (spec `<spec_id>`). The surviving findings so far are `<surviving_findings>`; do not re-raise them. Hunt for what the lenses missed: an unverified load-bearing claim, an untested UAT, a `success_criteria` entry with no covering UAT, a consumer or blast-radius site the SPEC overlooked.
>
> Lead with a tool call, not prose: your first action is a Read of the artifact under audit, and you emit your structured result before any prose. Read `<DRAFT_PATH>` first.
>
> **Write** your fresh findings to `.gaia/local/cache/audit-<spec_id>/findings/completeness.json` under the findings file schema in `.claude/skills/gaia/references/spec/lens-dispatch.md` (`{ "dimension": "completeness", "findings": [...] }`), writing the file even if your findings array is empty.
>
> **Return** only the thin digest, no finding bodies: `{ "dimension": "completeness", "counts": { "blocker": <int>, "high": <int>, "medium": <int>, "low": <int> }, "findings": [ { "id": "CPL-NNN", "severity": "...", "title": "..." } ] }`.

It **writes its fresh findings to `.gaia/local/cache/audit-<spec_id>/findings/completeness.json`** (the findings file schema in `spec/lens-dispatch.md`) and returns the thin digest above; its bodies never flow into main. After it finishes, classify `findings/completeness.json` the same way as a lens file (`## Pre-clear, classify, re-dispatch` in `spec/lens-dispatch.md`): re-dispatch once on a no-op, and run the critic inline on a second.

Append one `coverage.jsonl` record (`phase: "completeness"`, `disposition: "first_pass"|"not_applicable"`).

### 7b-iii. Completeness-critic refuter

Any fresh findings from 7b-ii run through a single-refuter round under the **same** refuter prompt, verdict schema, and naming contracts as 7b-i (its verdicts write to `verdicts/<finding-id>.json`); merge the survivors. Like 7b-i, pre-clear `verdicts/<finding-id>.json` before dispatch.

Append one `coverage.jsonl` record (`phase: "refuter"`, `disposition: "first_pass"|"not_applicable"`).

Its bodies never flow into main.

## 7c. Disposition routing + apply

Resolve the main-anchored SPEC folder first, before any dispatch below consumes it. The SPEC folder is main-anchored state (state registry `specs-main`), so the report lands beside the artifact the ledger row indexes rather than in a second specs tree inside a linked worktree. The `mkdir -p` keeps this self-sufficient: step 3 already created the folder earlier in the session, and this step's `mkdir -p` keeps it self-sufficient however it is reached. Whoever writes `AUDIT.md` there, the delegated applier or main's inline fallback, does so per the tool-choice contract in `spec.md`'s Operational primitives.

```bash
MAIN_ROOT="$(bash .gaia/scripts/main-root-lib.sh)"
SPEC_DIR="${MAIN_ROOT}/.gaia/local/specs/${SPEC_ID}"
mkdir -p "$SPEC_DIR"
AUDIT_MD="${SPEC_DIR}/AUDIT.md"
```

Route each surviving finding by its `disposition`, read from the **thin verdict lines** (main never opens the verdict files):

- **Plan-time directive** (the SPEC's contract is already satisfied; the fix is an implementation instruction). No change folds into the draft (it stays byte-identical), but the finding gains a plan-time-directive entry in `AUDIT.md` (7d) so `/gaia-plan` and the implementer honor it.
- **SPEC contract defect** (a UAT or the intent is itself wrong, gameable, or missing). The draft is not yet saved, so the fix folds straight into the draft cache with NO reopen ceremony.

**Interactive.** Main reads only the handful of **material** (severity ≠ `low`) spec-defect survivors from the findings files to surface them to the user, mirroring step 6b's high-finding prompt (issue, evidence, recommendation; apply / keep / revise). No numeric cap or paging. This is the second bounded interactive carve-out where a finding body legitimately reaches main. Collect the user's apply/keep/revise decisions into the delegated-fold decision list. **Low** spec-defect fixes are never read into main; the applier folds them directly from the on-disk findings files (it reads the full cache), and refuter verdict text is never read into main. (Low findings skip refutation and carry no verdict line, so the sourcing of a low finding's `disposition` is a pre-existing question the audit's logic leaves unchanged here; the applier folds only the low spec-defects an inline fold would fold.)

**Auto-mode per rule 12.** No reads; **no finding body reaches main**. The transcript carries ids, severities, titles, verdicts, and dispositions only. Unambiguous spec-defect ids apply (added to the decision list as `apply`); a defect with more than one defensible repair becomes a deferred-clarification note in `clarifications.deferred[]` with rationale `"Auto-mode audit, defer for human review."` and is not applied. Never revert intentional clarify-loop evolution.

**Fold through the delegated applier.** Dispatch the applier (see "Audit cache + delegated fold" in `spec.md`) with the inputs that primitive enumerates, taking `${SPEC_DIR}` from 7c above. It reads the draft plus every findings and verdict file plus the decision list, folds every spec-defect fix in **one Write**, and **writes `AUDIT.md` itself** (7d) at the folder path it was handed, from the on-disk findings and verdicts; main never loads a finding body to produce `AUDIT.md`. **Fallback:** if subagent dispatch is unavailable, main folds inline itself, writing `AUDIT.md` at that same resolved path.

Before dispatching, finalize `.gaia/local/cache/audit-<spec_id>/coverage.jsonl`, one thin JSON-Lines record per in-scope dispatch resolved so far, `{ "phase": ..., "lens": ..., "disposition": "first_pass"|"not_applicable" }`, carrying no finding body (this is the applier's data source for `## Coverage` in 7d; the findings/verdict files cannot encode a disposition).

## 7d. Persist AUDIT.md

`${SPEC_DIR}` and `${AUDIT_MD}` are already resolved at the top of 7c, which is where the applier dispatch consumes them; this step writes the report, it resolves no path of its own.

The **applier** writes a sibling report at `${AUDIT_MD}`, the report path main hands it, from the on-disk findings and verdicts (it already holds the complete record, so main never loads a finding body to produce it). `${SPEC_DIR}` sits inside the `.gaia/local/specs/**` write-surface allowlist entry. Keep it lean:

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

The `## Coverage` section is sourced from `.gaia/local/cache/audit-<spec_id>/coverage.jsonl`, one thin phase/lens/disposition record main appends per in-scope dispatch as it resolves, not from the findings/verdict files (which cannot encode a disposition). Each line's `<disposition>` is one of `first_pass` / `not_applicable`.

When a sibling `AUDIT.md` exists, the step-11 `/gaia-plan` handoff names it so its plan-time directives are discoverable.

## Close the audit window

The audit unit is now complete, the 7c applier has returned. Capture the end and write the audit-window breadcrumb by sourcing `.gaia/scripts/audit-window-lib.sh` and calling its single breadcrumb writer. Do not inline `jq -n` here, the write goes through `gaia_audit_window_write` so the same code path a unit test exercises is the one production runs:

```bash
AUDIT_WINDOW_END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
. .gaia/scripts/audit-window-lib.sh 2>/dev/null || true
AUDIT_CACHE_DIR="$(bash .gaia/scripts/main-root-lib.sh)/.gaia/local/cache"
gaia_audit_window_write \
  "$AUDIT_CACHE_DIR/audit-window-$SPEC_ID.json" \
  "${CLAUDE_CODE_SESSION_ID}" \
  "$AUDIT_WINDOW_START" "$AUDIT_WINDOW_END" \
  "<lenses-json-array>" \
  "<audit_intensity>" || true
```

`<lenses-json-array>` is a JSON array of the dispatched lens-id set, e.g. built with `jq -cn '$ARGS.positional' --args FG TST COV RT`. `<audit_intensity>` is the tier recorded at the top of step 7 (`standard` | `deep`); passing it as the 6th argument makes the writer include the `intensity` key. `$AUDIT_CACHE_DIR` resolves to the main checkout's cache root via the shared resolver (`.gaia/scripts/main-root-lib.sh`), so the breadcrumb lands there even when authoring runs inside a linked worktree; it never sits inside `.gaia/local/cache/audit-<spec_id>/`, so the step-9.1 teardown does not remove it. The call is best-effort (`|| true`) and never blocks the handoff to gate 2.

After the report is written, any folds are cached, and the breadcrumb is written, proceed to gate 2 (`spec.md` step 8), which renders the hardened draft.
