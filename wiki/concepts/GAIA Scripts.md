---
type: concept
status: active
created: 2026-09-20
updated: 2026-09-20
tags: [concept, gaia, scripts]
---

# GAIA Scripts

`.gaia/scripts/` is GAIA's shell layer: the shared libraries its hooks and skills source, the deterministic checks its gates run, and the small command-line helpers its workflows shell out to. It is flat by design, one level of `.sh` at the root plus a handful of single-purpose subdirectories, and the flatness is a tested contract rather than a convention, so a script is added beside its siblings rather than filed under a new folder.

Nothing in the directory itself says what any file is, which family it belongs to, or whether it reaches an adopter at all. This page is that index.

## The index

One row per file at the root of `.gaia/scripts/`, grouped by name prefix, because the prefix is the only structure the directory carries and it tracks what a script is for.

**Ships.** Whether the file reaches an adopter. The column restates the release boundary's verdict; it decides nothing itself.

**Invoker.** What runs the script: a CI job, a hook, a skill or slash command, another script, or a human. `sourced` marks a library that defines functions and runs nothing on its own, so it has no invoker of its own and is read through whatever sources it.

<!-- gaia:maintainer-only:start -->
`yes` in that column means the file reaches an adopter and `no` means it is withheld and exists only in the maintainer repository; `.gaia/manifest.json` and `.gaia/release-exclude` are the authorities it restates. The split runs along family lines and is invisible from the directory itself.

The maintainer's copy of this page carries every root file. An adopter's copy carries only the `yes` rows, so every row they read says `yes`: each withheld row ends in a single-line `gaia:maintainer-only` marker pair, which the bundle-time scrub drops whole before tar, so both audiences read one table built from one source. Prose that names a withheld path is wrapped the same way. See [[Bundle-time Scrub]] and [[Release Workflow]].

The index is held to the tree by `.gaia/scripts/lint-scripts-wiki-inventory.sh`, which reds when a root file exists that this page never mentions. That check is what makes an enumeration safe to keep on a page at all: an unenforced list caches a fact and drifts from it silently. It asks that one direction only; a file deleted from the tree and left on this page is real drift and is not covered, for the reasons its own header records.
<!-- gaia:maintainer-only:end -->

### `audit-`

| Script | Ships | Invoker | What it is |
|---|---|---|---|
| `audit-key-lib.sh` | yes | sourced | Mints the worktree-partitioned key every audit artifact path is built from, and the general slug rule those keys share. |
| `audit-member-digest.sh` | yes | CI, audit hooks, agent definitions | Prints one Code Audit Team member's content digest, and exits non-zero printing nothing on any condition it cannot resolve. |
| `audit-noop-detect.sh` | yes | `.claude/rules/subagent-dispatch.md`, the audit fan-out surfaces | Decides whether a dispatched agent's report artifact is a real result or a silent no-op. |
| `audit-resolve-scope.sh` | yes | every Code Audit Team agent definition | Resolves a member's review scope in one command: diff bases, changed-file lists, the dirty-in-scope check, and the scope digest. |
| `audit-respawn-lib.sh` | no | sourced | Shared reader and writer for the audit re-spawn ledger. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `audit-respawn-prune.sh` | no | `wiki-session-start.sh` hook | Prunes aged rows out of the re-spawn ledger. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `audit-respawn-report.sh` | no | by hand | Attribution query over the re-spawn ledger: which member was re-spawned, and against what. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `audit-scope-digest.sh` | yes | agent definitions, `local-janitor.sh` hook, CI | Carries a member's own content digest between scope resolution and clearance write, the two Bash calls that must agree. |
| `audit-scratch-dir.sh` | yes | agent definitions | Hands a member a per-run scratch directory when it needs real bytes on disk. |
| `audit-seed-dispositions.sh` | yes | agent definition, audit hooks | Seeds the default member's disposition ledger forward from the prior digest's sidecar. |
| `audit-window-lib.sh` | yes | sourced | Shared derivation of the audit window a run is accounted against. |
| `audit-write-clearance.sh` | yes | agent definitions, CI | The one writer for every Code Audit Team clearance marker. |
| `audit-write-findings.sh` | yes | agent definitions | The one writer for a member's findings sidecar, the report of record the merge workflow reads. |

