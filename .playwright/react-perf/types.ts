// Contract A — the wire format the bippy harness emits and the reduce CLI
// (Phase 2) consumes. Records hold only serialized primitives: never a live
// fiber, DOM node, or fiber.type. Change entries carry TYPE LABELS, never raw
// values (privacy + size).

// In-browser diagnostics channel the harness writes and the capture helper
// reads. It carries the browser-derived subset of RawDumpMeta plus an internal
// production-abort signal that is NOT written to the dump. strictMode is stamped
// capture-side from the noStrict option, so it is absent here.
export type BippyMeta = {
  bippyVersion: string;
  commits: number;
  errors: string[];
  installed: boolean;
  productionDetected: boolean;
  profilingAvailable: boolean;
  rendererVersion: null | string;
};

// One change entry inside propsChanged / stateChanged / contextChanged.
export type ChangeEntry = {
  index?: number; // state: the hook index. Omitted for props/context.
  name?: string; // props: the prop name. Omitted for state/context.
  next: string; // type label
  prev: string; // type label only: 'object' | 'function' | 'number' | ...
  unstable: boolean; // both refs are object/function and !Object.is(prev, next)
};

// The on-disk raw dump written to .gaia/local/cache/<run>/renders.json.
export type RawDump = {
  all: RenderRecord[];
  meta: RawDumpMeta;
  total: number; // all.length
};

// The `meta` envelope written to the raw dump.
export type RawDumpMeta = {
  bippyVersion: string; // pinned bippy version (e.g. '0.5.42')
  commits: number; // # onCommitFiberRoot calls observed
  errors: string[]; // swallowed per-fiber / onError messages
  installed: boolean; // instrumentation went active
  profilingAvailable: boolean; // a known render had non-zero actualDuration
  rendererVersion: null | string; // renderer.version (self-describing results)
  strictMode: boolean; // true ⇒ capture ran with <StrictMode> on (timings ~2x)
};

// One rendered fiber, serialized to primitives.
export type RenderRecord = {
  changedTotal: number; // propsChanged + stateChanged + contextChanged lengths
  componentName: string; // getDisplayName(getType(fiber.type)) ?? 'Unknown'
  contextChanged: ChangeEntry[];
  didCommit: boolean; // didFiberCommit(fiber)
  didRender: boolean; // didFiberRender(fiber)
  fiberId: number; // getFiberId(fiber) — stable cross-commit identity
  isMemo: boolean; // tag ∈ {MemoComponentTag, SimpleMemoComponentTag} or hasMemoCache
  kind: string; // 'Memo' | 'ForwardRef' | 'Class' | 'Function' | 'tag(N)'
  phase: string; // 'mount' | 'update' | 'unmount' (bippy phase)
  propsChanged: ChangeEntry[];
  selfTime: number; // getTimings(fiber).selfTime
  seq: number; // monotonic capture order
  stateChanged: ChangeEntry[];
  tag: number; // fiber.tag
  totalTime: number; // getTimings(fiber).totalTime (subtree-inclusive)
};

declare global {
  // eslint-disable-next-line @typescript-eslint/consistent-type-definitions -- augmenting the global Window needs declaration merging, which only an interface does
  interface Window {
    __bippyMeta?: BippyMeta;
    // Set by the capture helper (addInitScript) for honest non-StrictMode timing
    // runs; read by app/entry.client.tsx to skip the <StrictMode> wrapper.
    __PERF_NO_STRICT?: boolean;
    __renders?: RenderRecord[];
  }
}
