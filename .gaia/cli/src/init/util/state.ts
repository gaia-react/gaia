/**
 * Read/write `.gaia/init-state.json` — the per-repo resumability cursor
 * for `gaia init`. Each subcommand records its name into `completed_steps`
 * on success so a failed run can be resumed via `gaia init resume`.
 *
 * Stored at `.gaia/init-state.json` (repo-root-relative). Atomic writes:
 * temp + rename so a partial write can never leave a half-serialized
 * file behind.
 */
import {existsSync, mkdirSync, readFileSync, renameSync, writeFileSync} from 'node:fs';
import path from 'node:path';

export const STATE_FILE_RELATIVE = '.gaia/init-state.json';

export type InitState = {
  completed_steps: string[];
  step_args: Record<string, unknown>;
};

const emptyState = (): InitState => ({completed_steps: [], step_args: {}});

const isStringArray = (value: unknown): value is string[] =>
  Array.isArray(value) && value.every((entry) => typeof entry === 'string');

const parseState = (raw: string): InitState => {
  let parsed: unknown;

  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error('.gaia/init-state.json is not valid JSON');
  }

  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('.gaia/init-state.json must be a JSON object');
  }

  const source = parsed as Record<string, unknown>;
  const completed = source.completed_steps;
  const args = source.step_args;
  const completedSteps = isStringArray(completed) ? completed : [];
  const stepArgs =
    args !== null && typeof args === 'object' && !Array.isArray(args)
      ? (args as Record<string, unknown>)
      : {};

  return {completed_steps: completedSteps, step_args: stepArgs};
};

export const stateFilePath = (cwd: string): string =>
  path.join(cwd, STATE_FILE_RELATIVE);

export const readState = (cwd: string): InitState => {
  const target = stateFilePath(cwd);

  if (!existsSync(target)) return emptyState();
  const raw = readFileSync(target, 'utf8');

  return parseState(raw);
};

export const writeState = (cwd: string, state: InitState): void => {
  const target = stateFilePath(cwd);
  mkdirSync(path.dirname(target), {recursive: true});
  const serialized = `${JSON.stringify(state, null, 2)}\n`;
  const tmp = `${target}.tmp`;
  writeFileSync(tmp, serialized, 'utf8');
  renameSync(tmp, target);
};

export const isStepCompleted = (cwd: string, step: string): boolean => {
  try {
    const state = readState(cwd);

    return state.completed_steps.includes(step);
  } catch {
    return false;
  }
};

export const markStepCompleted = (
  cwd: string,
  step: string,
  args: Record<string, unknown> = {}
): void => {
  const state = readState(cwd);

  if (!state.completed_steps.includes(step)) {
    state.completed_steps.push(step);
  }
  state.step_args[step] = args;
  writeState(cwd, state);
};

/**
 * Canonical step ordering used by `gaia init resume --from-step <N>`.
 * Steps are 1-indexed in user-facing surfaces.
 */
export const STEP_ORDER = [
  'strip-branding',
  'configure-i18n',
  'rename',
  'wire-statusline',
  'finalize',
] as const;

export type StepName = (typeof STEP_ORDER)[number];
