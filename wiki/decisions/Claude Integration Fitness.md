---
type: decision
status: active
created: 2026-05-12
updated: 2026-05-12
tags: [decision, claude, fitness]
---

# Claude Integration Fitness

`/gaia fitness` is a health check + auto-heal that answers one question — "how well-configured and coherent is this project's Claude integration?" — and fixes what it can. A single invocation runs three phases: triage (walk the seven graded categories below), heal (lane-aware Fixer subagents auto-apply confident fixes inside a bounded loop with oscillation detection), and verify (re-run the affected checks).

This page is the single source of truth for the check taxonomy, the F-to-A+ grading rubric, and the triage → heal → verify orchestration protocol. The protocol is harness-agnostic: `/gaia fitness` runs it standalone, and it is written so a larger audit harness can run the same protocol over the same seven categories as one bucket of a deeper loop.

The `/gaia fitness` skill's harness layer handles branch / repo-state — creating a `chore/gaia-fitness-<timestamp>` branch when HEAD is on the default branch and fixes are available, running triage-only when HEAD is detached or a rebase / merge / cherry-pick / bisect is in progress, and never committing. See the `/gaia fitness` skill reference for the full branching algorithm. That harness layer is not part of the triage/heal protocol described here.

`/update-gaia` three-way-merges this page, so project-specific check classes you add here survive GAIA upgrades, and `/gaia wiki` lints it. `/gaia fitness` runs whatever classes the page defines alongside the shipped ones.

## Check Taxonomy

Seven graded categories. Each category produces findings at `error`, `warning`, or `info` severity; the category grade derives from the worst severity found (see Grading Rubric).

### 1. Hook integrity

Checks `.claude/settings.json` and `.claude/settings.local.json` hook entries:

- Every hook command path exists on disk and is executable.
- No relative path that resolves only when the shell's working directory is the project root — paths must be stated in a form that is unambiguous regardless of cwd.
- Every hook event name is a valid Claude Code hook event.

Findings here are typically `error` severity.

### 2. Skill / command / agent frontmatter

Checks `.claude/skills/*/SKILL.md`, `.claude/commands/*.md`, and `.claude/agents/*.md`:

- `name` and `description` frontmatter fields present, non-empty, and not placeholder text.
- No `name` collision across the three surfaces.

One finding per defect, naming the file path and the remediation.

### 3. Rule hygiene

Checks `.claude/rules/*.md` and cross-references from `CLAUDE.md`:

- No `@`-import of skill files inside a rule — always-loaded rules that transitively preload skills bloat every session.
- Path-scoping glob syntax in rule frontmatter is valid.
- Content-vs-glob coherence: a rule path-scoped to a narrow glob must contain advice specific to those paths; universal advice must not be path-scoped (and vice versa).
- Rules referenced by `CLAUDE.md` exist at the cited path.

Findings here are typically `warning` severity.

### 4. `CLAUDE.md` hygiene

Checks `CLAUDE.md` (root and any subfolder `CLAUDE.md`s the root names in its folder map):

- Size vs. the project's stated size guidance.
- Every `@`-import resolves to an existing file.
- Every subfolder `CLAUDE.md` named in a folder map exists.
- No absolute machine-local paths (paths beginning with a user home directory prefix).
- No dead backticked path references (paths cited in backticks that do not exist on disk).

One finding per defect, naming the location and the remediation.

### 5. Settings hygiene

Checks `.claude/settings.json`:

- File is valid JSON — unparseable settings is an immediate category `F`.
- Permission entries whose pattern is a strict subset of another entry's glob are redundant (`info` or `warning`).
- Any secret-shaped value in the `env` block (`error`).
- `.claude/settings.local.json` not listed in `.gitignore` (`warning`).

### 6. GAIA-install fitness

Checks the GAIA installation:

- Per-file drift between the current contents of files tracked by `.gaia/manifest.json` and the contents the installed GAIA version shipped. Each drifted file is one `warning` finding.
- Installed GAIA version vs. latest release — if behind, one `info` finding recommending `/update-gaia`.

### 7. Wiki fitness

Checks wiki health by invoking the existing `gaia wiki` primitives — this category does not reimplement them:

- `wiki/.state.json` staleness vs. `app/**` HEAD — if `commits_ahead` is non-zero, one `info` finding recommending `/gaia wiki sync`.
- `gaia wiki dead-paths` — any dead backticked path reference in wiki body prose is one `warning` finding per occurrence.
- `gaia wiki orphans` — any orphan page (zero inbound links) is one `info` finding per page, recommending `/gaia wiki sync` to cross-link or archive.

### Decided / not findings

Things audits keep re-discovering that are not findings:

