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

### Discovery-noted real targets (audit these by name; you are guaranteed non-trivial findings here)

1. **Audit/heal/grade cluster: `/gaia-fitness` is a subset of `/health-audit`, sharing one fitness doc.**
   `.claude/commands/gaia-fitness.md:5` delegates the entire triage/heal/verify
   protocol to `wiki/decisions/Claude Integration Fitness.md`, running its own
   dedicated harness (auto-branch, unsafe-state guard, bounded heal loop).
   `.claude/commands/health-audit.md` (SELF surface, out of scope to edit, but
   its Bucket E, roughly line 50) runs the *same* seven-category protocol from
   the same wiki page as one leaf inside a larger audit. `.claude/skills/gaia/references/fitness.md:89`
   even carries a hand-maintained "mirror" of the model-assignment table from
   the wiki page, with a note "if the two ever diverge the wiki wins" —
   evidence the duplication is already a known drift risk. Two independently
   evolving harnesses wrap one shared protocol; a change validated by
   retesting only one harness (e.g. `/gaia-fitness`) is not proven safe for
   the other's different orchestration (Bucket E leaf + Fixer lane vs
   triage/heal/verify loop). Cite `.claude/commands/gaia-fitness.md:5` and
   `.claude/skills/gaia/references/fitness.md:87-89` as your FEAT-surface
   locations (the health-audit.md half belongs to SELF).

2. **The PR-merge contract is restated (not pointed-to) in roughly five places.**
   `.claude/rules/pr-merge.md` is a thin pointer to `wiki/concepts/PR Merge Workflow.md`
   (the canonical source), but several `.claude/skills/` reference docs restate
   the concrete mechanics locally instead of pointing at it alone — the
   poll-for-`MERGED` loop, the `--auto`/`--admin` choice, and the post-merge
   cleanup sequencing are typed out again and again:
   - `.claude/skills/gaia/references/debt.md:101-110`
   - `.claude/skills/gaia/references/plan.md:198,263,279`
   - `.claude/skills/gaia/references/audit.md:582-626`
   - `.claude/commands/gaia-release.md:11,120-139,171-203`
   - `.claude/skills/update-gaia/SKILL.md:649,717-735`
   - `.claude/skills/update-deps/SKILL.md:456-497`
   Each restatement is a place the mechanics can drift from the canonical
   workflow page (e.g. a `--auto` vs `--admin` distinction updated in one file
   and missed in the other five). Judge whether this rises to a finding (it
   is a real single-source-of-truth hazard) and cite the concrete file:line
   set above as evidence.

3. **Serena code-search routing is enforced in roughly three independent places.**
   `.claude/rules/serena-cc-override.md` (repo-wide prose guidance),
   `.claude/rules/code-search.md` (path-scoped prose rule, `paths:` frontmatter
   at line 2-4, restates the same Serena-over-grep guidance for a narrower
   trigger surface), and `.claude/hooks/serena-code-search-guard.sh` (runtime
   enforcement, registered twice in `.claude/settings.json` — PreToolUse
   `Bash` matcher and PreToolUse `Grep` matcher, roughly lines 175 and 204).
   Three mechanisms (two prose rules plus a hook) independently encode
   "prefer Serena for symbol work"; verify whether they agree on scope
   (`code-search.md`'s `Enforcement` section, roughly line 20, describes the
   guard's TypeScript-conservative narrowing versus the language-agnostic
   prose above it — check this self-declared gap is accurate and not stale).

4. **Inconsistent `model:` frontmatter across skills, with no stated rule.**
   `grep -n "^model:" .claude/skills/*/SKILL.md` (check the first ~6 lines of
   each) shows 9 skills pin `model: haiku` in frontmatter —
   `a11y-fixes`, `eslint-fixes`, `new-component`, `new-hook`, `new-route`,
   `new-service`, `tailwind`, `typescript`, `skeleton-loaders` — while others
   (`gaia`, `gaia-handoff`, `gaia-pickup`, `gaia-react-perf`, `gaia-wiki`,
   `playwright-cli`, `react-code`, `release-notes`, `tdd`, `update-deps`,
   `update-gaia`) have no `model:` field at all and inherit the session
   model. `.claude/agents/code-review-audit.md:4` and
   `.claude/agents/worthiness-evaluator.md:4` both pin `model: opus`. No file
   under `.claude/rules/` states when a skill should pin a model vs inherit.
   Confirm no rule exists (check `.claude/rules/` for a model-pinning
   convention) before filing; if genuinely absent, this is a real
   convention-inconsistency finding — cite the split file lists above.

