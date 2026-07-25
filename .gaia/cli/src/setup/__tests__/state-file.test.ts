import {afterEach, beforeEach, describe, expect, test} from 'vitest';
/**
 * Tests for `.gaia/cli/src/setup/util/state-file.ts`'s retired-step
 * migration: `readStateFile` must tolerate a persisted
 * `'mentorship-decision'` entry (dropping it from the returned
 * `completed_steps`) while still throwing on a genuinely unrecognized step.
 * Also covers `resolveMainWorktreeRoot`'s validation hardening (task 8.3);
 * that resolver now lives in `.gaia/cli/src/util/main-root.ts`.
 */
import {execFileSync} from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {newMainCheckout} from '../../util/main-checkout-fixture.js';
import {resolveMainWorktreeRoot} from '../../util/main-root.js';
import {
  pendingSteps,
  readStateFile,
  RETIRED_SETUP_STEPS,
  SETUP_STEPS,
} from '../util/state-file.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
  statePath: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-state-file-'));
  execFileSync('git', ['init', '-q'], {cwd: root});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
    statePath: path.join(root, '.gaia', 'local', 'setup-state.json'),
  };
};

const writeStateJson = (statePath: string, value: unknown): void => {
  mkdirSync(path.dirname(statePath), {mode: 0o755, recursive: true});
  writeFileSync(statePath, JSON.stringify(value), 'utf8');
};

describe('SETUP_STEPS / RETIRED_SETUP_STEPS', () => {
  test('SETUP_STEPS does not contain the retired mentorship-decision step', () => {
    expect(SETUP_STEPS).not.toContain('mentorship-decision');
  });

  test('RETIRED_SETUP_STEPS contains mentorship-decision', () => {
    expect(RETIRED_SETUP_STEPS).toContain('mentorship-decision');
  });
});

describe('readStateFile: retired-step migration', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('a persisted mentorship-decision entry parses and is dropped from completed_steps', () => {
    writeStateJson(sandbox.statePath, {
      completed_at: null,
      completed_steps: [
        'install-tools',
        'install-plugins',
        'init-speckit',
        'chmod-statusline',
        'bootstrap-env',
        'mentorship-decision',
        'audit-mode-decision',
      ],
      started_at: '2026-05-07T11:00:00.000Z',
      version: 1,
    });

    const state = readStateFile(sandbox.root);
    expect(state).not.toBeNull();
    expect(state?.completed_steps).not.toContain('mentorship-decision');
    expect(state?.completed_steps).toEqual([...SETUP_STEPS]);
  });

  test('pendingSteps reports none when the six surviving steps are all present', () => {
    writeStateJson(sandbox.statePath, {
      completed_at: null,
      completed_steps: [
        'install-tools',
        'install-plugins',
        'init-speckit',
        'chmod-statusline',
        'bootstrap-env',
        'mentorship-decision',
        'audit-mode-decision',
      ],
      started_at: '2026-05-07T11:00:00.000Z',
      version: 1,
    });

    const state = readStateFile(sandbox.root);
    expect(pendingSteps(state)).toEqual([]);
  });

  test('a genuinely unrecognized step still throws', () => {
    writeStateJson(sandbox.statePath, {
      completed_at: null,
      completed_steps: ['install-tools', 'bogus-step'],
      started_at: '2026-05-07T11:00:00.000Z',
      version: 1,
    });

    expect(() => readStateFile(sandbox.root)).toThrow('bogus-step');
  });
});

describe('resolveMainWorktreeRoot', () => {
  let scratch: string[];

  beforeEach(() => {
    scratch = [];
  });

  afterEach(() => {
    for (const dir of scratch) rmSync(dir, {force: true, recursive: true});
  });

  test('resolves a main checkout to itself', () => {
    const mainRoot = newMainCheckout('gaia-resolver-');
    scratch.push(mainRoot);

    expect(resolveMainWorktreeRoot(mainRoot)).toBe(mainRoot);
  });

  test('resolves a linked worktree to the main checkout root', () => {
    const mainRoot = newMainCheckout('gaia-resolver-');
    scratch.push(mainRoot);
    const worktree = realpathSync(
      mkdtempSync(path.join(tmpdir(), 'gaia-resolver-wt-'))
    );
    rmSync(worktree, {force: true, recursive: true});
    execFileSync(
      'git',
      ['worktree', 'add', '-q', '-b', 'gaia-resolver-treeB', worktree],
      {cwd: mainRoot}
    );
    scratch.push(worktree);

    expect(resolveMainWorktreeRoot(worktree)).toBe(mainRoot);
  });

  test('throws a named validation error for a candidate that cannot round-trip (bare repository)', () => {
    // A bare repository's --git-common-dir is ".", so the candidate this
    // derives is the bare repo's PARENT directory -- which is not a git
    // working tree at all. `--show-toplevel` from there fails, so
    // validation must reject the candidate rather than returning it.
    const parent = realpathSync(
      mkdtempSync(path.join(tmpdir(), 'gaia-resolver-bare-'))
    );
    scratch.push(parent);
    const bareRepo = path.join(parent, 'bare.git');
    execFileSync('git', ['init', '-q', '--bare', bareRepo]);

    expect(() => resolveMainWorktreeRoot(bareRepo)).toThrow(
      /resolveMainWorktreeRoot:.*not a git working tree/u
    );
  });

  test('an ambient GIT_DIR pointing at an unrelated repository does not change the answer', () => {
    // D1 regression test: GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR override git's
    // repository discovery for every subprocess regardless of `cwd`. Without
    // the env-stripping in execGaiaGit, this would hijack resolution toward
    // `other` and the answer would silently change.
    const mainRoot = newMainCheckout('gaia-resolver-');
    scratch.push(mainRoot);
    const other = newMainCheckout('gaia-resolver-');
    scratch.push(other);

    const saved = {
      GIT_COMMON_DIR: process.env.GIT_COMMON_DIR,
      GIT_DIR: process.env.GIT_DIR,
      GIT_WORK_TREE: process.env.GIT_WORK_TREE,
    };
    process.env.GIT_DIR = path.join(other, '.git');
    process.env.GIT_WORK_TREE = other;
    process.env.GIT_COMMON_DIR = path.join(other, '.git');

    try {
      expect(resolveMainWorktreeRoot(mainRoot)).toBe(mainRoot);
    } finally {
      for (const [key, value] of Object.entries(saved)) {
        if (value === undefined) delete process.env[key];
        else process.env[key] = value;
      }
    }
  });
});