**Slash commands appear under "skills" in Claude Code's surface listing.** `.claude/commands/` files register through Claude Code's plugin/skill discovery and appear in the same listing as actual skills. This is a Claude Code surface artifact. Skip the round-trip.

**`wiki/.state.json` lagging HEAD.** Normal pre-release state. The session-start hook reports drift informationally; the wiki-fitness category surfaces it as `info` (not `error` or `warning`) and recommends `/gaia wiki sync`. Do not escalate to a blocking finding.

**`@`-imports that use valid repo-relative paths.** An `@`-import is a finding only when it imports a skill file from inside a rule. Imports of always-loaded rule files from `CLAUDE.md` are the correct pattern; do not flag them.

**Dead backticked path in `wiki/log.md` or `wiki/hot.md`.** These files are exempt from `gaia wiki dead-paths` by design — `wiki/log.md` is the append-only historical record; `wiki/hot.md` is the auto-overwritten session cache. Do not raise dead-path findings against either.

---

## Grading Rubric

Per-category grade is deterministic given the finding set for that category. The overall grade is the floor of the seven category grades (one `D` drags the headline to `D`).

### Per-category bands

| Grade | Condition |
|---|---|
| **A+** | Zero findings in the category |
| **A** | Only `info` findings |
| **B+** | One `warning`, no `error` |
| **B** | Two `warning`s, no `error` |
| **B−** | Three or more `warning`s, no `error` |
| **C+** | One `error` |
| **C** | Two `error`s |
| **C−** | (reserved — treat three errors as D band entry) |
| **D+** | Three `error`s |
| **D** | Four `error`s |
| **D−** | Five or more `error`s |
| **F** | Category is structurally broken — e.g. `.claude/settings.json` is unparseable (settings F); no `CLAUDE.md` exists (`CLAUDE.md` F) |

The exact +/− band thresholds are tunable — adjust the counts above for your project's tolerance.

### Overall grade

The overall grade equals the floor of the seven category grades. One `D` in any category drags the overall grade to `D`.

### Ordinal encoding

Grades ordinal-encode A+=12, A=11, A−=10, B+=9, B=8, B−=7, C+=6, C=5, C−=4, D+=3, D=2, D−=1, F=0. This encoding supports per-category trending if a project wants it. No 0–100 score is exposed — a percentage would be 100 minus arbitrary per-finding weights, which is false precision the letter-grade scale avoids.

---

## Severity Vocabulary

Every finding carries exactly three fields:

- **`severity`** — one of `error`, `warning`, `info` (lowercase, exactly these three).
- **`file`** — repo-relative path, with `:line` appended where the finding is attributable to a specific line.
- **`remediation`** — one-line description of what to do.

The chat report groups findings by the seven category names above.

---

## Triage → Heal → Verify Protocol

When `/gaia fitness` runs this protocol, the harness is minimal: no Orchestrator-above-Triager layer, no preserved per-cycle artifact directories, no escalation handoff. On loop exhaustion it simply reports the unresolved findings with the grade. (A larger harness composing this protocol can wrap it in its own deeper loop — the protocol below does not assume one.)

### Roles

- **Orchestrator** — owns the cycle loop and the final report. When `/gaia fitness` runs, this is the `/gaia fitness` skill reference.
- **Auditors** — per-category check executors dispatched during the triage phase.
- **Fixers** — edit agents dispatched during the heal phase, lane-aware so multiple run in parallel without merge conflicts.

### Triage phase

The Orchestrator dispatches the seven category checks as **parallel subagents** (or parallel tool calls — the verifiable property is the structured findings artifact, not the dispatch mechanism):

| Category | Model | What it does |
|---|---|---|
| Hook integrity | **Haiku** | File-exists + executable checks on hook command paths; event-name validation against a known-valid list |
| Settings hygiene | **Haiku** | `jq` parse of `settings.json`; glob-subset detection; secret-pattern grep on `env` values; `.gitignore` check for `settings.local.json` |
| GAIA-install fitness | **Haiku** | Hash-diff of manifest-tracked files against installed-version checksums; version string comparison |
| Wiki fitness | **Haiku** | `gaia wiki state` for staleness; `gaia wiki dead-paths`; `gaia wiki orphans` |
| Skill / command / agent frontmatter | **Sonnet** | Frontmatter completeness + placeholder detection (requires judgment); name-collision check |
| Rule hygiene | **Sonnet** | Content-vs-glob coherence (requires judgment about whether advice is universal or path-specific); `@`-import detection; `CLAUDE.md` cross-reference |
| `CLAUDE.md` hygiene | **Sonnet** | Size evaluation vs. project guidance (requires judgment); dead-path + absolute-path grep; `@`-import resolution; folder-map cross-reference |

**Structured findings only flow back to the Orchestrator.** Raw command output stays in subagent context to avoid return-budget truncation. Each auditor returns an array of `{severity, file, remediation, fingerprint}` objects.

