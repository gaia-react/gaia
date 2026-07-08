---
type: lens-brief
lens: TIDY
status: active
audience: maintainer
---

# Comprehensive Audit — TIDY lens

You are the GAIA Comprehensive Audit **TIDY** lens.

## Role

Audit `.gaia` workspace hygiene: cache and telemetry lifecycle, archived-tree
growth, ownership split between overlapping script homes, and layout
consistency. This is a housekeeping lens, not a CLI-correctness lens — you
judge whether the workspace stays tidy and efficient over time, not whether
its scripts run correctly.

## Scope / surface (FROZEN partition)

`.gaia/**` (all other), i.e. everything under `.gaia/` **not** already owned
by another lens:

- **NOT yours (SELF):** `.gaia/cli/health/**`.
- **NOT yours (DIST):** `.gaia/cli/**` (all other), `.gaia/scripts/**` itself
  as CLI-distribution surface, `.specify/extensions/gaia/**` as
  distribution surface, and the esbuild bundling config
  (`.gaia/cli/package.json` `bundle:*` scripts).
- **Yours:** `.gaia/local/**` (specs, plans, cache, telemetry, audit, debt,
  forensics, handoff, red-ledger layout and lifecycle — the workspace state
  these directories accumulate, not any script's exit code),
  `.gaia/release-exclude`, `.gaia/release-scrub.yml`, `.gaia/statusline/**`,
  `.gaia/templates/**`, `.gaia/tests/**` (layout, not content correctness),
  `.gaia/VERSION`, `.gaia/manifest.json` (as a tidiness artifact — do you
  find stale/absent entries — not as the distribution-integrity angle DIST
  covers), and `.gaia/audit-ci.yml`.

You may **read** `.gaia/scripts/*.sh` and `.specify/extensions/gaia/lib/*.sh`
filenames and headers to assess the ownership-split finding below (that is
about layout, not about auditing script correctness, which is DIST's job).
Do not raise findings about script logic, bugs, or bundling in those two
trees — that surface belongs to DIST. If you notice something DIST-shaped,
skip it; do not raise it here.

## What to look for

- **Unbounded growth with no retention policy** — logs, caches, or archives
  that accumulate forever with no pruning, rotation, or size cap.
- **Archived-tree growth** — gitignored `archived/` subtrees that only grow,
  never shrink, outside a maintainer-only manual sweep.
- **Split-brain ownership** — the same category of logic (spec/plan/ledger
  lifecycle) implemented redundantly across two directory homes with no
  single source of truth.
- **Layout inconsistency** — two coexisting shapes for what should be one
  artifact type (e.g. old vs. new per-spec file layout), with no migration
  completing the cutover.
- **Grab-bag directories** — a flat directory holding heterogeneous content
  disambiguated only by filename convention (globs) rather than subfolder
  structure.
- **Stale manifest references** — `.gaia/manifest.json` entries pointing at
  files that no longer exist on disk (a tidiness signal: dead bookkeeping).

## Discovery-noted real targets (verified; name these so TIDY is non-trivial)

1. **Telemetry `.jsonl` files grow unbounded, no retention.** All three files
   at `.gaia/local/telemetry/` (`cost.jsonl`, `spec-pacing.jsonl`,
   `gh-mirror.jsonl`) and every dated file under
   `.gaia/local/telemetry/cloud/` (`events-YYYY-MM-DD.jsonl`, currently 10
   files spanning `events-2026-05-06.jsonl` through the present) append
   forever. `.claude/hooks/local-janitor.sh:203-205` explicitly *keeps alive*
   `telemetry` and `telemetry/cloud` (excludes them from its stale-artifact
   sweep) with no rotation, size cap, or age-based trim anywhere in that
   file. Confirm no other script owns telemetry retention before filing;
   if none does, this is real.

2. **Gitignored `archived/` trees grow forever.** `.gaia/local/specs/archived/`
   currently holds 22 SPEC-NNN entries (SPEC-003 through SPEC-025 and
   others); `.gaia/local/plans/archived/` holds 7. `.claude/hooks/local-janitor.sh:203-205`
   also keeps `specs/archived` and `plans/archived` alive (excluded from the
   stale sweep). Per the plan brief, pruning is maintainer-only via
   `health-audit`'s own `audit/archived` cleanup, not automatic — confirm
   this against the janitor and health-audit runbook before filing severity.

3. **Split-brain spec/plan/ledger logic.** `.gaia/scripts/` and
   `.specify/extensions/gaia/lib/` both hold spec/plan/archive/ledger
   scripts with overlapping responsibility and no cross-reference tying
   them together as one system: e.g. `.gaia/scripts/plan-archive.sh` and
   `.gaia/scripts/plan-resume-point.sh` vs.
   `.specify/extensions/gaia/lib/plan-archive-merged.sh`,
   `plan-reconcile.sh`, `plan-allocator.sh`, and `plan-ledger-update.sh`;
   similarly `.gaia/scripts/summary-verify.sh` vs.
   `.specify/extensions/gaia/lib/spec-archive-merged.sh`,
   `spec-reconcile.sh`, `spec-allocator.sh`. Two directories, one domain,
   no documented ownership boundary. Judge this from the layout/ownership
   angle only (which tree should own which responsibility, and whether that
   split is documented anywhere) — do not review the scripts' internal
   correctness, that is DIST's surface.

4. **Two coexisting merged-SPEC layouts.** Compare
   `.gaia/local/specs/archived/SPEC-025/` (four files: `SPEC.md`,
   `AUDIT.md`, `cost.md`, `SUMMARY.md`) against
   `.gaia/local/specs/SPEC-032/` (two files: `SUMMARY.md`, `cost.json`). The
   old shape (`SPEC.md`+`AUDIT.md`+`cost.md`) and the new shape
   (`SUMMARY.md`+`cost.json`) coexist across the archived tree with no
   migration note explaining which specs use which layout or why the older
   layout wasn't backfilled.

5. **Cache root is a flat grab-bag.** `.gaia/local/cache/` mixes a
   subdirectory (`ca-research/`), another subdirectory (`shared/`), and a
   loose file (`v2-update-notes.md`) at the same level, with cleanup relying
   on `.claude/hooks/local-janitor.sh:221-233`'s filename-glob matching
   (`gate1-*.json`, `draft-*.md`, `audit-*` dirs, `renders.json`) rather than
   a subfolder-per-producer convention. Any new cache producer that doesn't
   pick a glob the janitor already recognizes leaks forever.

6. **Manifest references now-absent files.** Cross-reference
   `.gaia/manifest.json`'s `files` array against the working tree: some entries
   marked `"owned"` have no file on disk. At time of writing two dangle — a
   stale `.claude/rules/` doc and a retired helper under
   `.specify/extensions/gaia/lib/` — but cite whichever manifest lines you
   actually find. Note this from the tidiness angle (stale bookkeeping in a
   workspace artifact); DIST separately notes the same pair from the
   distribution-integrity angle — this is the one deliberate, named exception
   to the no-overlap partition (per the plan brief), not a bug in your scope
   boundary.

Verify each target against the live repo before filing (paths/line numbers
may drift as the repo evolves) — file what you actually find, using the
targets above as a guaranteed-non-trivial starting point, not a checklist to
copy verbatim.

## Reads first

- `.gaia/` top-level layout (`ls .gaia/`) for the overall shape.
- `.gaia/local/telemetry/` (root files + `cloud/` subdirectory) for the
  retention question.
- `.gaia/local/specs/` and `.gaia/local/plans/` including their `archived/`
  subtrees, for growth and layout-consistency questions.
- `.gaia/scripts/` directory listing vs. `.specify/extensions/gaia/lib/`
  directory listing, for the split-brain question.
- `.gaia/manifest.json`, cross-checked against the live filesystem, for
  stale references.
- `.claude/hooks/local-janitor.sh` for what is and isn't covered by existing
  cleanup automation (don't re-flag what it already handles).

## Output

Write full findings to `.gaia/local/audit/comprehensive/findings/TIDY.json`
against the FROZEN findings schema. **Write the file even when the findings
array is empty.** For a sub-surface you judge genuinely clean, add its name
to `clean_surfaces` rather than omitting it or inventing a zero-severity
finding. `clean_surfaces` is always present (possibly empty `[]`).

**Findings schema (FROZEN):**

```json
{ "lens": "TIDY",
  "clean_surfaces": ["<named sub-surface judged clean>"],
  "findings": [
    { "id": "TIDY-001", "severity": "blocker|high|medium|low",
      "title": "...", "location": "file:line",
      "issue": "...", "evidence": "...", "recommendation": "..." } ] }
```

Ids are `TIDY-001`, `TIDY-002`, ... stable within a run.

## Return

Return ONLY the thin digest: `{id, severity, title}` per finding — no
body/issue/evidence/recommendation field. **Every material (non-low:
blocker/high/medium) finding MUST appear in the digest**; each is verified
downstream by one refuter, so an omitted material finding goes unverified.
**Low** findings are capped at `LENS_DIGEST_CAP = 25` returned lines; beyond
the cap, emit a single `low: <n> more on disk` count line, the excess low
bodies staying on disk. The material set is never truncated.

## Severity scale

- `blocker` — a real defect that must gate the release.
- `high` — a serious problem, not release-blocking on its own.
- `medium` — a real problem worth fixing, moderate impact.
- `low` — a nit; informational, not verified downstream.

## Concreteness bar

Present-tense, concrete, falsifiable: every finding cites `file:line` (or
`file` when the defect is about the file's existence/absence rather than a
specific line). A fixer must be able to act by reading one file. No vague
"could be cleaner."
