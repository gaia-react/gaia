---
type: concept
status: active
created: 2026-04-20
updated: 2026-07-16
tags: [concept, claude, agent, review]
---

# Code Review Audit Agent

Defined in `.claude/agents/code-audit-frontend.md`. Opus-class holistic reviewer for comprehensive code review beyond what ESLint and TypeScript catch; it dispatches cheaper Sonnet specialist subagents for line-level rule compliance.

`code-audit-frontend` is the default, adopter-facing member of the [[Code Audit Team]] roster: the config-driven `auditors:` block that maps file globs to auditor members, with a dispatch resolver and an AND-aggregator requiring every dispatched member's clearance before a merge unblocks. This page covers `code-audit-frontend`'s own review dimensions and disposition contract; see [[Code Audit Team]] for the roster mechanism and the maintainer-only members layered on top of it.

Full spec: `.claude/agents/code-audit-frontend.md`.

Reviews security, performance, code smells, architecture, robustness, and maintainability. Output is tiered: Critical (must fix) → Important (should fix) → Suggestions → What's done well. After its own pass, spawns three specialist subagents in parallel (React Patterns & Accessibility, TypeScript & Architecture, Translation) plus `react-doctor`, `pnpm knip --reporter json`, and `pnpm audit --json` in a single tool call. Each subagent is gated on file scope so it doesn't spawn when there's nothing to review (e.g. no `.tsx` → skip Subagent 1).

Knip runs pre-merge here (post-task by design) and its findings are bucketed advisory: real dead code, intentional library export (update `entry` globs), or implicit dependency (update `ignoreDependencies`). See [[knip]].

A deterministic `pnpm audit --json` run is the oracle for known-vulnerable dependencies; the Security dimension does not LLM-judge current CVEs. Its high/critical advisories surface in an advisory bucket (read-only; never blocking the marker), scoped by a severity threshold and a machine-local baseline allowlist at `.gaia/local/dep-audit-baseline.json`. It is distinct from the blocking GAIA CI `pnpm audit` cron, which opens review-required security PRs. See [[pnpm-audit]].

## Finding proof gate and adversarial verification

Every holistic-reviewer finding must clear a four-check proof gate before it is reported: the finding must cite an exact `file:line`, name a concrete failure mode (input + state + bad outcome), confirm that callers and tests were read, and assign a defensible severity. Any check that fails drops or demotes the finding.

Critical and Important holistic findings that survive the proof gate go to a selective adversarial pass: a fresh-context refuter subagent that did not produce the finding reads the cited evidence and attempts to rebut. A refuter overturns a finding only with concrete counter-evidence (a guard at `file:line`, a covering test, or an unreachable path). Without that, the verdict defaults to STANDS. Outcome options: drop on "cannot occur," demote on "smaller blast radius," keep otherwise. The resulting disposition flows into the marker-decision interlock so a dropped Critical does not block the merge gate.

Deterministic oracles (`react-doctor`, `knip`) are exempt from the proof gate and adversarial pass; they are not probabilistic judgments.

## No-op guard against silent subagents

A dispatched specialist or refuter can return a harness-reminder-echo instead of doing the work, silently. A shared deterministic predicate (`.gaia/scripts/audit-noop-detect.sh`) classifies each returned text against its expected shape and exits non-zero on a no-op; it loads no finding body into the classifying caller's context. On a no-op, the agent re-dispatches that one subagent exactly once with a hardened retry prefix that forces a Read of the concrete target as its first action. A second consecutive no-op does not re-dispatch again: the agent reviews or refutes that unit itself inline, applies the result exactly as if the subagent had returned it, and records the degraded unit as a count (never detail) on the relevant progress breadcrumb (`oracles done` for a specialist, `adversarial verify done` for a refuter) and in the report summary. The same guard covers the equivalent dispatch surfaces in [[GAIA Spec]] and [[GAIA Plan]].

## Scope classification and disposition

