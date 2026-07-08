---
type: runbook
status: active
audience: maintainer
---

# Comprehensive Audit Runbook

Operational protocol for the Comprehensive Audit phase, an extension of
`/health-audit`. Maintainer-only; release-excluded by
`.gaia/release-exclude` category 10 (`.gaia/cli/health` is wholesale
excluded).

## Framing

- **Report-only.** The phase applies no automatic edit and files no
  tech-debt issue. It evaluates and recommends; a human dispositions every
  confirmed finding by hand.
- **Runs exactly once** per `/health-audit` invocation, after the N=3
  integrity loop terminates and before the final verdict is emitted. Never
  inside the loop.
- **Does not recompute or mutate** health-audit's integrity verdict math
  (its three-input floor). It reports alongside that verdict; it does not
  feed the Fixer lanes or the verdict computation.

## Topology

Depth-1: the Orchestrator (main thread) is the only spawner. Every lens,
every refuter, and the report writer is a leaf `general-purpose` subagent
the Orchestrator dispatches directly; no leaf spawns another leaf.

## Step 0: Phase-start reset

Clear and recreate the two working subdirs so a scoped run never inherits a
prior run's stale `<LENS>.json`:

```bash
rm -rf .gaia/local/audit/comprehensive/findings .gaia/local/audit/comprehensive/verdicts
mkdir -p .gaia/local/audit/comprehensive/findings .gaia/local/audit/comprehensive/verdicts
```

Both paths match `.gaia/local/audit/*`, whitelisted by `block-rm-rf.sh`. The
tree is gitignored (release-exclude category 7) and swept by the existing
janitor and health-audit cleanup, so it does not grow unbounded. A stale
`gauge.json` or `REPORT.md` at the top level is simply overwritten this run.

## Step 1: Pre-flight gauge

Run the gauge and read only its thin depth token:

```bash
bash .gaia/cli/health/comprehensive/gauge.sh [--comprehensive-full] [--major]
```

The gauge writes `.gaia/local/audit/comprehensive/gauge.json`
(`{depth, lenses, source, rationale, baseline_tag, churn_files}`) and echoes
a one-line summary. The Orchestrator reads `depth` and `lenses` (thin) —
via the stdout line or `jq -r '.depth, (.lenses|join(","))' gauge.json`.
Pass `--comprehensive-full` through when the maintainer invoked
`/health-audit` with that force flag; pass `--major` through when the
maintainer signaled explicit major-release intent. The gauge's internal
depth-decision precedence, churn threshold, and diff surface set are its own
contract; this step names only the invocation and the fields the
Orchestrator reads.

## Step 2: Skip path

If `depth == skip`: dispatch no lens; `findings/` stays empty. The
health-audit output records the fixed marker line, with `<tag>`
**interpolated** from the gauge's resolved baseline
(`jq -r '.baseline_tag' .gaia/local/audit/comprehensive/gauge.json`), never
emitted as the literal placeholder:

```
comprehensive: skipped (no framework-facing changes since <tag>)
```

Stop the phase here.

## Step 3: Lens fan-out

Otherwise dispatch **one auditor leaf per selected lens, all in parallel**.
Each lens L reads its brief at
`.gaia/cli/health/comprehensive/lenses/<L>.md` and its slice of the repo,
writes full findings to `.gaia/local/audit/comprehensive/findings/<L>.json`
(**written even when the findings array is empty**), and returns **only
the thin digest**.

Pin each lens dispatch to its brief. The verbatim lens dispatch template
(the Orchestrator fills `<L>`):

> You are the GAIA Comprehensive Audit **<L>** lens. Read
> `.gaia/cli/health/comprehensive/lenses/<L>.md` end-to-end and execute it
> against the current repo. Write your full findings to
> `.gaia/local/audit/comprehensive/findings/<L>.json` against the pinned
> findings schema. Return ONLY the thin digest: `{id, severity, title}` per
> finding, no body/issue/evidence/recommendation text. **Every material
> (non-low: blocker/high/medium) finding MUST appear in the digest** — each
> is verified downstream by one refuter, so a material finding you omit
> from the digest goes unverified. **Low** findings are capped at
> `LENS_DIGEST_CAP` (25) lines total; if you have more low findings than
> that, emit that many plus a single `low: <n> more on disk` count line —
> the excess low bodies stay on disk. The material set is never truncated.

