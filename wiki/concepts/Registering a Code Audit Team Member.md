---
type: concept
status: active
created: 2026-07-18
updated: 2026-07-18
tags: [concept, ci, audit, claude]
---

# Registering a Code Audit Team Member

The [[Code Audit Team]] gate dispatches specialized auditor members by file glob rather than running one generic reviewer over every diff. Adding a member is config plus an agent file: the dispatch resolver is generic over the roster, so registering a member never touches `.gaia/scripts/resolve-audit-members.sh` itself.

## Registration steps

### 1. Author the agent definition

Write `.claude/agents/<name>.md` following the shape of the existing members: `name` / `description` / `model` / `color` frontmatter, a **Remit and self-skip** section that resolves the diff base and filters changed files to the member's own globs (self-skipping cleanly, writing no marker, when nothing matches), **Review dimensions**, a **Finding Proof Gate**, **Findings grading** (which severities the member may use), an advisory-only or self-heal stance, **Cross-remit findings** handling, an **Output Format** section, the **Gate handshake** (mark / stamp / status), a **Findings sidecar** for the recurrence tally, and a **Methodology** summary. The `description` states the member's remit and self-heal stance in one line, since that's what a dispatching agent reads first.

### 2. Register in the roster

Add an entry to the `auditors:` list in `.gaia/audit-ci.yml`: `name`, `globs`, `scope` (`adopter` or `maintainer-only`), and `push_fixes`. Mirror the same entry, verbatim, into `_audit_scope_builtin_roster()` inside `.claude/hooks/lib/audit-scope.sh`, the built-in fallback roster the ownership classifier parses when `.gaia/audit-ci.yml` carries no `auditors:` block. The two stay in lockstep: a glob present in the config but missing from the fallback leaves that path ownerless whenever the fallback is the one in effect.

### 3. Wire into the machinery set

Add the new agent file's path to `AUDIT_MACHINERY_PATHS` in `.claude/hooks/lib/audit-machinery.sh`, and to the mirrored `GATE_MACHINERY_FILES` list in `.gaia/scripts/audit-machinery-complete.sh`. Every member's clearance marker keys to a content digest computed over the files it owns plus this machinery set; an agent file missing from either list rotates no digest when it changes, so a rewrite of the member's own instructions would merge unaudited by that member. `.gaia/scripts/audit-machinery-complete.sh` asserts the two lists agree.

### 4. Add a finding_class bucket, if the member needs new classes

A member reporting an **oracle** finding, backed by a deterministic tool (`react-doctor/`, `axe/`, `knip/`, `cve/`), needs no schema change: the tool owns the id space after its prefix, and any well-formed slug is valid. A member reporting findings in a genuinely new category needs a new closed-vocabulary bucket in the `finding_class` schema: a new prefix, a seeded `as const` union of specific classes, and that union folded into the closed-vocabulary set the validator checks against. Keep new classes genuine root-cause categories the member can assign reliably and repeatably, never a subsystem tag standing in for "somewhere in this member's remit." When in doubt, leave a class out; an unclassed finding still stands in the member's prose report, it just carries no recurrence signal.

<!-- gaia:maintainer-only:start -->
The schema lives at `.gaia/cli/src/schemas/finding-class.ts`, maintainer-only CLI source that never reaches an adopter clone. A bucket added there only reaches the shipped `harden-tally` command once the bundled binary is rebuilt (see step 6).
<!-- gaia:maintainer-only:end -->

### 5. Integrate the recurrence tally

The finding-recurrence tally reads each member's findings sidecar to feed `/gaia-harden`'s judge-the-form logic. If the new member's finding classes need routing guidance beyond the default (a mechanizable pattern routes to a deterministic check, a judgment call routes to a prose rule), add a short paragraph to `.claude/skills/gaia/references/harden.md` describing how the new bucket routes, alongside the existing oracle / holistic / rule / workflow / prose paragraphs.

<!-- gaia:maintainer-only:start -->
### 6. Regenerate the CLI binary

A finding-class schema change only reaches the shipped `harden-tally` command once the bundled adopter binary (`.gaia/cli/gaia`) is rebuilt from `.gaia/cli/src` and committed alongside the schema edit. Skipping this leaves the schema and the binary disagreeing about the valid vocabulary.

### 7. Release-exclude any test fixtures

A `scope: maintainer-only` member's agent file, and any fixtures or bats suites written to exercise it, belong in `.gaia/release-exclude` so the release scrub strips them from the adopter bundle. A `scope: adopter` member ships as-is and needs no exclusion entry.
<!-- gaia:maintainer-only:end -->

## Choices to make per member

- **Advisory vs. gating.** `push_fixes: true` lets the member self-heal (push a fix commit) as part of clearing its own marker; `push_fixes: false` makes it advisory-only, it reports and then clears or withholds, but never rewrites the tree. No auditor may self-heal the surface that runs auditors, regardless of its own `push_fixes` setting: a deterministic push gate refuses a self-heal touching workflow YAML, the roster, the machinery scripts, or the agent definitions that produce clearances.
- **`scope`.** `adopter` ships to every clone. `maintainer-only` entries sit inside `# gaia:maintainer-only` marker comments in both the roster and the builtin fallback, and the release scrub strips them, so an adopter's fallback roster only ever carries adopter-scope members.
- **Globs and roster disjointness.** Every claimant member's globs are matched first-match-wins over roster order; the default member's globs are a catch-all tier reached only once every claimant has failed to match. Two claimants must never claim overlapping territory, an overlap silently hands a path to whichever member the roster happens to list first. `.gaia/scripts/verify-audit-roster.sh` checks pairwise claimant-glob disjointness as glob languages (not just against files that happen to exist today), machinery registration, and that exactly one member carries `default: true`. It ships to every clone and is not wired into CI or a hook automatically, run it by hand after any roster change: `bash .gaia/scripts/verify-audit-roster.sh`.

<!-- gaia:maintainer-only:start -->
## Local-gate checklist

Registering a member touches shared classifier and merge-gate machinery, not just the new agent file, so the bats suites guarding that machinery are the local gate for the change. Run all of these before merge:

- `bash .gaia/scripts/verify-audit-roster.sh`, the roster's own deterministic check (disjointness, machinery registration, exactly-one-default).
- `.gaia/tests/hooks/audit-scope-lib.bats`, structural and invariant tests over the shared ownership classifier (`.claude/hooks/lib/audit-scope.sh`): golden ownership-resolution cases, the machinery-is-roster-claimed invariant, and scrub-marker survival.
- `.gaia/tests/hooks/audit-scope-routing-parity.bats`, the before/after routing-parity proof: it classifies every tracked file against a committed fixture snapshot and asserts each resolves to its prior owner, except the named set of paths a deliberate roster change is moving. A new member's globs belong in that named-exception set.
- `.gaia/tests/hooks/pr-merge-audit-check.bats`, tests over the local merge-gate deny-hook itself: the dispatched-member set it resolves, and the AND-aggregation across every dispatched member's own marker.

All four read live roster and machinery state, so a registration that only edits `.gaia/audit-ci.yml` and the agent file, without updating the fallback roster or the machinery lists in lockstep, is exactly the drift these checks exist to catch before CI does.
<!-- gaia:maintainer-only:end -->

## Pairs with

- [[Code Audit Team]]: the roster mechanism, ownership classifier, machinery-digest keying, and AND-aggregation this page's steps plug into.
- [[Policy-Memory Loop]]: what happens to a member's findings once they start recurring.
