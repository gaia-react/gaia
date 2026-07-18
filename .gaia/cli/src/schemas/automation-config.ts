import {z} from 'zod';
/**
 * Zod schema + read helpers for `.gaia/automation.json`, the committed
 * file carrying GAIA CI configuration and team-level GAIA preferences.
 *
 * Per the SPEC-001 slice 1 contract: a missing config file means
 * "GAIA CI not configured"; every defer / cron read returns a no-op
 * result. The `read*` helpers therefore never throw; callers branch on
 * the discriminated `status` field.
 */
import {existsSync, readFileSync} from 'node:fs';
import {automationConfigPath} from '../automation/paths.js';
import {summarizeZodError} from './zod-error.js';

export const TOOL_IDS = [
  'wiki',
  'update-deps',
  'pnpm-audit',
  'stale-branches',
] as const;

export type ToolId = (typeof TOOL_IDS)[number];

export const ToolModeSchema = z.literal(['ci', 'local', 'off']);

export type ToolMode = z.infer<typeof ToolModeSchema>;

export const ScheduleSchema = z.literal(['daily', 'monthly', 'weekly']);

export type Schedule = z.infer<typeof ScheduleSchema>;

/**
 * `mode` and `schedule` are read permissively here, the same pattern as
 * `isolation_policy` below: an unrecognized value degrades to a safe
 * default (`mode` -> 'off', `schedule` -> undefined) instead of failing
 * the whole config. `ToolModeSchema`/`ScheduleSchema` themselves stay
 * strict and validate at the WRITE boundary (`setup-ci/write-tool-mode.ts`).
 */
export const ToolConfigSchema = z.object({
  mode: ToolModeSchema.catch('off'),
  schedule: ScheduleSchema.optional().catch(undefined),
});

export type ToolConfig = z.infer<typeof ToolConfigSchema>;

export const UpdateGaiaConfigSchema = z.object({
  mode: z.literal('local'),
});

export type UpdateGaiaConfig = z.infer<typeof UpdateGaiaConfigSchema>;

/**
 * The team's git isolation strategy for `/gaia-plan` and `/gaia-debt`
 * orchestration. Read at the CONSUMER (the shared isolation fragment's
 * `case`), never at the config-parse boundary: `AutomationConfigSchema`
 * stores the raw string permissively (see `isolation_policy` below) so an
 * unrecognized or future value never malforms the whole config.
 */
export const ISOLATION_POLICIES = [
  'always-worktree',
  'prefer-branch',
  'prefer-worktree',
] as const;

export type IsolationPolicy = (typeof ISOLATION_POLICIES)[number];

export const isIsolationPolicy = (value: string): value is IsolationPolicy =>
  (ISOLATION_POLICIES as readonly string[]).includes(value);

export const AutomationConfigSchema = z.object({
  // Permissive by contract: an absent key, an unrecognized string, and a
  // non-string value must all leave the config parsing `ok`. A bare
  // `z.literal([...])` union would reject a typo or a future value and
  // malform the whole config, which reddens every adopter's scheduled
  // cron. The three known values are validated at the WRITE boundary (the
  // CLI) and at the CONSUMER (the fragment's `case`), not here.
  isolation_policy: z.string().optional().catch(undefined),
  pnpm_audit: ToolConfigSchema,
  sandbox_recommended: z.boolean().optional(),
  setup_complete: z.boolean(),
  setup_opted_out: z.boolean(),
  stale_branches: ToolConfigSchema,
  update_deps: ToolConfigSchema,
  update_gaia: UpdateGaiaConfigSchema,
  // Same permissive-at-read pattern as isolation_policy above: an
  // unrecognized or absent version degrades to 1 rather than malforming
  // the config.
  version: z.literal(1).catch(1),
  wiki: ToolConfigSchema,
});

export type AutomationConfig = z.infer<typeof AutomationConfigSchema>;

