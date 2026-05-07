---
type: runbook
status: active
audience: maintainer
---

# Health Audit Runbook

Operational protocol for the autonomous audit + auto-heal loop, invoked by `/health-audit`. Maintainer-only — release-excluded by `.gaia/release-exclude` category 10 (`.gaia/cli/health` is wholesale excluded).

## Roles

- **Orchestrator** — top-level coordinator. Owns the cycle loop, the circuit breakers, and the final verdict. Spawns a Triager per cycle. Never fixes anything itself.
- **Triager** (per cycle) — runs the Audit Team (buckets A–D), waits for reports, classifies findings, updates the taxonomy directly for non-fix cases, and either reports clean to Orchestrator or dispatches Fixers.
- **Auditors** — bucket executors. The Triager MAY execute the four buckets directly via parallel tool calls, OR dispatch fresh `general-purpose` subagents (one per bucket). Both modes are acceptable so long as: each bucket's spec below is followed verbatim, the four buckets run in parallel (not serially), and outputs are captured as independently-checkable artifacts (stdout, file reads). The verifiable property is the artifact, not the dispatch mechanism. Prefer fresh-subagent dispatch when a bucket is expected to produce high finding volume (preserves Triager context budget) or when the human explicitly requests strict isolation (e.g. compliance audit). Auditors write raw outputs to `.gaia/local/audit/c<N>/<bucket>/` (paths specified per bucket below) and return summary + file path in their report — not raw content. The Triager reads files on demand for triage. This avoids subagent return-budget truncation in dirty cycles.
- **Fixers** — fix agents, lane-aware so multiple run in parallel without merge conflicts.

## Cycle loop

```
Orchestrator initializes .gaia/local/audit/ (archives any stale prior run)
For cycle in 1..3:
  Triager creates c<N>/ and bucket sub-dirs under .gaia/local/audit/
  spawn Triager → Triager runs Audit Team in parallel (buckets A–D) → reports
  if clean (0 findings, Bucket D verdict A+ readiness):
    Orchestrator removes .gaia/local/audit/c* (whitelisted; top-level dir kept as marker)
    grade A+, exit
  Triager classifies findings → writes c<N>/findings.json
  Orchestrator checks fingerprints vs prior cycle (mechanical diff via jq) → if oscillation: escalate (Orchestrator preserves all c*/ dirs, surfaces paths in escalation report)
  Triager dispatches parallel Fixers (lane-aware)
  Fixers complete, Triager reports post-fix state to Orchestrator
  Orchestrator shuts down the team, starts the next cycle
After cycle 3 without clean: escalate (max loops hit; Orchestrator preserves all c*/ dirs, surfaces paths in escalation report)
```

## Termination

- **Clean** — Audit Team reports zero findings AND Bucket D returns "A+ readiness" (every § Distribution boundary class fully enforced, high confidence). Orchestrator grades A+ and exits.
- **Max loops** — three cycles without a clean report. Orchestrator escalates with the outstanding findings list.
- **Oscillation** — same finding fingerprint appears in `c<N>/findings.json` AND `c<N-1>/findings.json`. Detection is mechanical: `comm -12 <(jq -r '.findings[].fingerprint' c<N-1>/findings.json | sort) <(jq -r '.findings[].fingerprint' c<N>/findings.json | sort)` — non-empty intersection means a finding survived a Fixer dispatch. Escalate immediately; don't burn the third cycle.

## Circuit breakers

