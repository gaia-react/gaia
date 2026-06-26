# /gaia-react-perf (measure-only)

A trigger-gated React render-performance diagnostic. It drives one targeted
micro-interaction, captures the real renders bippy observes, reduces the raw
capture to a small ranked summary, and presents a noise-filtered diagnosis: the
memo-defeating reference instability behind an over-render, the matching
react-doctor cross-reference, and the recommended structural-first fix. After a
fix it re-captures to confirm the targeted finding goes to zero, then stops.

## Boundaries (read first, do not exceed)

- **v1 is measure-only.** The skill emits a diagnosis. The human (or Claude, in
  normal conversation) applies the fix. This is NOT a bounded auto-fix loop.
- **The framework/app boundary is a name heuristic**, not a source-path check.
  The reduce filters a framework name denylist; an unusual component name can
  slip it. That is exactly why a human stays in the loop on the fix.
- **The raw dump never enters the model context.** It is roughly 172 KB (about
  43K tokens) for a trivial flow. Only the reduced summary is read. Any
  drill-down is a targeted query (for example `jq`) against the on-disk raw, not
  a full read.
- **Deferred surfacing is NOT part of v1.** The trip-wire offer, the local
  audit prompt, the CI label plus merge-gate, and decline persistence are
  designed but unbuilt. The reduced summary's `findings` array is the unit a
  future surfacing flow would consume; reserve that seam, do not build it.

## Step 1: Confirm intent and target

Proceed only on an explicit perf-investigation intent ("profile renders",
"measure renders", "why is X re-rendering", "diagnose render performance"). Do
not run off vague "feels slow" or "janky".

**Require a concrete micro-interaction target:** a button click or a local state
change on a specific page (for example "the theme toggle in the header on `/`",
"the add-to-cart button on the product page"). If the target is absent, ask for
one.

**Refuse a navigation or "the whole app" target.** A navigation re-renders the
whole tree and buries the signal in framework noise (the router, links, layout
cohort), so the same memo defeat that reads as a single clean culprit under a
local interaction becomes one row among hundreds. A local state interaction
re-renders only its own subtree. If the user names a navigation or "everything",
explain this and ask them to narrow to a micro-interaction.

## Step 2: Drive and capture

Drive the target interaction in a short Playwright spec using the committed
Phase-1 capture helper, `.playwright/react-perf/capture.ts`. The diagnosis spec
installs the capture, `goto`s the target route, waits for `hydration`, drives the
micro-interaction, then collects; it passes `{keep: true}` so the raw dump
survives the Playwright process for the reduce step, and it logs the written
`rawPath`. Use the template below.

Write a temporary spec under `.playwright/e2e/` (the configured `testDir`), for
example `.playwright/e2e/react-perf-drive.spec.ts`:

```ts
import {expect, test} from '@playwright/test';
import {collectRenderDump, installRenderCapture} from '../react-perf/capture';
import {hydration} from '../utils';

test('drive the target micro-interaction and capture renders', async ({page}) => {
  // Honest (non-doubled) timings: isStrictModeDisabled sets window.__PERF_NO_STRICT
  // so app/entry.client.tsx skips <StrictMode>. The dump's meta.strictMode is
  // stamped false, and the reduce reports strictModeTimingCaveat: false.
  await installRenderCapture(page, {isStrictModeDisabled: true});

  await page.goto('/'); // the target route
  await hydration(page); // wait for hydration before interacting

  // Drive the micro-interaction (a button click / local state change).
  const toggle = page.locator('header').getByRole('button');
  await expect(toggle).toBeVisible();
  await toggle.click();

  // keep: true is REQUIRED. collectRenderDump auto-deletes the run dir on
  // process exit unless kept, which would erase the raw before reduce reads it.
  const result = await collectRenderDump(page, {keep: true});
  console.log(`RAW_DUMP_PATH=${result.rawPath}`);
});
```

Run it (the Playwright config auto-starts `pnpm dev`; the capture requires a
development build, a production build is rejected):

```
pnpm pw react-perf-drive
```

Read the `RAW_DUMP_PATH=...` line from stdout; that absolute path under
`.gaia/local/cache/<run>/renders.json` is the input to the reduce. Remove the
temporary spec when the diagnosis (and any verify pass) is done:

```
rm .playwright/e2e/react-perf-drive.spec.ts
```

Honest-timing note: the capture above runs StrictMode-off via
`installRenderCapture(page, {isStrictModeDisabled: true})`. With StrictMode on,
React sums both render passes into the timings, so `selfTime`/`totalTime` read
roughly 2x. If a run keeps StrictMode on, the reduce flags it with
`strictModeTimingCaveat: true`; treat those timings as relative, not absolute.

## Step 3: Reduce

Run the deterministic reduce over the raw dump and read only its stdout JSON:

```
.gaia/cli/gaia react-perf reduce <RAW_DUMP_PATH>
```

The frame budget defaults to 16ms; pass `--frame-budget-ms <n>` to override the
timing gate. The command prints a `ReducedSummary` (Contract B) to stdout and
exits 0; malformed input prints a structured error and exits non-zero. The
`ReducedSummary` is the ONLY thing you ingest. Do not open the raw dump.

## Step 4: Diagnose

The `ReducedSummary` has these fields (read these, cite them by name):

- `totals`: `records`, `updates`, `mounts`, `frameworkFiltered`,
  `appComponents`, `memoDefeated`.
- `findings[]` (app-owned, memoDefeated-first, ranked by blast-radius x cost).
  Each finding: `componentName`, `isMemo`, `renderCount` (update renders),
  `memoDefeatedCount`, `totalSelfTime`, `maxTotalTime`, `exceedsFrameBudget`,
  `unstableInputs`, `reactDoctorRule`, `rank`.