### Heal phase

The Orchestrator dispatches **lane-aware Fixer subagents (Sonnet)** in parallel. Fixer lanes:

| Lane | Owns |
|---|---|
| **`claude-surface`** | `.claude/skills/**`, `.claude/commands/**`, `.claude/agents/**`, `.claude/hooks/**`, `CLAUDE.md`, `.claude/rules/**` |
| **`settings`** | `.claude/settings.json` |
| **`gitignore`** | `.gitignore` |
| **`manifest`** | `.gaia/manifest.json` |

Manifest edits must serialize — dispatch only a single Fixer at a time when `.gaia/manifest.json` is touched.

If a single finding's fix straddles multiple lanes, dispatch one Fixer with multi-lane scope (sequential edits inside that Fixer) rather than splitting across Fixers.

**Too-invasive fixes:** a fix a Fixer judges too invasive to apply without product context — e.g. restructuring a `.claude/rules/` file, splitting an oversized `CLAUDE.md`, changing the structure of hook logic — is **left unapplied**. The Fixer surfaces it in the report with a **recommended approach** (a description of what to do and why) so the operator can apply it manually.

### Oscillation detection

Finding fingerprint format:

```
{check-id}:{file}:{line}:{first-40-chars-of-match-text}
```

A finding whose fingerprint appears in both the current cycle's findings and the prior cycle's findings has survived a Fixer dispatch unchanged — the loop stops for that finding and it is reported as unresolved.

Detection is mechanical: compare fingerprint sets across consecutive cycles. Any fingerprint in both sets triggers loop termination for that finding.

### Bounded loop

Default: **3 cycles** (tunable — adjust the cycle count in this page for your project's tolerance). Each cycle runs triage → heal → verify. The loop exits early when all findings resolve. On loop exhaustion, `/gaia fitness` reports the remaining unresolved findings with the affected category grades and the overall grade. No escalation handoff — it reports and stops.

### Verify phase

After each heal cycle, re-run the affected category checks. Recompute the affected category grades and the overall grade. If the overall grade reaches A+, the loop exits clean.

---

## Findings Schema

```json
{
  "category": "hook-integrity",
  "findings": [
    {
      "severity": "error",
      "file": ".claude/settings.json:14",
      "remediation": "Hook command path '.claude/hooks/missing.sh' does not exist — create the file or remove the hook entry.",
      "fingerprint": "hook-integrity:.claude/settings.json:14:.claude/hooks/missing.sh"
    }
  ]
}
```

`findings` is the only content that flows back from auditors to the Orchestrator. The Orchestrator assembles the per-category arrays into the chat report.

---

## Chat Report Format

```
## Claude Integration Fitness Report

### Category Grades
| Category | Grade | Findings |
|---|---|---|
| Hook integrity | A+ | 0 |
| Skill / command / agent frontmatter | B+ | 1 warning |
| Rule hygiene | A+ | 0 |
| CLAUDE.md hygiene | A | 1 info |
| Settings hygiene | A+ | 0 |
| GAIA-install fitness | A | 1 info |
| Wiki fitness | A+ | 0 |

**Overall grade: A** (floor of category grades)

### Findings

#### Skill / command / agent frontmatter — B+
- ⚠️ **warning** `<path-to-command>` — `description` frontmatter is missing. Add a concise description of what this command does.

#### CLAUDE.md hygiene — A
- ℹ️ **info** `CLAUDE.md` — `@`-import of `<path-to-rule>` resolves but the rule is path-scoped; consider whether it warrants always-loading.

#### GAIA-install fitness — A
- ℹ️ **info** `.gaia/manifest.json` — GAIA v1.1.1 installed; v1.2.0 available. Run `/update-gaia` to upgrade.

### Post-heal instructions
Changes applied to the working tree. Review with `git diff`, commit when satisfied, or discard with `git checkout -- .` (and `git branch -D chore/gaia-fitness-<timestamp>` if a branch was created).
```

---

## Extensibility

Add a project-specific check class by appending a new numbered section under [Check Taxonomy](#check-taxonomy) above. Format:

```markdown
### 8. <Category name>

<What it checks and how. Describe the model (Haiku or Sonnet) and what the auditor does.>
```

`/gaia fitness` runs whatever classes this page defines. `/update-gaia` three-way-merges the page so your additions survive GAIA upgrades. `/gaia wiki` lints the page. The extension point is this page itself — edit it directly, the way the `code-review-audit` agent picks up extension files from `.claude/agents/code-review-audit/`.

---

## See also

[[Wiki Management]] — `gaia wiki dead-paths`, `gaia wiki orphans`, and the other primitives the wiki-fitness category invokes.
