---
type: concept
status: active
created: 2026-04-20
updated: 2026-06-05
tags: [concept, claude, agent, review]
---

# Code Review Audit Agent

Defined in `.claude/agents/code-review-audit.md`. Opus-class holistic reviewer for comprehensive code review beyond what ESLint and TypeScript catch; it dispatches cheaper Sonnet specialist subagents for line-level rule compliance.

Full spec: `.claude/agents/code-review-audit.md`.

Reviews security, performance, code smells, architecture, robustness, and maintainability. Output is tiered: Critical (must fix) → Important (should fix) → Suggestions → What's done well. After its own pass, spawns three specialist subagents in parallel (React Patterns & Accessibility, TypeScript & Architecture, Translation) plus `react-doctor`, `pnpm knip --reporter json`, and `pnpm audit --json` in a single tool call. Each subagent is gated on file scope so it doesn't spawn when there's nothing to review (e.g. no `.tsx` → skip Subagent 1).

Knip runs pre-merge here (post-task by design) and its findings are bucketed advisory: real dead code, intentional library export (update `entry` globs), or implicit dependency (update `ignoreDependencies`). See [[knip]].

A deterministic `pnpm audit --json` run is the oracle for known-vulnerable dependencies; the Security dimension does not LLM-judge current CVEs. Its high/critical advisories surface in an advisory bucket (read-only; never blocking the marker), scoped by a severity threshold and a machine-local baseline allowlist at `.gaia/local/dep-audit-baseline.json`. It is distinct from the blocking GAIA CI `pnpm audit` cron, which opens review-required security PRs. See [[pnpm-audit]].

## Finding proof gate and adversarial verification

Every holistic-reviewer finding must clear a four-check proof gate before it is reported: the finding must cite an exact `file:line`, name a concrete failure mode (input + state + bad outcome), confirm that callers and tests were read, and assign a defensible severity. Any check that fails drops or demotes the finding.

Critical and Important holistic findings that survive the proof gate go to a selective adversarial pass: a fresh-context refuter subagent that did not produce the finding reads the cited evidence and attempts to rebut. A refuter overturns a finding only with concrete counter-evidence (a guard at `file:line`, a covering test, or an unreachable path). Without that, the verdict defaults to STANDS. Outcome options: drop on "cannot occur," demote on "smaller blast radius," keep otherwise. The resulting disposition flows into the marker-decision interlock so a dropped Critical does not block the merge gate.

Deterministic oracles (`react-doctor`, `knip`) are exempt from the proof gate and adversarial pass; they are not probabilistic judgments.

## Scope classification and disposition

Every finding that survives the proof gate and any adversarial verification gets a forced disposition before the marker clears, split by scope and bounded to the review radius. In-scope findings (inside the PR's changed line ranges) flow into the Critical/Important/Suggestions sections and gate the marker as before. Out-of-scope findings (debt the audit opens within its review radius but the PR did not change) route **out of** those gating sections into a separate disposition: a deduped, severity-labeled `tech-debt` issue, or a diverted security finding. The audit never opens an unrelated file to hunt for debt, and it never fixes an out-of-scope finding (it files, it does not edit the reviewed tree).

The marker is gated on every out-of-scope finding carrying a disposition (the fourth marker precondition), withheld only on a genuinely-missing disposition on a present, writable backend and failing open otherwise. Security-class findings are classified fail-safe and never reach a public or enterprise-readable channel: on a PUBLIC or INTERNAL repo they divert to a redacted operator surface or a count-only PR signal rather than a public issue. See [[Audit Disposition and Debt Drain]] for the full contract, the dedup key, the backend probe, the disposition-ledger sidecar, and the `/gaia-debt` drain loop.

## Incremental scope

The audit does not always review the full `origin/main...HEAD` diff. `.github/audit/resolve-audit-base.sh` resolves a review base, the most recent ancestor of HEAD that already passed a clean audit under the current `.gaia/VERSION`, proven by a GAIA-Audit commit trailer (local stamps) or a GAIA-Audit commit status (CI stamps; see [[PR Merge Workflow]] for the trailer/status handshake). The audit then reviews only `<base>...HEAD`.

The base is only ever a commit that passed a clean audit. An interrupted, failed, or differently-versioned run leaves no signal to anchor on, so the base falls back to `origin/main` and the full PR diff is reviewed. The scope therefore can never skip uncleared code; worst case it reviews too much. A `.gaia/VERSION` bump invalidates every prior base and forces a full re-audit under the new ruleset.

The benefit lands when an audit completes between pushes: a follow-up push reviews only its own delta instead of re-reviewing the whole PR. The `cancel-in-progress` concurrency policy means rapid-fire pushes cancel before a base is stamped, so they fall back to full scope safely. The one risk an incremental scope must guard is a delta that breaks an already-cleared caller, so the agent rechecks importers of any exported symbol whose contract changed in the delta.

## Durable knowledge

The wiki (`wiki/`) is the source of truth for patterns, decisions, and conventions worth preserving across reviews. The agent surfaces recurring anti-patterns or architectural concerns in its report so they can be filed into the wiki.

`.claude/agent-memory/` is **not** treated as canonical: in this repo it is gitignored / machine-local, so anything written there is invisible to other developers and to fresh checkouts. Use the wiki for durable knowledge; let agent-memory accumulate only ephemeral, machine-local notes if at all.

## Extension mechanism

Library-specific audit rules live in `.claude/agents/code-review-audit/*.md`. Each file targets one or more specialist subagents via YAML frontmatter (`subagents: [react-patterns, typescript, translation]`). The agent reads all extension files at startup and injects their rules into the relevant subagent prompts.

The `subagents:` values (`react-patterns`, `typescript`, `translation`) are **rule-injection labels** - metadata that selects which specialist prompt receives this file's rules. They are not skill or command names. The agent dispatches each specialist via the **Agent (Task) tool** with an explicit `subagent_type`. Routing a specialist through the Skill tool misroutes it to a fuzzy-matched command (e.g. `/gaia-audit`), which rejects the args and aborts the audit before its marker is written.

To swap a library: remove its extension file, add one for the replacement. The main agent definition stays unchanged. See the `README.md` in that directory for the full format.

| File                 | Library              |
| -------------------- | -------------------- |
| `conform.md`         | `@conform-to/zod`    |
| `tailwind-merge.md`  | `tailwind-merge`     |
| `react-i18next.md`   | `react-i18next`      |
| `form-components.md` | GAIA Form Components |

## Finding emission

After the human-readable report, the agent appends a machine-readable telemetry trailer as the last fenced `---` block of its Task return. The PostToolUse Task hook parses this block; `findings_json` carries one entry per eligible finding with `finding_class`, `severity`, and `area_tags`. The cross-machine tally in [[Policy-Memory Loop]] reads these findings (plus the identical CI findings block written to the PR comment) when computing recurring-finding candidates.

`finding_class` follows a per-bucket convention: oracle buckets use the tool's own id prefixed (`react-doctor/...`, `axe/...`, `knip/...`, `cve/...`); holistic and rule-subagent buckets draw from a constrained vocabulary seeded in the agent definition. A finding with no stable class is omitted from the trailer but may still appear in the prose report.

The CI workflow appends the same structured findings as an HTML-comment block at the end of its PR comment (framed by `<!-- gaia-harden:findings:start -->` / `<!-- gaia-harden:findings:end -->` sentinel lines), so the tally can read findings from both local and CI runs via `gh`.

## Trigger

Always before `gh pr merge` ([[PR Merge Workflow]]), enforced by the `pr-merge-audit-check.sh` advisory hook ([[Claude Hooks]]). Also on demand for any review.