Every finding that survives the proof gate and any adversarial verification gets a forced disposition before the marker clears, split by scope and bounded to the review radius. In-scope findings (inside the PR's changed line ranges) flow into the Critical/Important/Suggestions sections and gate the marker as before. Out-of-scope findings (debt the audit opens within its review radius but the PR did not change) route **out of** those gating sections into a separate disposition: a deduped, severity-labeled `tech-debt` issue, or a diverted security finding. The audit never opens an unrelated file to hunt for debt, and it never fixes an out-of-scope finding (it files, it does not edit the reviewed tree).

The marker is gated on every out-of-scope finding carrying a disposition (the fourth marker precondition), withheld only on a genuinely-missing disposition on a present, writable backend and failing open otherwise. Security-class findings are classified fail-safe and never reach a public or enterprise-readable channel: on a PUBLIC or INTERNAL repo they divert to a redacted operator surface or a count-only PR signal rather than a public issue. See [[Audit Disposition and Debt Fix]] for the full contract, the dedup key, the backend probe, the disposition-ledger sidecar, and the `/gaia-debt` fix loop.

## Incremental scope

The audit does not always review the full `origin/main...HEAD` diff. `.github/audit/resolve-audit-base.sh` resolves a review base, the most recent ancestor of HEAD that already passed a clean audit under the current `.gaia/VERSION`, proven by a GAIA-Audit commit trailer (local stamps) or a GAIA-Audit commit status (CI stamps; see [[PR Merge Workflow]] for the trailer/status handshake). The audit then reviews only `<base>...HEAD`.

The base is only ever a commit that passed a clean audit. An interrupted, failed, or differently-versioned run leaves no signal to anchor on, so the base falls back to `origin/main` and the full PR diff is reviewed. The scope therefore can never skip uncleared code; worst case it reviews too much. A `.gaia/VERSION` bump invalidates every prior base and forces a full re-audit under the new ruleset.

The benefit lands when an audit completes between pushes: a follow-up push reviews only its own delta instead of re-reviewing the whole PR. The `cancel-in-progress` concurrency policy means rapid-fire pushes cancel before a base is stamped, so they fall back to full scope safely. The one risk an incremental scope must guard is a delta that breaks an already-cleared caller, so the agent rechecks importers of any exported symbol whose contract changed in the delta.

## Re-run carry-forward ledger

The local fix → re-audit loop carries its state across rounds in a gitignored per-base-and-branch file, `.gaia/local/audit/<audit-key>.rerun.json` (`<audit-key>` is the incremental base sha plus the acting tree's own branch, `.gaia/scripts/audit-key-lib.sh`, so two worktrees sharing a base sha never collide on this filename). The ledger holds the in-scope findings still open, what was fixed last round, the cleared/incremental base, and a round counter, so the carried state is deterministic and lossless instead of living in the orchestrator thread's degrading memory.

The ledger keys on the incremental base (the fork point `git merge-base "$BASE_REF" HEAD`, resolved the same way the audit resolves its review base), not HEAD. The per-member marker (`<digest>.ok` for the frontend, `<digest>.<member>.ok` for a specialist) and the dispositions sidecar (`<frontend-digest>.dispositions.json`) key on each member's own content digest, not HEAD, because they certify the content that member reviewed. A fix commit that touches frontend-owned content rotates the frontend digest, and both artifacts, just as a HEAD move used to; a commit that touches nothing any member owns and no machinery leaves every digest, and every marker, valid. The ledger accumulates "what is still wrong relative to the cleared base," and that base fork point is stable across fix rounds within one loop, so the remaining items survive the HEAD moves each fix commit produces with no HEAD-chaining logic. Its `remaining[]` carries in-scope open findings only; out-of-scope findings stay in the dispositions sidecar (see [[Audit Disposition and Debt Fix]]).

The next re-audit and the fixer read the ledger for a deterministic, lossless briefing instead of a main-thread-authored prompt summary. Because the detail lives in the ledger, the agent's local Task return is then a terse pointer plus counts (remaining Critical/Important/Suggestion, escalated, fixed-this-round, out-of-scope dispositions) rather than a full per-round report, so the orchestrator stops absorbing the round's full output each pass. On a non-clean pass the audit writes/updates the ledger and increments the round; on a clean pass (the marker writes) it removes the ledger.

The ledger fails open and never gates anything. An absent, corrupt, or stale ledger (its recorded branch or base no longer matches the current branch and resolved base) is treated as absent and the loop falls back to the prompt summary; no hook reads it, so it cannot perturb merge gating. The terse Task return itself is conditional: it is emitted only when the ledger write succeeds, and when the write is skipped (no base resolved) or fails, the audit returns the full report instead, so the per-finding detail is never lost.

### Local-flow-only

The ledger is read, written, and cleaned up only on local runs; the agent skips it entirely when `GITHUB_ACTIONS` (or `CI`) is set. Each CI audit is a fresh ephemeral job with no persistence of `.gaia/local/audit/`, so a ledger written in one run is never read by the next. CI instead carries cross-round state by git-native means that survive a fresh checkout: the cleared/incremental base rides the `GAIA-Audit` commit trailer and commit status read by `.github/audit/resolve-audit-base.sh`, and the remaining findings ride the PR-comment findings block (with out-of-scope debt in `tech-debt` issues). The ledger therefore has no reader and no role in CI.

The terse Task return is the contract the local re-run orchestrator reads; it does not collapse the CI PR comment, which CI keeps full. The Task return and the PR-comment findings block are separate channels, so making the local return terse leaves CI's comment surface untouched. See [[PR Merge Workflow]] for the fix → re-spawn loop that consumes the ledger.

## Durable knowledge

The wiki (`wiki/`) is the source of truth for patterns, decisions, and conventions worth preserving across reviews. The agent surfaces recurring anti-patterns or architectural concerns in its report so they can be filed into the wiki.

`.claude/agent-memory/` is **not** treated as canonical: in this repo it is gitignored / machine-local, so anything written there is invisible to other developers and to fresh checkouts. Use the wiki for durable knowledge; let agent-memory accumulate only ephemeral, machine-local notes if at all.

## Extension mechanism

Library-specific audit rules live in `.claude/agents/code-audit-frontend/*.md`. Each file targets one or more specialist subagents via YAML frontmatter (`subagents: [react-patterns, typescript, translation]`). The agent reads all extension files at startup and injects their rules into the relevant subagent prompts.

The `subagents:` values (`react-patterns`, `typescript`, `translation`) are **rule-injection labels** - metadata that selects which specialist prompt receives this file's rules. They are not skill or command names. The agent dispatches each specialist via the **Agent (Task) tool** with an explicit `subagent_type`. Routing a specialist through the Skill tool misroutes it to a fuzzy-matched command (e.g. `/gaia-audit`), which rejects the args and aborts the audit before its marker is written.

To swap a library: remove its extension file, add one for the replacement. The main agent definition stays unchanged. See the `README.md` in that directory for the full format.

| File                 | Library              |
| -------------------- | -------------------- |
| `conform.md`         | `@conform-to/zod`    |
| `tailwind-merge.md`  | `tailwind-merge`     |
| `react-i18next.md`   | `react-i18next`      |
| `form-components.md` | GAIA Form Components |

## Finding emission

`finding_class` follows a per-bucket convention: oracle buckets use the tool's own id prefixed (`react-doctor/...`, `axe/...`, `knip/...`, `cve/...`); holistic and rule-subagent buckets draw from a constrained vocabulary seeded in the agent definition. A finding with no stable class is omitted from the findings block but may still appear in the prose report.

The CI workflow appends structured findings as an HTML-comment block at the end of its PR comment (framed by `<!-- gaia-harden:findings:start -->` / `<!-- gaia-harden:findings:end -->` sentinel lines). The cross-machine tally in [[Policy-Memory Loop]] reads this block via `gh` when computing recurring-finding candidates.

## Trigger

Always before `gh pr merge` ([[PR Merge Workflow]]), enforced by the `pr-merge-audit-check.sh` advisory hook ([[Claude Hooks]]). Also on demand for any review.
