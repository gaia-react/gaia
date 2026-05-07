---
type: runbook
status: active
audience: maintainer
---

# Health Audit Runbook

Operational protocol for the autonomous audit + auto-heal loop, invoked by `/health-audit`. Maintainer-only — release-excluded by `.gaia/release-exclude` category 10 (`.gaia/cli/health` is wholesale excluded).

## Roles

- **Attending** — top-level orchestrator. Owns the cycle loop, the circuit breakers, and the final verdict. Spawns a Nurse Team per cycle. Never fixes anything itself.
- **Nurse Manager** (per cycle) — spawns parallel Nurses, waits for reports, classifies findings, updates the taxonomy directly for non-fix cases, and either reports clean to Attending or dispatches Doctors.
- **Nurses** — fresh subagents (one per bucket A–D), each given a self-contained brief. Report structured findings.
- **Doctors** — fix agents, lane-aware so multiple run in parallel without merge conflicts.

## Cycle loop

```
For cycle in 1..3:
  spawn Nurse Manager → Nurse Team (parallel buckets A–D) → reports
  if clean (0 findings, Bucket D verdict A+ readiness): grade A+, exit
  Nurse Manager triages findings
  Attending checks fingerprints vs prior cycle → if oscillation: escalate
  Nurse Manager dispatches parallel Doctors (lane-aware)
  Doctors complete, Nurse Manager reports doctored state to Attending
  Attending shuts down the team, starts the next cycle
After cycle 3 without clean: escalate (max loops hit)
```

## Termination

- **Clean** — Nurse Team reports zero findings AND Bucket D returns "A+ readiness" (every § Distribution boundary class fully enforced, high confidence). Attending grades A+ and exits.
- **Max loops** — three cycles without a clean report. Attending escalates with the outstanding findings list.
- **Oscillation** — same finding fingerprint (`{check-id}:{file}:{line}:{match-prefix}`) appears in two consecutive Nurse reports. Escalate immediately; don't burn the third cycle.

## Circuit breakers

