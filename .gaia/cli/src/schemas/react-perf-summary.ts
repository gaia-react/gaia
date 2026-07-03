/**
 * Zod schemas for the `gaia react-perf reduce` subcommand.
 *
 * Two contracts live here:
 *
 * - Contract A (INPUT): `RawDump` / `RenderRecord`, the on-disk bippy render
 *   dump the reduce consumes. It is deliberately PERMISSIVE (`z.object`, not
 *   `z.strictObject`): the committed legacy fixture
 *   `test-fixtures/react-perf/bippy-renders-dump.json` predates the
 *   `isMemo`/`kind`/`tag`/`fiberId` record fields and the
 *   `strictMode`/`rendererVersion`/`profilingAvailable`/`bippyVersion` meta
 *   fields, so those are OPTIONAL (meta fields carry documented defaults).
 *   `meta` itself is REQUIRED: its absence is the signal that rejects the
 *   alien react-scan dump. Unknown envelope/record keys are tolerated
 *   (`z.object` strips them) so the legacy envelope's extra `afterLoad` key
 *   and the legacy record's extra `unnecessary` key parse cleanly.
 *
 * - Contract B (OUTPUT): `ReducedSummary`, the small ranked summary the
 *   Phase-3 `/gaia-react-perf` skill reads. Strict (`z.strictObject`): we own
 *   the shape, so drift should fail loudly.
 *
 * The `reactDoctorRule` values are CONCEPTUAL static-cause cross-reference
 * labels, not live `react-doctor/` ESLint rule ids. They map a runtime
 * symptom to its static cause for human guidance and are never matched
 * against ESLint output.
 */
import {z} from 'zod';

// --- Contract A: raw bippy render dump (input) ---

const ChangeEntrySchema = z.object({
  name: z.string().optional(),
  index: z.number().optional(),
  prev: z.string(),
  next: z.string(),
  unstable: z.boolean(),
});
export type ChangeEntry = z.infer<typeof ChangeEntrySchema>;

export const RenderRecordSchema = z.object({
  seq: z.number(),
  // Newer harness fields. OPTIONAL because the committed legacy fixture
  // predates them. A record lacking `isMemo` can never be `memoDefeated`.
  fiberId: z.number().optional(),
  componentName: z.string(),
  phase: z.string(),
  kind: z.string().optional(),
  tag: z.number().optional(),
  isMemo: z.boolean().optional(),
  selfTime: z.number(),
  totalTime: z.number(),
  didCommit: z.boolean(),
  didRender: z.boolean(),
  changedTotal: z.number(),
  propsChanged: z.array(ChangeEntrySchema),
  stateChanged: z.array(ChangeEntrySchema),
  contextChanged: z.array(ChangeEntrySchema),
});
export type RenderRecord = z.infer<typeof RenderRecordSchema>;

const MetaSchema = z.object({
  installed: z.boolean(),
  commits: z.number(),
  errors: z.array(z.string()),
  // Newer meta fields. OPTIONAL with documented defaults so the legacy
  // fixture's `{installed, commits, errors}`-only meta parses.
  strictMode: z.boolean().default(true),
  rendererVersion: z.string().nullable().default(null),
  profilingAvailable: z.boolean().default(false),
  bippyVersion: z.string().default('unknown'),
});

export const RawDumpSchema = z.object({
  // `meta` is REQUIRED. Its absence rejects the alien react-scan dump
  // (`{total, cut, all}`, no meta).
  meta: MetaSchema,
  total: z.number().optional(),
  all: z.array(RenderRecordSchema),
});
export type RawDump = z.infer<typeof RawDumpSchema>;

// --- Contract B: reduced summary (output) ---

export const ReactDoctorRuleSchema = z.literal([
  'jsx-no-constructed-context-values',
  'jsx-no-new-object-as-prop',
  'no-unstable-nested-components',
]);
export type ReactDoctorRule = z.infer<typeof ReactDoctorRuleSchema>;

export const ReducedFindingSchema = z.strictObject({
  componentName: z.string(),
  isMemo: z.boolean(),
  renderCount: z.number().int(),
  memoDefeatedCount: z.number().int(),
  totalSelfTime: z.number(),
  maxTotalTime: z.number(),
  exceedsFrameBudget: z.boolean(),
  unstableInputs: z.array(z.string()),
  reactDoctorRule: ReactDoctorRuleSchema.nullable(),
  rank: z.number().int(),
});
export type ReducedFinding = z.infer<typeof ReducedFindingSchema>;

export const ReducedSummarySchema = z.strictObject({
  schemaVersion: z.literal(1),
  rendererVersion: z.string().nullable(),
  profilingAvailable: z.boolean(),
  strictModeTimingCaveat: z.boolean(),
  totals: z.strictObject({
    records: z.number().int(),
    updates: z.number().int(),
    mounts: z.number().int(),
    frameworkFiltered: z.number().int(),
    appComponents: z.number().int(),
    memoDefeated: z.number().int(),
  }),
  findings: z.array(ReducedFindingSchema),
  unknownNameCount: z.number().int(),
  stopSignal: z.strictObject({
    zeroAppMemoDefeated: z.boolean(),
    noAppFrameBudgetBreach: z.boolean(),
  }),
});
export type ReducedSummary = z.infer<typeof ReducedSummarySchema>;
