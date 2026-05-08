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
import {execFileSync} from 'node:child_process';
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
 * Resolve the main worktree's root from any cwd inside any worktree of
 * the same repository.
 *
 * `git rev-parse --show-toplevel` returns the calling worktree's root,
 * which differs between the main checkout and a linked worktree. The
 * setup-state file is canonical to the clone (not per-worktree), so
 * every reader/writer must anchor to the SAME path regardless of which
 * worktree they ran from. `--git-common-dir` returns the shared `.git`
 * directory (the main repo's `.git` in every worktree); the directory
 * containing it is the main worktree root.
 *
 * Assumption: `--git-common-dir` returns the shared `.git` (relative
 * `.git` from main, or an absolute path like `/repo/.git` from a linked
 * worktree). `path.dirname` of that yields the main checkout root. This
 * holds for standard git worktrees but NOT submodules, where the common
 * dir is an internal gitdir path inside the parent repo. GAIA does not
 * support a submodule topology; do not change the resolution strategy
 * without re-validating that constraint.
 *
 * Throws if `git` is unavailable or `cwd` is not inside a git repo —
 * matching `resolveRepoRoot`'s contract so callers can translate to the
 * existing `not_a_git_repo` exit code.
 */
export const resolveMainWorktreeRoot = (cwd: string): string => {
  const commonDir = execFileSync('git', ['rev-parse', '--git-common-dir'], {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  }).trim();

  const absoluteCommonDir = path.isAbsolute(commonDir)
    ? commonDir
    : path.resolve(cwd, commonDir);

  return path.dirname(absoluteCommonDir);
};

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