### `check-`

| Script | Ships | Invoker | What it is |
|---|---|---|---|
| `check-audit-base-derivation.sh` | yes | GAIA's own invariant harness (maintainer-side) | Keeps every Code Audit Team member resolving one review base rather than several. |
| `check-audit-key-callers.sh` | yes | GAIA's own invariant harness (maintainer-side) | Asserts the agent definitions that name an audit artifact actually call the shared key helper instead of hand-building a path. |
| `check-base-provenance-adoption.sh` | no | GAIA's own invariant harness | Adoption check for the shared base-provenance resolver: flags a consumer that resolves provenance its own way. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `check-cli-workspace-floors.sh` | no | `cli-advisory-scan.yml`, `cli-tests.yml` | Reports security floors that have stopped being applied in a pnpm workspace root outside the repository root. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `check-debt-issue-metadata.sh` | yes | `code-review-audit.yml`, the audit agent, `/gaia-debt` | Validates the label set and dedup key a tech-debt filing carries against the filing rules. |
| `check-hook-command-rooting.sh` | yes | GAIA's own invariant harness (maintainer-side) | Asserts every hook command in `.claude/settings.json` is rooted at the repository top level rather than at the working directory. |
| `check-hook-scope-manifest.sh` | yes | GAIA's own invariant harness (maintainer-side) | Scans every hook for a `.gaia/local` path built without a resolved root. |
| `check-main-root-derivation.sh` | no | GAIA's own invariant harness | Catches a hand-rolled main-checkout derivation inlined into a consumer that declares no resolver at all. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `check-registry-completeness.sh` | no | GAIA's own invariant harness | Reconciles the state registry against the frozen inventory denominator. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `check-registry-runtime.sh` | yes | GAIA's own invariant harness (maintainer-side) | Reconciles the state registry against the runtime directory it describes. |
| `check-registry-settings-permissions.sh` | yes | GAIA's own invariant harness (maintainer-side) | Reconciles `.claude/settings.json` permissions against the state registry. |
| `check-registry-source-literals.sh` | no | GAIA's own invariant harness | Reconciles the state registry against the path literals tracked source actually spells. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `check-resolver-singleton.sh` | no | GAIA's own invariant harness | Asserts one canonical main-checkout resolver per language, never a second definition. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `check-scope-digest-adoption.sh` | no | GAIA's own invariant harness | Adoption check for the scope-digest staleness gate across the agent definitions. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `check-step-body-extractor-roster.sh` | no | GAIA's own invariant harness | Asserts the bats suites agree about how they extract a step out of the audit workflow, as a declared roster rather than a grep recipe. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `check-updates.sh` | yes | `SessionStart`, the statusline | Background check for a newer GAIA release, feeding the statusline update nudge. |
| `check-verb-arming-adoption.sh` | no | `audit-ci-tests.yml` | Adoption check for the shared verb-arming decision across the hooks that gate on a command verb. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `check-wiki-state-collision.sh` | no | `audit-ci-tests.yml` | Catches two branches advancing `wiki/.state.json` to different positions on the same lines. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->

### `cost-`

| Script | Ships | Invoker | What it is |
|---|---|---|---|
| `cost-represented.sh` | yes | the archive scripts | Value-aware, fail-closed gate that a run is represented in the cost ledger before its folder is reduced. |

### `debt-`

| Script | Ships | Invoker | What it is |
|---|---|---|---|
| `debt-count-refresh.sh` | yes | the statusline | Recomputes the open tech-debt count the statusline nudge shows. |
| `debt-stale-claims.sh` | yes | `/gaia-debt` | Prints the number of every open tech-debt issue whose `in-progress` claim is stale. It never strips a label; the caller does. |

