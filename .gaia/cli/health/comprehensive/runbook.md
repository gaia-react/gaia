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
  tech-debt issue automatically. It evaluates and recommends; a human
  dispositions every confirmed finding by hand, and at hand-back the
  Orchestrator offers a human-gated path to file confirmed, unmatched
  findings through `/file-tech-debt` (see Step 6).
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

## Model selection

| Role                  | Model                        |
| ---------------------- | ----------------------------- |
| Orchestrator            | main thread (session model)  |
| Lens: FEAT              | Sonnet                        |
| Lens: DIST              | Sonnet                        |
| Lens: TIDY              | Sonnet                        |
| Lens: SELF              | Sonnet                        |
| Refuter (per finding)   | Sonnet                        |
| Report writer           | Sonnet                        |

The four lenses, the per-finding refuters, and the report writer are
judgment-bearing adversarial passes, so they pin to Sonnet, mirroring the
judgment-bearing buckets and the Adjudicator (`.gaia/cli/health/runbook.md`
§Model selection). The Orchestrator stays on the main thread (session
model), consistent with the parent.

## Step 0: Phase-start reset

Archive this phase's prior outputs, prune old archives, then recreate the
two working subdirs, so a scoped run never inherits a prior run's stale
`<LENS>.json` and the prior report is preserved rather than destroyed:

```bash
RUN_STAMP=$(date +%Y-%m-%d-%H-%M)
ARCHIVE_DIR=".gaia/local/audit/comprehensive/archived/$RUN_STAMP"
mkdir -p "$ARCHIVE_DIR"
[ -e .gaia/local/audit/comprehensive/findings ] && mv .gaia/local/audit/comprehensive/findings "$ARCHIVE_DIR"/
[ -e .gaia/local/audit/comprehensive/verdicts ] && mv .gaia/local/audit/comprehensive/verdicts "$ARCHIVE_DIR"/
[ -e .gaia/local/audit/comprehensive/gauge.json ] && mv .gaia/local/audit/comprehensive/gauge.json "$ARCHIVE_DIR"/
[ -e .gaia/local/audit/comprehensive/REPORT.md ] && mv .gaia/local/audit/comprehensive/REPORT.md "$ARCHIVE_DIR"/
[ -e .gaia/local/audit/comprehensive/CONTINUATION.md ] && mv .gaia/local/audit/comprehensive/CONTINUATION.md "$ARCHIVE_DIR"/
find .gaia/local/audit/comprehensive/archived -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
  | sort -r | tail -n +4 | while IFS= read -r d; do rm -rf "$d"; done
mkdir -p .gaia/local/audit/comprehensive/findings .gaia/local/audit/comprehensive/verdicts
```

The prune loop's `rm -rf "$d"` target, and every path this step moves or
creates, matches `.gaia/local/audit/*`, whitelisted by `block-rm-rf.sh`.
The tree is gitignored (release-exclude category 7). This step's own
archive-and-prune is what bounds its growth: the prior `findings/`,
`verdicts/`, `gauge.json`, `REPORT.md`, and `CONTINUATION.md` move into
`archived/<stamp>/`, and `archived/` is pruned to the 3 most recent runs.
This lifecycle is scoped to `.gaia/local/audit/comprehensive/`, its own
tree separate from the integrity loop's `.gaia/local/audit/archived/` (see
`.gaia/cli/health/runbook.md` §Audit artifacts lifecycle).

Then capture two pre-phase baselines the Step 6 integrity check diffs
against. They cover disjoint surfaces: `git status` sees tracked files but
is blind to gitignored `.gaia/local/`; the inventory sees `.gaia/local/`'s
durable working-state directories but nothing outside them.

Snapshot the tracked surface. Earlier cycles' Fixer lanes may have already
left legitimate changes in the tree, so the invariant is "this phase adds
nothing", not "the tree is clean":

```bash
git status --porcelain > .gaia/local/audit/comprehensive/git-status.pre.txt
```

Snapshot the durable working-state directories under `.gaia/local/`:
`specs/`, `plans/`, and `handoff/`, the artifact classes a destructive
script can wipe out unnoticed (the incident this guard exists for: a
refuter ran `spec-archive-merged.sh --close` to probe its gates and
deleted `.gaia/local/specs/SPEC-031/`). `debt/`, `telemetry/`, `audit/`,
`cache/`, and `red-ledger/` are deliberately excluded: each is rewritten
or appended by a background process with no leaf involved (the
statusline's debt-count refresher, the token tally, other audit runs'
`<sha>.rerun.json` markers, the wiki-promote cache, and RED-phase test
hooks), so including them would turn routine churn into a false integrity
violation:

```bash
find .gaia/local/specs .gaia/local/plans .gaia/local/handoff -type f -print0 2>/dev/null \
  | sort -z \
  | xargs -0 -r sh -c '(shasum -a 256 "$@" 2>/dev/null || sha256sum "$@")' _ \
  > .gaia/local/audit/comprehensive/local-inventory.pre.txt
```

