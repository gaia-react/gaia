import {afterEach, beforeEach, describe, expect, test} from 'vitest';
/**
 * Tests for `.gaia/cli/src/setup/util/state-file.ts`, focused on the
 * retired-step migration: `readStateFile` must tolerate a persisted
 * `'mentorship-decision'` entry (dropping it from the returned
 * `completed_steps`) while still throwing on a genuinely unrecognized step.
 */
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
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
