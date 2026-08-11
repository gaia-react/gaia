/**
 * Strategy: each test gets a fresh `setupWorktreeSandbox()` that creates
 * a real main checkout + linked worktree under one `mkdtemp`'d parent so
 * `git rev-parse --git-common-dir` resolves correctly.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readlinkSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';
import {run as runLinkWorktree} from '../link-worktree.js';

// The handler reads the shared-path set from this repo's own state registry,
// via state-registry-lib.sh (which sources its sibling main-root-lib.sh),
// resolved relative to the sandbox's main root. A sandbox is a throwaway
// `git init`, not a checkout of this repo, so its main root needs its own
// copies of these three tracked files to resolve against.
const REPO_GAIA_DIR = path.join(
  resolveRepoRootFromImportMeta(import.meta.url),
  '.gaia'
);
const REPO_STATE_REGISTRY_PATH = path.join(
  REPO_GAIA_DIR,
  'state-registry.json'
);
const REPO_STATE_REGISTRY_LIB_PATH = path.join(
  REPO_GAIA_DIR,
  'scripts',
  'state-registry-lib.sh'
);
const REPO_MAIN_ROOT_LIB_PATH = path.join(
  REPO_GAIA_DIR,
  'scripts',
  'main-root-lib.sh'
);

type MainOnlySandbox = {
  cleanup: () => void;
  /** Path to a plain main checkout (no linked worktree). */
  mainRoot: string;
};

type WorktreeSandbox = {
  cleanup: () => void;
  /** Path to the linked worktree (cwd for tests). */
  linkedRoot: string;
  /** Path to the main checkout. */
  mainRoot: string;
};

const GIT_IDENTITY_ENV = {
  GIT_AUTHOR_EMAIL: 'gaia-test@example.com',
  GIT_AUTHOR_NAME: 'GAIA Test',
  GIT_COMMITTER_EMAIL: 'gaia-test@example.com',
  GIT_COMMITTER_NAME: 'GAIA Test',
};

const setupWorktreeSandbox = (): WorktreeSandbox => {
  const parent = mkdtempSync(path.join(tmpdir(), 'gaia-link-wt-'));
  const mainRoot = path.join(parent, 'main');
  const linkedRoot = path.join(parent, 'linked');

  mkdirSync(mainRoot, {recursive: true});
  execFileSync('git', ['init', '-q'], {cwd: mainRoot});
  execFileSync('git', ['commit', '--allow-empty', '-q', '-m', 'init'], {
    cwd: mainRoot,
    env: {...process.env, ...GIT_IDENTITY_ENV},
  });
  execFileSync(
    'git',
    ['worktree', 'add', '-q', linkedRoot, '-b', 'feature/test'],
    {cwd: mainRoot, env: {...process.env, ...GIT_IDENTITY_ENV}}
  );

  mkdirSync(path.join(mainRoot, '.gaia', 'scripts'), {recursive: true});
  copyFileSync(
    REPO_STATE_REGISTRY_PATH,
    path.join(mainRoot, '.gaia', 'state-registry.json')
  );
  copyFileSync(
    REPO_STATE_REGISTRY_LIB_PATH,
    path.join(mainRoot, '.gaia', 'scripts', 'state-registry-lib.sh')
  );
  copyFileSync(
    REPO_MAIN_ROOT_LIB_PATH,
    path.join(mainRoot, '.gaia', 'scripts', 'main-root-lib.sh')
  );

  // macOS resolves /var -> /private/var; the handler canonicalizes via
  // realpathSync so tests must compare against the canonicalized paths.
  return {
    cleanup: () => {
      rmSync(parent, {force: true, recursive: true});
    },
    linkedRoot: realpathSync(linkedRoot),
    mainRoot: realpathSync(mainRoot),
  };
};

const setupMainOnlySandbox = (): MainOnlySandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-link-main-'));
  execFileSync('git', ['init', '-q'], {cwd: root});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    mainRoot: realpathSync(root),
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

const FROZEN_TS = new Date('2026-05-08T15:30:45.000Z');
// Local-time formatting in link-worktree.ts produces an environment-dependent
// string. Tests should not assert exact backup paths against this constant;
// the tests check the prefix and existence on disk instead.
const FROZEN_TS_PREFIX = '.bak.';

