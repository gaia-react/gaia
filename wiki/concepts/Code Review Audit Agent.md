---
type: concept
status: active
created: 2026-04-20
updated: 2026-08-04
tags: [concept, claude, agent, review]
---

# Code Review Audit Agent

Defined in `.claude/agents/code-audit-frontend.md`. Opus-class holistic reviewer for comprehensive code review beyond what ESLint and TypeScript catch; it dispatches cheaper Sonnet specialist subagents for line-level rule compliance.

`code-audit-frontend` is the default, adopter-facing member of the [[Code Audit Team]] roster: the config-driven `auditors:` block that maps file globs to auditor members, with a dispatch resolver and an AND-aggregator requiring every dispatched member's clearance before a merge unblocks. This page covers `code-audit-frontend`'s own review dimensions and disposition contract; see [[Code Audit Team]] for the roster mechanism and the maintainer-only members layered on top of it.

Full spec: `.claude/agents/code-audit-frontend.md`.

Reviews security, performance, code smells, architecture, robustness, and maintainability. Output is tiered: Critical (must fix) → Important (should fix) → Suggestions → What's done well. After its own pass, spawns three specialist subagents in parallel (React Patterns & Accessibility, TypeScript & Architecture, Translation) plus `react-doctor`, `pnpm knip --reporter json`, and `pnpm audit --json` in a single tool call. Every dispatch is gated on scope so nothing spawns with nothing to review, but the two kinds of dispatch read different lists. Each subagent gates on file extension against the TS/TSX-filtered review scope (e.g. no `.tsx` → skip Subagent 1). The three oracles scan the whole repo or the whole dependency tree by design, so a diff carrying no `.ts` must still run them; they gate instead on the unfiltered whole-PR changed set, and only on its emptiness, which is the one case where a whole-repo oracle provably has nothing new to report. An unresolvable base runs them.

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

The audit does not always review the full `origin/main...HEAD` diff. `.github/audit/resolve-audit-base.sh` resolves a **per-member review base**: a dispatched member names itself with `--member <name>`, and the resolver anchors on the newer of two things, a commit carrying a clean whole-team signal under the current `.gaia/VERSION` (a GAIA-Audit commit trailer for local stamps, or a GAIA-Audit commit status for CI stamps; see [[PR Merge Workflow]] for the trailer/status handshake), or a commit whose tree matches one of that member's own earned clearances recorded under the current version. The tree, not the commit sha, is the matching field, because the trailer stamp that closes a clean round amends HEAD and rewrites the sha while leaving the tree unchanged. A member holding a refusal anywhere in the candidate range anchors on neither that commit nor anything past it. Every caller that does not name a member, the merge-time findings-block producer, the source-change skip gate, the installed workflows, uses the resolver's argument-less form, which resolves one shared pull-request-wide base and is unaffected by member identity. The audit then reviews only `<per-member base>...HEAD`.

The clearance store the per-member arm reads is local, gitignored, and swept on retention: an accelerator, never a system of record. It is empty on every continuous-integration run, so CI resolution always falls back to the whole-team signal and never narrows on the strength of an absent record. A clearance records no reviewed range, so a member's coverage up to its anchor holds by chaining, each clearance inheriting the coverage of the ones recorded before it, a documented assumption rather than a proven invariant.

**The reset is two-tier.** A change to a global-rules path, the files deciding what a member owns, what counts as machinery, how a digest is computed, whether a clearance is believed, which members are dispatched, where the store lives, or under which version any of that was decided, resets every member back to full scope. A change to a member's own agent definition resets only that member. Machinery that is merely shared resets nobody's review base: it still rotates every member's content digest, so a fresh clearance is still required before the merge gate opens, but the review that earns it stays incremental.

**Keys stay shared and are deliberately never per member.** The value keying a member's findings sidecar, the shared re-run ledger, and the consolidated findings block is one pull-request-wide base every dispatched member reaches through the resolver's argument-less form, and review time and merge time derive it identically. `gaia_audit_key` (`.gaia/scripts/audit-key-lib.sh`) combines that one shared base with the branch, and `post-findings-block.sh` globs exactly one key when it reads sidecars back. A member keyed to a different base for this purpose would produce a consolidated block missing that member's findings, with no error raised anywhere; a member's own per-member review base never keys anything.

