/**
 * Zod schema + read helpers for `.gaia/local/automation.json`, the
 * gitignored personal nudge state.
 *
 * The path constant and read helper are shared with the write helper in
 * `setup-ci/util/local-automation-write.ts`, so both sides agree on one
 * canonical source.
 */
import {z} from 'zod';
import {existsSync, readFileSync} from 'node:fs';
import {localAutomationPath} from '../automation/paths.js';
import {summarizeZodError} from './zod-error.js';

export const LocalAutomationSchema = z.object({
  nudge_dismissed: z.boolean(),
  version: z.literal(1),
});

export type LocalAutomation = z.infer<typeof LocalAutomationSchema>;

export const parseLocalAutomation = (raw: unknown): LocalAutomation =>
  LocalAutomationSchema.parse(raw);

export type ReadLocalAutomationResult =
  | {error: string; status: 'malformed'}
  | {local: LocalAutomation; status: 'ok'}
  | {status: 'missing'};

export const readLocalAutomation = (
  repoRoot: string
): ReadLocalAutomationResult => {
  const filePath = localAutomationPath(repoRoot);

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

  const result = LocalAutomationSchema.safeParse(parsed);

  if (!result.success) {
    return {
      error: summarizeZodError(filePath, result.error),
      status: 'malformed',
    };
  }

  return {local: result.data, status: 'ok'};
};
