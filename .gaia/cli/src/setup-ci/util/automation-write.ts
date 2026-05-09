/**
 * Atomic-write helper for `.gaia/automation.json` (the committed GAIA
 * CI configuration).
 *
 * Used by the `opt-out-team` and `finalize` primitives. Mirrors the
 * `writeFileSync(tmp); renameSync(tmp, target)` idiom from
 * `automation/util/state-write.ts`. Validates the payload against
 * `AutomationConfigSchema` before any I/O so callers cannot persist a
 * malformed shape.
 */
import {mkdirSync, renameSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {automationConfigPath} from '../../automation/paths.js';
import {
  AutomationConfigSchema,
  type AutomationConfig,
} from '../../schemas/automation-config.js';

export const writeAutomationConfig = (
  repoRoot: string,
  payload: AutomationConfig
): void => {
  const validated = AutomationConfigSchema.parse(payload);

  const target = automationConfigPath(repoRoot);
  mkdirSync(path.dirname(target), {recursive: true});

  const serialized = `${JSON.stringify(validated, null, 2)}\n`;
  const tmpPath = `${target}.tmp`;
  writeFileSync(tmpPath, serialized, 'utf8');
  renameSync(tmpPath, target);
};
