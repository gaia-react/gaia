---
type: decision
status: active
priority: 2
date: 2026-07-20
created: 2026-07-20
updated: 2026-07-20
tags: [decision, distribution, maintainer, cli, shell]
---

# Folding Shell Scripts into the CLI Binary

> [!note] Audience
> Maintainer-only. This page is excluded from adopter distribution by `.gaia/release-exclude`. It records an architecture choice about how GAIA-the-template is built and shipped; adopters never rebuild the binary, so the question has no adopter surface. Sits alongside [[CLI-Binary-Split]] and [[Bundle-time Scrub]].

**Status:** Declined. Revisit only under the narrow condition in "The one parked option."

## The question

Can the roughly 109 shipped `.sh` files (hooks, `.gaia/scripts`, spec-kit lib, CI helpers, statusline) fold into the single `.gaia/cli/gaia` Node binary, or into a separate shell binary, so that `/update-gaia` diffs get simpler and `.gaia/manifest.json` gets smaller? Pushback was invited if this misreads the CLI-versus-`.sh` split. It does.

## Why both premises fail

- **"Smaller manifest means simpler diffs" is false.** `.gaia/manifest.json` is a sentinel path: the update walk replaces it wholesale with the latest version's copy and never three-way-merges it (see [[Update Workflow]], "Sentinel paths" and Step 8). Its entry count has zero effect on merge complexity or on any adopter-facing diff. Shrinking it changes nothing an adopter experiences.
- **"The binary already churns every release, so folding is free" is false.** esbuild is deterministic: unchanged source produces identical bytes. `.gaia/cli/gaia` has 14 distinct release builds across the 16 tags that carry it and changes in roughly 7 of 15 consecutive release windows (about half, not every release). In full maintainer history it is touched by 68 commits with 68 distinct blobs, so it is already a frequently rebuilt, opaque 1 MB blob in the maintainer git log. Folding every `.sh` in makes each hook or script edit rebuild that blob, pushing release churn toward 100% and adding to the maintainer commit churn. The maintainer diff gets larger and more opaque, not smaller.
- **The fold is a delete, and delete is not silent.** For a pristine adopter (`adopter[P] == baseline[P]`) an upstream deletion prompts `delete (default) / keep` (Update Workflow deletion table). Folding therefore manufactures a one-time per-file prompt on every adopter's next update. It adds an adopter-facing event; it does not remove one.
- **On the ongoing modify path the diff is degraded, not simplified.** The update lands changes as ordinary working-tree edits for the adopter to review. Folding replaces N readable `.sh` text diffs with one unreviewable 1 MB binary blob in that same commit.

## Why most files cannot move even if the premise held

- **Hot guards fire 21 times per Bash tool call.** `.claude/settings.json` runs 15 PreToolUse hooks on the `Bash` matcher plus 6 PostToolUse hooks, all invoked by path, on every Bash tool call. The bundled Node binary cold-starts at about 50 ms measured, versus a few ms for bash. Routing those through the binary adds on the order of one second of latency per Bash command. The guards already fast-path in pure bash and reach for heavier logic only on rare branches (for example `worthiness-presence-check.sh` exits early for any non-`gh pr merge` command).
- **A Node-binary hook cannot fail-open.** Bash guards defensively skip when node is unavailable (`command -v node || exit 0`). Folded into the `#!/usr/bin/env node` binary, an unresolved node either fails closed (breaking every tool call) or the safety guard silently disappears. Both are worse than the bash skip.
- **Sourced libs export functions, not commands.** The `lib/` scripts (`.claude/hooks/lib/*`, `with-ledger-lock.sh`, `title-normalize.sh`) are sourced (`. lib.sh`), so they are categorically not subcommands.
- **Cross-directory ledger mutex.** `with-ledger-lock.sh` is sourced by both spec-kit lib scripts and `.gaia/scripts` (token-tally, create-worktree, ledger migration), all contending on one lock over `ledger.json`. A partial fold races a Node process against a bash process on the same lock across the macOS-mkdir and Linux-flock split. A blanket move is blocked unless the whole consumer group co-moves.
- **Statusline latency budget.** `gaia-statusline.sh` renders on a tight budget that Node cold-start blows.
- **Shared-class call sites.** `.claude/settings.json` and `.github/workflows/tests.yml` are both manifest class `shared`. Rewriting either to call the binary writes a `.gaia-merge/` conflict for every customizing adopter, the exact per-adopter merge cost the premise wants to remove.
- **Binary-to-`.sh` reverse edges.** The binary already spawns `token-tally.sh` (via `gaia wiki chain`) and writes `bash .gaia/statusline/gaia-statusline.sh` into settings during init, so no `.sh` reachable from `.gaia/cli/src` is a fold candidate regardless of its class.
- **Adopter customizability.** Editable hook files (`block-rm-rf.sh` is about 490 lines) are a template value proposition; a compiled binary forecloses adopter guard tuning.

