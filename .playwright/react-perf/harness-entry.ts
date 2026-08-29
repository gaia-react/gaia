// bippy instrumentation entry. esbuild bundles this to an IIFE that Playwright
// injects via addInitScript at document_start, so bippy patches the React
// DevTools global hook BEFORE the app's React initializes (import-before-React
// is load-bearing). It records per-render attribution to window.__renders and
// diagnostics to window.__bippyMeta, both serialized to primitives only.
//
// Safeguards: a manual canProfile gate (dev-build + minimum React 19 check)
// plus a non-throwing guard() wrapper stand in for bippy's removed secure()
// helper, backed by a 5000ms install-check timeout (defuses the window.stop()
// landmine); it stays on the onCommitFiberRoot chaining path (never
// injectProfilingHooks/lite); it gates real renders via didFiberRender
// (traverseRenderedFibers) and keys cross-commit identity by getFiberId; it
// retains no fibers, DOM nodes, or fiber.type objects.

/* eslint-disable no-underscore-dangle -- window.__renders / __bippyMeta are the
   harness wire contract this file publishes for capture.ts to read. */
import {
  detectReactBuildType,
  didFiberRender,
  getDisplayName,
  getFiberId,
  getRDTHook,
  getReactWorkTagsForFiber,
  getType,
  hasMemoCache,
  instrument,
  isCompositeFiber,
  isInstrumentationActive,
  MutationMask,
  ReactFiberFlags,
  traverseRenderedFibers,
  version,
} from 'bippy';
import type {
  ContextDependency,
  Fiber,
  MemoizedState,
  ReactWorkTagMap,
  RenderPhase,
} from 'bippy';
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

// --- Ports of helpers bippy removed in 0.7.0 -------------------------------
// 0.7.0 dropped didFiberCommit, getTimings, and the traverseProps/State/
// Contexts visitors as "policy-heavy helpers" (upstream changelog); they are
// not coming back. These reproduce bippy 0.6.1's implementations, narrowed to
// the void-returning visitors this harness actually uses (bippy's returned a
// boolean to short-circuit; nothing here short-circuits). The fiber-shape
// reads stay identical, so behaviour is unchanged across the bump. onRender
// wraps every call in try/catch, so these do not each need their own.

/* eslint-disable no-bitwise -- React fiber effect flags are a bitmask; masking
   is the only way to read them, and this is the read bippy 0.6.1 did. */
const COMMIT_MASK = MutationMask | ReactFiberFlags.Cloned;

const didFiberCommit = (fiber: Fiber): boolean =>
  (fiber.flags & COMMIT_MASK) !== 0 || (fiber.subtreeFlags & COMMIT_MASK) !== 0;
/* eslint-enable no-bitwise */

// selfTime is the fiber's own actualDuration minus its children's, so a parent
// is not credited with time its subtree spent.
const getTimings = (fiber: Fiber): {selfTime: number; totalTime: number} => {
  const totalTime = fiber.actualDuration ?? 0;
  let selfTime = totalTime;
  let {child} = fiber;

  while (totalTime > 0 && child !== null) {
    selfTime -= child.actualDuration ?? 0;
    child = child.sibling;
  }

  return {selfTime, totalTime};
};

const traverseProps = (
  fiber: Fiber,
  visit: (propertyName: string, nextValue: unknown, prevValue: unknown) => void
): void => {
  // memoizedProps is declared non-nullable, but React leaves it null on a fiber
  // that has not completed a render, so widen before guarding rather than after.
  const nextProps =
    (fiber.memoizedProps as null | Record<string, unknown>) ?? {};
  const prevProps =
    (fiber.alternate?.memoizedProps as null | Record<string, unknown>) ?? {};

  for (const propertyName of Object.keys(nextProps)) {
    visit(propertyName, nextProps[propertyName], prevProps[propertyName]);
  }

  // Props present last render but not this one still count as changed.
  for (const propertyName of Object.keys(prevProps)) {
    if (!(propertyName in nextProps)) {
      visit(propertyName, nextProps[propertyName], prevProps[propertyName]);
    }
  }
};