### `lint-`

| Script | Ships | Invoker | What it is |
|---|---|---|---|
| `lint-awk-interpreter-pin.sh` | no | GAIA's own shell-lint harness | Flags a bare `awk`, `gawk`, `mawk` or `nawk` in command position inside the `guard-awk-lib.sh` closure, where the resolved `GAIA_AWK` is the required form. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `lint-collapsed-signal-trap.sh` | no | `shell-lint.yml` | Flags one `trap` arm binding EXIT together with INT or TERM, the shape that leaves a script uninterruptible. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `lint-errexit-source-guard.sh` | no | `shell-lint.yml` | Flags a `source` that can run with errexit armed and is not bracketed against an unparseable target. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `lint-errexit-status-read.sh` | no | `shell-lint.yml` | Flags `$?` read after a command-substitution assignment under `set -e`, where it reports the wrong command. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `lint-git-path-quoting.sh` | no | `shell-lint.yml` | Flags an executed git listing that names files without `-z`, so a C-quoted path reaches the reader mangled. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `lint-grep-ere-escapes.sh` | no | `shell-lint.yml` | Flags a `grep -E` pattern whose escapes mean different things under BSD and GNU regex. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `lint-guard-rule-shell-coverage.sh` | no | GAIA's own shell-lint harness | Flags a tracked shell file the guard and diagnostic rules do not reach. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `lint-hook-advisory-classification.sh` | no | GAIA's own shell-lint harness | Flags a hook that stops a tool call but is filed under an Advisory heading on a wiki page. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `lint-hook-array-guard.sh` | yes | GAIA's own CI (maintainer-side) | Flags unguarded bare array expansions under `set -u` across the framework's own bash, the bash-3.2 empty-array class. |
| `lint-hook-cwd-relative-loads.sh` | no | GAIA's own shell-lint harness | Flags a hook that locates the framework code it loads from the working directory rather than from its own path. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `lint-hook-jq-availability.sh` | no | GAIA's own shell-lint harness | Flags a blocking hook that parses its payload with jq and fails open when jq is absent. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `lint-hook-monitor-arming.sh` | no | GAIA's own shell-lint harness | Flags a blocking command-reading guard bound to `Bash` alone, which a `Monitor`-armed command walks past. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `lint-hook-wiki-inventory.sh` | no | GAIA's own shell-lint harness | Flags a hook absent from the bundled-hooks inventory page. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `lint-retired-label-spellings.sh` | no | GAIA's own invariant harness | Fails when a label spelling the registry records as retired still occurs in tracked source. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `lint-scripts-wiki-inventory.sh` | no | GAIA's own shell-lint harness | Flags a root script of this directory absent from the index on this page. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `lint-shipped-issue-refs.sh` | no | `audit-ci-tests.yml` | Flags an unqualified issue or pull-request reference on a shipped non-Markdown file. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `lint-sigpipe-readers.sh` | no | `shell-lint.yml`, `audit-ci-tests.yml` | Flags a short-circuiting reader downstream of a pipe under `pipefail`, where the pipeline status inverts on a match. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `lint-stale-cardinals.sh` | no | GAIA's own shell-lint harness | Flags a definite cardinal in a comment or a bats test name that states how many of something the tree holds, where nothing recounts the set. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `lint-wiki-cached-version.sh` | no | GAIA's own shell-lint harness | Flags a `version:` field in wiki frontmatter, a hand-kept copy of a number `package.json` already holds. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `lint-workflow-run-interpolation.sh` | no | `shell-lint.yml` | Flags a `${{ }}` expression substituted into a workflow `run:` body, the script-injection shape. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->

### `token-`

