---
type: dependency
status: active
package: pnpm
role: override-application-gotcha
created: 2026-06-22
updated: 2026-06-22
tags: [dependency, pnpm, overrides, security, lockfile]
---

# pnpm-overrides

The `overrides:` map in `pnpm-workspace.yaml` pins transitive dependency versions, most often to enforce a **security floor**: hold a transitive at or above a patched version to clear a known advisory. A change to that map only takes effect once it reaches `pnpm-lock.yaml` as a top-level `overrides:` block. The gotcha is which command writes it.

## The gotcha

`pnpm install` does **not** re-resolve when only the `overrides:` map changed. It short-circuits with `Already up to date` and leaves the lockfile byte-for-byte unchanged. `pnpm install --force` behaves the same: it re-links `node_modules` but still does not re-resolve an overrides-only edit. The result is silent: the config declares a floor, the lockfile carries no `overrides:` block, and the vulnerable transitive resolves anyway.

`pnpm dedupe` is the reliable primitive. It performs a full install that re-resolves the graph, writes the `overrides:` block into the lockfile, applies the pin, and drops any now-redundant duplicate that the override made unreachable. Regenerating the lockfile from scratch (delete `pnpm-lock.yaml`, then `pnpm install`) also re-resolves, but `pnpm dedupe` is the targeted, non-destructive choice.

## Verify a floor is applied

A floor is applied only when both hold:

1. The lockfile's top-level `overrides:` block lists every key from the `overrides:` map in `pnpm-workspace.yaml`.

   ```bash
   # the block must exist and match config
   grep -A20 '^overrides:' pnpm-lock.yaml
   ```

2. No version below the floor survives in the tree.

   ```bash
   pnpm why qs        # every path resolves to the pinned floor, no older copy
   ```

If the config declares a key the lockfile block omits, or `pnpm why` shows a version under the floor, the floor is unapplied: run `pnpm dedupe` and re-run the quality gate.

## Tradeoff

`pnpm dedupe` re-optimizes the entire tree, so applying one override can produce a wider lockfile diff than the single key warrants (it also removes transitives that deduplicate away). That broader diff is expected and correct, the alternative is an unapplied floor.

## Where this bites

The `update-deps` skill's override audit (Phase 0 and Phase 6) toggles each override key out, re-resolves, and tests whether removal regresses a peer dependency or reintroduces an advisory. If the toggle re-resolves with `pnpm install` instead of `pnpm dedupe`, the tree never moves: the audit reads a stale graph, its keep/remove decisions are unreliable, and a restored key can be left unapplied, silently disabling the floor it was meant to enforce. The audit re-resolves with `pnpm dedupe` for exactly this reason, and asserts the lockfile `overrides:` block matches config before it finishes.

See [[pnpm]], [[pnpm-audit]].
