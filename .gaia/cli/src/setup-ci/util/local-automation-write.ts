/**
 * Atomic-write helper for `.gaia/local/automation.json` (the gitignored
 * personal nudge state).
 *
 * Slice 1 ships only the read; slice 4 adds the write (per Phase B's
 * personal-dismiss flow). Mirrors the `writeFileSync(tmp);
 * renameSync(tmp, target)` idiom used by `automation/util/state-write.ts`
 * and the wiki state writers.
 *
 * Validates against `LocalAutomationSchema` before writing; no caller
 * can persist a malformed shape.
 */
import {mkdirSync, renameSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {localAutomationPath} from '../../automation/paths.js';
import {
  LocalAutomationSchema,
  type LocalAutomation,
} from '../../schemas/local-automation.js';

export const writeLocalAutomation = (
  repoRoot: string,
  payload: LocalAutomation
): void => {
  // Validate the shape (throws on malformed input). Serialize the raw
  // payload, not the parsed output, so unknown fields land
  // round-trip-safe instead of being silently stripped by Zod's default
  // `.strip()` behaviour.
  LocalAutomationSchema.parse(payload);

  const target = localAutomationPath(repoRoot);
  mkdirSync(path.dirname(target), {recursive: true});

  const serialized = `${JSON.stringify(payload, null, 2)}\n`;
  const tmpPath = `${target}.tmp`;
  writeFileSync(tmpPath, serialized, 'utf8');
  renameSync(tmpPath, target);
};