describe('gaia setup link-worktree (linked worktree)', () => {
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

  test('fresh worktree: creates the one .gaia/local symlink; --json shape is correct; exit 0', () => {
    const exit = runLinkWorktree(['--json'], {
      cwd: sandbox.linkedRoot,
      now: () => FROZEN_TS,
    });

    expect(exit).toBe(0);

    const out = JSON.parse(stdio.outputs.join('').trim()) as {
      actions: {path: string; result: string}[];
      is_worktree: boolean;
      main_root: string;
      worktree_root: string;
    };

    expect(out.is_worktree).toBe(true);
    expect(out.main_root).toBe(sandbox.mainRoot);
    expect(out.worktree_root).toBe(sandbox.linkedRoot);
    // Exactly one action: the whole .gaia/local directory, not a per-entry
    // list. Every registry-declared entry lives under it now.
    expect(out.actions).toHaveLength(1);
    expect(out.actions.map((action) => action.path)).toEqual(['.gaia/local']);
    expect(out.actions[0]?.result).toBe('linked');

    // On disk, .gaia/local is a symlink pointing at the main checkout.
    const sourcePath = path.join(sandbox.linkedRoot, '.gaia', 'local');
    expect(lstatSync(sourcePath).isSymbolicLink()).toBe(true);
    expect(readlinkSync(sourcePath)).toBe(
      path.join(sandbox.mainRoot, '.gaia', 'local')
    );
  });

  test('already-linked worktree: re-running is a no-op; already-linked; exit 0', () => {
    runLinkWorktree([], {cwd: sandbox.linkedRoot, now: () => FROZEN_TS});
    stdio.outputs.length = 0;
    stdio.errors.length = 0;

    const exit = runLinkWorktree(['--json'], {
      cwd: sandbox.linkedRoot,
      now: () => FROZEN_TS,
    });

    expect(exit).toBe(0);

    const out = JSON.parse(stdio.outputs.join('').trim()) as {
      actions: {result: string}[];
    };

    for (const action of out.actions) {
      expect(action.result).toBe('already-linked');
    }
  });

  test('already-linked human summary reports "All 1 paths already linked."', () => {
    runLinkWorktree([], {cwd: sandbox.linkedRoot, now: () => FROZEN_TS});
    stdio.outputs.length = 0;

    const exit = runLinkWorktree([], {
      cwd: sandbox.linkedRoot,
      now: () => FROZEN_TS,
    });
    expect(exit).toBe(0);

    expect(stdio.outputs.join('')).toContain('All 1 paths already linked.');
  });

  test('worktree with a pre-existing plain .gaia/local: backed up whole; backup path in JSON; exit 0', () => {
    // A real (non-symlink) .gaia/local, with content, on the worktree side --
    // e.g. a worktree used before this cutover, where per-tree entries lived
    // as real directories under it.
    mkdirSync(path.join(sandbox.linkedRoot, '.gaia', 'local', 'red-ledger'), {
      recursive: true,
    });
    writeFileSync(
      path.join(
        sandbox.linkedRoot,
        '.gaia',
        'local',
        'red-ledger',
        'observations.jsonl'
      ),
      '{"stale":true}\n',
      'utf8'
    );

    const exit = runLinkWorktree(['--json'], {
      cwd: sandbox.linkedRoot,
      now: () => FROZEN_TS,
    });
    expect(exit).toBe(0);

    const out = JSON.parse(stdio.outputs.join('').trim()) as {
      actions: {backup?: string; path: string; result: string}[];
    };

    expect(out.actions).toHaveLength(1);
    const action = out.actions[0];
    expect(action.result).toBe('linked-after-backup');
    expect(action.backup).toBeDefined();
    expect(action.backup).toContain(FROZEN_TS_PREFIX);

    const backupAbs = path.join(sandbox.linkedRoot, String(action.backup));
    expect(existsSync(backupAbs)).toBe(true);
    expect(
      existsSync(path.join(backupAbs, 'red-ledger', 'observations.jsonl'))
    ).toBe(true);

    const sourceAbs = path.join(sandbox.linkedRoot, action.path);
    expect(lstatSync(sourceAbs).isSymbolicLink()).toBe(true);
  });

  test('worktree with a broken .gaia/local symlink: backed up and replaced; exit 0', () => {
    // A symlink pointing at a nonexistent target on the worktree side.
    mkdirSync(path.join(sandbox.linkedRoot, '.gaia'), {recursive: true});
    const bogusTarget = path.join(sandbox.linkedRoot, '.gaia', 'nope');
    execFileSync('ln', [
      '-s',
      bogusTarget,
      path.join(sandbox.linkedRoot, '.gaia', 'local'),
    ]);

    const exit = runLinkWorktree(['--json'], {
      cwd: sandbox.linkedRoot,
      now: () => FROZEN_TS,
    });
    expect(exit).toBe(0);

    const out = JSON.parse(stdio.outputs.join('').trim()) as {
      actions: {result: string}[];
    };

    expect(out.actions).toHaveLength(1);
    expect(out.actions[0]?.result).toBe('linked-after-backup');
  });

  test('main checkout missing .gaia/local: creates it first, then symlinks; exit 0', () => {
    // Sanity: fresh sandbox already has no main-side .gaia/local.
    expect(existsSync(path.join(sandbox.mainRoot, '.gaia', 'local'))).toBe(
      false
    );

    const exit = runLinkWorktree([], {
      cwd: sandbox.linkedRoot,
      now: () => FROZEN_TS,
    });
    expect(exit).toBe(0);

    // main's .gaia/local now exists (a real directory; the worktree's own
    // .gaia/local is the symlink into it).
    expect(existsSync(path.join(sandbox.mainRoot, '.gaia', 'local'))).toBe(
      true
    );
    expect(
      lstatSync(path.join(sandbox.mainRoot, '.gaia', 'local')).isSymbolicLink()
    ).toBe(false);
  });

  test('symlink failure surfaces as failed action and exits 1', () => {
    const exit = runLinkWorktree(['--json'], {
      cwd: sandbox.linkedRoot,
      now: () => FROZEN_TS,
      symlink: () => {
        throw new Error('mocked permission denied');
      },
    });

    expect(exit).toBe(1);

    const out = JSON.parse(stdio.outputs.join('').trim()) as {
      actions: {error?: string; result: string}[];
    };

    for (const action of out.actions) {
      expect(action.result).toBe('failed');
      expect(action.error).toContain('mocked permission denied');
    }
  });

  test('--json prints exactly one line of valid JSON', () => {
    const exit = runLinkWorktree(['--json'], {
      cwd: sandbox.linkedRoot,
      now: () => FROZEN_TS,
    });
    expect(exit).toBe(0);

    const raw = stdio.outputs.join('');
    expect(raw.endsWith('\n')).toBe(true);
    expect(raw.split('\n').filter(Boolean)).toHaveLength(1);
    expect((): unknown => JSON.parse(raw.trim())).not.toThrow();
  });

  test('human summary on a fresh worktree mentions the linked count and main root', () => {
    const exit = runLinkWorktree([], {
      cwd: sandbox.linkedRoot,
      now: () => FROZEN_TS,
    });
    expect(exit).toBe(0);

    const out = stdio.outputs.join('');
    expect(out).toContain('Linked 1 paths to');
    expect(out).toContain(sandbox.mainRoot);
  });

  test('rejects unknown flags', () => {
    const exit = runLinkWorktree(['--bogus'], {cwd: sandbox.linkedRoot});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });

  test('--help prints usage and exits 0', () => {
    const exit = runLinkWorktree(['--help'], {cwd: sandbox.linkedRoot});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('Usage: gaia setup link-worktree');
  });
});

