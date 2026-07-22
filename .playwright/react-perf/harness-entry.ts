// bippy instrumentation entry. esbuild bundles this to an IIFE that Playwright
// injects via addInitScript at document_start, so bippy patches the React
// DevTools global hook BEFORE the app's React initializes (import-before-React
// is load-bearing). It records per-render attribution to window.__renders and
// diagnostics to window.__bippyMeta, both serialized to primitives only.
//
// Safeguards (bippy-safeguards.md): instrumentation is wrapped in secure() with
// a non-throwing onError and a 5000ms installCheckTimeout (defuses the
// window.stop() landmine); it stays on the onCommitFiberRoot chaining path
// (never injectProfilingHooks/lite); it gates real renders via didFiberRender
// (traverseRenderedFibers) and keys cross-commit identity by getFiberId; it
// retains no fibers, DOM nodes, or fiber.type objects.

/* eslint-disable no-underscore-dangle -- window.__renders / __bippyMeta are the
   harness wire contract this file publishes for capture.ts to read. */
import {
  ClassComponentTag,
  detectReactBuildType,
  didFiberCommit,
  didFiberRender,
  ForwardRefTag,
  FunctionComponentTag,
  getDisplayName,
  getFiberId,
  getRDTHook,
  getTimings,
  getType,
  hasMemoCache,
  instrument,
  isCompositeFiber,
  MemoComponentTag,
  secure,
  SimpleMemoComponentTag,
  traverseContexts,
  traverseProps,
  traverseRenderedFibers,
  traverseState,
  version,
} from 'bippy';
import type {Fiber, RenderPhase} from 'bippy';
import type {BippyMeta, ChangeEntry, RenderRecord} from './types';

const meta: BippyMeta = {
  bippyVersion: version ?? 'unknown',
  commits: 0,
  errors: [],
  installed: false,
  productionDetected: false,
  profilingAvailable: false,
  rendererVersion: null,
};
const renders: RenderRecord[] = [];
window.__bippyMeta = meta;
window.__renders = renders;

let renderSequenceNumber = 0;

const recordError = (error: unknown): void => {
  meta.errors.push(error instanceof Error ? error.message : String(error));
};

const getTypeLabel = (value: unknown): string => {
  if (value === null) return 'null';
  if (value === undefined) return 'undefined';
  if (Array.isArray(value)) return `array(${value.length})`;

  return typeof value;
};

// "referentially-new object/function each render" smell: a memo-defeating
// reference change carries no real value change.
const isRef = (value: unknown): boolean =>
  value !== null && (typeof value === 'object' || typeof value === 'function');

const isUnstableReference = (prev: unknown, next: unknown): boolean =>
  isRef(prev) && isRef(next) && !Object.is(prev, next);

// An effect hook's memoizedState is the effect record {create, deps, ...}; a
// useState/useReducer hook's memoizedState is the state value itself.
const isEffectState = (value: unknown): boolean =>
  typeof value === 'object' &&
  value !== null &&
  'create' in value &&
  'deps' in value;

// Map fiber.tag to a human label via imported constants, never literal ints.
const getFiberKindLabel = (tag: number): string => {
  if (tag === SimpleMemoComponentTag || tag === MemoComponentTag) return 'Memo';
  if (tag === ForwardRefTag) return 'ForwardRef';
  if (tag === ClassComponentTag) return 'Class';
  if (tag === FunctionComponentTag) return 'Function';

  return `tag(${tag})`;
};

const onRender = (fiber: Fiber, phase: RenderPhase): void => {
  // Per-fiber isolation: secure() guards the outer commit handler, but one bad
  // fiber must not abort the rest of the commit's capture.
  try {
    // Only attribute composite (function/class) components; skip host nodes.
    if (!isCompositeFiber(fiber)) return;

    const componentName = getDisplayName(getType(fiber.type)) ?? 'Unknown';
    // actualDuration-derived; measured by React before our callback, so our
    // traversal does not inflate it. Zero in non-profile / prod builds.
    const {selfTime, totalTime} = getTimings(fiber);
    if (totalTime > 0 || selfTime > 0) meta.profilingAvailable = true;

    const {tag} = fiber;
    const isMemo =
      tag === MemoComponentTag ||
      tag === SimpleMemoComponentTag ||
      hasMemoCache(fiber);

    const propsChanged: ChangeEntry[] = [];
    const stateChanged: ChangeEntry[] = [];
    const contextChanged: ChangeEntry[] = [];

    if (phase === 'update') {
      traverseProps(fiber, (name, next, prev) => {
        if (!Object.is(prev, next)) {
          propsChanged.push({
            name,
            next: getTypeLabel(next),
            prev: getTypeLabel(prev),
            unstable: isUnstableReference(prev, next),
          });
        }
      });

      let stateIndex = 0;
      traverseState(fiber, (next, prev) => {
        const nextValue = next?.memoizedState;
        const prevValue = prev?.memoizedState;

        if (!isEffectState(nextValue) && !Object.is(prevValue, nextValue)) {
          stateChanged.push({
            index: stateIndex,
            next: getTypeLabel(nextValue),
            prev: getTypeLabel(prevValue),
            unstable: isUnstableReference(prevValue, nextValue),
          });
        }
        stateIndex += 1;
      });

      traverseContexts(fiber, (next, prev) => {
        const nextValue = next?.memoizedValue;
        const prevValue = prev?.memoizedValue;

        if (!Object.is(prevValue, nextValue)) {
          contextChanged.push({
            next: getTypeLabel(nextValue),
            prev: getTypeLabel(prevValue),
            unstable: isUnstableReference(prevValue, nextValue),
          });
        }
      });
    }

    const seq = renderSequenceNumber;
    renderSequenceNumber += 1;

    const record: RenderRecord = {
      changedTotal:
        propsChanged.length + stateChanged.length + contextChanged.length,
      componentName,
      contextChanged,
      didCommit: didFiberCommit(fiber),
      didRender: didFiberRender(fiber),
      fiberId: getFiberId(fiber),
      isMemo,
      kind: getFiberKindLabel(tag),
      phase,
      propsChanged,
      selfTime,
      seq,
      stateChanged,
      tag,
      totalTime,
    };
    renders.push(record);
  } catch (error) {
    recordError(error);
  }
};

// Read renderer.version for self-describing results, and abort the run if any
// renderer is a production build (actualDuration is 0 in prod → meaningless
// timings). secure()'s prod-gate is the backstop; this surfaces a clear error.
const inspectRenderers = (): void => {
  try {
    const hook = getRDTHook();

    for (const renderer of hook.renderers.values()) {
      meta.rendererVersion ??= renderer.version;

      if (detectReactBuildType(renderer) === 'production') {
        meta.productionDetected = true;
        meta.errors.push(
          `production React build detected (renderer ${renderer.version}); aborting capture (timings are 0 in production)`
        );
      }
    }
  } catch (error) {
    recordError(error);
  }
};

instrument(
  secure(
    {
      name: 'gaia-react-perf',
      onActive: () => {
        meta.installed = true;
        inspectRenderers();
      },
      onCommitFiberRoot: (_rendererID, root) => {
        meta.commits += 1;

        try {
          traverseRenderedFibers(root, onRender);
        } catch (error) {
          recordError(error);
        }
      },
    },
    {
      dangerouslyRunInProduction: false,
      installCheckTimeout: 5000,
      minReactMajorVersion: 19,
      onError: recordError,
    }
  )
);