- `unknownNameCount` (name-resolution-failed renders, a finding in itself).
- `strictModeTimingCaveat`, `profilingAvailable`, `rendererVersion`.
- `stopSignal`: `zeroAppMemoDefeated`, `noAppFrameBudgetBreach`.

For the top finding (`rank: 1`), state:

1. **Component + count.** `componentName` (note `isMemo`) re-rendered
   `renderCount` times on the interaction, of which `memoDefeatedCount` were
   memo-defeated.
2. **The unstable input.** `unstableInputs` names what defeated the memo:
   `prop:<name>` (a referentially-new object/array/function prop), `state[<i>]`
   (an unstable state ref), or `context` (a freshly-constructed context value).
3. **The static cross-reference.** `reactDoctorRule` maps the runtime symptom to
   its static cause (see the cross-reference table below). It is `null` when the
   instability is state-only, where there is no clean structural cross-ref.
4. **The recommended fix.** Lead with the structural-first option from the table.
5. **The cost gate.** `maxTotalTime` plus `exceedsFrameBudget` say whether the
   defeated subtree is actually expensive (over the frame budget) or cheap.

**State the honest caveat up front.** Render-count wins are often
sub-perceptible: a cheap leaf memo-defeat costs on the order of 0.038ms,
roughly three orders of magnitude under the 16ms frame budget. This tool is
primarily a memo-defeat and reference-hygiene finder. It is most valuable when
the defeated child is an expensive subtree (`exceedsFrameBudget: true`). Frame
this so the user does not over-optimize a finding that costs nothing
perceptible.

### react-doctor cross-reference

These three values are CONCEPTUAL static-cause labels for human guidance, not
live `react-doctor/` ESLint rule ids. `react-doctor` is GAIA's static layer (an
ESLint-based, always-on, pre-merge `react-doctor/`-namespaced rule set surfaced
via the `react-doctor` skill); this runtime tool is the complementary diagnosis
layer. But none of the three labels below is an enabled `react-doctor/` rule:
`jsx-no-new-object-as-prop` has no literal lint-rule equivalent in this repo, and
`jsx-no-constructed-context-values` / `no-unstable-nested-components` exist only
as `eslint-plugin-react` `react/*` names that are not enabled. Present them as
symptom-to-cause-to-fix guidance. Never claim a named lint rule catches the
pattern, and never match these strings against ESLint output.

The recommended fix is **structural-first**: prefer hoisting a stable value to a
module-level constant before reaching for a `useMemo` / `useCallback` /
context-split, and only use a hook when the value genuinely depends on render
state.

| Unstable input | `reactDoctorRule` (conceptual) | Structural-first fix | Hook fallback |
|---|---|---|---|
| An inline object/array prop literal (`prop:<name>`) | `jsx-no-new-object-as-prop` | Hoist the literal to a module-level `const` | `useMemo` only when the value depends on render state |
| A callback prop (`prop:<name>`, a function ref) | `jsx-no-new-object-as-prop` (same "new reference as a prop" class) | Hoist the handler to module scope when it closes over nothing | `useCallback` with the right deps when it closes over render state |
| A freshly-constructed context value (`context`) | `jsx-no-constructed-context-values` | Move a static `value` to a module const, or split the context so unrelated consumers do not churn | `useMemo` the provider `value` when it depends on state |
| A child component defined inside another component's body | `no-unstable-nested-components` | Lift the component to module scope | Not a hook fix |

What the reduce emits versus what you apply: the CLI sets `reactDoctorRule` to
`jsx-no-new-object-as-prop` when an unstable prop dominates, to
`jsx-no-constructed-context-values` when an unstable context dominates, or to
`null` for state-only instability. `no-unstable-nested-components` is never
emitted, because a nested-component-definition smell needs the component's
source, which the flat capture records cannot surface. Apply that third label
yourself when the unstable input traces to a component defined inside another
component's render.

## Step 5: Hand off the fix

The human (or Claude, in normal conversation) applies the fix. This is not an
auto-fix loop. Offer the structural-first option first; reach for a hook only
when the value depends on render state, per the table. The right fix is
context-dependent (hoist vs `useMemo` vs `useCallback` vs context-split), which
is why a human stays in the loop.

## Step 6: Verify

After the fix, re-run the SAME drive spec and reduce from Steps 2 and 3. Confirm
the targeted finding's `memoDefeatedCount` goes to 0. After a real fix the
component does not appear in `findings` at all: the capture only records fibers
that actually rendered, so a memo that now correctly skips leaves no record.
That absence is the cleanest "gone" proof.

## Step 7: Stop

Apply the composite stop rule from the summary's `stopSignal`:

> **STOP when `stopSignal.zeroAppMemoDefeated` is true AND
> `stopSignal.noAppFrameBudgetBreach` is true.**

The memo-defeat count catches the cheap-but-wrong cases (a memo silently
defeated); the frame-budget gate catches the rare expensive-subtree case that
count alone under-weights. Both, not either.

Call out residual findings explicitly as out of scope:

- **Framework-level residuals** (a `memoDefeated` row whose component is a
  router or library internal that the name denylist did not catch) are not
  app-fixable. Name them and stop; do not chase them.
- **Sub-perceptible residuals** (an app finding well under the frame budget with
  no remaining memo defeat) are not worth fixing. Do not tempt
  memoize-everything over-optimization.

When the stop rule is met, report the closed finding, the confirmed
`memoDefeatedCount: 0`, and the residuals you are deliberately leaving, then
stop.