describe('gaia setup link-worktree (env file sharing)', () => {
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

  test('fresh worktree: shares .env and .env.local, skips .env.example; actions still length 1', () => {
    writeFileSync(path.join(sandbox.mainRoot, '.env'), 'A=1', 'utf8');
    writeFileSync(path.join(sandbox.mainRoot, '.env.local'), 'B=2', 'utf8');
    writeFileSync(path.join(sandbox.mainRoot, '.env.example'), 'C=3', 'utf8');

    const exit = runLinkWorktree(['--json'], {
      cwd: sandbox.linkedRoot,
      now: () => FROZEN_TS,
    });
    expect(exit).toBe(0);

    const out = JSON.parse(stdio.outputs.join('').trim()) as {
      actions: {path: string}[];
      env_actions: {path: string; result: string}[];
    };

    expect(out.env_actions.map((action) => action.path)).toEqual([
      '.env',
      '.env.local',
    ]);

    for (const action of out.env_actions) {
      expect(action.result).toBe('linked');
    }

    expect(out.actions).toHaveLength(1);

    for (const rel of ['.env', '.env.local']) {
      const sourcePath = path.join(sandbox.linkedRoot, rel);
      expect(lstatSync(sourcePath).isSymbolicLink()).toBe(true);
      expect(readlinkSync(sourcePath)).toBe(path.join(sandbox.mainRoot, rel));
    }

    expect(existsSync(path.join(sandbox.linkedRoot, '.env.example'))).toBe(
      false
    );
  });

  test('no env files in main checkout: env_actions is an empty array', () => {
    const exit = runLinkWorktree(['--json'], {
      cwd: sandbox.linkedRoot,
      now: () => FROZEN_TS,
    });
    expect(exit).toBe(0);

    const out = JSON.parse(stdio.outputs.join('').trim()) as {
      env_actions: unknown[];
    };
    expect(out.env_actions).toEqual([]);
  });

  test('idempotent: second run reports env already-linked for .env', () => {
    writeFileSync(path.join(sandbox.mainRoot, '.env'), 'A=1', 'utf8');

    runLinkWorktree([], {cwd: sandbox.linkedRoot, now: () => FROZEN_TS});
    stdio.outputs.length = 0;

    const exit = runLinkWorktree(['--json'], {
      cwd: sandbox.linkedRoot,
      now: () => FROZEN_TS,
    });
    expect(exit).toBe(0);

    const out = JSON.parse(stdio.outputs.join('').trim()) as {
      env_actions: {path: string; result: string}[];
    };
    expect(out.env_actions).toEqual([{path: '.env', result: 'already-linked'}]);
  });

  test('pre-existing plain .env in worktree: linked-after-backup with a backup file on disk', () => {
    writeFileSync(path.join(sandbox.mainRoot, '.env'), 'A=1', 'utf8');
    writeFileSync(path.join(sandbox.linkedRoot, '.env'), 'STALE=1', 'utf8');

    const exit = runLinkWorktree(['--json'], {
      cwd: sandbox.linkedRoot,
      now: () => FROZEN_TS,
    });
    expect(exit).toBe(0);

    const out = JSON.parse(stdio.outputs.join('').trim()) as {
      env_actions: {backup?: string; path: string; result: string}[];
    };
    const envAction = out.env_actions.find((action) => action.path === '.env');

    expect(envAction?.result).toBe('linked-after-backup');
    expect(envAction?.backup).toBeDefined();

    const backupAbs = path.join(sandbox.linkedRoot, String(envAction?.backup));
    expect(existsSync(backupAbs)).toBe(true);
  });

  test('editor cruft (.env.local~) is rejected by the shareable-env regex', () => {
    writeFileSync(path.join(sandbox.mainRoot, '.env'), 'A=1', 'utf8');
    writeFileSync(path.join(sandbox.mainRoot, '.env.local~'), 'B=2', 'utf8');

    const exit = runLinkWorktree(['--json'], {
      cwd: sandbox.linkedRoot,
      now: () => FROZEN_TS,
    });
    expect(exit).toBe(0);

    const out = JSON.parse(stdio.outputs.join('').trim()) as {
      env_actions: {path: string}[];
    };
    expect(out.env_actions.map((action) => action.path)).toEqual(['.env']);
  });
});