`shasum -a 256` is present on macOS and most Linux; `sha256sum` is the
coreutils fallback (same portability pattern as `token-tally.sh`).

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

Pin each lens dispatch to its brief, and dispatch each lens leaf with
`model: sonnet` (see §Model selection); the model pin is an
Orchestrator-side dispatch parameter, not part of the prompt text below.
The verbatim lens dispatch template (the Orchestrator fills `<L>`):

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
- A refuter is read-only against the repo: it may read files and run
  read-only commands to gather evidence, but must never execute a
  state-mutating script or command, even to probe what it does. The
  prohibition is stated verbatim in the dispatch template below.

The Orchestrator dispatches each refuter leaf with `model: sonnet` (see
§Model selection), an Orchestrator-side dispatch parameter, not part of
the prompt text below.

Verbatim refuter dispatch template:

> You are an ADVERSARIAL refuter of a single GAIA Comprehensive Audit
> finding. Read the finding `<finding-id>` from
> `.gaia/local/audit/comprehensive/findings/<LENS>.json` and nothing else
> from other findings. Your job is to find the ground-truth reason this
> finding is FALSE or mis-severed, not to confirm it. Cite evidence as
> `file:line` or a command you ran. Gather evidence with read-only commands
> only: reading a script's source to reason about its gates is fine, but you
> MUST NOT execute a state-mutating script or command against this repo (any
> command that writes, deletes, moves, archives, or otherwise changes repo
> or `.gaia/local/` state) even to see what it does or to probe its gates.
> If you need to know a script's behavior, read it; do not run it. A local
> `.gaia/local/specs/<ID>/` folder is working state, not the durable
> record; never mutate one, even one that looks merged or stale (see
> `wiki/concepts/GAIA Spec.md` § "When a SPEC folder is deleted"). Write
> your verdict to `.gaia/local/audit/comprehensive/verdicts/<finding-id>.json`
> against the pinned verdict schema. A `refuted` verdict MUST carry concrete
> contradicting evidence; absent that, return `confirmed`.

Material = severity ∈ {blocker, high, medium}. Low findings are **not**
verified (listed informationally, not gated).

## Step 5: Report (delegated writer)

A **named delegated writer** leaf composes the report content from the
on-disk `gauge.json`, `findings/*.json`, and `verdicts/*.json`, and returns
it **as text**, not as a file. Subagents are blocked at the harness level
from writing report files, so the writer never touches
`.gaia/local/audit/comprehensive/REPORT.md` directly; the **Orchestrator**
(the main thread, not subject to that guard) writes the file from the
returned text. This keeps the delegated-composition context savings (the
writer, not the Orchestrator, loads every findings/verdicts file) while
respecting the guard: only the disk write moves to the Orchestrator, not
the composition. After writing the file verbatim from the returned text,
the Orchestrator discards the text from its own working context and
retains only the report path and top-line counts.

The writer is the only phase leaf that is stateful across runs: it also
reads the open `tech-debt` issue tracker to annotate findings already
under a tracking issue (see the dispatch template below). It still reads
only from disk and the issue tracker, never the code under audit, which is
what makes it the safe place to be stateful. The lens auditors and
refuters stay completely ignorant of prior runs, no issue-querying is
added to their dispatch templates, preserving the fresh-context
anti-anchoring property those leaves depend on.

A denied tool call is surfaced, never routed around. If the writer's
dispatch, or any leaf's dispatch, hits a denied write (or any other denied
tool call), it stops and reports the denial in its response; it does not
retry the same operation through a different tool to work around a guard
it cannot use directly.

The Orchestrator dispatches the writer leaf with `model: sonnet` (see
§Model selection), an Orchestrator-side dispatch parameter, not part of
the prompt text below.

Verbatim writer dispatch template:

> You are the GAIA Comprehensive Audit **report writer**. Read
> `.gaia/local/audit/comprehensive/gauge.json`, every
> `.gaia/local/audit/comprehensive/findings/*.json`, and every
> `.gaia/local/audit/comprehensive/verdicts/*.json`. Also run `gh issue
> list --label tech-debt --state open --json number,title,body` and, for
> each returned issue, parse its `gaia-debt-key` comment's `path=` and
> `line=` fields. For each finding that carries a `confirmed` or
> `severity-corrected` verdict, parse its `location` field into
> `file:line` (a `location` with no line cannot match; leave it
> unannotated) and compare it against those keys on **both path and
> line**; where a match exists, annotate that finding's `## Priority
> index` entry with the tracking issue number (`Tracked: #<n>`). Compose
> the single report with the FROZEN greppable anchors below and return it
> **as text in your response, in full**; do not write it to disk yourself.
> You do not have write access to report files, and that restriction is
> not a bug to route around: if a tool call you need is denied, stop and
> report the denial in your response rather than retrying with a different
> tool. **Actionable-list gate (hard rule):** a material finding enters the
> `## Priority index` **only if it carries a verdict file** whose verdict
> is `confirmed` or `severity-corrected`; `refuted` findings and any
> material finding **missing a verdict file** are excluded from the
> actionable list. A material finding present on disk but lacking a
> verdict must NOT silently vanish: list it under a `## Unverified` note so
> the gap is visible. Low findings and each lens's `clean_surfaces` entries
> are listed informationally under `## Findings by lens` and are never
> gated. Give every confirmed finding a recommended `Disposition:` line.
> Return the full composed report text, followed on a separate line by the
> top-line counts (total actionable, per-severity, refuted count,
> unverified count, matched-to-existing-issue count, suspect-flag).

