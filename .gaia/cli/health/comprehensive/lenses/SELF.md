---
type: audit-lens
status: active
audience: maintainer
---

# Comprehensive Audit — SELF lens

You are the GAIA Comprehensive Audit **SELF** lens.

## Scope / surface

**FROZEN partition, Order 1** (most-specific glob wins over every other
lens): `.claude/commands/health-audit.md` and `.gaia/cli/health/**` in
full — the command entry point, the main runbook, the taxonomy, and the
`comprehensive/` subtree (gauge, comprehensive runbook, the four lens
briefs including this one). This is `/health-audit`'s own machinery: the
audit auditing itself.

**Out of scope:** `wiki/decisions/Claude Integration Fitness.md` (~315
lines). It is shared surface — the seven-category Claude-integration
fitness protocol Bucket E runs wholesale, used by `/health-audit` but not
private to it (`/gaia-fitness` also runs it standalone). Do not audit it
here; a fitness-spec defect belongs to whichever surface owns
`wiki/decisions/**` under Bucket E / the FEAT-adjacent fitness protocol,
not to SELF. Do not read it as part of this lens's target surface (reading
it for cross-reference context, e.g. confirming the runbook's pointer to
it is accurate, is fine; auditing its content is not).

Everything else under `.claude/**` (skills, agents, rules, hooks, other
commands) is FEAT's surface, not SELF's. Everything else under
`.gaia/cli/**` and `.gaia/scripts/**` is DIST's. Everything else under
`.gaia/**` is TIDY's. Do not raise findings outside the SELF partition
above, even if something looks wrong there — note it is out of scope and
move on.

## What to look for

Audit of `/health-audit`'s own machinery: command-vs-runbook duplication
(single-source drift hazard — the command should be a thin pointer, not a
restatement), scope-vs-name mismatch (does "health audit" actually mean
what it claims), model pinning gaps (every dispatched role should have an
explicit, deliberate model assignment), and surface weight (is the
machinery proportionate to what it audits, and is it growing without
bound).

### Mandatory defects (SPEC UAT-010 — a SELF run reporting nothing FAILS)

You MUST surface both of the following as findings. They are real,
verified against the current repo; this is not a hypothetical prompt.

**1. Command-versus-runbook loop/termination duplication.**
`.claude/commands/health-audit.md` Step 2 (lines 14-56) restates the
runbook's cycle-loop pseudocode and the oscillation-threshold definition
almost verbatim, rather than pointing at it. Compare:

- `.claude/commands/health-audit.md:16-46` — the fenced pseudocode block
  (`mkdir -p .gaia/local/audit` ... `For cycle in 1..3:` ... clean-exit /
  oscillation-check / Fixer-dispatch / escalate steps).
- `.gaia/cli/health/runbook.md:20-43` — the "## Cycle loop" section, the
  same sequence of steps in the same order, independently worded.
- `.claude/commands/health-audit.md:48` ("**Oscillation threshold
  (definition).**" paragraph) restates
  `.gaia/cli/health/runbook.md:53` (the Oscillation bullet under
  "## Termination").

Two independently-maintained copies of the same control-flow logic is a
drift hazard: an edit to one (e.g. a change to the archive-prune count, or
to what counts as an oscillating fingerprint) can land without the other
being updated, and nothing catches the divergence. The finding's
`location` field MUST cite **both** files (see the exact format below).

**2. Orchestrator not pinned to the session model.**
`.gaia/cli/health/runbook.md:77` (the "## Model selection" table) reads:

```
| Orchestrator | main thread (session model) |
```

Every other dispatched role in the same table (Adjudicator, Bucket D,
Bucket E judgment auditor, all four challenger lenses, all four Fixer
lanes) carries an explicit model pin (Sonnet, or Haiku for the mechanical
buckets). The Orchestrator alone inherits "session model" — whatever
model the invoking session happens to be running under. Because the
Orchestrator authors the final A-to-F verdict framing, drives the
oscillation compare, and gates every circuit breaker, an unpinned
Orchestrator means the audit's own judgment layer can vary in capability
run to run depending on what model the maintainer happened to invoke
`/health-audit` from, with no floor. `.gaia/cli/health/comprehensive/runbook.md`
(the "## Topology" section, line 28) has the identical gap for the same
Orchestrator role in the comprehensive phase: "the Orchestrator (main
thread) is the only spawner" with no model pin stated there either.

### Additional real targets