// A composite fiber's memoizedState is the singly-linked hook list; walk it in
// lockstep with the alternate's so each hook index compares against itself.
const traverseState = (
  fiber: Fiber,
  visit: (
    nextValue: MemoizedState | null | undefined,
    prevValue: MemoizedState | null | undefined
  ) => void
): void => {
  let nextState: MemoizedState | null | undefined = fiber.memoizedState;
  let prevState: MemoizedState | null | undefined =
    fiber.alternate?.memoizedState;

  while (nextState || prevState) {
    visit(nextState, prevState);
    nextState = nextState?.next;
    prevState = prevState?.next;
  }
};

// firstContext is absent on React versions that shape dependencies
// differently; bail rather than guess.
const hasFirstContext = (
  dependencies: unknown
): dependencies is {firstContext: ContextDependency<unknown> | null} =>
  typeof dependencies === 'object' &&
  dependencies !== null &&
  'firstContext' in dependencies;

const traverseContexts = (
  fiber: Fiber,
  visit: (
    nextValue: ContextDependency<unknown> | null | undefined,
    prevValue: ContextDependency<unknown> | null | undefined
  ) => void
): void => {
  const nextDependencies = fiber.dependencies;
  const prevDependencies = fiber.alternate?.dependencies;

  if (
    !hasFirstContext(nextDependencies) ||
    !hasFirstContext(prevDependencies)
  ) {
    return;
  }

  let nextContext: ContextDependency<unknown> | null | undefined =
    nextDependencies.firstContext;
  let prevContext: ContextDependency<unknown> | null | undefined =
    prevDependencies.firstContext;

  while (
    (nextContext && 'memoizedValue' in nextContext) ||
    (prevContext && 'memoizedValue' in prevContext)
  ) {
    visit(nextContext, prevContext);
    nextContext = nextContext?.next;
    prevContext = prevContext?.next;
  }
};

// --- End ports -------------------------------------------------------------

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

// Map fiber.tag to a human label. Work-tag integers are renumbered between
// React versions, so they resolve through bippy's per-fiber tag map (0.7.0
// replaced the fixed *Tag export constants with it) rather than literal ints.
const getFiberKindLabel = (
  tag: number,
  tags: Readonly<ReactWorkTagMap>
): string => {
  if (tag === tags.SimpleMemoComponent || tag === tags.MemoComponent)
    return 'Memo';
  if (tag === tags.ForwardRef) return 'ForwardRef';
  if (tag === tags.ClassComponent) return 'Class';
  if (tag === tags.FunctionComponent) return 'Function';

  return `tag(${tag})`;
};

const onRender = (fiber: Fiber, phase: RenderPhase): void => {
  // Per-fiber isolation: guard() guards the outer commit handler, but one bad
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
    // WeakMap-cached per fiber and alternate, so this is amortized O(1).
    const tags = getReactWorkTagsForFiber(fiber);
    const isMemo =
      tag === tags.MemoComponent ||
      tag === tags.SimpleMemoComponent ||
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
      kind: getFiberKindLabel(tag, tags),
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
// timings). onActive's canProfile gate is the backstop; this surfaces a clear
// error.
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

let canProfile = false;

// bippy's secure() helper was removed in 0.6.0 (upstream confirms this was
// intentional); this reproduces its production gate, minimum-version check,
// install-check timeout, and per-commit error isolation by hand.
const guard =
  <Arguments extends unknown[]>(handler: (...arguments_: Arguments) => void) =>
  (...arguments_: Arguments): void => {
    if (!canProfile) return;

    try {
      handler(...arguments_);
    } catch (error) {
      recordError(error);
    }
  };

const installCheckTimeout = window.setTimeout(() => {
  if (isInstrumentationActive()) return;
  recordError(new Error('bippy did not attach within 5000ms'));
  window.stop();
}, 5000);

instrument({
  name: 'gaia-react-perf',
  onActive: () => {
    window.clearTimeout(installCheckTimeout);
    canProfile = [...getRDTHook().renderers.values()].every(
      (renderer) =>
        Number.parseInt(renderer.version, 10) >= 19 &&
        detectReactBuildType(renderer) === 'development'
    );
    if (!canProfile) return;

    meta.installed = true;
    inspectRenderers();
  },
  onCommitFiberRoot: guard((_rendererID, root) => {
    meta.commits += 1;
    traverseRenderedFibers(root, onRender);
  }),
});
