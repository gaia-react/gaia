/**
 * Worktree-aware coverage for the `gaia setup` CLI surface.
 *
 * The state-file resolver derives the canonical path from
 * `git rev-parse --git-common-dir`, so when the cwd is a linked worktree the
 * helper resolves to the MAIN checkout's `.gaia/local/setup-state.json`,
 * never the linked worktree's own `.gaia/local/`.
 *
 * Strategy: each test gets a fresh `setupWorktreeSandbox()` that creates BOTH
 * a main checkout and a linked worktree under one `mkdtemp`'d parent.
 */
import {execFileSync} from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {run as runFinalize} from '../finalize.js';
import {run as runMarkStep} from '../mark-step.js';
import {run as runStatus} from '../status.js';
import {SETUP_STEPS, type SetupState} from '../util/state-file.js';

type WorktreeSandbox = {
  cleanup: () => void;
  /** Path to the linked worktree (cwd for tests). */
  linkedRoot: string;
  /** Path to the main checkout. Setup-state lookup must resolve here. */
  mainRoot: string;
  /** Canonical path: `${mainRoot}/.gaia/local/setup-state.json`. */
  statePath: string;
};

const GIT_IDENTITY_ENV = {
  GIT_AUTHOR_EMAIL: 'gaia-test@example.com',
  GIT_AUTHOR_NAME: 'GAIA Test',
  GIT_COMMITTER_EMAIL: 'gaia-test@example.com',
  GIT_COMMITTER_NAME: 'GAIA Test',
};

const setupWorktreeSandbox = (): WorktreeSandbox => {
  const parent = mkdtempSync(path.join(tmpdir(), 'gaia-setup-wt-'));
  const mainRoot = path.join(parent, 'main');
  const linkedRoot = path.join(parent, 'linked');

  mkdirSync(mainRoot, {recursive: true});
  execFileSync('git', ['init', '-q'], {cwd: mainRoot});
  // `git worktree add` requires a ref to point at; create an empty commit so
  // there's a HEAD for the new branch to fork from. Set author/committer env
  // explicitly so this works in CI environments without a configured user.
  execFileSync('git', ['commit', '--allow-empty', '-q', '-m', 'init'], {
    cwd: mainRoot,
    env: {...process.env, ...GIT_IDENTITY_ENV},
  });
  execFileSync(
    'git',
    ['worktree', 'add', '-q', linkedRoot, '-b', 'feature/test'],
    {cwd: mainRoot, env: {...process.env, ...GIT_IDENTITY_ENV}}
  );

  return {
    cleanup: () => {
      rmSync(parent, {force: true, recursive: true});
    },
    linkedRoot,
    mainRoot,
    statePath: path.join(mainRoot, '.gaia', 'local', 'setup-state.json'),
  };
};