**Lens return contract (FROZEN, observable):** the digest is `{id,
severity, title}` per finding. **All material (non-low) findings are
always returned** — their count is the irreducible floor for the
one-refuter-each verification round. **Low** findings are capped at
`LENS_DIGEST_CAP = 25` returned lines; beyond that the lens returns a count
line and the excess low bodies stay on disk. This bounds aggregate
orchestrator context to the material set plus a bounded low sample (not
O(all findings)) while guaranteeing every material finding is visible for
verification. The return schema names **no** `body`, `content`, `issue`,
`evidence`, or `recommendation` field.

**Findings schema (FROZEN)** written to `findings/<L>.json`:

```json
{ "lens": "<L>",
  "clean_surfaces": ["<named sub-surface the lens judged clean>"],
  "findings": [
    { "id": "<L>-001", "severity": "blocker|high|medium|low",
      "title": "...", "location": "file:line or file",
      "issue": "...", "evidence": "...", "recommendation": "..." } ] }
```

`clean_surfaces` encodes the clean-verdict escape hatch: when a lens judges
a named sub-surface genuinely clean (rather than raising a finding), it
records that sub-surface name here instead of inventing a zero-severity
finding. The array is present (possibly empty) in every findings file. The
writer lists `clean_surfaces` **informationally** under the lens's `##
Findings by lens` subsection and **never** in the actionable `## Priority
index`. It carries no severity and is not verified.

**Design intent:** the Orchestrator loads no finding body — it holds only
the digest.

Four lenses, canonical order `FEAT, DIST, TIDY, SELF`, full briefs in the
lens files:
- **FEAT** — coherence and conflict across `.claude` commands, skills,
  agents, rules, hooks.
- **DIST** — CLI and adopter-distribution integrity, including bundle
  test-coverage gaps.
- **TIDY** — `.gaia` workspace tidiness and efficiency.
- **SELF** — `/health-audit`'s own machinery (command, runbook, taxonomy).

## Step 4: Verification round (bounded, adversarial)

The Orchestrator selects **every material (non-low) finding id** from the
digests and dispatches **exactly one refuter per finding** (never a
multi-member panel), in **bounded waves**: no more than
`REFUTER_WAVE_CAP = 8` refuters live at once, each wave reaped to disk
before the next launches, so aggregate main-thread context is bounded, not
O(findings). Because the lens return contract returns **every** material
finding in the digest (only low findings are capped), "from the digests"
enumerates the **complete** material set — no material finding is missed.

Each refuter reads its target finding from its on-disk file
(`findings/<L>.json`, by id), tries to **refute it against ground truth**,
and writes a verdict file at
`.gaia/local/audit/comprehensive/verdicts/<finding-id>.json`.

**Verdict schema (FROZEN):**

```json
{ "id": "<finding-id>",
  "verdict": "confirmed | refuted | severity-corrected",
  "corrected_severity": "blocker|high|medium|low",   // present only when severity-corrected
  "evidence": "...", "rationale": "..." }
