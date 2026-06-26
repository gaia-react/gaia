---
type: concept
title: React Perf Diagnostic
status: active
created: 2026-06-26
updated: 2026-06-26
tags: [concept, claude, skill, performance]
---

# React Perf Diagnostic

`/gaia-react-perf` is a trigger-gated runtime render-performance diagnostic built on `bippy`. It drives a targeted micro-interaction, captures real per-render attribution, reduces the raw capture to a small ranked summary, and presents a diagnosis with a static-cause cross-reference and a recommended structural fix. v1 is **measure-only**: it emits a diagnosis, the human or Claude applies the fix in normal conversation. It does not auto-fix.

## Three layers plus verify

The diagnostic separates a token-heavy raw capture from the small summary the model reasons over. The raw dump (roughly 172 KB, about 43K tokens for a trivial flow) never enters the model context.

| Layer | Home | Role |
|---|---|---|
| **Capture** | `.playwright/react-perf/` | A bippy harness, bundled to an IIFE and injected via Playwright `addInitScript` before React initializes, records each rendered fiber to primitives and writes a raw `RenderRecord` dump to `.gaia/local/cache/<run>/`. |
| **Reduce** | `gaia react-perf reduce <raw.json>` | A deterministic, vitest-tested CLI subcommand. Filters framework noise, recomputes the signal, ranks findings, applies a frame-budget gate, and prints a small `ReducedSummary` JSON. |
| **Reason** | `.claude/skills/gaia-react-perf/` | The skill ingests only the `ReducedSummary` and presents the ranked diagnosis. |
| **Verify** | the skill runbook | After a fix, re-capture and re-reduce, then confirm the targeted finding count drops to 0 before stopping. |

The capture helper exports `installRenderCapture(page, {isStrictModeDisabled?})` and `collectRenderDump(page, {runId?, keep?})`. `collectRenderDump` auto-deletes the run directory on process exit unless `keep` is set, so a diagnosis drive passes `{keep: true}` to let the reduce step read the dump.

## The signal: memoDefeated, not "unnecessary"

A render is `memoDefeated` when it is an update render of a `memo`-wrapped component whose every changed input is an unstable reference (a fresh object or function passed where `Object.is` fails across commits). This is the actionable, low-false-positive signal. A plain "nothing meaningfully changed" render is not surfaced, because chasing it leads to memoize-everything over-optimization.

The reduce recomputes `memoDefeated` from primitives (`phase`, `isMemo`, `changedTotal`, and each change entry's `unstable` flag) rather than trusting a precomputed flag, which keeps the authoritative computation deterministic and unit-tested in the CLI rather than in the browser.

Timing is a **gate, not a trigger**. Findings rank by blast-radius times cost (`memoDefeatedCount` times `maxTotalTime`), and `exceedsFrameBudget` flags a component whose max subtree time crosses the frame budget (16 ms default, overridable with `--frame-budget-ms`). Render-count wins are often sub-perceptible, so the tool is most valuable where a defeated memo guards an expensive subtree.

## Privacy and bippy safeguards

The capture serializes every changed input to a **type label** (`object`, `function`, `number`), never the raw value, and retains no fibers, DOM nodes, or `fiber.type`. The harness wraps bippy's instrumentation in `secure()` with a non-throwing `onError` and a 5 second install-check timeout, stays on `onCommitFiberRoot` (never the lite profiling channel that would kill the DevTools timeline), filters to real renders via `didFiberRender`, keys cross-commit identity by `getFiberId`, and detects memo via imported `MemoComponentTag` / `SimpleMemoComponentTag` constants rather than literal tag integers. Names resolve through `getDisplayName(getType(...))`, and unnamed fibers bucket as `Unknown` rather than being dropped. `bippy` is pinned exactly (no caret), and a smoke spec asserts a known component still resolves name, memo, and timing as a version-bump canary.

GAIA renders under `<StrictMode>`, which double-invokes render and inflates timings. The capture can inject `window.__PERF_NO_STRICT` so `app/entry.client.tsx` skips the `<StrictMode>` wrapper for honest timings, and stamps `meta.strictMode` accordingly. When StrictMode was on, the summary carries `strictModeTimingCaveat` so timings are read as relative rather than absolute.

## react-doctor cross-reference

Each finding maps to one of three conceptual cross-reference labels: `jsx-no-new-object-as-prop`, `jsx-no-constructed-context-values`, and `no-unstable-nested-components`. These name the static cause and the structural-first fix (hoist to a module constant before reaching for `useMemo` / `useCallback` / a context split). They are guidance labels, **not** live `react-doctor/` rule ids, and are never matched against lint output. [[react-doctor]] is the always-on static prevention layer; this runtime tool is the complementary diagnosis layer for instability that only manifests at render time.

## Trigger and scope boundaries

The skill carries a conservative trigger. It fires on explicit perf-investigation intent ("profile renders", "why is X re-rendering", "diagnose render performance") and the `/gaia-react-perf` handle, and deliberately does not fire on vague "feels slow", "janky", or "optimize my app". The runbook requires a concrete micro-interaction target (a button click or local state change) and refuses a navigation, because a navigation re-renders the whole tree and buries the signal in framework noise.

v1 boundaries:

- **Measure-only.** No autonomous fixing loop. The skill emits a diagnosis and the human or Claude applies the fix.
- **The framework/app boundary is a name-denylist heuristic.** It drops React Router and Remix internals plus the react-icons pack by name. A name shared between framework and app code is a known limitation: the app's own `Form` component shares a name with React Router's `Form`, so its renders filter as framework noise.

<!-- gaia:maintainer-only:start -->

## Phase 4 (deferred)

The surfacing and regression-gate work is reserved by the contracts but not built in v1:

- **Surfacing.** A [[react-doctor]] trip-wire that *offers* a scan when a post-feature static pass flags a render-class rule on touched code (it offers, never auto-runs), a local audit prompt, a non-blocking CI PR label (`perf:measure-locally`) that the [[PR Merge Workflow]] merge-gate surfaces to a human, and decline persistence so a dismissed offer does not nag.
- **CI regression gate.** A native `<Profiler>`-based committed Playwright spec with a committed baseline and a deterministic threshold, opt-in, warn-not-fix. The native profiler gives timing but not which component or why, so it suits a zero-dependency regression catch rather than diagnosis.

<!-- gaia:maintainer-only:end -->

## Pairs with

- [[Playwright]]: the capture drives the target interaction through a Playwright page.
- [[react-doctor]]: the static prevention layer this runtime tool cross-references.
- [[Telemetry]]: the `.gaia/cli/gaia` bundled binary that hosts the `react-perf reduce` subcommand.
