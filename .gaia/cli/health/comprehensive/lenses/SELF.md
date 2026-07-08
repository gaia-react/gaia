---
type: lens-brief
lens: SELF
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

Audit of `/health-audit`'s own machinery. Hunt these defect classes; each
is a class to look for, not a named defect to confirm — file what you
actually find against the current repo, and an empty result is valid when
the surface is genuinely clean:

- **Command-versus-runbook duplication.** The command entry point should be
  a thin pointer to the runbook, not a restatement of it. Two
  independently-maintained copies of the same control-flow logic (the cycle
  loop, the oscillation threshold, termination/escalation steps) are a
  drift hazard: an edit to one can land without the other, and nothing
  catches the divergence. When the defect is a duplicated contract, cite
  **both** files in `location`.
- **Model-pinning gaps.** Every dispatched role should carry an explicit,
  deliberate model assignment. A role that inherits the bare "session
  model" with no pin means that layer's capability varies run to run with
  no floor — worth a finding for any role whose judgment gates the audit
  (the Orchestrator, adjudicators, challenger lenses, Fixer lanes).
- **Scope-versus-name mismatch.** Does "health audit" actually mean what
  the command name implies? A naming-clarity gap — the name suggesting
  broader coverage than the machinery delivers — is a finding; assess
  severity soberly (usually `low`/`medium`, absent evidence a maintainer
  was actually misled).
- **Surface weight.** Is the machinery proportionate to what it audits, and
  is it growing without bound? Measure the current total with
  `find .gaia/cli/health -type f \( -name '*.md' -o -name '*.sh' \) | xargs wc -l`
  and cite the number you observe; the audit auditing itself is not exempt
  from the weight concern it catches elsewhere.

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
findings schema below, **even when the findings array is empty**. For any
named sub-surface you judge genuinely clean (e.g. "taxonomy
Decided/not-findings entries are self-consistent"), add its name to
`clean_surfaces` rather than omitting it or inventing a zero-severity
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

When a finding's defect is the *relationship* between two files (e.g.
duplicated control-flow across the command and its runbook), set `location`
to cite **both** files, e.g. `fileA:16-56 and fileB:20-53`. When the same
gap recurs in a second file, cite both locations.

## Return

Return ONLY the thin digest: `{id, severity, title}` per finding — no
`body`, `issue`, `evidence`, or `recommendation` field. **Every material
(non-low: blocker/high/medium) finding MUST appear in the digest**; each
is verified downstream by one refuter, so an omitted material finding goes
unverified. **Low** findings are capped at
`LENS_DIGEST_CAP = 25` returned lines; beyond the cap emit a single
`low: <n> more on disk` count line, with the excess low bodies staying on
disk. The material set is never truncated.

## Severity scale

- `blocker` — a real defect that must gate the release.
- `high` — a real defect, should fix before release.
- `medium` — should fix, not release-blocking on its own.
- `low` — nit; informational, not verified downstream.

## Concreteness

Present-tense. Every finding cites `file:line` (or, when the defect is the
relationship between two files, both files' line ranges). A fixer must be
able to act by reading the file(s) named in `location` alone. No vague
"could be cleaner" findings — if you cannot name a file and line, it is not
a finding.