5. **Fragile relative hook paths: one persisted `cd` breaks every lifecycle hook.**
   `.claude/settings.json` registers essentially every hook command as a
   bare repo-relative path (e.g. `.claude/hooks/wiki-session-start.sh`,
   `.claude/hooks/block-rm-rf.sh`, and roughly 30 more across `SessionStart`,
   `Stop`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`). These resolve
   only from the shell's current directory. `.claude/rules/shell-cwd.md`
   documents this exact fragility as the reason for its no-persistent-`cd`
   rule, but the rule is a mitigation for agent *behavior*, not a fix to the
   *registration* — the hook paths themselves stay relative and brittle.
   Judge whether this is worth a finding (a design fragility already
   partially mitigated by policy) or a `clean_surfaces` entry (if you judge
   the existing mitigation sufficient, name it explicitly rather than
   silently skipping).

6. **Worktree-hook parity gap.** In `.claude/settings.json`, `WorktreeCreate`
   (around line 66-73) invokes `bash .gaia/scripts/create-worktree.sh` — a
   bare relative path with no root derivation. `WorktreeRemove` (around line
   77-84) invokes `bash -c 'root="$(dirname "$(git rev-parse --git-common-dir)")"; exec bash "$root/.gaia/scripts/remove-worktree.sh"'`
   — it robustly derives the repo root before invoking the script. The two
   lifecycle hooks for the same feature (worktree create/remove) use
   inconsistent path-resolution strategies; if `WorktreeCreate` ever fires
   from a cwd other than the repo root, it breaks where `WorktreeRemove`
   would not. Cite `.claude/settings.json:72` vs `.claude/settings.json:83`.

7. **Several double-registered hooks whose idempotency matters.** The same
   hook script is wired to fire on more than one event/matcher in
   `.claude/settings.json`:
   - `.claude/hooks/block-manifest-write.sh` — PreToolUse `Edit|Write|MultiEdit`
     (~line 122) and PreToolUse `Bash` (~line 180)
   - `.claude/hooks/block-env-read.sh` — PreToolUse `Bash` (~line 185) and
     PreToolUse `Read` (~line 195)
   - `.claude/hooks/serena-code-search-guard.sh` — PreToolUse `Bash` (~line 175)
     and PreToolUse `Grep` (~line 204)
   - `.claude/hooks/token-tally-review.sh` — `Stop` (~line 35) and
     PostToolUse `Bash` (~line 224)
   Each registration is plausibly intentional (different tool surfaces need
   the same guard), but verify each script is idempotent / cheap to re-run
   and doesn't assume single-invocation-per-turn semantics (e.g. a counter
   that increments per registration rather than per logical event). Read the
   script bodies, not just the registrations, before filing.

## Reads first

- `.claude/settings.json` in full (hook registration, matchers, permissions)
- Survey `.claude/skills/` (one `SKILL.md` per folder; note `model:` frontmatter)
- Survey `.claude/commands/` (all files except `health-audit.md`)
- Survey `.claude/agents/` and `.claude/rules/`
- `.claude/hooks/` — at minimum, read the bodies of every hook named in
  target 7 above, plus `shell-cwd.md` for target 5's cross-reference
- Cross-check for duplicated contracts and conflicting instructions beyond
  the named targets — the list above is a floor, not a ceiling.

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
`clean_surfaces` is always present in the file (possibly empty `[]`). Given
the seven named targets above, an entirely empty `findings` array is not a
plausible outcome for this run — at minimum, verify each target and either
file it as a finding or explicitly reason why it does not rise to a finding.

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
the defect is the *relationship* between two files, both locations, as in
target 1 and target 6). A fixer must be able to act by reading one file. No
vague "could be cleaner" — name the exact drift, duplication, or conflict.