```

Rules:
- A `refuted` verdict **must cite the ground-truth evidence** that
  contradicts the finding (its `evidence` field is mandatory and concrete:
  `file:line` or a command output).
- Refuted findings drop from the actionable list; `confirmed` and
  `severity-corrected` survive (with corrected severity).
- A round that refutes an **implausibly high fraction** of material
  findings is itself **surfaced in the report as suspect** (the writer
  computes and flags this; a threshold above 60% refuted across a run is
  flagged suspect).

Verbatim refuter dispatch template:

> You are an ADVERSARIAL refuter of a single GAIA Comprehensive Audit
> finding. Read the finding `<finding-id>` from
> `.gaia/local/audit/comprehensive/findings/<LENS>.json` and nothing else
> from other findings. Your job is to find the ground-truth reason this
> finding is FALSE or mis-severed, not to confirm it. Cite evidence as
> `file:line` or a command you ran. Write your verdict to
> `.gaia/local/audit/comprehensive/verdicts/<finding-id>.json` against the
> pinned verdict schema. A `refuted` verdict MUST carry concrete
> contradicting evidence; absent that, return `confirmed`.

Material = severity ∈ {blocker, high, medium}. Low findings are **not**
verified (listed informationally, not gated).

## Step 5: Report (delegated writer)

A **named delegated writer** leaf composes the single report at
`.gaia/local/audit/comprehensive/REPORT.md` from the on-disk `gauge.json`,
`findings/*.json`, and `verdicts/*.json`. The Orchestrator dispatches the
writer and then holds only the report path and top-line counts — it does
not read the findings itself.

Verbatim writer dispatch template:

> You are the GAIA Comprehensive Audit **report writer**. Read
> `.gaia/local/audit/comprehensive/gauge.json`, every
> `.gaia/local/audit/comprehensive/findings/*.json`, and every
> `.gaia/local/audit/comprehensive/verdicts/*.json`. Compose a single
> `.gaia/local/audit/comprehensive/REPORT.md` with the FROZEN greppable
> anchors below. **Actionable-list gate (hard rule):** a material finding
> enters the `## Priority index` **only if it carries a verdict file**
> whose verdict is `confirmed` or `severity-corrected`; `refuted` findings
> and any material finding **missing a verdict file** are excluded from the
> actionable list. A material finding present on disk but lacking a
> verdict must NOT silently vanish: list it under a `## Unverified` note so
> the gap is visible. Low findings and each lens's `clean_surfaces` entries
> are listed informationally under `## Findings by lens` and are never
> gated. Give every confirmed finding a recommended `Disposition:` line.
> Return only the report path and the top-line counts (total actionable,
> per-severity, refuted count, unverified count, suspect-flag).

**REPORT.md anchors (FROZEN):**
- `## Depth` — the depth token, `source`, and `rationale` (must equal
  `gauge.json`).
- `## Priority index` — the actionable list, ranked by severity **across
  all lenses**. Membership is verdict-gated: a material finding appears
  here only if it carries a `confirmed` or `severity-corrected` verdict
  file (refuted and verdict-missing findings excluded).
- `## Findings by lens` — one `### Lens: <LENS>` subsection per dispatched
  lens; each subsection lists the lens's findings and its `clean_surfaces`
  entries (informational).
- `## Coverage` — exactly one `Coverage: <LENS> <n>` line per dispatched
  lens (line count equals the dispatched-lens count).
- Each confirmed finding carries a recommended `Disposition:` line (e.g.
  `candidate for the tech-debt backlog`, or `open design question for
  maintainer decision`).
- If any material finding on disk lacks a verdict file, add a `##
  Unverified` note listing those ids (excluded from the actionable list but
  never silently dropped).
- If the verification round refuted an implausibly high fraction, add a
  `## Suspect` note surfacing it.

## Step 6: Report-only disposition + hand-back

The phase files nothing and edits nothing outside
`.gaia/local/audit/comprehensive/`. The Orchestrator surfaces, in the
final health-audit output: the REPORT.md path, its top-line counts, and
any **confirmed blocker** as a prominent release-gate flag. It does not
recompute the integrity verdict math. `git status` after the phase shows
changes only under `.gaia/local/audit/comprehensive/`.

## Pointers

- **Gauge**: `.gaia/cli/health/comprehensive/gauge.sh`.
- **Lens briefs**: `.gaia/cli/health/comprehensive/lenses/{FEAT,DIST,TIDY,SELF}.md`.
- **Parent protocol**: `.gaia/cli/health/runbook.md`; the N=3 integrity loop
  this phase runs after.
- **Delegated-writer pattern origin**: `.claude/skills/gaia/references/spec.md`
  § "Audit cache + delegated fold".
