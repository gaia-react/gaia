---
type: concept
status: active
created: 2026-06-30
updated: 2026-06-30
tags: [concept, claude, review]
---

# Audit Disposition and Debt Drain

Every finding the [[Code Review Audit Agent]] surfaces carries a **forced disposition** before its marker clears. In-scope findings keep their existing handling (a self-heal commit or an escalation that blocks the marker). Out-of-scope findings, debt in code the PR did not change but the audit opened anyway within its review radius, route out of the gating Critical/Important/Suggestions sections into a separate disposition: a deduped, severity-labeled `tech-debt` GitHub issue, a diverted security surface, or a backend-absent waive. The `/gaia-debt` skill then drains that backlog one issue at a time, and a statusline segment surfaces the open count.

The system **fails open**. A definitively-absent issue backend makes the whole feature inert. A transient backend failure never silently drops a finding and never blocks the merge. The single intended block is a genuinely-missing disposition on a present, writable backend.

## Two-axis disposition matrix

A finding sorts on two axes: **scope** (in-scope vs out-of-scope) and **resolution** (auto-safe vs needs-human). Only the out-of-scope row is new; the in-scope row is the existing audit behavior.

| | auto-safe | needs-human |
|---|---|---|
| **in-scope** | self-heal commit in the working tree | escalation; blocks the marker until the operator resolves it |
| **out-of-scope** | filed `tech-debt` issue (non-security), or backend-absent waive | diverted security surface (never a public channel); `/gaia-debt` drains the filed backlog |

The audit never edits the reviewed PR's working tree for an out-of-scope finding: it files, it does not fix. Auto-fixing debt the PR did not touch would breach surgical-changes.

## Scope classification

Each surviving finding (one that clears the proof gate and any adversarial verification) is tagged against the audit base's changed line ranges:

- **in-scope**: the finding's `file:line` falls inside the PR's changed line ranges. It flows into the Critical/Important/Suggestions sections and gates the marker exactly as before.
- **out-of-scope**: the defective line is outside those ranges, but the audit already opened the file within its review radius, a caller, a test, an upstream guard, or an importer of a changed export (the same files the incremental-scope importer recheck opens).

The bound is hard: the audit **never opens an unrelated file to hunt for debt**. Out-of-scope filing is a byproduct of reviewing the diff and its review radius, never a whole-file or whole-repo sweep. A file the audit never opened to review the diff is out of bounds and its debt is not filed.

## Out-of-scope disposition

For each out-of-scope finding the audit classifies security first (below), probes the backend, then either files or diverts.

### Filing a tech-debt issue

A non-security out-of-scope finding on a present backend files as a `tech-debt` GitHub issue carrying:

- A **frozen versioned dedup key**, a single HTML-comment line present verbatim in the body:

  ```
  <!-- gaia-debt-key: v1 class=<finding_class> path=<repo-relative-posix-path> line=<integer> -->
  ```

  `v1` is the schema version. `<finding_class>` is a seeded `finding_class` or the fallback class `holistic/unclassified` when the finding maps to no seeded class. `<path>` is a repo-relative POSIX path; `<line>` is an integer.

- A **self-contained body**, built in a gitignored body-file (e.g. `.gaia/local/audit/issue-body.md`) and passed via `gh issue create --body-file <path>` (or stdin), never a `--body` argv string. The CI workflow runs `--verbose`, so an argv body would echo finding detail into the public Actions log. The body carries the dedup-key line, the `file:line` (resolving to a real line in the named file), a concrete failure mode (input + state + bad outcome), a suggested fix, and a handler-class line.

- **Exactly one severity label** plus `tech-debt`. Report tier maps to label: Critical → `severity:critical`, Important → `severity:important`, Suggestion → `severity:suggestion`. A deliberately-closed finding carries the GitHub `wontfix` label so it is not re-filed. Labels are created idempotently before the first filing (`gh label create <name> --color <hex> 2>/dev/null || true`); a pre-existing label is not an error.

The **handler class** is exactly `prompt` or `plan` (never `gaia-spec`). `prompt` means the fix is a single logical unit confined to one file, with no public-contract change and no cross-module ripple; `plan` is anything else. It is advisory: `/gaia-debt` may override it after reading the code.

### Idempotent dedup

Filing is idempotent. Before creating, the audit dedups by **exact local substring match** (never `gh` full-text search, which tokenizes on `/ : @` and cannot reliably match the key):

1. `gh issue list --label tech-debt --state open` → exact substring match of the key line in each body.
2. `--state closed` → an exact key match on a closed issue carrying `wontfix` (or closed as not-planned) is a **declined** finding; do not re-file.
3. Keyless human-filed fallback → a bare `<path>:<line>` substring in an open `tech-debt` body suppresses the re-file even with no machine key present.

The dedup is re-checked immediately before `gh issue create` to shrink the TOCTOU window for a concurrent CI-plus-local run.

## Security classification and divert