Every member pipes its findings array into `audit-write-findings.sh --findings -` through a quoted heredoc rather than naming a shared file path. The wave of members runs in parallel against one shared session scratchpad, so a literal placeholder path is the same filename every member would write to: one member's array can land on another's sidecar, and a stale file left by an earlier round can republish as a fresh report. Stdin keys the write to the invoking member's own process instead.

Neither base is ever a commit that failed to anchor. When the classifier, machinery, or rules-changed library cannot be sourced, the resolver emits the full-scope reference on every path and logs the degradation; it never emits a candidate there, which agrees with the merge gate, which already denies outright on the same input. An absent clearance library disables the per-member arm only, the same condition as an empty CI store, and resolution falls back to the whole-team floor with both reset tiers still evaluable. The scope therefore can never skip uncleared code; worst case it reviews too much. A `.gaia/VERSION` bump is a global-rules change and invalidates every prior anchor, forcing a full re-audit under the new ruleset for every member.

**Self-skip is decided on the whole PR diff, not on the increment.** `FULL_BASE` names the whole-pull-request fork point wherever a member needs one that is not a review base: each specialized member resolves it and filters that list against its remit to decide whether it runs at all, and the default member resolves its own for the eligibility set the out-of-scope waive reads (see [[Audit Disposition and Debt Fix]]). The two answer to different branches, because the direction a wider set errs in differs. A self-skip base takes the repository's advertised default, matching the membership resolver: wide only over-dispatches, and a member that skips while membership still demands its marker deadlocks the merge instead. The eligibility base takes the branch the pull request merges into, because wide there waives findings that should be filed. Membership is a function of the whole PR diff (see [[PR Merge Workflow]]), and a member's marker is invalid at HEAD whenever its content digest rotated, which a machinery change does even when the member owns nothing in the increment. Deciding self-skip on the increment lets such a member write no marker while the gate still demands one, and nothing is left that can clear it.

The benefit lands when an audit completes between pushes: a follow-up push reviews only its own delta instead of re-reviewing the whole PR. The `cancel-in-progress` concurrency policy means rapid-fire pushes cancel before a base is stamped, so they fall back to full scope safely. The one risk an incremental scope must guard is a delta that breaks an already-cleared caller, and each member answers it in its own domain: importers of a changed export for the frontend and the CLI TypeScript, sourcers and `bash` callers plus the bats suites pinning a script's output for shell, `uses:` references and `needs.*.outputs` reads for workflows, and files cross-referencing a changed instruction file for prose.

**The reviewed range is `<per-member base>...HEAD` for the member that resolved it, three-dot and against the HEAD commit.** A member's clearance digest is computed over `git ls-tree HEAD` (`.claude/hooks/lib/audit-digest.sh`), so its review scope has to be HEAD's content or the marker attests to bytes the member never read. The two-dot spelling (`git diff <base> -- <paths>`, no `...HEAD`) compares the base to the working tree instead, and diverges from the digest in three ways at once: a change committed and then reverted in the working tree leaves the reviewed list while the marker still covers it, an uncommitted edit enters the list where no marker can cover it and the dispatch oracle never saw it, and a base that is a ref whose tip has advanced past the fork point drags in every file the default branch changed. Three-dot resolves its own merge base, so it is immune to all three regardless of whether the resolver returned a sha or a ref. `merge-base` runs twice, once against the per-member base for the diff and once against the shared base for the key: `gaia_audit_key` needs the latter's stable sha.