const captureStdio = (): {
  errors: string[];
  outputs: string[];
  restore: () => void;
} => {
  const outputs: string[] = [];
  const errors: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      outputs.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      errors.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    errors,
    outputs,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

const writeStateAt = (filePath: string, state: SetupState): void => {
  mkdirSync(path.dirname(filePath), {mode: 0o755, recursive: true});
  writeFileSync(filePath, `${JSON.stringify(state, null, 2)}\n`, 'utf8');
};

/**
 * Parse the last non-empty stderr line as JSON and return its `code` field.
 */
const lastErrorCode = (errors: string[]): string => {
  const lines = errors.join('').trim().split('\n');

  return (JSON.parse(lines[lines.length - 1] as string) as {code: string}).code;
};

/**
 * Write a realistic `mentorship.json` at the given repo root's `.gaia/local/`.
 * The finalize gate is existence-only, so the value is a free knob.
 */
const writeMentorshipFixture = (
  repoRoot: string,
  enabled: boolean | null = false
): void => {
  const dir = path.join(repoRoot, '.gaia', 'local');
  mkdirSync(dir, {mode: 0o755, recursive: true});
  writeFileSync(
    path.join(dir, 'mentorship.json'),
    `${JSON.stringify({analytics: {enabled: false}, decided_at: null, decided_via: null, enabled}, null, 2)}\n`,
    'utf8'
  );
};

describe('gaia setup (linked worktree)', () => {
  let sandbox: WorktreeSandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupWorktreeSandbox();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('status --json reads the main checkout state file from the linked worktree', () => {
    const completedAt = '2026-05-07T12:00:00.000Z';
    writeStateAt(sandbox.statePath, {
      completed_at: completedAt,
      completed_steps: [...SETUP_STEPS],
      started_at: '2026-05-07T11:00:00.000Z',
      version: 1,
    });

    const linkedStatePath = path.join(
      sandbox.linkedRoot,
      '.gaia',
      'local',
      'setup-state.json'
    );
    expect(existsSync(linkedStatePath)).toBe(false);

    const exit = runStatus(['--json'], {cwd: sandbox.linkedRoot});
    expect(exit).toBe(0);

    const out = JSON.parse(stdio.outputs.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(out.complete).toBe(true);
    expect(out.completed_at).toBe(completedAt);
  });

  test('mark-step writes to the main checkout when invoked from the linked worktree', () => {
    expect(existsSync(sandbox.statePath)).toBe(false);

    const exit = runMarkStep(['install-tools'], {cwd: sandbox.linkedRoot});
    expect(exit).toBe(0);

    expect(existsSync(sandbox.statePath)).toBe(true);
    const linkedStatePath = path.join(
      sandbox.linkedRoot,
      '.gaia',
      'local',
      'setup-state.json'
    );
    expect(existsSync(linkedStatePath)).toBe(false);

    const parsed = JSON.parse(
      readFileSync(sandbox.statePath, 'utf8')
    ) as Record<string, unknown>;
    expect(parsed.completed_steps).toEqual(['install-tools']);
  });

  test('finalize updates the main checkout state file when invoked from the linked worktree', () => {
    for (const step of SETUP_STEPS) {
      runMarkStep([step], {cwd: sandbox.linkedRoot});
    }
    // The gate resolves mentorship.json from the MAIN worktree root, so the
    // fixture must live there even though finalize is invoked from the linked
    // cwd.
    writeMentorshipFixture(sandbox.mainRoot);

    const fixedNow = new Date('2026-05-07T12:00:00.000Z');
    const exit = runFinalize([], {
      cwd: sandbox.linkedRoot,
      now: () => fixedNow,
    });
    expect(exit).toBe(0);

    const parsed = JSON.parse(
      readFileSync(sandbox.statePath, 'utf8')
    ) as Record<string, unknown>;
    expect(parsed.completed_at).toBe(fixedNow.toISOString());

    const linkedStatePath = path.join(
      sandbox.linkedRoot,
      '.gaia',
      'local',
      'setup-state.json'
    );
    expect(existsSync(linkedStatePath)).toBe(false);
  });

  test('finalize refuses when mentorship.json exists only in the linked worktree', () => {
    for (const step of SETUP_STEPS) {
      runMarkStep([step], {cwd: sandbox.linkedRoot});
    }
    // Fixture at the LINKED root only; the main root has none. The gate must
    // resolve from the main root, so this must NOT satisfy it.
    writeMentorshipFixture(sandbox.linkedRoot);

    const exit = runFinalize([], {cwd: sandbox.linkedRoot});
    expect(exit).toBe(1);
    expect(lastErrorCode(stdio.errors)).toBe('mentorship_decision_missing');
  });

  test('a pre-existing per-worktree state file is ignored (no migration)', () => {
    writeStateAt(sandbox.statePath, {
      completed_at: null,
      completed_steps: [],
      started_at: '2026-05-07T11:00:00.000Z',
      version: 1,
    });

    const linkedStatePath = path.join(
      sandbox.linkedRoot,
      '.gaia',
      'local',
      'setup-state.json'
    );
    const linkedCompletedAt = '2026-05-07T13:00:00.000Z';
    writeStateAt(linkedStatePath, {
      completed_at: linkedCompletedAt,
      completed_steps: [...SETUP_STEPS],
      started_at: '2026-05-07T12:00:00.000Z',
      version: 1,
    });

    const exit = runStatus(['--json'], {cwd: sandbox.linkedRoot});
    expect(exit).toBe(0);

    const out = JSON.parse(stdio.outputs.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(out.complete).toBe(false);
    // The stale linked-side file is not mutated by the resolver.
    expect(existsSync(linkedStatePath)).toBe(true);
    const linkedParsed = JSON.parse(
      readFileSync(linkedStatePath, 'utf8')
    ) as Record<string, unknown>;
    expect(linkedParsed.completed_at).toBe(linkedCompletedAt);
  });
});