Security classification runs **before** any filing path. A finding is **security-class** (fail-safe) if any of these hold, regardless of its `finding_class` tag: it came from the security review dimension, its severity is Critical, it carries no stable `finding_class`, or it is secret-shaped. Exact-string matching on the seeded security classes alone is insufficient, severity is demotable, several security dimensions have no seeded class, and a finding can be classless, so when in doubt the audit treats a finding as security-class.

The authoritative `finding_class` vocabulary lives in `.gaia/cli/src/schemas/finding-class.ts` (`HOLISTIC_FINDING_CLASSES`, `RULE_FINDING_CLASSES`, and the oracle prefixes); the page references it rather than re-listing the security members. The same file defines `OUT_OF_SCOPE_FALLBACK_FINDING_CLASS` (`holistic/unclassified`), the dedup-key fallback for a classless finding. That constant is not a member of the closed telemetry vocabulary and is never emitted in the telemetry trailer; it only builds a dedup key.

Because "any Critical" and "no stable `finding_class`" are both security-class triggers, an out-of-scope **Critical** or **classless** finding is security-class and routes through the visibility gate before any public filing. `gh repo view --json visibility` returns `PUBLIC | PRIVATE | INTERNAL`, re-read immediately before each security-relevant write (a repo can flip); any non-confirmed-`PRIVATE` state diverts.

- security-class on **PUBLIC or INTERNAL** → **divert**, never a public or internal issue:
  - **local run**: a redacted operator surface at `.gaia/local/audit/security/<HEAD-sha>.md` (gitignored) plus a count-only pointer (no detail) in the report. The operator is surfaced to and the flow waits; nothing is auto-drafted or auto-disclosed.
  - **CI run**: a redacted count-only signal in the public PR comment (`N security-class findings diverted; maintainer must review`), never the detail.
- security-class on **confirmed PRIVATE** → file as a normal private `tech-debt` issue, fully dedupable and drainable.

A security-class finding's detail never reaches a public or internal issue, the PR comment, the Actions log, or `.gaia/local/audit/progress.log`; a diverted finding contributes only to counts on those surfaces. Even a classless finding that diverts builds its dedup key with the fallback class, so the operator surface and any future dedup stay well-formed. Either disposition (`filed` or `diverted`) lets the marker write, so the never-public guarantee never deadlocks the merge.

## The disposition gate and the marker

The disposition gate is the **fourth marker precondition**, alongside the three existing ones (no in-scope Critical, every in-scope Important addressed, every in-scope Suggestion auto-fixed or escalated), which are now scoped to in-scope findings. Before writing the marker the audit re-queries open `tech-debt` issues for each out-of-scope key and confirms each `filed` entry still resolves to an open issue carrying the key.

The audit records its decision in a gitignored **disposition-ledger sidecar** at `.gaia/local/audit/<HEAD-sha>.dispositions.json` (`findings: []` when none were identified, so a reader can tell "audit ran, none identified" from "no sidecar"). Each entry carries the dedup key's inner content (the `v1 class=… path=… line=…` text without the `<!-- gaia-debt-key: … -->` wrapper), its severity, `security_class`, and a `disposition`:

- `filed` — an open `tech-debt` issue carries the key (`issue_number` set).
- `diverted` — security-class diverted; no public issue.
- `waived` — backend definitively absent; the finding reverts to prose only.
- `pending` with `pending_reason: "transient"` — a transient `gh` failure; the finding is surfaced and retained for the next idempotent run.
- `pending` with `pending_reason: "definitive"` — a definitive filing failure on a present, writable backend; the disposition is genuinely missing.

The marker writes when every entry is `filed`, `diverted`, `waived`, or `pending(transient)`. It is withheld **only** on `pending(definitive)`, the one intended block: the operator resolves the filing failure and re-invokes before the marker clears. Backend-absent, transient, and diversion-failure cases all fail open and never block the merge.

### Backend probe (three outcomes)

The audit probes the issue backend once at the start of the disposition flow:

- **Definitive-absent** → waive: file nothing, the gate waives, out-of-scope findings revert to prose, the marker writes. Triggers: repo unresolvable, `gh` unauthenticated, Issues disabled (`gh repo view --json hasIssuesEnabled` false or a structurally-failing issue-list probe, never `gh repo view` resolution alone), or the viewer lacks write permission.
- **Transient/ambiguous** → do not waive, do not drop: timeout, rate-limit, 5xx. Surface the finding and retain it for the next run; dedup makes the retry safe. Never block the merge.
- **Present** → proceed with dedup, filing, or divert.

### Deterministic backstop hook

The audit's verify-after-file re-query is agent behavior, not code. `.claude/hooks/audit-disposition-check.sh` is the deterministic backstop: a PreToolUse hook that gates `gh pr merge` alongside `pr-merge-audit-check.sh` and `worthiness-presence-check.sh`, each denying independently. It re-reads the sidecar for the current HEAD and denies the merge on exactly two conditions:

1. a `filed` entry whose key has **no** matching open `tech-debt` issue on a reachable backend, or
2. a `pending(definitive)` entry.