| Script | Ships | Invoker | What it is |
|---|---|---|---|
| `token-pricing-lib.sh` | yes | sourced | Shared rate-table resolution and the pricing jq definitions the ledger readers share. |
| `token-rates.json` | yes | read by the pricing lib | The rate card the cost ledger prices rows against. |
| `token-rollup.sh` | yes | `token-rollup-merge.sh` hook | Reads the token ledger and rolls it up for reporting. |
| `token-tally.sh` | yes | the cost-accounting hooks | Appends a run's token and dollar tally to the ledger. |

### `verify-`

| Script | Ships | Invoker | What it is |
|---|---|---|---|
| `verify-audit-roster.sh` | yes | run by hand (maintainer-side) | Deterministic check of the Code Audit Team roster against the member definitions it generates. |
| `verify-cli-bundle-fresh.sh` | no | `cli-tests.yml`, `release.yml` | Asserts the committed CLI bundles and templates are exactly what rebuilding from source produces. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `verify-required-checks.sh` | no | `/gaia-release` preflight | Detects drift between the checks this repo requires to merge and the live GitHub ruleset. It never writes to the ruleset. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->

### Unprefixed

| Script | Ships | Invoker | What it is |
|---|---|---|---|
| `append-audit-author.sh` | yes | `/setup-gaia` | Writes one `login=mode` pair into the audit config's author knob without clobbering other entries. |
| `archived-backlog-migrate.sh` | yes | by hand, once | One-time, human-gated removal of the pre-existing archived spec and plan backlog. |
| `assert-no-release-leak.sh` | no | `release.yml` | Proves no release-excluded path survived into the tree that becomes the tarball. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `awk-interp-lib.sh` | no | sourced | Resolves `GAIA_AWK`, the sanctioned awk interpreter (mawk or BWK one-true-awk) the awk-tokenizer guards run under. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `bats5.sh` | yes | the bats runners | Runs bats under a bash 5 when one is available, so local matches CI. |
| `branch-name-lib.sh` | yes | sourced, and run as a command by the skills | GAIA's branch-naming convention: the one place a branch or worktree name is minted and read back. |
| `chore-deps-skip.sh` | yes | `tests.yml`, `chromatic.yml`, `code-review-audit.yml`, `pr-merge-audit-check.sh` | The single source for the `chore(deps)` skip predicate every CI gate shares. |
| `gh-artifact-lib.sh` | yes | sourced | Shared breadcrumb for the GitHub pull request a run produced. |
| `guard-awk-lib.sh` | no | sourced | Shared awk scaffolding the guard lints build their detectors on. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `hook-registration-lib.sh` | no | sourced | The shared read of `.claude/settings.json`'s registrations, and the oracle for whether a registered hook can stop a tool call. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `knowledge-audit-clean.sh` | yes | `/gaia-audit` | Confirms a zero-action knowledge-audit report covered every store before it may skip the decision gate. |
| `ledger-path-lib.sh` | yes | sourced | The one definition of every main-checkout ledger path, so renaming one changes one place. |
| `ledger-status-migrate.sh` | yes | `local-janitor.sh` hook | One-time, idempotent migration of spec and plan ledger rows onto the unified status vocabulary. |
| `link-worktree.sh` | yes | `provision-worktree.sh` hook, `/setup-gaia` | Lays the shared-state symlinks a linked worktree needs. |
| `list-tracked-paths.sh` | no | `release.yml` | The one boundary where release staging turns git's NUL-delimited tracked set into the newline-delimited list its consumers read. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `main-only-lib.sh` | yes | the main-only skills | Refusal helper for a flow that must run in the main checkout, never a linked worktree. |
| `main-root-lib.sh` | yes | sourced by most hooks and scripts | GAIA's shared main-checkout resolver: the one answer to which checkout am I in. |
| `mentorship-cleanup-sweep.sh` | yes | `local-janitor.sh` hook | One-time, idempotent destruction of the mentorship residue a checkout carries. |
| `plan-archive.sh` | yes | `local-janitor.sh` hook, the plan-close flows | Reduces or deletes a merged plan folder. |
| `plan-resume-point.sh` | yes | `/gaia-plan` | Deterministic phase-level resume point for a plan picked up mid-flight. |
| `post-findings-block.sh` | yes | agent definitions, `post-findings-block-on-merge.sh` hook | Merges every dispatched member's findings sidecar into one machine-readable block and posts it on the pull request. |
| `pr-wait-merge.sh` | yes | the merge workflow, `/gaia-release`, every flow that merges | The merge wait: polls a pull request to `MERGED` and exits early on every state that means it never will. |
| `read-audit-ci-config.sh` | yes | `code-review-audit.yml`, the merge workflow, audit hooks | Reader and per-author resolver for the audit CI config, so a flow obeys the project's own settings. |
| `resolve-audit-members.sh` | yes | the merge workflow, audit hooks, CI | Resolves which Code Audit Team members a diff dispatches. |
| `resolve-audit-spawn.sh` | no | the merge workflow, audit hooks | The spawn oracle: which members this run actually spawns, re-spawns included. |<!-- gaia:maintainer-only:start --><!-- gaia:maintainer-only:end -->
| `state-registry-lib.sh` | yes | sourced | Reader for the state registry, the record of every runtime path GAIA writes. |
| `summary-verify.sh` | yes | the spec and plan close flows | Fail-closed verify gate for the consolidated summary artifact, run before the irreversible removal of the layers it replaces. |
| `write-audit-remits.sh` | yes | GAIA's own CI (maintainer-side) | Generates each Code Audit Team member's remit region from the roster. |

