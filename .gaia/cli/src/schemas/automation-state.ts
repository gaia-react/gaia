/**
 * Zod schema + read helpers for `.gaia/automation.state-<tool>.json`,
 * the per-tool state files driven by the smart-cron decision tree.
 *
 * A missing state file is treated by the SPEC as "no prior run, force a
 * run" but that decision belongs in `cron-decide`. This module reports
 * `{status: 'missing'}` and lets the caller decide.
 */
import {existsSync, readFileSync} from 'node:fs';
import {z} from 'zod';
import {automationStatePath} from '../automation/paths.js';
import type {ToolId} from './automation-config.js';
import {summarizeZodError} from './zod-error.js';

export const TriggerSchema = z.enum(['cron', 'force', 'workflow_dispatch']);
export type Trigger = z.infer<typeof TriggerSchema>;

const SHA_REGEX = /^[0-9a-f]{40}$/u;

export const AutomationStateFileSchema = z.object({
  version: z.literal(1),
  last_run_at: z.iso.datetime({offset: false}),
  last_run_sha: z.string().regex(SHA_REGEX, '40-char git sha'),
  last_run_trigger: TriggerSchema,
  skip_count: z.number().int().min(0),
  last_run_cost: z.number().min(0),
  cost_overage: z.boolean(),
});
export type AutomationStateFile = z.infer<typeof AutomationStateFileSchema>;

export const parseAutomationState = (raw: unknown): AutomationStateFile =>
  AutomationStateFileSchema.parse(raw);

export type ReadAutomationStateResult =
  | {state: AutomationStateFile; status: 'ok'}
  | {status: 'missing'}
  | {error: string; status: 'malformed'};

export const readAutomationState = (
  repoRoot: string,
  tool: ToolId
): ReadAutomationStateResult => {
  const filePath = automationStatePath(repoRoot, tool);

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

  const result = AutomationStateFileSchema.safeParse(parsed);

  if (!result.success) {
    return {
      error: summarizeZodError(filePath, result.error),
      status: 'malformed',
    };
  }

  return {state: result.data, status: 'ok'};
};
