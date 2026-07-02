---
type: runbook
status: active
audience: maintainer
---

# Health Audit Runbook

Operational protocol for the autonomous audit + auto-heal loop, invoked by `/health-audit`. Maintainer-only; release-excluded by `.gaia/release-exclude` category 10 (`.gaia/cli/health` is wholesale excluded).

## Roles

Subagents are leaf nodes: a spawned subagent cannot spawn another subagent (the hard depth-1 limit, independent of its tools config). So the Orchestrator on the main thread owns every spawn; the Auditors, the Adjudicator, and the Fixers are all leaves it dispatches directly. No middle layer spawns workers.

- **Orchestrator**: top-level coordinator, runs on the main thread. Owns the cycle loop, per-cycle directory creation, spawning the Audit buckets, spawning the Adjudicator, the cross-cycle oscillation compare, the circuit breakers, spawning the Fixers, and the final verdict. Stays mechanical (counters, disk reads, `jq`/`comm`, dispatch); it never audits, adjudicates, or fixes in its own context, so session state it inherits cannot bias a grade. Never fixes anything itself.
- **Auditors**: bucket executors, one fresh `general-purpose` leaf subagent per bucket (A–E), spawned in parallel by the Orchestrator with each bucket's assigned model (see §Model selection). Each follows its bucket spec below verbatim, runs in parallel (not serially), writes raw output to disk under `.gaia/local/audit/c<N>/<bucket>/` (paths per bucket below), and returns summary + file path in its report, not raw content. The verifiable property is the artifact, not the dispatch mechanism. This avoids subagent return-budget truncation in dirty cycles. **Bucket E** is spawned the same way; its seven-category fitness protocol produces voluminous raw output, which is exactly why it is its own leaf writing JSON to disk: the Adjudicator reads that JSON, never Bucket E's raw context.
- **Adjudicator** (per cycle): a fresh `general-purpose` leaf subagent the Orchestrator spawns once the buckets return. It reads the cycle's bucket artifacts from disk, classifies findings, updates the taxonomy Issue Classes directly for non-fix cases (circuit-breaker-gated edits route back to the Orchestrator, see §Finding classification), and writes `c<N>/findings.json`. A fresh context per cycle keeps prior-cycle findings from bleeding into this cycle's verification; it never reads a prior cycle's `findings.json` (the Orchestrator owns the cross-cycle compare). It does not spawn anything and does not dispatch Fixers.
- **Fixers**: fix agents, lane-aware leaf subagents the Orchestrator spawns so multiple run in parallel without merge conflicts.

## Cycle loop

```
Orchestrator initializes .gaia/local/audit/ (archives any stale prior run)
For cycle in 1..3:
  Orchestrator creates c<N>/ and bucket sub-dirs under .gaia/local/audit/
  Orchestrator spawns the Audit buckets (A–E) as parallel leaf subagents → each writes artifacts, returns summary + path
  Orchestrator spawns a fresh Adjudicator leaf → it reads the c<N> bucket artifacts, classifies, writes c<N>/findings.json → reports
  if clean (no open findings, Bucket D verdict A+ readiness, effective shared-fitness grade = A+; see §Termination):
    if the challenger has not run yet this run (at-most-once flag, see §False-clean challenger):
      Orchestrator spawns the false-clean challenger lenses as parallel leaf subagents; mark the challenger as run
      if any lens returns a substantiated finding (clean verdict REVOKED):
        Orchestrator injects it into c<N>/findings.json (action: real-fix, bucket: challenger, lane, fingerprint)
        if cycle == 3: escalate with reason false-clean-refuted (preserve all c*/ dirs, surface paths), exit   # no next cycle to fix-and-reverify
        else: skip the clean exit; fall through to the oscillation check + Fixer dispatch below (the injected real-fix lands next cycle)
    if still clean (challenger cleared, or already ran this run):
      Orchestrator removes .gaia/local/audit/c* (whitelisted; top-level dir kept as marker)
      report the honest overall grade (A+ when no findings of any kind, else the floor that non-blocking residuals may cap at A), exit
  Orchestrator checks open-finding fingerprints vs prior cycle (mechanical diff via jq; non-blocking residuals excluded, see §Termination) → if oscillation: escalate (Orchestrator preserves all c*/ dirs, surfaces paths in escalation report)
  Orchestrator spawns parallel Fixers (lane-aware leaf subagents)
  Fixers complete and report post-fix state to Orchestrator
  Orchestrator starts the next cycle
After cycle 3 without clean: escalate (max loops hit; Orchestrator preserves all c*/ dirs, surfaces paths in escalation report)
```

## Termination