## Subdirectories

The root holds the shell layer; each subdirectory holds one thing that is not shell, or is not a script at all. None of them is a second tier of the index above, and nothing that holds this page to the tree descends into any of them.

| Directory | What is in it |
|---|---|
| `a11y-structural/` | The Node helper that decides whether an accessibility assertion is structurally trivial. |
| `audit-ledger/` | The Node writer that appends a worthiness verdict to the audit ledger. |
| `classifier/` | The Node helper that classifies a test as deterministic or not. |
| `lib/` | Shell that is sourced by a root script rather than run: the Serena language helper. |
| `red-ledger/` | The Node extractor that reads test signals out of a RED run, plus its own README. |

`tests/` is separate, and separate on purpose. It holds the bats suites that guard the root scripts, and it is far larger than everything above it put together. A suite there is the blocking runner for the guard beside it, which is why a guard's conformance lives next to the guard rather than in the general test tree. It is not indexed here: a suite is discovered from the script it names, so an index of it would be an index of the index above.

## Adding a script

A new file at the root of `.gaia/scripts/` owes **a row on this page**, in the family its prefix names, with its invoker and what it is. That is every root file, not only the shell: a data file the scripts read is as invisible from the directory as a script is. The index is the only place the directory says what anything is, so a file added without a row is a file nobody can find.