## Options considered

| Option | What | Verdict |
|---|---|---|
| A. Keep all `.sh` as path-invoked files | Change nothing | Chosen. The two goals are unreachable and folding regresses latency, portability, and reviewability. |
| B. Fold logic, keep thin `.sh` stubs | Body moves to a subcommand, stub execs the binary | Rejected. Manifest delta is exactly zero (the stub files remain); adds Node cold-start to every fire; flips the binary toward 100% release churn. Pure loss. |
| C. Rewrite invokers, delete the `.sh` | Point call sites at the binary | Rejected as a strategy; survives only as the narrow slice below. Hot hooks and the CI script live in `shared`-class call sites (per-adopter conflicts), the delete prompts every pristine adopter, and it orphans the release-excluded bats suites. |
| D. Separate shell binary (shc / makeself / bash-in-Node / Go) | Pack shell into its own artifact | Rejected for every mechanism. shc and makeself still need bash at runtime and still leave `.sh` on disk, so the path-invocation contract is untouched; bash-in-Node needs bash, pays Node cold-start, and still needs a path stub; a Go rewrite is roughly 20k lines plus a second toolchain and per-platform cross-compilation, chasing a manifest and diff win that does not exist. |

## Decision

Keep all shipped `.sh` as path-invoked files. Fold none into the Node binary; build no separate shell binary.

## The one parked option (opportunistic, not scheduled)

If the spec-kit area is already being refactored for other reasons, the roughly one dozen genuinely self-contained spec-kit executable lib leaves (`lint.sh`, `uat-write.sh`, `version-check.sh`, the archive and reconcile leaves) may consolidate into a `gaia spec <sub>` family, motivated purely by code locality, not manifest size. Book these costs up front:

- delete and re-author the release-excluded bats suites into Vitest, accepting loss of bash-native mutex and concurrency coverage;
- respect the `with-ledger-lock` co-move constraint (the allocator and ledger-update scripts cannot move unless their `.gaia/scripts` consumers move too);
- a one-time upstream-deletion prompt per file on every adopter's next update;
- reassign the maintainer-shell audit remit to the node agent and re-point (not delete) the guarding coverage;
- wire an external invoker for each new subcommand so command-reachability coverage stays satisfied.

Excluded even here: all CI scripts. `ci-revert` and `ci-stale-check` already live in the binary; `resolve-check-base.sh` runs before Node is set up in CI and has a `shared`-class call site, so folding it would couple a required status check to the binary.

## Consequences

The question is parked. A future re-opener must first refute the three mechanism facts above: the manifest is a never-merged sentinel, the binary is a deterministic build that changes in roughly half of releases (not every one), and the fold is a delete (which prompts the adopter) not a silent overwrite. See also: [[CLI-Binary-Split]], [[Bundle-time Scrub]], [[Update Workflow]].