/**
 * The `AutomationConfig` keys that hold a `ToolConfig` row, i.e. the
 * per-tool slots a `ToolId` can resolve to. Excludes `update_gaia`
 * (`UpdateGaiaConfig`) and the scalar config fields.
 *
 * `-?` strips the source's optional modifier from the intermediate mapped
 * type: without it, an optional `AutomationConfig` key (e.g.
 * `sandbox_recommended`) makes the homomorphic mapping preserve that
 * optionality onto its own (unrelated) `never` slot, and indexing the
 * mapped type by `keyof AutomationConfig` then widens the whole union to
 * include `undefined`.
 */
export type ToolConfigKey = {
  [K in keyof AutomationConfig]-?: AutomationConfig[K] extends ToolConfig ? K
  : never;
}[keyof AutomationConfig];

/**
 * Map from kebab-case tool id (used in state file paths and CLI args)
 * to the snake_case key used inside `.gaia/automation.json`.
 *
 * The split is intentional: the SPEC names the JSON keys snake_case
 * (`pnpm_audit`, `stale_branches`) but workflow / state-file paths use
 * kebab-case. The value type is `ToolConfigKey` so `config[key]` resolves
 * directly to `ToolConfig`; no cast needed at call sites.
 */
export const TOOL_ID_TO_CONFIG_KEY: Readonly<Record<ToolId, ToolConfigKey>> = {
  'pnpm-audit': 'pnpm_audit',
  'stale-branches': 'stale_branches',
  'update-deps': 'update_deps',
  wiki: 'wiki',
};

export const CONFIG_KEY_TO_TOOL_ID: Readonly<Record<string, ToolId>> = {
  pnpm_audit: 'pnpm-audit',
  stale_branches: 'stale-branches',
  update_deps: 'update-deps',
  wiki: 'wiki',
};

export const parseAutomationConfig = (raw: unknown): AutomationConfig =>
  AutomationConfigSchema.parse(raw);

/**
 * Raw-preserving variant of `readAutomationConfig`. `raw` is the
 * unstripped `JSON.parse` output, so a key a newer binary wrote (and
 * this schema doesn't yet know about) survives a read-merge-write cycle
 * instead of being dropped by Zod's default `.strip()` behaviour. Write
 * primitives that must preserve forward-compatibility (e.g.
 * `setup-ci write-isolation-policy`) read-merge onto `raw`, never onto
 * `config`.
 */
export type ReadAutomationConfigRawResult =
  | {config: AutomationConfig; raw: Record<string, unknown>; status: 'ok'}
  | {error: string; status: 'malformed'}
  | {status: 'missing'};

export const readAutomationConfigRaw = (
  repoRoot: string
): ReadAutomationConfigRawResult => {
  const filePath = automationConfigPath(repoRoot);

  if (!existsSync(filePath)) return {status: 'missing'};

  let raw: string;

  try {
    raw = readFileSync(filePath, 'utf8');
  } catch (error) {
    return {
      error: `${filePath}: ${error instanceof Error ? error.message : String(error)}`,
      status: 'malformed',
    };
  }

  let parsed: unknown;

  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    return {
      error: `${filePath}: invalid JSON: ${error instanceof Error ? error.message : String(error)}`,
      status: 'malformed',
    };
  }

  const result = AutomationConfigSchema.safeParse(parsed);

  if (!result.success) {
    return {
      error: summarizeZodError(filePath, result.error),
      status: 'malformed',
    };
  }

  // The schema is a `z.object(...)`, so a successful `safeParse` implies
  // `parsed` was itself an object; the cast just names that fact for
  // TypeScript, `parsed` came straight from `JSON.parse` unstripped.
  return {
    config: result.data,
    raw: parsed as Record<string, unknown>,
    status: 'ok',
  };
};

export type ReadAutomationConfigResult =
  | {config: AutomationConfig; status: 'ok'}
  | {error: string; status: 'malformed'}
  | {status: 'missing'};

export const readAutomationConfig = (
  repoRoot: string
): ReadAutomationConfigResult => {
  const result = readAutomationConfigRaw(repoRoot);

  if (result.status === 'ok') {
    return {config: result.config, status: 'ok'};
  }

  return result;
};
