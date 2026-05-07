/**
 * Shared IO + schema for `.gaia/local/setup-state.json`.
 *
 * Every clone needs to run a one-shot per-machine setup (install React
 * Doctor, Playwright CLI, Serena MCP, plugins, init spec-kit, chmod the
 * statusline, opt into mentorship). The slash command `/setup-gaia`
 * orchestrates the steps; this state file records progress so a partial
 * run can resume idempotently.
 *
 * The file lives under `.gaia/local/` (gitignored) — every developer on
 * a clone has their own state file. Maintainers in the upstream repo
 * also write here; the file is just a per-machine marker.
 */
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';

export const STATE_FILENAME = 'setup-state.json';
export const STATE_DIRECTORY_RELATIVE = path.join('.gaia', 'local');

/**
 * Canonical step identifiers. The slash command decides which steps it
 * runs; the CLI is just a recorder. Adding a new step here requires
 * updating both the slash command and the statusline gate (any
 * incomplete step in this list keeps the indicator visible).
 */
export const SETUP_STEPS = [
  'install-tools',
  'install-plugins',
  'init-speckit',
  'chmod-statusline',
  'bootstrap-env',
  'mentorship-decision',
] as const;

export type SetupStep = (typeof SETUP_STEPS)[number];

export type SetupState = {
  completed_at: null | string;
  completed_steps: SetupStep[];
  started_at: string;
  version: 1;
};

const isSetupStep = (value: string): value is SetupStep =>
  (SETUP_STEPS as readonly string[]).includes(value);

export const resolveStateFilePath = (repoRoot: string): string =>
  path.join(repoRoot, STATE_DIRECTORY_RELATIVE, STATE_FILENAME);

export const readStateFile = (repoRoot: string): SetupState | null => {
  const filePath = resolveStateFilePath(repoRoot);

  if (!existsSync(filePath)) return null;

  const raw = readFileSync(filePath, 'utf8');
  const parsed = JSON.parse(raw) as Partial<SetupState>;

  if (parsed.version !== 1) {
    throw new Error(
      `setup-state.json has unexpected version: ${String(parsed.version)}`
    );
  }

  return {
    completed_at: parsed.completed_at ?? null,
    completed_steps: (parsed.completed_steps ?? []).filter(isSetupStep),
    started_at: parsed.started_at ?? new Date().toISOString(),
    version: 1,
  };
};

export const writeStateFile = (
  repoRoot: string,
  state: SetupState
): void => {
  const filePath = resolveStateFilePath(repoRoot);
  const parent = path.dirname(filePath);

  if (!existsSync(parent)) {
    mkdirSync(parent, {mode: 0o755, recursive: true});
  }

  const serialized = `${JSON.stringify(state, null, 2)}\n`;
  const tmpPath = `${filePath}.tmp`;
  writeFileSync(tmpPath, serialized, 'utf8');
  renameSync(tmpPath, filePath);
};

/**
 * Compute the set of steps that have NOT yet been recorded as complete.
 * Order matches `SETUP_STEPS` so callers can present them in the canonical
 * sequence the slash command expects.
 */
export const pendingSteps = (state: null | SetupState): SetupStep[] => {
  const completed = new Set(state?.completed_steps ?? []);

  return SETUP_STEPS.filter((step) => !completed.has(step));
};

export const isComplete = (state: null | SetupState): boolean =>
  state?.completed_at !== null && state?.completed_at !== undefined;
