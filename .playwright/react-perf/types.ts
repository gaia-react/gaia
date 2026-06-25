// Contract A — the wire format the bippy harness emits and the reduce CLI
// (Phase 2) consumes. Records hold only serialized primitives: never a live
// fiber, DOM node, or fiber.type. Change entries carry TYPE LABELS, never raw
// values (privacy + size).

// One change entry inside propsChanged / stateChanged / contextChanged.
export type ChangeEntry = {
  name?: string; // props: the prop name. Omitted for state/context.
  index?: number; // state: the hook index. Omitted for props/context.
  prev: string; // type label only: 'object' | 'function' | 'number' | ...
  next: string; // type label
  unstable: boolean; // both refs are object/function and !Object.is(prev, next)
};

// One rendered fiber, serialized to primitives.
export type RenderRecord = {
  seq: number; // monotonic capture order
  fiberId: number; // getFiberId(fiber) — stable cross-commit identity
  componentName: string; // getDisplayName(getType(fiber.type)) ?? 'Unknown'
  phase: string; // 'mount' | 'update' | 'unmount' (bippy phase)
  kind: string; // 'Memo' | 'ForwardRef' | 'Class' | 'Function' | 'tag(N)'
  tag: number; // fiber.tag
  isMemo: boolean; // tag ∈ {MemoComponentTag, SimpleMemoComponentTag} or hasMemoCache
  selfTime: number; // getTimings(fiber).selfTime
  totalTime: number; // getTimings(fiber).totalTime (subtree-inclusive)
  didCommit: boolean; // didFiberCommit(fiber)
  didRender: boolean; // didFiberRender(fiber)
  changedTotal: number; // propsChanged + stateChanged + contextChanged lengths
  propsChanged: ChangeEntry[];
  stateChanged: ChangeEntry[];
  contextChanged: ChangeEntry[];
};

// The `meta` envelope written to the raw dump.
export type RawDumpMeta = {
  installed: boolean; // instrumentation went active
  commits: number; // # onCommitFiberRoot calls observed
  errors: string[]; // swallowed per-fiber / onError messages
  strictMode: boolean; // true ⇒ capture ran with <StrictMode> on (timings ~2x)
  rendererVersion: string | null; // renderer.version (self-describing results)
  profilingAvailable: boolean; // a known render had non-zero actualDuration
  bippyVersion: string; // pinned bippy version (e.g. '0.5.42')
};

// The on-disk raw dump written to .gaia/local/cache/<run>/renders.json.
export type RawDump = {
  meta: RawDumpMeta;
  total: number; // all.length
  all: RenderRecord[];
};

// In-browser diagnostics channel the harness writes and the capture helper
// reads. It carries the browser-derived subset of RawDumpMeta plus an internal
// production-abort signal that is NOT written to the dump. strictMode is stamped
// capture-side from the noStrict option, so it is absent here.
export type BippyMeta = {
  installed: boolean;
  commits: number;
  errors: string[];
  rendererVersion: string | null;
  profilingAvailable: boolean;
  bippyVersion: string;
  productionDetected: boolean;
};

declare global {
  interface Window {
    __renders?: RenderRecord[];
    __bippyMeta?: BippyMeta;
    // Set by the capture helper (addInitScript) for honest non-StrictMode timing
    // runs; read by app/entry.client.tsx to skip the <StrictMode> wrapper.
    __PERF_NO_STRICT?: boolean;
  }
}