**REPORT.md anchors (FROZEN):**
- `## Depth` — the depth token, `source`, and `rationale` (must equal
  `gauge.json`).
- `## Priority index` — the actionable list, ranked by severity **across
  all lenses**. Membership is verdict-gated: a material finding appears
  here only if it carries a `confirmed` or `severity-corrected` verdict
  file (refuted and verdict-missing findings excluded). Each entry whose
  `location` matches an open `tech-debt` issue's `gaia-debt-key` (on both
  path and line) carries a `Tracked: #<n>` annotation; an entry with no
  match carries none.
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

The audit leaves, the lenses, the refuters, and the writer, touch nothing
outside `.gaia/local/audit/comprehensive/`; the phase files no tech-debt
issue automatically. The Orchestrator surfaces, in the final health-audit
output: the REPORT.md path, its top-line counts, and any **confirmed
blocker** as a prominent release-gate flag. It does not recompute the
integrity verdict math.

**Verify the report-only invariant against both Step 0 baselines.**
Neither alone is sufficient: `git status` sees tracked files but is
structurally blind to `.gaia/local/`, which is gitignored and is exactly
where a leaf can do unrecoverable harm; the inventory sees
`.gaia/local/`'s durable working-state directories but nothing outside
them. Run both.

First, the tracked surface. The phase must not add, remove, or modify any
tracked file, so the post-phase status must equal the Step 0 snapshot:

```bash
git status --porcelain > .gaia/local/audit/comprehensive/git-status.post.txt
diff .gaia/local/audit/comprehensive/git-status.pre.txt .gaia/local/audit/comprehensive/git-status.post.txt
```

Second, the gitignored working state. Recompute the inventory captured in
Step 0, `specs/`, `plans/`, and `handoff/` only, and diff against that
baseline:

```bash
find .gaia/local/specs .gaia/local/plans .gaia/local/handoff -type f -print0 2>/dev/null \
  | sort -z \
  | xargs -0 -r sh -c '(shasum -a 256 "$@" 2>/dev/null || sha256sum "$@")' _ \
  > .gaia/local/audit/comprehensive/local-inventory.post.txt
diff .gaia/local/audit/comprehensive/local-inventory.pre.txt .gaia/local/audit/comprehensive/local-inventory.post.txt
```

An empty diff (exit 0) confirms no lens, refuter, or writer touched the
durable working state under `.gaia/local/`. A non-empty diff from either
check is an integrity violation, not a report finding: stop before
hand-back and surface exactly which paths were added, removed, or
changed, so the maintainer investigates before trusting this run's
report.

**Human-gated filing offer.** After the integrity checks above pass and
the report is surfaced, the Orchestrator reads the written REPORT.md's
`## Priority index` and separates its confirmed findings into matched
(carry a `Tracked: #<n>` annotation) and unmatched. If any unmatched
confirmed finding exists, the Orchestrator makes **one** offer: file the
unmatched confirmed findings as tech-debt issues through the existing
`.claude/skills/file-tech-debt/SKILL.md` recipe, which owns the dedup key,
the label set, and the debt-count sentinel, invoked once per unmatched
finding. The operator answers yes or no; filing never happens without
that answer. This offer is a separate, post-integrity-check,
human-approved Orchestrator action, distinct from and after the leaves'
own work; the lenses, refuters, and writer still touch nothing outside
`.gaia/local/audit/comprehensive/`, and the only write this offer can
produce, a new GitHub issue, happens only on an explicit yes.

## Pointers

- **Gauge**: `.gaia/cli/health/comprehensive/gauge.sh`.
- **Lens briefs**: `.gaia/cli/health/comprehensive/lenses/{FEAT,DIST,TIDY,SELF}.md`.
- **Parent protocol**: `.gaia/cli/health/runbook.md`; the N=3 integrity loop
  this phase runs after.
- **Delegated-writer pattern origin**: `.claude/skills/gaia/references/spec.md`
  § "Audit cache + delegated fold".