`.gaia/scripts/check-audit-base-derivation.sh` holds the arrangement in place with four assertions over `.claude/agents/`. No review base may come from a bare `merge-base` against the default branch; the named `FULL_BASE` and `KEY_BASE` exemptions, covering a specialist's self-skip derivation, the default member's eligibility derivation, and the shared artifact-keying base, are the exceptions, by name, because the name is what tells a legitimate whole-PR fork point or shared key apart from a drifted review base. Every definition naming `BASE_SHA` must also name the resolver. No `diff --name-only` may consume the base without a three-dot range, which is what keeps the reviewed scope and the digest on the same content. And none may consume it without `-z`: git's default `core.quotePath` C-quotes any path carrying non-ASCII or control bytes, and a quoted token matches no remit glob. A member filtering that list self-skips as if nothing it owned had changed, and the membership resolver reading the same list names no owner at all, which sends the dispatch to its ownerless fallback and the default member. Either way the specialist whose remit the file is in never reviews it, and nothing in the run says so.

Each member's resolution is recorded: the per-member base, a reason drawn from a closed set (an earned clearance, the whole-team floor, no usable anchor, one of the two reset tiers, a flat machinery reset, degradation, or a missing version file), and the clearance that anchored it. The record rides that member's own findings sidecar and is projected into the consolidated findings block (see [[PR Merge Workflow#Findings block]]), so it survives the local store's pruning and reaches a reviewer even though the store itself is swept.

<!-- gaia:maintainer-only:start -->
`.gaia/scripts/tests/audit-base-agreement.bats` is the behavioural counterpart: it executes the real derivation snippets and compares the file lists they produce, covering the multi-line drift a line-scoped static check cannot see.
<!-- gaia:maintainer-only:end -->

## Re-run carry-forward ledger

The local fix → re-audit loop carries its state across rounds in a gitignored per-base-and-branch file, `.gaia/local/audit/<audit-key>.rerun.json` (`<audit-key>` is the incremental base sha plus the acting tree's own branch, `.gaia/scripts/audit-key-lib.sh`, so two worktrees sharing a base sha never collide on this filename; see [[Worktrees]] for the shared-state model this keying follows). The ledger holds the in-scope findings still open, what was fixed last round, the cleared/incremental base, and a round counter, so the carried state is deterministic and lossless instead of living in the orchestrator thread's degrading memory.

The ledger keys on the shared pull-request-wide base (the fork point `git merge-base "$BASE_REF" HEAD`, resolved the same way every dispatched member resolves the shared base through the resolver's argument-less form), not HEAD, and not any member's own narrower per-member review base. The per-member marker (`<digest>.ok` for the frontend, `<digest>.<member>.ok` for a specialist) and the dispositions sidecar (`<frontend-digest>.dispositions.json`) key on each member's own content digest, not HEAD, because they certify the content that member reviewed. A fix commit that touches frontend-owned content rotates the frontend digest, and both artifacts, just as a HEAD move used to; a commit that touches nothing any member owns and no machinery leaves every digest, and every marker, valid. The ledger accumulates "what is still wrong relative to the cleared base," and that base fork point is stable across fix rounds within one loop, so the remaining items survive the HEAD moves each fix commit produces with no HEAD-chaining logic. Its `remaining[]` carries in-scope open findings only; out-of-scope findings stay in the dispositions sidecar (see [[Audit Disposition and Debt Fix]]).

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

`finding_class` follows a per-bucket convention: oracle buckets use the tool's own id prefixed (`react-doctor/...`, `axe/...`, `knip/...`, `cve/...`); holistic and rule-subagent buckets draw from a constrained vocabulary seeded in the `finding_class` schema, not in the agent definition. The frontend member carries a mirror of it; the schema is authoritative.

<!-- gaia:maintainer-only:start -->
The schema lives at `.gaia/cli/src/schemas/finding-class.ts`.
<!-- gaia:maintainer-only:end -->

A finding with no stable class is not omitted: it is stamped `holistic/unclassified` and included, and it surfaces as the distinct unclassified recurrence signal.

The CI workflow appends structured findings as an HTML-comment block at the end of its PR comment (framed by `<!-- gaia-harden:findings:start -->` / `<!-- gaia-harden:findings:end -->` sentinel lines). The cross-machine tally in [[Policy-Memory Loop]] reads this block via `gh` when computing recurring-finding candidates.

## Trigger

Always before `gh pr merge` ([[PR Merge Workflow]]), enforced by the `pr-merge-audit-check.sh` advisory hook ([[Claude Hooks]]). Also on demand for any review.
