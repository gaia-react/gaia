/**
 * Atomic-write helper for per-tool state files at
 * `.gaia/automation.state-<tool>.json`.
 *
 * Tiny extraction of the `writeFileSync(tmp); renameSync(tmp, target)`
 * idiom from `wiki/state-init.ts` and `wiki/state-bump.ts`. The wiki
 * handlers continue to inline the idiom; refactoring them to use this
 * helper is intentionally out of scope for slice 1 (surgical changes).
 *
 * Serializes with 2-space indentation + trailing newline to match the
 * wiki state file format.
 */
import {mkdirSync, renameSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {automationStatePath} from '../paths.js';
import type {AutomationStateFile} from '../../schemas/automation-state.js';
import type {ToolId} from '../../schemas/automation-config.js';

export const writeStateFile = (
  repoRoot: string,
  tool: ToolId,
  state: AutomationStateFile
): void => {
  const target = automationStatePath(repoRoot, tool);
  mkdirSync(path.dirname(target), {recursive: true});

  const serialized = `${JSON.stringify(state, null, 2)}\n`;
  const tmpPath = `${target}.tmp`;
  writeFileSync(tmpPath, serialized, 'utf8');
  renameSync(tmpPath, target);
};