**Non-blocking residuals.** A finding that matches an existing entry on a "Decided / not findings" list (`.gaia/cli/health/taxonomy.md` or the fitness spec's "Decided / not findings" section) is a **non-blocking residual** (`action: decided-not-finding`): recorded in `findings.json` for the artifact, but it does **not** count toward the clean-exit gate, it is exempt from the effective-shared-fitness test below, and it is excluded from the oscillation guard. The canonical case is the post-sync `wiki/.state.json` drift. `gaia wiki state` counts the wiki-sync commit itself, so drift is permanently ≥1 in steady state, surfaced as an `info` the fitness spec marks "do not escalate to a blocking finding." Without this carve-out the clean-A+ gate is unreachable in normal operation, and recall-oriented auditors re-surface the same decided non-findings every cycle, forcing a false oscillation escalation. An **open** finding, by contrast, is an unresolved `action: real-fix`. A `false-positive` that cannot be suppressed escalates via the _fixer-unable-to-fix_ trigger (not oscillation), or is reclassified `decided-not-finding` if genuinely acceptable.

**Effective shared-fitness grade.** For the clean-exit gate _only_, a Bucket E category that sits below A+ _solely_ because of non-blocking residual `info` findings counts as A+. The reported `shared_fitness_grade` stays honest: it may be A. A category held below A+ by any `warning`/`error`, or by `info` not on a "Decided / not findings" list, is **not** exempt.

- **Clean**: no open findings remain AND Bucket D returns "A+ readiness" AND the _effective_ shared-fitness grade = A+. A clean Adjudicator report is necessary but no longer sufficient on its own: the terminal (first) clean cycle's verdict must also survive the false-clean challenger (see §False-clean challenger) before the clean exit fires. Orchestrator computes the reported overall grade as the F-to-A+ floor of: Bucket D verdict (A+/A/A−), the open-findings-count signal (zero open findings → A+; else degrade per wiki page rubric applied to open maintainer findings), and Bucket E's honest `shared_fitness_grade`. A clean run is **not necessarily A+**: it is the honest floor with no open work left, and non-blocking residual `info` findings legitimately cap it at A. Exit with the overall grade and the Bucket E sub-grade in the report.
- **Max loops**: three cycles without a clean report. Orchestrator escalates with the outstanding open findings list and the overall grade.
- **Oscillation**: same _open_-finding fingerprint appears in `c<N>/findings.json` AND `c<N-1>/findings.json`. Detection is mechanical: `comm -12 <(jq -r '.findings[] | select(.action=="real-fix") | .fingerprint' c<N-1>/findings.json | sort) <(jq -r '.findings[] | select(.action=="real-fix") | .fingerprint' c<N>/findings.json | sort)`. A non-empty intersection means an open finding survived a Fixer dispatch. Escalate immediately; don't burn the third cycle. Non-blocking residuals (`decided-not-finding`) recur by design and are excluded from the guard so they never trigger a false escalation.
- **False-clean refuted**: the false-clean challenger substantiates a finding on the terminal clean cycle (see §False-clean challenger). On a non-cycle-3 clean cycle the finding is injected as `action: real-fix` and the loop continues (fix + next-cycle reverify), so it is not an escalation. On cycle 3 there is no next cycle to fix-and-reverify, so the Orchestrator escalates with reason `false-clean-refuted` and preserves all `c*/` dirs.

**Verdict widening note.** The overall verdict is F-to-A+, computed as the floor of all buckets. It is never higher than Bucket E's `shared_fitness_grade`. Both the overall grade and the shared-fitness sub-grade appear in all report templates (clean exit and escalation).

## Circuit breakers

A Fixer dispatch pauses for human-confirm if the proposed fix:

- Touches more than 100 lines.
- Modifies `.gaia/release-exclude` (could ship maintainer files to adopters).
- Modifies `.claude/rules/` (changes session-load contract).
- Removes a check from `.gaia/release-scrub.yml` (silently weakens enforcement).
- Edits `.gaia/cli/health/taxonomy.md` "Decided / not findings" entries (claims a real class isn't real).
- Edits `wiki/decisions/Claude Integration Fitness.md` "Decided / not findings" section (claims a real fitness class isn't real; same risk, shared page).

Human refuses → escalate.

**No challenger-specific breaker.** A false-clean-challenger finding is injected as a normal `action: real-fix` and dispatched through the existing Fixer lanes, so it is gated by exactly the breakers above; the challenger introduces no new breaker. A reader should not expect one.

## Model selection

| Role                                                                                                              | Model  |
| ----------------------------------------------------------------------------------------------------------------- | ------ |
| Orchestrator                                                                                                      | main thread (session model) |
| Adjudicator                                                                                                      | Sonnet |
| Bucket A (static checks)                                                                                          | Haiku  |
| Bucket B (source greps)                                                                                           | Haiku  |
| Bucket C (bundle simulation)                                                                                      | Haiku  |
| Bucket D (cross-class walk)                                                                                       | Sonnet |
| Bucket E: Auditor (mechanical: hook integrity, settings hygiene, GAIA-install fitness, wiki fitness)              | Haiku  |
| Bucket E: Auditor (judgment: skill/command/agent frontmatter, rule hygiene, `CLAUDE.md` hygiene, grade synthesis) | Sonnet |
| Challenger lens: BS (blind-spot)                                                                                  | Sonnet |
| Challenger lens: MC (misclassification)                                                                           | Sonnet |
| Challenger lens: GH (grade-honesty)                                                                               | Sonnet |
| Challenger lens: FV (fix-verification, deep/optional)                                                             | Sonnet |
| Fixer: config-yaml-md                                                                                             | Sonnet |
| Fixer: source-ts                                                                                                  | Sonnet |
| Fixer: wiki-content                                                                                               | Sonnet |
| Fixer: claude-surface                                                                                             | Sonnet |

Promote a role to Opus only on Adjudicator flag for high-complexity fixes (cross-module refactor, tricky type inference, > 300-line change): the Adjudicator records the flag in `findings.json` and the Orchestrator spawns that Fixer with `model: opus`.

Bucket E model assignments follow the wiki page's spec: mechanical category checks (file-exists, JSON parse, hash-diff, `gaia wiki` invocations) on Haiku; judgment-bearing checks (frontmatter substantiveness, content-vs-glob coherence, size evaluation) and grade synthesis on Sonnet. See `wiki/decisions/Claude Integration Fitness.md` §Triage phase for the per-category model table.

The four challenger lenses (BS/MC/GH/FV) are judgment-bearing adversarial passes, so they pin to Sonnet, mirroring the judgment-bearing buckets and the Adjudicator.

## Bucket A: Static checks

Reads: none.

Commands:

```bash
pnpm -C .gaia/cli typecheck
pnpm -C .gaia/cli test --run
```

Reports: typecheck pass/fail; test count (passed/total); test files (passed/total); wall-clock duration. Under 100 words.

**Outputs:** `.gaia/local/audit/c<N>/bucket-a.txt`

Crash-safety: read-only commands; no scratch state. Phase 2 redirection to `bucket-a.txt` is recoverable; partial file on crash is overwritten on cycle re-spawn.

## Bucket B: Source-tree audit greps

Detects distribution-boundary leaks in adopter-shipped files via the two path/monorepo greps below. The former greps 1–5 no longer run as Bucket B greps, and they did not all land in one place: the `/Users|/home` absolute-path literal check (formerly grep 8) moved to Bucket E's `CLAUDE.md` hygiene category (its dead-path + absolute-path grep); the UAT-NNN and concrete-SPEC-ID leak checks for shipped instruction surfaces are codified in the bundle-time scrub (`uat-narrative`, `spec-concrete-ids` in `.gaia/release-scrub.yml`) and proven by Bucket C's scrub simulation; and the historical-phrasing / UAT-SPEC narrative-prose checks live in `.claude/rules/wiki-style.md`, enforced by `gaia wiki lint` (lint check #13), which no mandatory audit bucket invokes. Only the two distribution-boundary path greps remain here.

Reads (in order):

1. `.gaia/cli/health/taxonomy.md` § Distribution boundary (allowlist lines)
2. `.gaia/release-scrub.yml` (path-allowlist + line-allowlist)

Greps (run both from repo root with `git grep`, no line cap): `git grep` searches tracked files only, so gitignored paths (`.claude/worktrees/`, `.gaia/local/`, and other per-machine scratch) are excluded by construction, and every match is examined. Do **not** pipe through `head` or any other truncating filter: a capped sample can exhaust its budget on one noisy tree and leave shipped surfaces unread, which is precisely the blind spot a distribution-boundary audit cannot afford.

1. `git grep -nE "\.gaia/cli/src/|\.gaia/cli/test-fixtures/|\.gaia/cli/__tests__/|\.gaia/cli/health/|\.specify/extensions/gaia/test/|\.specify/specs/|\.gaia/tests/|\.gaia/scripts/tests/|\.github/audit/tests/|\.claude/rules/_internal/" -- CLAUDE.md .claude/ wiki/ .gaia/statusline/ .specify/extensions/gaia/README.md .specify/extensions/gaia/commands/ .specify/extensions/gaia/lib/ .specify/extensions/gaia/rules/ .specify/extensions/gaia/templates/`
2. `git grep -nE "(studio|website)/|\bgaia/\." -- .claude/ wiki/ CLAUDE.md`

**Formatting note for Grep 1**: directory targets carry a trailing `/` (e.g. `.specify/extensions/gaia/commands/`) so each pathspec resolves to everything beneath that directory. Do not strip the trailing slash when copy-pasting. `git grep` skips binary files automatically, so no `--include` extension filter is needed; the trade is that it scans every tracked text file under a target (not only `*.md|*.sh|*.yml`), which strictly widens leak coverage.

Triage rules (per match; apply in order; first hit wins):

- Allowlisted by `.gaia/release-scrub.yml` path-allowlist or line-allowlist → skip.
- Allowlisted by `.gaia/cli/health/taxonomy.md` → skip.
- **Path is absent from `.gaia/manifest.json` → skip.** The manifest is the authoritative list of files that ship to adopters (built from `.gaia/release-exclude`). "Absent from manifest" is the operative test for "release-excluded"; do not attempt to glob-match `.gaia/release-exclude` patterns by hand.
- **Maintainer-path match (Grep 1) inside a _balanced_ `<!-- gaia:maintainer-only:start -->` / `<!-- gaia:maintainer-only:end -->` block, in a marker-strip-scoped markdown file (`wiki/**/*.md`, `.claude/**/*.md`, `.specify/extensions/gaia/**/*.md` per `.gaia/release-scrub.yml`) → skip.** The bundle-time scrub's `marker-strip` transform deletes the whole block from the staging tree before the tarball is built, so the reference does not ship even though its containing file does. The match must sit between a start marker and a following end marker (start before end, both present); an orphaned or unbalanced marker does not strip, so it stays a candidate. Bucket C (bundle simulation) is the marker-aware authority that proves the strip end-to-end; this rule lets Bucket B's marker-unaware grep stop re-flagging correctly wrapped refs as genuine.
- Gitignored (e.g. `.claude/settings.local.json`) → skip.
- Otherwise → genuine finding.

Triage decisions are written to `.gaia/local/audit/c<N>/bucket-b/triage.md`; one section per grep, listing each match and its disposition (skip / finding) with the rule that decided it.

Reports: per-grep line (pattern, match count, triage breakdown). One-line verdict: "all matches accounted for" or "N genuine finding(s)". Under 400 words.

**Outputs:** `.gaia/local/audit/c<N>/bucket-b/grep-1.txt`, `grep-2.txt`, `.gaia/local/audit/c<N>/bucket-b/triage.md`

Crash-safety: read-only commands; no scratch state. Phase 2 redirection to `bucket-b/grep-N.txt` files is recoverable; partial files on crash are overwritten on cycle re-spawn.

## Bucket C: Bundle simulation

Reads: none.

Commands. Three notes before reading the block:

1. `block-rm-rf.sh` PreToolUse hook denies any literal absolute-path token to `rm -rf`. All cleanup paths below live in variables; the hook tokenizes statically, sees the literal `"$STAGING"` / `"$ALL_TRACKED"` / etc., and lets the rm through. Do not inline `/tmp/...` paths inside the trap or anywhere else; keep them in variables.
2. Cleanup is `trap`-protected so an early non-zero exit (e.g. `release scrub` returning 1 when it reports a leak under `set -e`) cannot orphan the staging dir. Empty leak output is the success signal; a non-zero scrub exit is the build-failure path it is meant to surface, not a harness error.
3. **The `trap … EXIT` only fires when the shell that registered it exits.** This matters because the post-cleanup verification (below) must observe the _post-trap_ state; i.e. cleanup must have already happened. Two ways to ensure this, pick one:
   - **Separate shell invocations**: run the trap-protected block as one shell command, then the verification as a second, independent command. The trap fires when the first shell exits, before the second starts.
   - **Subshell wrapping in a single invocation**: if you combine both into one shell call (e.g. one Bash tool call), wrap the trap-protected block in a **subshell** `(...)`, NOT a **brace group** `{...}`. A subshell forks; its EXIT fires when the subshell exits, _before_ the parent reaches the verification. A brace group runs in the same shell, so the trap waits for the parent to exit; by which time the verification has already observed the pre-cleanup state and the report is wrong. Example:
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
./.gaia/cli/gaia-maintainer release scrub "$STAGING"
./.gaia/cli/gaia-maintainer release runtime-deps --staging "$STAGING"
find "$STAGING" -name "*.md" -exec grep -l "gaia:maintainer-only" {} \;
# wikilink-to-excluded is enforced by `release scrub` above: it derives the
# excluded-slug set from `.gaia/release-exclude` at scan time, so it needs no
# separate grep here (a hardcoded slug alternation would only reintroduce the
# drift the derived check removes). Read its result from the scrub stdout.
```

After the trap-protected block exits and cleanup fires (see note 3 above), run a one-line **post-cleanup verification** to observe the post-trap state:

```bash
ls -d /tmp/gaia-vAUDIT* 2>/dev/null | wc -l
```

Expected output: `0`. Any non-zero value indicates an orphan from this run or a prior run; investigate before grading.

Reports: staged file count; `release scrub` stdout; `release runtime-deps` stdout; marker-fragment scan result (must be empty); wikilink-to-excluded result (from the `release scrub` stdout; must be empty); **post-cleanup leftover-staging count (must be `0`)**. One-line verdict: "bundle clean" or "N anomalies". Under 250 words.

**Outputs:** `.gaia/local/audit/c<N>/bucket-c.txt`

Crash-safety: `trap`-protected (see commands above). Phase 2 redirection to `bucket-c.txt` is in addition to the trap; both protections are independent.

## Bucket D: Cross-class enforcement walk

Reads (in order):

1. `.gaia/cli/health/taxonomy.md` (focus § Distribution boundary)
2. `wiki/decisions/Bundle-time Scrub.md`
3. `.gaia/release-scrub.yml`
4. `.gaia/cli/src/release/runtime-deps.ts`
5. `.gaia/cli/src/release/manifest.ts`
6. `.github/workflows/release.yml`

**Key symbols to locate while reading `manifest.ts`** (load-bearing for the verdict):

- `--check` mode; staleness detection.
- `lintClassifierSets()`; cross-checks classifier sets for release-excluded paths; the enforcing primitive for the _classifier-sets_ D-B class.

Output: structured table; for each § Distribution boundary class, name the enforcing primitive (scrub check id, runtime-deps, manifest --check) or `none`. Confidence: high / medium / low.

Verdict:

- **A+ readiness**: every D-B class fully enforced, high confidence.
- **A**: at least one partial-enforcement note or low confidence, but no fully unenforced classes.
- **A−**: at least one D-B class is unenforced.

Bucket D grades enforcement-primitive completeness only. Findings volume in the current cycle does not enter the grade; a cycle with open findings can still warrant "A+ readiness" when every primitive is intact (the primitives detected the findings, after all). The Orchestrator combines this verdict with the findings count for the cycle's clean-exit determination per §Termination; do not pre-combine them inside Bucket D.

**No acknowledged structural carve-outs.** `wikilink-to-excluded` derives its excluded-slug set from `.gaia/release-exclude` at scan time (every `.md` exclude plus a walk of every bare-directory exclude), so a newly excluded wiki page is covered with no config edit. Grade this class fully enforced; there is no enumeration to audit for coverage gaps, and the "new excluded page with no matching enumeration entry → A−" downgrade no longer applies. If a future check reintroduces a hand-maintained list whose drift Bucket D must police, record the carve-out here.

Under 600 words. Read-only; no commands beyond file reads.

**Outputs:** `.gaia/local/audit/c<N>/bucket-d.md`

Crash-safety: read-only file reads; no scratch state. Phase 2 redirection to `bucket-d.md` is recoverable; partial file on crash is overwritten on cycle re-spawn.

## Bucket E: Shared Claude-integration fitness

Reads: `wiki/decisions/Claude Integration Fitness.md` (the protocol spec).

**This bucket runs the triage phase of the protocol defined in `wiki/decisions/Claude Integration Fitness.md` over the seven fitness categories.** Do not re-specify the check taxonomy, grading rubric, or Fixer lanes here; reference the page and run it. Any drift from the wiki page's spec is the failure mode this indirection prevents.

The wiki page defines:

- The seven categories (hook integrity; skill/command/agent frontmatter; rule hygiene; `CLAUDE.md` hygiene; settings hygiene; GAIA-install fitness; wiki fitness).
- Per-category Auditor model assignments (mechanical on Haiku; judgment on Sonnet); see the wiki page's Triage phase table.
- The Fixer lanes; fitness findings route to the **existing `claude-surface` lane** (`.claude/skills/**`, `.claude/commands/**`, `.claude/agents/**`, `.claude/hooks/**`, `CLAUDE.md`, `.claude/rules/**`) plus the `settings`, `gitignore`, and `manifest` lanes as defined in the wiki page's Heal phase.
- The F-to-A+ per-category grading rubric (every band; including `A−` and `C−`; reachable; `shared_fitness_grade` may be any of them).
- The bounded loop (default 3 cycles) with oscillation detection; which the wiki page's own "Composed inside a deeper loop" note hands off to the outer harness when this protocol runs as a bucket. See the loop-nesting rule below.

**Loop nesting.** Bucket E does not run the wiki page's bounded heal loop. The outer `/health-audit` cycle loop _is_ that loop: each outer cycle, Bucket E runs the wiki page's triage phase once (audit the seven categories, grade) and writes its per-category findings JSON plus a `shared_fitness_grade` (F-to-A+, the floor of the seven category grades) to disk; it does not heal or verify on its own. The Adjudicator folds Bucket E's findings into `c<N>/findings.json` alongside the other buckets' findings, so fitness fingerprints participate in the **outer** oscillation guard (no separate inner guard), and tags the fitness fixes for the `claude-surface` Fixer lane (or `settings`/`gitignore`/`manifest` as appropriate); the Orchestrator dispatches them in the outer heal phase. The verify step for a cycle's fitness fixes is the next outer cycle's fresh Bucket E run. No new Fixer lane is introduced, and there is no inner cycle count to tune; the outer `1..3` bound covers fitness too.

**Outputs:** `.gaia/local/audit/c<N>/bucket-e/`; per-category findings JSON and the per-category + overall fitness grade report, following the same structure as the wiki page's Findings Schema.

```
.gaia/local/audit/c<N>/bucket-e/
  category-grades.json        # per-category grade + finding count
  shared_fitness_grade.txt    # single letter grade (floor of seven)
  findings/
    hook-integrity.json
    frontmatter.json
    rule-hygiene.json
    claude-md-hygiene.json
    settings-hygiene.json
    gaia-install-fitness.json
    wiki-fitness.json
```

Crash-safety: Bucket E writes incrementally per category; a crash mid-run leaves partial output. The Adjudicator treats a missing `shared_fitness_grade.txt` as Bucket E incomplete; the Orchestrator re-spawns Bucket E on the next cycle (the outer loop handles this).

## Fixer lanes

| Lane               | Owns                                                                                                                            | Triggered by                                                                  |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| **config-yaml-md** | `.gaia/release-scrub.yml`, `.gaia/cli/health/taxonomy.md`, `.gaia/cli/health/runbook.md`, `wiki/decisions/Bundle-time Scrub.md` | New scrub check: allowlist tightening; taxonomy class addition; runbook tweak |
| **source-ts**      | `.gaia/cli/src/**`, `.github/workflows/release.yml`, `.gaia/cli/gaia` (rebundle)                                                | New CLI primitive: release.yml step; bundle regeneration                      |
| **wiki-content**   | `wiki/**/*.md` (shipped pages only; exclude `hot.md`, `log.md`, anything release-excluded)                                      | Wiki-style or structural finding                                              |
| **claude-surface** | `.claude/skills/**`, `.claude/commands/**`, `.claude/agents/**`, `.claude/hooks/**`, `CLAUDE.md`, `.claude/rules/**`            | Instruction-file leak: fitness findings from Bucket E                         |

Mutual-exclusion (must serialize, never run in parallel; single Fixer at a time across the whole team):

- Anything that runs `pnpm -C .gaia/cli bundle` (rewrites the binary).
- Anything that touches `.gaia/release-exclude`.
- Anything that touches `.gaia/manifest.json`.

If a single finding's fix straddles multiple lanes, dispatch one Fixer with multi-lane scope (sequential edits) rather than splitting across Fixers.

## Finding classification

The Adjudicator assigns each finding one action and records it in `findings.json`; the Orchestrator executes the action (dispatching Fixers, gating circuit breakers, applying breaker-gated edits). Each finding fits one action:

- **real-fix** → the Orchestrator dispatches a Fixer in the appropriate lane.
- **taxonomy-update** (new genuine class) → the Adjudicator adds an Issue Class entry under the right section of `.gaia/cli/health/taxonomy.md` (this section is not circuit-breaker-gated). The Orchestrator then dispatches a Fixer for the fix.
- **false-positive** → the Orchestrator dispatches a config-yaml-md Fixer to tighten the pattern or extend the allowlist with a written justification.
- **decided-not-finding** → the finding matches a "Decided / not findings" entry (in `.gaia/cli/health/taxonomy.md` or the fitness spec). **If the entry already exists**, the Adjudicator records the match and moves on (no edit, no circuit breaker); it becomes a non-blocking residual (see §Termination), retained in `findings.json` but excluded from the clean gate and the oscillation guard. **If it is a new not-a-finding class**, the Adjudicator records the proposed entry in `findings.json` rather than writing it (a leaf subagent cannot pause for human-confirm). The Orchestrator gates it on the circuit breaker, gets human-confirm, and writes the entry, after which it is likewise a non-blocking residual.

## False-clean challenger

The cycle loop is adversarial against the product (five buckets, a fresh per-cycle Adjudicator, cross-cycle oscillation detection), but nothing challenges its own terminal CLEAN verdict. A false-clean (a blind spot shared by every bucket, the Adjudicator dismissing a real finding as a `decided-not-finding`, or an over-graded category) exits A+ and then deletes the per-cycle `c*/` evidence, and oscillation cannot catch it: a clean exit has zero open findings and no next cycle to intersect against.

The challenger is a single adversarial pass the Orchestrator spawns at the clean-exit boundary, AFTER a cycle produces a clean `findings.json` but BEFORE the `c*/` deletion and the A+ report. A substantiated finding from any lens REVOKES the clean exit.

**Intentional divergences from the canonical adversarial-audit pattern** (`.claude/skills/gaia/references/spec.md` step 7, `.claude/skills/gaia/references/plan.md` step 4.6); these are deliberate, do not "fix" them back toward that shape:

1. **No interactive gate.** The loop is autonomous, so the challenger runs UNCONDITIONALLY on the terminal clean cycle. There is no recommended-but-optional prompt.
2. **No refutation pass.** Challenger findings are binary and checkable (a defect exists at a file + pattern or it does not; a near-match matches a Decided entry or it does not), exactly like the plan-decomposition audit, so there is no severity-debate refutation round.
3. **Revokes the clean exit** rather than folding a fix into an editable artifact: a substantiated finding is injected into `findings.json` as `action: real-fix` and the run continues into the normal Fixer → next-cycle machinery.

**At most once per run.** The Orchestrator tracks a per-run boolean (the challenger has run). The challenger fires on the FIRST cycle that meets the clean gate and sets the flag. If it clears, the genuine clean exit proceeds. If it revokes the exit and budget remains, the run continues; a LATER clean exit then proceeds WITHOUT re-challenging. The backstop for a miss the single shot does not catch is the fresh Adjudicator plus the fact that a true miss resurfaces on the next `/health-audit` run.

**Depth-1.** Only the Orchestrator (main thread) spawns leaves; the challenger lenses are Orchestrator-spawned `general-purpose` leaf subagents, consistent with the buckets, the Adjudicator, and the Fixers. No leaf spawns the challenger.

### Lenses

Each lens is a parallel `general-purpose` leaf the Orchestrator spawns, handed: the terminal cycle's bucket artifacts (`.gaia/local/audit/c<N>/bucket-a.txt`, `bucket-b/`, `bucket-c.txt`, `bucket-d.md`, `bucket-e/`), `.gaia/local/audit/c<N>/findings.json`, and BOTH "Decided / not findings" lists (`.gaia/cli/health/taxonomy.md` § Decided / not findings and `wiki/decisions/Claude Integration Fitness.md` § Decided / not findings) so it does not re-surface settled items. Each returns only the findings JSON (the canonical schema, see §Audit artifacts), no narrative.

- **Blind-spot (id prefix `BS`).** Always runs. Assume a real defect exists that EVERY bucket missed. Attack the UNION of the five bucket scopes (static checks, source greps, bundle simulation, cross-class enforcement walk, the seven fitness categories) and produce the concrete file + pattern that no bucket grep covers. A concrete uncovered file + pattern is a finding.
- **Misclassification (id prefix `MC`).** Always runs. For each `decided-not-finding` and `false-positive` in `findings.json`, verify it TRULY matches a taxonomy or fitness "Decided" entry, not a stretched near-match; cite the matched entry's line. A `decided-not-finding` that does not actually match its claimed Decided entry (a real finding dismissed as settled) is a finding.
- **Grade-honesty (id prefix `GH`).** Always runs. Re-verify Bucket D's "A+ readiness" against each enforcing primitive (scrub check id, runtime-deps, manifest `--check`), and verify the effective-shared-fitness-A+ promotion legitimately applies the residual carve-out (a Bucket E category below A+ SOLELY because of non-blocking residual `info` on a Decided list) rather than masking a `warning`/`error` or an `info` NOT on a Decided list. A grade promoted on a false premise is a finding.
- **Fix-verification (id prefix `FV`, deep/optional).** Independently re-run the prior cycles' fixed-finding detection against the working tree instead of trusting Fixer self-reports. A prior finding a Fixer reported fixed but that still reproduces is a finding. **Deterministic gate:** include FV in the fan-out only when any prior cycle in this run dispatched a Fixer (there are applied fixes to verify); skip it on a run that reached clean with zero fixes applied (nothing to verify). FV is the lens that covers a failed fix, including a failed fix of an earlier challenger-injected finding.

**Shared preamble** (mirrors the canonical adversarial preamble; interpolate `<C_DIR>` = `.gaia/local/audit/c<N>` and `<repo_root>` = `$PWD`):

> You are an ADVERSARIAL challenger of a GAIA health-audit's TERMINAL CLEAN verdict. The cycle artifacts are in `<C_DIR>`; repo root is `<repo_root>`. Read the bucket artifacts and `findings.json` first, and read the two "Decided / not findings" lists so you do not re-surface settled items. The loop is about to report A+ and delete the evidence. Your job is to find the reason that verdict is FALSE, not to confirm it. Cite evidence as `file:line`. Be concrete and falsifiable: a defect a fixer can act on by reading one file is a good finding, a vague "could be cleaner" is not.
>
> - Severity: `blocker` = the clean verdict is factually wrong (a real defect ships); `high` = a real finding the buckets or Adjudicator missed or misclassified; `medium` = should fix; `low` = nit.
> - Give each finding a stable id prefixed with your lens code (`BS`, `MC`, `GH`, or `FV`).

### Routing: a substantiated finding revokes the clean exit

A substantiated finding (any lens) revokes the clean exit. The Orchestrator injects it into `c<N>/findings.json` as a finding with `action: "real-fix"`, `bucket: "challenger"`, a `lane` chosen from the file it targets, and a `fingerprint` in the `<check-id>:<file>:<line>:<first-40-chars>` format. Then:

- **Clean cycle is NOT cycle 3** (budget remains): continue into the normal Fixer → next-cycle machinery. The Orchestrator dispatches Fixers for the injected finding and starts the next cycle. The injected finding participates in the standard oscillation guard (which keys on `action == "real-fix"` fingerprints, bucket-agnostic). A Fixer that reports unable to fix triggers the existing `fixer-unable-to-fix` escalation.
- **Clean cycle IS cycle 3** (no next cycle to fix-and-reverify): do NOT inject-and-continue (there is nowhere for the fix to land). Escalate with reason `false-clean-refuted` and PRESERVE all `c*/` dirs (skip the clean-exit `rm -rf .gaia/local/audit/c*`).

**Oscillation coverage (design note).** A `BS` blind-spot finding is by definition NOT re-detected by the buckets on the next cycle, so the bucket-sourced oscillation guard does not cover a failed fix of a `BS` finding. The concrete protections for a failed challenger fix are: the `fixer-unable-to-fix` escalation (immediate, when a Fixer reports it cannot fix), the cycle-3 `false-clean-refuted` escalation (the terminal backstop), the optional deep `FV` lens (re-detects failed fixes directly), and resurfacing on the next `/health-audit` run. The general oscillation guard covers only the subset of findings the buckets can re-detect; it does not on its own protect a blind-spot finding.

**Never-block fallback.** The Orchestrator spawns the challenger, so the fan-out exists by construction. If it is nonetheless unavailable (a restricted context that cannot spawn leaves), SKIP the challenger, note the skip in the report, and rely on the fresh Adjudicator plus next-run resurfacing. NEVER block the clean exit on the challenger's unavailability.

## Escalation

Orchestrator escalates to human (returns control with structured report) on:

- N=3 cycles without a clean report.
- Oscillation (same fingerprint two consecutive cycles).
- Any circuit-breaker trip the human declines.
- Adjudicator can't classify a finding (not in taxonomy, not allowlist, not structural).
- Fixer reports unable to fix (e.g. test failure that requires a product decision).
- False-clean challenger substantiates a finding on the cycle-3 clean cycle (reason `false-clean-refuted`; see §False-clean challenger). On a non-cycle-3 clean cycle the same finding is injected as `real-fix` and the loop continues instead of escalating.

## Audit artifacts

Per-cycle artifacts are stored under `.gaia/local/audit/c<N>/` (`.gaia/local/` is gitignored, release-excluded, and `block-rm-rf.sh`-whitelisted for these paths).

```
.gaia/local/audit/c<N>/
  bucket-a.txt              # typecheck + test stdout
  bucket-b/
    grep-1.txt grep-2.txt   # raw per-grep stdout (distribution-boundary greps)
    triage.md               # per-match triage decisions
  bucket-c.txt              # scrub + rdeps + post-cleanup count
  bucket-d.md               # cross-class enforcement table + verdict
  bucket-e/
    category-grades.json    # per-category grade + finding count
    shared_fitness_grade.txt # floor of seven category grades (F-to-A+)
    findings/               # per-category findings JSON
  findings.json             # canonical findings list (includes shared_fitness_grade, overall_grade)
```

`findings.json` schema:

```json
{
  "cycle": 1,
  "branch": "feat/...",
  "verdict": "A+ readiness | A | A−",
  "shared_fitness_grade": "A+ | A | A− | B+ | B | B− | C+ | C | C− | D+ | D | D− | F",
  "overall_grade": "A+ | A | A− | B+ | B | B− | C+ | C | C− | D+ | D | D− | F",
  "findings": [
    {
      "id": "c1-f001",
      "bucket": "B | E | challenger",
      "fingerprint": "<check-id>:<file>:<line>:<first-40-chars>",
      "lane": "wiki-content | claude-surface | source-ts | config-yaml-md | settings | gitignore | manifest",
      "action": "real-fix | taxonomy-update | false-positive | decided-not-finding"
    }
  ]
}
```

The `verdict` field stores Bucket D's verdict verbatim. It is _not_ a synthesized cycle grade. It reports enforcement-primitive completeness independent of `findings.length` (see §Bucket D). The `shared_fitness_grade` field stores Bucket E's honest grade (the floor of the seven category grades, F-to-A+). The `overall_grade` field is the F-to-A+ floor of: the `verdict` mapped to the same scale ("A+ readiness"→A+, "A"→A, "A−"→A−), the open-findings-count signal (zero open maintainer findings → A+; else degrade per wiki page rubric), and `shared_fitness_grade`. A challenger-injected finding (see §False-clean challenger) carries `action: "real-fix"`, `bucket: "challenger"`, a `lane`, and a `fingerprint`, and participates in the oscillation guard exactly like any other `real-fix`. The Orchestrator's clean-exit signal is `(no unresolved findings with action === "real-fix") AND verdict === "A+ readiness" AND effective shared_fitness_grade === "A+"` per §Termination: non-blocking residuals (`decided-not-finding`) do not count, and a category capped solely by residual `info` is treated as A+ for the effective grade. The `overall_grade` on a clean exit is the honest floor: A+ when there are no findings of any kind, otherwise the floor (residual `info` may cap it at A).

Lifecycle:

- **At `/health-audit` start**: Orchestrator runs `[ -d .gaia/local/audit ] && mv .gaia/local/audit .gaia/local/audit.prev-$(date +%s) ; mkdir -p .gaia/local/audit`. Archives stale dirs from prior interrupted runs.
- **At cycle start**: Orchestrator creates `c<N>/` and bucket sub-dirs.
- **Auditors**: write raw outputs to their per-cycle paths; return summary + file path in their report (not the full content).
- **Adjudicator**: reads bucket files, classifies, writes `c<N>/findings.json`.
- **Orchestrator (oscillation detection)**: mechanical diff via `jq -r '.findings[].fingerprint' .gaia/local/audit/c<N>/findings.json | sort` against the prior cycle's same. Non-empty intersection → oscillation, escalate.
- **Clean exit**: Orchestrator computes `overall_grade` = floor of (Bucket D verdict, open-findings-count signal, Bucket E `shared_fitness_grade`). A clean exit requires no open findings and an _effective_ shared-fitness A+ (non-blocking residuals exempt); the reported grade may be A. On a clean exit: Orchestrator runs `rm -rf .gaia/local/audit/c*` (whitelisted; safe). Top-level dir kept as run marker. The `rm -rf .gaia/local/audit/c*` runs only AFTER the false-clean challenger clears the terminal clean cycle (see §False-clean challenger); a challenger that revokes the exit either continues the loop (non-cycle-3) or escalates `false-clean-refuted` and preserves `c*/` (cycle 3).
- **Escalation**: Orchestrator preserves all `c*/` dirs and surfaces their paths in the escalation report for human review.

## State

Cycle artifacts persist in `.gaia/local/audit/c<N>/` for the duration of the audit. On a clean exit (which the terminal cycle reaches only after the false-clean challenger clears, see §False-clean challenger), the Orchestrator removes all `c*/` dirs (`rm -rf .gaia/local/audit/c*`; whitelisted; top-level dir kept as run marker). On escalation, all `c*/` dirs are preserved and surfaced in the escalation report for human review; a cycle-3 `false-clean-refuted` escalation preserves them the same way.

The audit does not write to `wiki/log.md` or `wiki/hot.md`.

Fingerprint format: `{check-id}:{file}:{line}:{first-40-chars-of-match-text}`. Stored in `c<N>/findings.json`. Compared mechanically across cycles for oscillation detection via `jq` + `comm`.

## Composition

The seven shared Claude-integration fitness categories (hook integrity; skill/command/agent frontmatter; rule hygiene; `CLAUDE.md` hygiene; settings hygiene; GAIA-install fitness; wiki fitness), their grading rubric, and the triage/heal orchestration protocol are defined in `wiki/decisions/Claude Integration Fitness.md`. Bucket E runs that page's triage phase over those seven categories; its bounded heal loop is subsumed by the outer cycle loop (see §Bucket E: Shared Claude-integration fitness for the loop-nesting rule). Do not re-specify the check classes or the grading rubric here. Cross-references are one-directional: this runbook references the wiki page; the wiki page never references `.gaia/cli/health/` paths.

## Pointers

- **Taxonomy**: `.gaia/cli/health/taxonomy.md`; Issue classes + Decided / not findings.
- **Shared fitness**: `wiki/decisions/Claude Integration Fitness.md`; seven fitness categories, F-to-A+ grading rubric, triage/heal orchestration protocol.
- **Scrub config**: `.gaia/release-scrub.yml`; codified leak-checks with allowlists.
- **ADR**: `wiki/decisions/Bundle-time Scrub.md`; what scrub catches, what it doesn't.
- **Wiki-style rule**: `.claude/rules/wiki-style.md`; UAT/SPEC narrative-vs-structural triage.
- **Release flow**: `.github/workflows/release.yml`; step order; primitives wired in.