Naming: take the family prefix that matches what the script does (`check-` and `lint-` for a deterministic gate, `audit-` for the Code Audit Team's machinery, `cost-` and `token-` for the accounting ledger, `debt-` for the tech-debt backlog, `verify-` for a drift check against an external authority), and `*-lib.sh` for a file that is sourced rather than run. A script that fits no family takes a plain descriptive name and joins the unprefixed table.

**Do not reorganize the directory into subfolders.** The single-level glob `.gaia/scripts/*.sh` is a contract several places depend on by value, not a hazard to be tidied away: it is asserted in a bats suite, it is a literal registry entry, and it is what a worktree provisioning step chmods through. A new subdirectory leaves all three reading a tree that no longer matches, silently. Reference density compounds it, worst in the family with the cleanest case for a move: its members are each named across dozens of files, so relocating one family is a several-hundred-file rename for no functional gain. This directory has already paid for a location change once, recorded in GAIA's own release health taxonomy: moving it across the release boundary added it as a manifest-owned tree without adding it as a scan target to either distribution-boundary primitive, and the repair covered the one file its finding named rather than the tree it had un-excluded.

<!-- gaia:maintainer-only:start -->
Three further decisions ride with a new root script in the maintainer repository, and each one is a real edit somewhere else:

- **Ship or withhold**, through `/distribution-audit`. The release CLI refuses to produce a manifest until every newly-shipping file has an answer, so this one cannot be skipped, only deferred to the release that trips over it.
- **Whether a CI job's paths filter arms on it.** A scan surface a job reads that its filter does not arm on reports green having run the assertion zero times, which is the arming-stage failure `.claude/rules/guards-must-fail.md` names: adding a root to a scan is always two edits, the scan and the filter. The bats shards are discovered by glob rather than enumerated, so a sibling suite needs no registration of its own. Read a filter entry for which question it answers before adding one, because the two look alike and are not: whether the job runs at all, and, where a job narrows further, which of its legs run.
- **Whether it folds into `.gaia/tests/shell-lint.sh`** alongside the other guards shellcheck cannot model, and whether it is advisory or blocking there.
<!-- gaia:maintainer-only:end -->

## Why a guard must be able to fail

A guard (a test assertion, a lint script, a CI condition, a hook precondition) is only evidence of anything when red is reachable. A guard that cannot go red says nothing, in the exact voice of one that checked and approved. The failure is silent by construction: it surfaces as a construct nobody defends, discovered when the construct breaks in a place the guard was believed to cover. Three independent stages can lose a guard its power to fail; sound at two of three still proves nothing.

- **Discovery, the input set.** The step that builds the guard's own input set can drop an element and say nothing: a glob that misses an extension, an over-reaching `find` prune, a manifest-derived list that does not enumerate every member, a tracked-file listing that cannot see a file not yet tracked. An empty or short input set reads exactly like a clean pass. The untracked variant is the sharpest case: a new guard and its sibling suite are both untracked at the moment the author first runs the guard to check the tree is clean, and those two files are the ones most likely to carry the class deliberately (a guard's header quotes its own class as worked counter-examples, its suite spells the class out in fixtures), so the very first run reports clean over the set most likely to red.
- **Arming, which inputs reach the check.** The check is correct wherever it runs, but its arming condition covers less than the surface the rule governs: a path filter narrower than the files the rule binds, a changed-files list omitting a directory, a refinement keyed to an optional field's presence. The diff that creates the obligation is the one that skips the check.
- **Match region, what the check accepts.** The assertion runs on the right input but admits a region wider than the construct its own name pins: a needle satisfied by surrounding boilerplate or unrelated prose, a snapshot standing in for the behavioral claim beside it, an exit-code check where the message content is the actual claim. Corrupt the construct and the check stays green.

Correct pattern: prove the guard can fail before relying on it (break the construct, run the guard, confirm red; restore, confirm green; commit an awkward-to-hand-break fixture instead), assert the input set is non-empty and the expected size (derived from the same source the rule binds to, never a hand-maintained parallel list), derive the arming condition from the surface the rule governs, and pin the match region to the construct (anchor the pattern, match the full value, assert on the field carrying the behavioral claim).

Where discovery reads tracked files, the new guard and its suite must be visible to it before the run that validates them: `git add` them first for an index-reading discovery (`git ls-files`, `git grep`); a committed-ref discovery (`git ls-tree HEAD`) needs the commit itself. Run the discovery command on its own and confirm the two new paths appear in its output, which is the only thing distinguishing a clean pass from a pass over a set that never held them.

Mechanism-level cases on the `.bats` surface, where an assertion's status never reaches the test result at all, are `.claude/rules/bats-assertions.md`.

See [[Claude Hooks]], [[Code Review Audit Agent]], [[PR Merge Workflow]], [[Quality Gate]].