It fails open everywhere else: no sidecar, backend `absent`, every `filed` entry confirmed, all entries diverted/waived/pending(transient), or any `gh`/tooling failure. A match is an issue body that **contains** the sidecar key as a substring, never whole-line equality. The CI workflow grants the job `issues: write` and adds `Bash(gh:*)` to the agent's `--allowedTools` so the same filing path runs from CI.

## /gaia-debt: draining the backlog

`/gaia-debt` (`.claude/commands/gaia-debt.md`, playbook at `.claude/skills/gaia/references/debt.md`) drains the `tech-debt` backlog the audit files. It resolves **exactly one** issue per invocation, never a batch, on a fresh branch through the same `code-review-audit` marker gate every feature PR passes, with `Closes #N` in the PR body so the merge closes the issue natively. The skill opens the fix PR and stops; it never runs `gh pr merge`.

The ordering is a pure, source-checkable sort, never an LLM evaluator: severity descending (`severity:critical → 3`, `severity:important → 2`, `severity:suggestion → 1`, a label-less issue falls to the suggestion band), then `createdAt` ascending within a band (oldest first, FIFO). `list` prints the ordered backlog; `why <issue-number>` explains where one issue sits and its recommended handler class; bare or `drain` runs the interactive, human-gated flow.

Before opening any fix PR, the skill re-applies the fail-safe security screen to the selected issue and re-reads visibility. A security-class issue on a PUBLIC or INTERNAL repo diverts to the redacted operator surface and stops, opening a public `Closes #N` PR for a security issue would complete a disclosure failure the screen exists to prevent; only a confirmed-PRIVATE repo drains it as a normal fix PR. A `/gaia-debt` fix PR is otherwise an ordinary in-scope change that passes the normal gate.

## Statusline and debt-count refresh

A statusline segment, `Run /gaia-debt (N issues)` (`issue` singular at N==1), surfaces the open count, matching the other right-side `Run /<skill> (N noun)` indicators and suppressed in linked worktrees and before per-clone setup. It reads a pinned cache at `.gaia/local/debt/count.json` (`{"schema":1,"openCount":<int>,"computedAt":<unix-epoch>}`), so the no-network statusline hot path never recomputes inline.

`.gaia/scripts/debt-count-refresh.sh` runs detached in the background each tick. It recomputes `openCount` via `gh issue list --label tech-debt --state open` and rewrites the cache when a staleness sentinel (`.gaia/local/debt/refresh-requested`, an empty marker file) is present or the cache is older than its own TTL, independent of the aggregate update-check TTL. On any `gh` failure it preserves the previous count rather than blanking it; a backend-absent run with no prior cache seeds `openCount` 0 so no segment renders.

Two first-party events set the sentinel deterministically: the audit filing a `tech-debt` issue, and a `/gaia-debt` PR merging. The merge event is a `gh pr merge` PostToolUse hook (`.claude/hooks/debt-sentinel-touch.sh`) that touches the sentinel after a successful merge, since the merge usually lands via the orchestrator or human after the skill has left the conversation; the skill's own in-conversation touch is best-effort belt-and-suspenders. Every sentinel or cache writer runs `mkdir -p .gaia/local/debt` first, because the directory is not assumed to pre-exist on a fresh clone or in CI. External (web-UI or teammate) mutations are best-effort and surface by the next TTL or session refresh.

## Relationship to the Policy-Memory Loop

`/gaia-debt` and `/gaia-harden` (the [[Policy-Memory Loop]]) share the `finding_class` vocabulary but do not overlap. `/gaia-harden` hardens recurring **forms**: when the same `finding_class` recurs across distinct PRs, it drafts the lowest-context-weight guard (a deterministic check, skill, or path-scoped rule) so the class stops recurring. `/gaia-debt` drains concrete **instances**: the specific out-of-scope defects the audit filed as `tech-debt` issues, one fix PR at a time. One governs the rule that prevents a pattern; the other clears the individual debts already on the books.

## Deferred (not yet built)

The following are intentionally out of scope for the current implementation and are not yet built:

- **Line-drift-tolerant dedup.** The dedup key is `finding_class` + `file:line`; a residual line-drift duplicate risk is accepted.
- **CI security-advisory credential mechanism.** The default `GITHUB_TOKEN` cannot create a repository advisory, so a CI security divert reverts to a redacted maintainer count-only surface rather than a private advisory.
- **Durable drain for diverted PUBLIC/INTERNAL security findings.** Only the confirmed-PRIVATE-repo private-issue path is dedupable and drainable; a diverted PUBLIC/INTERNAL security finding has no durable backlog.
- **Cross-band drain fairness.** `/gaia-debt` is within-band FIFO, severity-first; cross-band fairness and a starvation guard are out of scope.

## Pairs with

- [[Code Review Audit Agent]]: the producer; classifies scope, disposes out-of-scope findings, and writes the disposition-ledger sidecar.
- [[PR Merge Workflow]]: the disposition gate is the fourth marker precondition; the backstop hook gates `gh pr merge`.
- [[Policy-Memory Loop]]: the sibling `finding_class` consumer; hardens recurring forms while `/gaia-debt` drains concrete instances.