**Surface weight.** At discovery time the health-audit-private surface
(`.claude/commands/health-audit.md` + `.gaia/cli/health/runbook.md` +
`.gaia/cli/health/taxonomy.md`) was ~741 lines (108 + 425 + 208). This
comprehensive-audit phase itself now adds `.gaia/cli/health/comprehensive/`
(gauge.sh + comprehensive/runbook.md + four lens briefs) on top of that
base, so the SELF surface has grown past 1,100 lines and keeps growing:
the audit auditing itself is not exempt from the weight concern it is
meant to catch elsewhere. Verify the current total with
`find .gaia/cli/health -type f -name '*.md' -o -name '*.sh' | xargs wc -l`
and cite it precisely rather than repeating "~741" as if it still held.

**Name vs scope.** The command is named `/health-audit` — "health" reads
as covering the whole project. In practice it audits only the
framework-boundary / CLI-distribution surface plus the shared
Claude-integration fitness categories (`.claude`, `.gaia`, wiki, CLI
release machinery). It never touches `app/**` (the product source) or its
tests. A maintainer skimming the command list could reasonably expect
`/health-audit` to say something about application code health and be
wrong. This is a naming-clarity finding, not a functional bug: assess
severity accordingly (most likely `low` or `medium`, not `high`/`blocker`
absent evidence of a maintainer actually being misled by it).

## Reads first

1. `.claude/commands/health-audit.md` (full, 108 lines).
2. `.gaia/cli/health/runbook.md` (full, 425 lines) — cycle loop, model
   selection table, termination, escalation.
3. `.gaia/cli/health/taxonomy.md` (full, 208 lines).
4. `.gaia/cli/health/comprehensive/runbook.md` and
   `.gaia/cli/health/comprehensive/gauge.sh` (this phase's own machinery;
   in-scope as part of `.gaia/cli/health/**`).
5. The other three lens briefs at `.gaia/cli/health/comprehensive/lenses/`
   (`FEAT.md`, `DIST.md`, `TIDY.md`) if present, to confirm this lens does
   not bleed into their surfaces.

Do not read `wiki/decisions/Claude Integration Fitness.md` as an audit
target (see Scope exclusion above); a pointer-accuracy spot-check of a
cross-reference to it is fine.

## Output

Write full findings to
`.gaia/local/audit/comprehensive/findings/SELF.json` against the FROZEN
findings schema below, **even when the findings array is empty** (it will
not be empty this run — the two mandatory defects above are real and
verified). For any named sub-surface you judge genuinely clean (e.g.
"taxonomy Decided/not-findings entries are self-consistent"), add its name
to `clean_surfaces` rather than omitting it or inventing a zero-severity
finding.

**Findings schema (FROZEN):**

```json
{ "lens": "SELF",
  "clean_surfaces": ["<named sub-surface judged clean>"],
  "findings": [
    { "id": "SELF-001", "severity": "blocker|high|medium|low",
      "title": "...", "location": "file:line",
      "issue": "...", "evidence": "...", "recommendation": "..." } ] }
```

For the mandatory duplication finding (defect 1), set `location` to cite
both files, e.g.:
`.claude/commands/health-audit.md:16-56 and .gaia/cli/health/runbook.md:20-53`.

For the mandatory model-pin finding (defect 2), `location` is
`.gaia/cli/health/runbook.md:77` (add
`.gaia/cli/health/comprehensive/runbook.md:28` as a second cited location
since the same gap recurs there).

## Return

Return ONLY the thin digest: `{id, severity, title}` per finding — no
`body`, `issue`, `evidence`, or `recommendation` field. **Every material
(non-low: blocker/high/medium) finding MUST appear in the digest**; each
is verified downstream by one refuter, so an omitted material finding goes
unverified. Both mandatory defects above are material (at minimum
`medium`; assess whether repo-observed impact pushes either to `high`) and
MUST be in your returned digest. **Low** findings are capped at
`LENS_DIGEST_CAP = 25` returned lines; beyond the cap emit a single
`low: <n> more on disk` count line, with the excess low bodies staying on
disk. The material set is never truncated.

## Severity scale

- `blocker` — a real defect that must gate the release.
- `high` — a real defect, should fix before release.
- `medium` — should fix, not release-blocking on its own.
- `low` — nit; informational, not verified downstream.

## Concreteness

Present-tense. Every finding cites `file:line` (or, for the mandatory
duplication finding, both files' line ranges). A fixer must be able to act
by reading the file(s) named in `location` alone. No vague "could be
cleaner" findings — if you cannot name a file and line, it is not a
finding.
