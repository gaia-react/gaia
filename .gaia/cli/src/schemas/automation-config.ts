/**
 * Zod schema + read helpers for `.gaia/automation.json`, the committed
 * GAIA CI configuration file.
 *
 * Per the SPEC-001 slice 1 contract: a missing config file means
 * "GAIA CI not configured" — every defer / cron read returns a no-op
 * result. The `read*` helpers therefore never throw; callers branch on
 * the discriminated `status` field.
 */
import {existsSync, readFileSync} from 'node:fs';
import {z} from 'zod';
import {automationConfigPath} from '../automation/paths.js';

export const TOOL_IDS = ['wiki', 'update-deps', 'pnpm-audit', 'stale-branches'] as const;
export type ToolId = (typeof TOOL_IDS)[number];

export const ToolModeSchema = z.enum(['ci', 'local', 'off']);
export type ToolMode = z.infer<typeof ToolModeSchema>;

export const ScheduleSchema = z.enum(['daily', 'weekly', 'monthly']);
export type Schedule = z.infer<typeof ScheduleSchema>;

export const ToolConfigSchema = z.object({
  mode: ToolModeSchema,
  schedule: ScheduleSchema.optional(),
});
export type ToolConfig = z.infer<typeof ToolConfigSchema>;

export const UpdateGaiaConfigSchema = z.object({
  mode: z.literal('local'),
});
export type UpdateGaiaConfig = z.infer<typeof UpdateGaiaConfigSchema>;

export const AutomationConfigSchema = z.object({
  version: z.literal(1),
  setup_complete: z.boolean(),
  setup_opted_out: z.boolean(),
  wiki: ToolConfigSchema,
  update_deps: ToolConfigSchema,
  pnpm_audit: ToolConfigSchema,
  stale_branches: ToolConfigSchema,
  update_gaia: UpdateGaiaConfigSchema,
});
export type AutomationConfig = z.infer<typeof AutomationConfigSchema>;

/**
 * Map from kebab-case tool id (used in state file paths and CLI args)
 * to the snake_case key used inside `.gaia/automation.json`.
 *
 * The split is intentional: the SPEC names the JSON keys snake_case
 * (`pnpm_audit`, `stale_branches`) but workflow / state-file paths use
 * kebab-case. Locking the mapping in one place keeps callers typesafe.
 */
export const TOOL_ID_TO_CONFIG_KEY: Readonly<Record<ToolId, keyof AutomationConfig>> = {
  'pnpm-audit': 'pnpm_audit',
  'stale-branches': 'stale_branches',
  'update-deps': 'update_deps',
  'wiki': 'wiki',
};

export const CONFIG_KEY_TO_TOOL_ID: Readonly<Record<string, ToolId>> = {
  pnpm_audit: 'pnpm-audit',
  stale_branches: 'stale-branches',
  update_deps: 'update-deps',
  wiki: 'wiki',
};

export const parseAutomationConfig = (raw: unknown): AutomationConfig =>
  AutomationConfigSchema.parse(raw);

export type ReadAutomationConfigResult =
  | {config: AutomationConfig; status: 'ok'}
  | {status: 'missing'}
  | {error: string; status: 'malformed'};

const summarizeZodError = (filePath: string, error: z.ZodError): string => {
  const lines = error.issues.map((issue) => {
    const pathStr = issue.path.length === 0 ? '<root>' : issue.path.join('.');

    return `${pathStr}: ${issue.message}`;
  });

  return `${filePath}: ${lines.join('; ')}`;
};

export const readAutomationConfig = (
  repoRoot: string
): ReadAutomationConfigResult => {
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
      error: `${filePath}: invalid JSON — ${error instanceof Error ? error.message : String(error)}`,
      status: 'malformed',
    };
  }

  const result = AutomationConfigSchema.safeParse(parsed);

  if (!result.success) {
    return {error: summarizeZodError(filePath, result.error), status: 'malformed'};
  }

  return {config: result.data, status: 'ok'};
};