describe('gaia setup link-worktree (main checkout)', () => {
  let sandbox: MainOnlySandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupMainOnlySandbox();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('reports is_worktree:false with empty actions; exit 0', () => {
    const exit = runLinkWorktree(['--json'], {cwd: sandbox.mainRoot});
    expect(exit).toBe(0);

    const out = JSON.parse(stdio.outputs.join('').trim()) as {
      actions: unknown[];
      is_worktree: boolean;
    };
    expect(out.is_worktree).toBe(false);
    expect(out.actions).toEqual([]);
  });

  test('human summary on a main checkout is "not a linked worktree"', () => {
    const exit = runLinkWorktree([], {cwd: sandbox.mainRoot});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('not a linked worktree');
  });
});

describe('gaia setup link-worktree (non-git cwd)', () => {
  let stdio: ReturnType<typeof captureStdio>;
  let tmpRoot: string;

  beforeEach(() => {
    stdio = captureStdio();
    tmpRoot = mkdtempSync(path.join(tmpdir(), 'gaia-link-nogit-'));
  });

  afterEach(() => {
    stdio.restore();
    rmSync(tmpRoot, {force: true, recursive: true});
    vi.restoreAllMocks();
  });

  test('emits not_a_git_repo and exits non-zero', () => {
    const exit = runLinkWorktree([], {cwd: tmpRoot});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('not_a_git_repo');
  });
});
