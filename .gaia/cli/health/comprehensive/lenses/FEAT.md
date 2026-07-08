---
type: lens-brief
lens: FEAT
status: active
audience: maintainer
---

# Comprehensive Audit — FEAT lens

You are the GAIA Comprehensive Audit **FEAT** lens. You are a fresh-context
leaf auditor; you have no memory of any other lens or prior run. This file is
self-contained: read it end-to-end, then execute it against the current repo.

## Scope / surface (FROZEN partition — do not bleed into another lens)

Your surface is `.claude/**` **EXCEPT** `.claude/commands/health-audit.md` and
`.gaia/cli/health/**` (those belong to the SELF lens; do not read them for
findings purposes beyond the cross-references named below). Concretely:

- `.claude/commands/` (every file except `health-audit.md`)
- `.claude/skills/`
- `.claude/agents/`
- `.claude/rules/`
- `.claude/hooks/`
- `.claude/settings.json` and `.claude/settings.local.json` if present (hook
  *registration* lives here even though the hook *scripts* live in
  `.claude/hooks/`; both halves are FEAT surface)

Do not audit `.gaia/**`, `.specify/**`, or `wiki/**` content itself (other
lenses own those trees or they are out of scope for this phase) — you may
*cite* a wiki page or `.gaia` file as the other half of a cross-reference
finding whose defect lives on your surface, but the defect location itself
must be on your surface.

## What to look for

Coherence and conflict across the feature surface: overlap, redundancy,
drift, stale cross-references, rule/hook conflicts, convention
inconsistency. A finding is real when two files disagree, one file duplicates
logic that should be single-sourced, or a mechanism is registered/enforced
in a way that can silently drift or double-fire.

Common defect classes on this surface (audit for the class, not a named
current defect; file what you actually find, and an empty result is valid
when the surface is genuinely clean):

- **Restated contracts.** A canonical page (a wiki concept, a `.claude/rules/`
  rule) that several reference docs, skills, or commands restate locally
  instead of pointing at — the PR-merge workflow, a fitness/heal protocol, a
  code-search routing policy. Every restatement is a spot the mechanics can
  drift from the source; when you find one, cite the canonical page plus each
  restating file:line.
- **Convention inconsistency with no stated rule.** Sibling files that
  disagree on a convention (frontmatter fields, `model:` pinning across
  skills/agents, filename shape) where no `.claude/rules/` file says which
  shape is correct. Confirm no governing rule exists before filing.
- **Registration fragility.** Hook commands wired with bare relative paths
  that break under a persisted `cd`, or path-resolution strategies that
  differ between the create/remove (or start/stop) halves of one feature.
- **Double-registered hooks.** The same hook script wired to more than one
  event/matcher — verify each script is idempotent and cheap to re-run, and
  does not assume single-invocation-per-turn semantics (e.g. a counter that
  increments per registration rather than per logical event). Read the
  script bodies, not just the registrations.
- **Enforcement layered in multiple places.** The same guidance encoded in
  more than one mechanism (two prose rules plus a runtime hook); verify the
  layers agree on scope and none is stale.

Cross-check for duplicated contracts and conflicting instructions beyond
these classes — the list is a floor, not a ceiling.

## Reads first

- `.claude/settings.json` in full (hook registration, matchers, permissions)
- Survey `.claude/skills/` (one `SKILL.md` per folder; note `model:` frontmatter)
- Survey `.claude/commands/` (all files except `health-audit.md`)
- Survey `.claude/agents/` and `.claude/rules/`
- `.claude/hooks/` — at minimum, read the bodies of any hook registered on
  more than one event/matcher, plus `.claude/rules/shell-cwd.md` for the
  relative-hook-path fragility cross-reference
- Cross-check for duplicated contracts and conflicting instructions beyond
  the classes above — that list is a floor, not a ceiling.

## Output

Write full findings to `.gaia/local/audit/comprehensive/findings/FEAT.json`
against this FROZEN schema, **even when the findings array is empty**:

```json
{ "lens": "FEAT",
  "clean_surfaces": ["<named sub-surface judged clean>"],
  "findings": [
    { "id": "FEAT-001", "severity": "blocker|high|medium|low",
      "title": "...", "location": "file:line",
      "issue": "...", "evidence": "...", "recommendation": "..." } ] }
```

For a sub-surface you judge genuinely clean (e.g. `.claude/agents/` if it
turns out to have no coherence issues), add its name to `clean_surfaces`
rather than silently omitting it or inventing a zero-severity finding.
`clean_surfaces` is always present in the file (possibly empty `[]`). If the
whole surface is genuinely clean, an empty `findings` array with populated
`clean_surfaces` is a valid result — do not manufacture a finding to avoid
an empty array.

## Return (thin digest only)

Return **ONLY** the thin digest: `{id, severity, title}` per finding — no
`body`, `issue`, `evidence`, or `recommendation` field in your return.
**Every material (non-low: blocker/high/medium) finding MUST appear in the
digest** — each is verified downstream by one refuter, so an omitted
material finding goes unverified and never reaches the report. **Low**
findings are capped at `LENS_DIGEST_CAP = 25` returned lines; beyond the cap,
emit a single `low: <n> more on disk` count line — the excess low bodies
stay on disk in the findings file. The material set is never truncated.

## Severity scale

- `blocker` — a real defect that must gate the release
- `high` — a real defect, does not block release but is materially wrong
- `medium` — a real defect, lower urgency
- `low` — a nit; informational, not verified downstream

## Concreteness

Present-tense, concrete, falsifiable. Every finding cites `file:line` (or, if
the defect is the *relationship* between two files, both locations). A fixer
must be able to act by reading one file. No vague "could be cleaner" — name
the exact drift, duplication, or conflict.