A Doctor dispatch pauses for human-confirm if the proposed fix:
- Touches more than 100 lines.
- Modifies `.gaia/release-exclude` (could ship maintainer files to adopters).
- Modifies `.claude/rules/` (changes session-load contract).
- Removes a check from `.gaia/release-scrub.yml` (silently weakens enforcement).
- Edits `.gaia/cli/health/taxonomy.md` "Decided / not findings" entries (claims a real class isn't real).

Human refuses → escalate.

## Model selection

| Role | Model |
|---|---|
| Attending | Sonnet |
| Nurse Manager | Sonnet |
| Bucket A (static checks) | Haiku |
| Bucket B (source greps) | Haiku |
| Bucket C (bundle simulation) | Haiku |
| Bucket D (cross-class walk) | Sonnet |
| Doctor — config-yaml-md | Sonnet |
| Doctor — source-ts | Sonnet |
| Doctor — wiki-content | Sonnet |
| Doctor — claude-surface | Sonnet |

Promote a role to Opus only on Manager flag for high-complexity fixes (cross-module refactor, tricky type inference, > 300-line change).

## Bucket A — Static checks

Reads: none.

Commands:
```bash
pnpm -C .gaia/cli typecheck
pnpm -C .gaia/cli test --run
```

Reports: typecheck pass/fail; test count (passed/total); test files (passed/total); wall-clock duration. Under 100 words.

## Bucket B — Source-tree audit greps

Reads (in order):
1. `.claude/rules/wiki-style.md` § Exceptions
2. `.gaia/cli/health/taxonomy.md` § Distribution boundary (allowlist lines)
3. `.gaia/release-scrub.yml` (path-allowlist + line-allowlist)

Greps (run all eight from repo root, pipe each through `head -50`):

1. `grep -rEn "UAT-[0-9]+|SPEC-[0-9]+" wiki/ --include="*.md" --exclude="log.md" --exclude="hot.md" --exclude-dir="meta"`
2. `grep -rEn "// .*(UAT|SPEC)-[0-9]+|/\*.*(UAT|SPEC)-[0-9]+|\*.*(UAT|SPEC)-[0-9]+" app/`
3. `grep -rEn "UAT-[0-9]{3}" .claude/skills/ .claude/commands/ .claude/agents/ .claude/rules/ .claude/hooks/ .specify/extensions/gaia/README.md .specify/extensions/gaia/commands/ .specify/extensions/gaia/lib/ .specify/extensions/gaia/rules/ .specify/extensions/gaia/templates/ .claude-tests/`
4. `grep -rEn "\bSPEC-00[1-9]\b" .claude/skills/ .claude/commands/ .claude/agents/ .claude/rules/ .claude/hooks/ .specify/extensions/gaia/README.md .specify/extensions/gaia/commands/ .specify/extensions/gaia/lib/ .specify/extensions/gaia/rules/ .specify/extensions/gaia/templates/`
5. `grep -rEn "\bchanged from|was changed|previously (did|was|stated|had|used|set)|as of [0-9]{4}|in PR #?[0-9]+|in commit [a-f0-9]{6,}" wiki/ --include="*.md" --exclude="log.md" --exclude="hot.md" --exclude-dir="meta"`
6. `grep -rEn "\.gaia/cli/src/|\.gaia/cli/test-fixtures/|\.gaia/cli/__tests__/|\.gaia/cli/health/|\.specify/extensions/gaia/test/|\.specify/specs/|\.claude-tests/|\.claude/rules/_internal/" CLAUDE.md .claude/ wiki/ .gaia/statusline/ .specify/extensions/gaia/README.md .specify/extensions/gaia/commands .specify/extensions/gaia/lib .specify/extensions/gaia/rules .specify/extensions/gaia/templates --include="*.md" --include="*.sh" --include="*.yml"`
7. `grep -rEn "(studio|website)/|\bgaia/\." .claude/ wiki/ CLAUDE.md`
8. `grep -rEn "/Users/|/home/" .claude/`

Triage rules (per match):
- Allowlisted by `.gaia/release-scrub.yml` path-allowlist or line-allowlist → skip.
- Allowlisted by `.gaia/cli/health/taxonomy.md` → skip.
- Path lives under a `.gaia/release-exclude` pattern → skip.
- Structural per `wiki-style.md` Exceptions (fixture data, identifier fragments, filename literals, illustrative `(e.g. SPEC-NNN)`) → skip.
- Gitignored (e.g. `.claude/settings.local.json`) → skip.
- Otherwise → genuine finding.

Reports: per-grep line (pattern, match count, triage breakdown). One-line verdict: "all matches accounted for" or "N genuine finding(s)". Under 400 words.

## Bucket C — Bundle simulation

Reads: none.

Commands (the `rm -rf` PreToolUse hook blocks fixed `/tmp/gaia-staging-*` paths; the timestamp suffix is required):

```bash
git ls-files > /tmp/all-tracked.txt
awk '/^[[:space:]]*#/ {next} NF==0 {next} {print}' .gaia/release-exclude \
  | sed 's|[][\\.*^$()+?{}|]|\\&|g' \
  | awk '{print "^"$0"(/|$)"}' \
  > /tmp/exclude-regex.txt
grep -vE -f /tmp/exclude-regex.txt /tmp/all-tracked.txt > /tmp/include.txt
STAGING="/tmp/gaia-vAUDIT$(date +%s)"
mkdir -p "$STAGING"
rsync -a --files-from=/tmp/include.txt . "$STAGING"/
./.gaia/cli/gaia release scrub "$STAGING"
./.gaia/cli/gaia release runtime-deps --staging "$STAGING"
find "$STAGING" -name "*.md" -exec grep -l "gaia:maintainer-only" {} \;
grep -rEn "\[\[(Release Workflow|Bundle-time Scrub|GAIA|Steven Sacks|dashboard|Entities|Meta)\]\]" "$STAGING/wiki/"
rm -rf "$STAGING"
rm /tmp/all-tracked.txt /tmp/exclude-regex.txt /tmp/include.txt
```

Reports: staged file count; `release scrub` stdout; `release runtime-deps` stdout; marker-fragment scan result (must be empty); wikilink-to-excluded scan result (must be empty). One-line verdict: "bundle clean" or "N anomalies". Under 250 words.

## Bucket D — Cross-class enforcement walk

Reads (in order):
1. `.gaia/cli/health/taxonomy.md` (focus § Distribution boundary)
2. `wiki/decisions/Bundle-time Scrub.md`
3. `.gaia/release-scrub.yml`
4. `.gaia/cli/src/release/runtime-deps.ts`
5. `.gaia/cli/src/release/manifest.ts` (note `--check`, `lintClassifierSets`)
6. `.github/workflows/release.yml`

Output: structured table — for each § Distribution boundary class, name the enforcing primitive (scrub check id, runtime-deps, manifest --check) or `none`. Confidence: high / medium / low.

Verdict:
- **A+ readiness** — every D-B class fully enforced, high confidence.
- **A** — at least one partial-enforcement note or low confidence, but no fully unenforced classes.
- **A−** — at least one D-B class is unenforced.

Under 600 words. Read-only — no commands beyond file reads.

## Doctor lanes

| Lane | Owns | Triggered by |
|---|---|---|
| **config-yaml-md** | `.gaia/release-scrub.yml`, `.gaia/cli/health/taxonomy.md`, `.gaia/cli/health/runbook.md`, `wiki/decisions/Bundle-time Scrub.md` | New scrub check; allowlist tightening; taxonomy class addition; runbook tweak |
| **source-ts** | `.gaia/cli/src/**`, `.github/workflows/release.yml`, `.gaia/cli/gaia` (rebundle) | New CLI primitive; release.yml step; bundle regeneration |
| **wiki-content** | `wiki/**/*.md` (shipped pages only — exclude `hot.md`, `log.md`, anything release-excluded) | Wiki-style or structural finding |
| **claude-surface** | `.claude/skills/**`, `.claude/commands/**`, `.claude/agents/**`, `.claude/hooks/**`, `CLAUDE.md` | Instruction-file leak |

Mutual-exclusion (must serialize, never run in parallel — single Doctor at a time across the whole team):
- Anything that runs `pnpm -C .gaia/cli bundle` (rewrites the binary).
- Anything that touches `.gaia/release-exclude`.
- Anything that touches `.gaia/manifest.json`.

If a single finding's fix straddles multiple lanes, dispatch one Doctor with multi-lane scope (sequential edits) rather than splitting across Doctors.

## Manager triage

Each finding fits one bucket:
- **real-fix** → dispatch Doctor in the appropriate lane.
- **taxonomy-update** (new genuine class) → Manager edits `.gaia/cli/health/taxonomy.md` directly: add an Issue Class entry under the right section. Then dispatch Doctor for the fix.
- **false-positive** → dispatch config-yaml-md Doctor to tighten pattern or extend allowlist with a written justification.
- **decided-not-finding** → Manager edits the "Decided / not findings" list directly (this trips a circuit breaker; pause for human-confirm before writing).

## Escalation

Attending escalates to human (returns control with structured report) on:
- N=3 cycles without a clean report.
- Oscillation (same fingerprint two consecutive cycles).
- Any circuit-breaker trip the human declines.
- Manager can't classify a finding (not in taxonomy, not allowlist, not structural).
- Doctor reports unable to fix (e.g. test failure that requires a product decision).

## State

Cycle reports live in conversation only. The audit doesn't write to `wiki/log.md` or `wiki/hot.md`.

Fingerprint format: `{check-id}:{file}:{line}:{first-40-chars-of-match-text}`. Used only for oscillation detection.

## Pointers

- **Taxonomy**: `.gaia/cli/health/taxonomy.md` — Issue classes + Decided / not findings.
- **Scrub config**: `.gaia/release-scrub.yml` — codified leak-checks with allowlists.
- **ADR**: `wiki/decisions/Bundle-time Scrub.md` — what scrub catches, what it doesn't.
- **Wiki-style rule**: `.claude/rules/wiki-style.md` — UAT/SPEC narrative-vs-structural triage.
- **Release flow**: `.github/workflows/release.yml` — step order; primitives wired in.
