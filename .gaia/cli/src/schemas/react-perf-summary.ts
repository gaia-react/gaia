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
  index: z.number().optional(),
  name: z.string().optional(),
  next: z.string(),
  prev: z.string(),
  unstable: z.boolean(),
});

export type ChangeEntry = z.infer<typeof ChangeEntrySchema>;

export const RenderRecordSchema = z.object({
  changedTotal: z.number(),
  componentName: z.string(),
  contextChanged: z.array(ChangeEntrySchema),
  didCommit: z.boolean(),
  didRender: z.boolean(),
  // Newer harness fields. OPTIONAL because the committed legacy fixture
  // predates them. A record lacking `isMemo` can never be `memoDefeated`.
  fiberId: z.number().optional(),
  isMemo: z.boolean().optional(),
  kind: z.string().optional(),
  phase: z.string(),
  propsChanged: z.array(ChangeEntrySchema),
  selfTime: z.number(),
  seq: z.number(),
  stateChanged: z.array(ChangeEntrySchema),
  tag: z.number().optional(),
  totalTime: z.number(),
});

export type RenderRecord = z.infer<typeof RenderRecordSchema>;

const MetaSchema = z.object({
  bippyVersion: z.string().default('unknown'),
  commits: z.number(),
  errors: z.array(z.string()),
  installed: z.boolean(),
  profilingAvailable: z.boolean().default(false),
  rendererVersion: z.string().nullable().default(null),
  // Newer meta fields. OPTIONAL with documented defaults so the legacy
  // fixture's `{installed, commits, errors}`-only meta parses.
  strictMode: z.boolean().default(true),
});

export const RawDumpSchema = z.object({
  all: z.array(RenderRecordSchema),
  // `meta` is REQUIRED. Its absence rejects the alien react-scan dump
  // (`{total, cut, all}`, no meta).
  meta: MetaSchema,
  total: z.number().optional(),
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
  exceedsFrameBudget: z.boolean(),
  isMemo: z.boolean(),
  maxTotalTime: z.number(),
  memoDefeatedCount: z.number().int(),
  rank: z.number().int(),
  reactDoctorRule: ReactDoctorRuleSchema.nullable(),
  renderCount: z.number().int(),
  totalSelfTime: z.number(),
  unstableInputs: z.array(z.string()),
});

export type ReducedFinding = z.infer<typeof ReducedFindingSchema>;

export const ReducedSummarySchema = z.strictObject({
  findings: z.array(ReducedFindingSchema),
  profilingAvailable: z.boolean(),
  rendererVersion: z.string().nullable(),
  schemaVersion: z.literal(1),
  stopSignal: z.strictObject({
    noAppFrameBudgetBreach: z.boolean(),
    zeroAppMemoDefeated: z.boolean(),
  }),
  strictModeTimingCaveat: z.boolean(),
  totals: z.strictObject({
    appComponents: z.number().int(),
    frameworkFiltered: z.number().int(),
    memoDefeated: z.number().int(),
    mounts: z.number().int(),
    records: z.number().int(),
    updates: z.number().int(),
  }),
  unknownNameCount: z.number().int(),
});

export type ReducedSummary = z.infer<typeof ReducedSummarySchema>;