A Fixer dispatch pauses for human-confirm if the proposed fix:
- Touches more than 100 lines.
- Modifies `.gaia/release-exclude` (could ship maintainer files to adopters).
- Modifies `.claude/rules/` (changes session-load contract).
- Removes a check from `.gaia/release-scrub.yml` (silently weakens enforcement).
- Edits `.gaia/cli/health/taxonomy.md` "Decided / not findings" entries (claims a real class isn't real).

Human refuses → escalate.

## Model selection

| Role | Model |
|---|---|
| Orchestrator | Sonnet |
| Triager | Sonnet |
| Bucket A (static checks) | Haiku |
| Bucket B (source greps) | Haiku |
| Bucket C (bundle simulation) | Haiku |
| Bucket D (cross-class walk) | Sonnet |
| Fixer — config-yaml-md | Sonnet |
| Fixer — source-ts | Sonnet |
| Fixer — wiki-content | Sonnet |
| Fixer — claude-surface | Sonnet |

Promote a role to Opus only on Triager flag for high-complexity fixes (cross-module refactor, tricky type inference, > 300-line change).

## Bucket A — Static checks

Reads: none.

Commands:
```bash
pnpm -C .gaia/cli typecheck
pnpm -C .gaia/cli test --run
```

Reports: typecheck pass/fail; test count (passed/total); test files (passed/total); wall-clock duration. Under 100 words.

**Outputs:** `.gaia/local/audit/c<N>/bucket-a.txt`

Crash-safety: read-only commands; no scratch state. Phase 2 redirection to `bucket-a.txt` is recoverable — partial file on crash is overwritten on cycle re-spawn.

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
6. `grep -rEn "\.gaia/cli/src/|\.gaia/cli/test-fixtures/|\.gaia/cli/__tests__/|\.gaia/cli/health/|\.specify/extensions/gaia/test/|\.specify/specs/|\.claude-tests/|\.claude/rules/_internal/" CLAUDE.md .claude/ wiki/ .gaia/statusline/ .specify/extensions/gaia/README.md .specify/extensions/gaia/commands/ .specify/extensions/gaia/lib/ .specify/extensions/gaia/rules/ .specify/extensions/gaia/templates/ --include="*.md" --include="*.sh" --include="*.yml"`
7. `grep -rEn "(studio|website)/|\bgaia/\." .claude/ wiki/ CLAUDE.md`
8. `grep -rEn "/Users/|/home/" .claude/`

**Formatting note for Grep 6**: directory targets carry a trailing `/` (e.g. `.specify/extensions/gaia/commands/`) so `--include` filters apply consistently across `grep` implementations. Do not strip the trailing slash when copy-pasting.

Triage rules (per match — apply in order; first hit wins):
- Allowlisted by `.gaia/release-scrub.yml` path-allowlist or line-allowlist → skip.
- Allowlisted by `.gaia/cli/health/taxonomy.md` → skip.
- **Path is absent from `.gaia/manifest.json` → skip.** The manifest is the authoritative list of files that ship to adopters (built from `.gaia/release-exclude`). "Absent from manifest" is the operative test for "release-excluded" — do not attempt to glob-match `.gaia/release-exclude` patterns by hand.
- Structural per `wiki-style.md` Exceptions (fixture data, identifier fragments, filename literals, illustrative `(e.g. SPEC-NNN)`) → skip.
- Gitignored (e.g. `.claude/settings.local.json`) → skip.
- Otherwise → genuine finding.

Triage decisions are written to `.gaia/local/audit/c<N>/bucket-b/triage.md` — one section per grep, listing each match and its disposition (skip / finding) with the rule that decided it.

Reports: per-grep line (pattern, match count, triage breakdown). One-line verdict: "all matches accounted for" or "N genuine finding(s)". Under 400 words.

**Outputs:** `.gaia/local/audit/c<N>/bucket-b/grep-1.txt` … `grep-8.txt`, `.gaia/local/audit/c<N>/bucket-b/triage.md`

Crash-safety: read-only commands; no scratch state. Phase 2 redirection to `bucket-b/grep-N.txt` files is recoverable — partial files on crash are overwritten on cycle re-spawn.

## Bucket C — Bundle simulation

Reads: none.

Commands. Three notes before reading the block:

1. `block-rm-rf.sh` PreToolUse hook denies any literal absolute-path token to `rm -rf`. All cleanup paths below live in variables — the hook tokenizes statically, sees the literal `"$STAGING"` / `"$ALL_TRACKED"` / etc., and lets the rm through. Do not inline `/tmp/...` paths inside the trap or anywhere else; keep them in variables.
2. Cleanup is `trap`-protected so an early non-zero exit (e.g. the wikilink `grep` returning 1 on no-match under `set -e`) cannot orphan the staging dir. The wikilink `grep` is also explicitly suffixed with `|| true` for the same reason — empty output is the success signal, exit 1 is not a failure.
3. **The `trap … EXIT` only fires when the shell that registered it exits.** This matters because the post-cleanup verification (below) must observe the *post-trap* state — i.e. cleanup must have already happened. Two ways to ensure this, pick one:
   - **Separate shell invocations** — run the trap-protected block as one shell command, then the verification as a second, independent command. The trap fires when the first shell exits, before the second starts.
   - **Subshell wrapping in a single invocation** — if you combine both into one shell call (e.g. one Bash tool call), wrap the trap-protected block in a **subshell** `(...)`, NOT a **brace group** `{...}`. A subshell forks; its EXIT fires when the subshell exits, *before* the parent reaches the verification. A brace group runs in the same shell, so the trap waits for the parent to exit — by which time the verification has already observed the pre-cleanup state and the report is wrong. Example:
     ```bash
     ( STAGING="…"; trap '…' EXIT; mkdir …; … ) ; ls -d /tmp/gaia-vAUDIT* 2>/dev/null | wc -l
     ```

```bash
STAGING="/tmp/gaia-vAUDIT$(date +%s)"
ALL_TRACKED="/tmp/gaia-audit-all.$$"
EXCLUDE_REGEX="/tmp/gaia-audit-exclude.$$"
INCLUDE="/tmp/gaia-audit-include.$$"
trap 'rm -rf "$STAGING" "$ALL_TRACKED" "$EXCLUDE_REGEX" "$INCLUDE"' EXIT
mkdir -p "$STAGING"
git ls-files > "$ALL_TRACKED"
awk '/^[[:space:]]*#/ {next} NF==0 {next} {print}' .gaia/release-exclude \
  | sed 's|[][\\.*^$()+?{}|]|\\&|g' \
  | awk '{print "^"$0"(/|$)"}' \
  > "$EXCLUDE_REGEX"
grep -vE -f "$EXCLUDE_REGEX" "$ALL_TRACKED" > "$INCLUDE"
rsync -a --files-from="$INCLUDE" . "$STAGING"/
./.gaia/cli/gaia release scrub "$STAGING"
./.gaia/cli/gaia release runtime-deps --staging "$STAGING"
find "$STAGING" -name "*.md" -exec grep -l "gaia:maintainer-only" {} \;
grep -rEn "\[\[(Release Workflow|Bundle-time Scrub|GAIA|Steven Sacks|dashboard|Entities|Meta)\]\]" "$STAGING/wiki/" || true
```

After the trap-protected block exits and cleanup fires (see note 3 above), run a one-line **post-cleanup verification** to observe the post-trap state:

```bash
ls -d /tmp/gaia-vAUDIT* 2>/dev/null | wc -l
```

Expected output: `0`. Any non-zero value indicates an orphan from this run or a prior run; investigate before grading.

Reports: staged file count; `release scrub` stdout; `release runtime-deps` stdout; marker-fragment scan result (must be empty); wikilink-to-excluded scan result (must be empty); **post-cleanup leftover-staging count (must be `0`)**. One-line verdict: "bundle clean" or "N anomalies". Under 250 words.

**Outputs:** `.gaia/local/audit/c<N>/bucket-c.txt`

Crash-safety: `trap`-protected (see commands above). Phase 2 redirection to `bucket-c.txt` is in addition to the trap; both protections are independent.

## Bucket D — Cross-class enforcement walk

Reads (in order):
1. `.gaia/cli/health/taxonomy.md` (focus § Distribution boundary)
2. `wiki/decisions/Bundle-time Scrub.md`
3. `.gaia/release-scrub.yml`
4. `.gaia/cli/src/release/runtime-deps.ts`
5. `.gaia/cli/src/release/manifest.ts`
6. `.github/workflows/release.yml`

**Key symbols to locate while reading `manifest.ts`** (load-bearing for the verdict):
- `--check` mode — staleness detection.
- `lintClassifierSets()` — cross-checks classifier sets for release-excluded paths; the enforcing primitive for the *classifier-sets* D-B class.

Output: structured table — for each § Distribution boundary class, name the enforcing primitive (scrub check id, runtime-deps, manifest --check) or `none`. Confidence: high / medium / low.

Verdict:
- **A+ readiness** — every D-B class fully enforced, high confidence. Acknowledged structural carve-outs (below) do not block A+ as long as their preconditions hold.
- **A** — at least one partial-enforcement note or low confidence, but no fully unenforced classes.
- **A−** — at least one D-B class is unenforced.

Bucket D grades enforcement-primitive completeness only. Findings volume in the current cycle does not enter the grade — a cycle with open findings can still warrant "A+ readiness" when every primitive is intact (the primitives detected the findings, after all). The Orchestrator combines this verdict with the findings count for the cycle's clean-exit determination per §Termination; do not pre-combine them inside Bucket D.

**Acknowledged structural carve-outs** (do not block A+ on their own):
- `wikilink-to-excluded` enforces only an enumerated list of release-excluded slugs in `release-scrub.yml`. A *new* release-excluded wiki page whose slug is not in the enumeration would slip through. Bucket D may grade A+ if (a) every release-excluded wiki page in the current manifest snapshot is covered by the enumeration, and (b) the ADR / scrub config explicitly notes this is enumeration-driven. If a release-excluded wiki page exists with no matching enumeration entry, downgrade to **A−** and dispatch a Fixer.

Under 600 words. Read-only — no commands beyond file reads.

**Outputs:** `.gaia/local/audit/c<N>/bucket-d.md`

Crash-safety: read-only file reads; no scratch state. Phase 2 redirection to `bucket-d.md` is recoverable — partial file on crash is overwritten on cycle re-spawn.

## Fixer lanes

| Lane | Owns | Triggered by |
|---|---|---|
| **config-yaml-md** | `.gaia/release-scrub.yml`, `.gaia/cli/health/taxonomy.md`, `.gaia/cli/health/runbook.md`, `wiki/decisions/Bundle-time Scrub.md` | New scrub check; allowlist tightening; taxonomy class addition; runbook tweak |
| **source-ts** | `.gaia/cli/src/**`, `.github/workflows/release.yml`, `.gaia/cli/gaia` (rebundle) | New CLI primitive; release.yml step; bundle regeneration |
| **wiki-content** | `wiki/**/*.md` (shipped pages only — exclude `hot.md`, `log.md`, anything release-excluded) | Wiki-style or structural finding |
| **claude-surface** | `.claude/skills/**`, `.claude/commands/**`, `.claude/agents/**`, `.claude/hooks/**`, `CLAUDE.md` | Instruction-file leak |

Mutual-exclusion (must serialize, never run in parallel — single Fixer at a time across the whole team):
- Anything that runs `pnpm -C .gaia/cli bundle` (rewrites the binary).
- Anything that touches `.gaia/release-exclude`.
- Anything that touches `.gaia/manifest.json`.

If a single finding's fix straddles multiple lanes, dispatch one Fixer with multi-lane scope (sequential edits) rather than splitting across Fixers.

## Finding classification

Each finding fits one bucket:
- **real-fix** → dispatch Fixer in the appropriate lane.
- **taxonomy-update** (new genuine class) → Triager edits `.gaia/cli/health/taxonomy.md` directly: add an Issue Class entry under the right section. Then dispatch Fixer for the fix.
- **false-positive** → dispatch config-yaml-md Fixer to tighten pattern or extend allowlist with a written justification.
- **decided-not-finding** → Triager edits the "Decided / not findings" list directly (this trips a circuit breaker; pause for human-confirm before writing).

## Escalation

Orchestrator escalates to human (returns control with structured report) on:
- N=3 cycles without a clean report.
- Oscillation (same fingerprint two consecutive cycles).
- Any circuit-breaker trip the human declines.
- Triager can't classify a finding (not in taxonomy, not allowlist, not structural).
- Fixer reports unable to fix (e.g. test failure that requires a product decision).

## Audit artifacts

Per-cycle artifacts are stored under `.gaia/local/audit/c<N>/` (`.gaia/local/` is gitignored, release-excluded, and `block-rm-rf.sh`-whitelisted for these paths).

```
.gaia/local/audit/c<N>/
  bucket-a.txt              # typecheck + test stdout
  bucket-b/
    grep-1.txt … grep-8.txt # raw per-grep stdout
    triage.md               # per-match triage decisions
  bucket-c.txt              # scrub + rdeps + post-cleanup count
  bucket-d.md               # cross-class enforcement table + verdict
  findings.json             # canonical findings list
```

`findings.json` schema:

```json
{
  "cycle": 1,
  "branch": "feat/...",
  "verdict": "A+ readiness | A | A−",
  "findings": [
    {
      "id": "c1-f001",
      "bucket": "B",
      "fingerprint": "<check-id>:<file>:<line>:<first-40-chars>",
      "lane": "wiki-content | claude-surface | source-ts | config-yaml-md",
      "action": "real-fix | taxonomy-update | false-positive | decided-not-finding"
    }
  ]
}
```

The `verdict` field stores Bucket D's verdict verbatim — it is *not* a synthesized cycle grade. It reports enforcement-primitive completeness independent of `findings.length` (see §Bucket D). The Orchestrator's clean-exit signal is `findings.length === 0 AND verdict === "A+ readiness"` per §Termination; conflating findings volume into the verdict double-counts on one side and obscures whether the enforcement machinery itself is sound.

Lifecycle:

- **At `/health-audit` start**: Orchestrator runs `[ -d .gaia/local/audit ] && mv .gaia/local/audit .gaia/local/audit.prev-$(date +%s) ; mkdir -p .gaia/local/audit`. Archives stale dirs from prior interrupted runs.
- **At cycle start**: Triager creates `c<N>/` and bucket sub-dirs.
- **Auditors**: write raw outputs to their per-cycle paths; return summary + file path in their report (not the full content).
- **Triager**: reads bucket files for triage; writes `c<N>/findings.json`.
- **Orchestrator (oscillation detection)**: mechanical diff via `jq -r '.findings[].fingerprint' .gaia/local/audit/c<N>/findings.json | sort` against the prior cycle's same. Non-empty intersection → oscillation, escalate.
- **Clean A+ exit**: Orchestrator runs `rm -rf .gaia/local/audit/c*` (whitelisted; safe). Top-level dir kept as run marker.
- **Escalation**: Orchestrator preserves all `c*/` dirs and surfaces their paths in the escalation report for human review.

## State

Cycle artifacts persist in `.gaia/local/audit/c<N>/` for the duration of the audit. On clean A+ exit, the Orchestrator removes all `c*/` dirs (`rm -rf .gaia/local/audit/c*` — whitelisted; top-level dir kept as run marker). On escalation, all `c*/` dirs are preserved and surfaced in the escalation report for human review.

The audit does not write to `wiki/log.md` or `wiki/hot.md`.

Fingerprint format: `{check-id}:{file}:{line}:{first-40-chars-of-match-text}`. Stored in `c<N>/findings.json`. Compared mechanically across cycles for oscillation detection via `jq` + `comm`.

## Pointers

- **Taxonomy**: `.gaia/cli/health/taxonomy.md` — Issue classes + Decided / not findings.
- **Scrub config**: `.gaia/release-scrub.yml` — codified leak-checks with allowlists.
- **ADR**: `wiki/decisions/Bundle-time Scrub.md` — what scrub catches, what it doesn't.
- **Wiki-style rule**: `.claude/rules/wiki-style.md` — UAT/SPEC narrative-vs-structural triage.
- **Release flow**: `.github/workflows/release.yml` — step order; primitives wired in.
