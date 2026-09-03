/**
 * Includes a snapshot-style assertion against a fixture settings.json
 * (the merged result is byte-stable) and a global-mode test that uses a
 * temp $HOME so we never touch the real one.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
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
import {fileURLToPath} from 'node:url';
import {readState} from './util/state.js';
import {mergeStatusline, run} from './wire-statusline.js';

type Sandbox = {
  cleanup: () => void;
  home: string;
  root: string;
};

/*
 * The rooted statusline command wire-statusline registers, spelled out here
 * rather than imported from the module under test: pinning it independently
 * is the point, so a change to the registered command fails these tests.
 */
/* eslint-disable no-template-curly-in-string -- literal shell `${ }` syntax, not JS interpolation */
const CANONICAL_STATUSLINE_COMMAND =
  'bash "$(git rev-parse --show-toplevel 2>/dev/null || printf %s "${CLAUDE_PROJECT_DIR:-.}")/.gaia/statusline/gaia-statusline.sh"';
/* eslint-enable no-template-curly-in-string */

const FIXTURE_SETTINGS = {
  env: {EXAMPLE: '1'},
  permissions: {
    allow: ['Bash(pnpm test:ci)'],
    deny: [],
  },
};

const setupSandbox = (withProjectSettings = true): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-init-wire-statusline-'));
  const home = mkdtempSync(
    path.join(tmpdir(), 'gaia-init-wire-statusline-home-')
  );

  if (withProjectSettings) {
    mkdirSync(path.join(root, '.claude'), {recursive: true});
    writeFileSync(
      path.join(root, '.claude', 'settings.json'),
      `${JSON.stringify(FIXTURE_SETTINGS, null, 2)}\n`,
      'utf8'
    );
  }

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
      rmSync(home, {force: true, recursive: true});
    },
    home,
    root,
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

describe('mergeStatusline', () => {
  test('inserts canonical block at alphabetical position', () => {
    const merged = mergeStatusline({env: {}, permissions: {allow: []}});
    const keys = Object.keys(merged);
    // env < permissions < statusLine alphabetically.
    expect(keys).toEqual(['env', 'permissions', 'statusLine']);
    expect(merged.statusLine).toEqual({
      command: CANONICAL_STATUSLINE_COMMAND,
      type: 'command',
    });
  });

  test('idempotent: existing canonical block is preserved untouched', () => {
    const source = {
      env: {},
      statusLine: {
        command: CANONICAL_STATUSLINE_COMMAND,
        type: 'command',
      },
    };
    const merged = mergeStatusline(source);
    expect(merged).toBe(source);
  });

  test('overwrites a non-canonical statusLine', () => {
    const merged = mergeStatusline({
      env: {},
      statusLine: {command: 'bash other.sh', type: 'command'},
    });
    expect(merged.statusLine).toEqual({
      command: CANONICAL_STATUSLINE_COMMAND,
      type: 'command',
    });
  });
});

describe('canonical command parity', () => {
  /*
   * The canonical command lives at two independent sites and no single check
   * spans them: this module, which writes it into an adopter's settings during
   * `/gaia-init`, and this repo's own `.claude/settings.json`, which
   * `.gaia/scripts/check-hook-command-rooting.sh` reads. That check validates
   * rootedness, and only in settings.json, so a CLI-side drift to a
   * different-but-still-rooted spelling would be caught by nothing at all --
   * which is the shape of the regression this PR's round-1 audit found here.
   *
   * The assertion fails, and never skips, when the file cannot be read. A check
   * that answers green where it cannot answer is the defect #1748 records, and
   * it would be a strange thing to reintroduce in the test closing its sibling.
   */
  test("matches this repo's own .claude/settings.json", () => {
    const settingsPath = fileURLToPath(
      new URL('../../../../.claude/settings.json', import.meta.url)
    );
    expect(existsSync(settingsPath)).toBe(true);

    const parsed = JSON.parse(readFileSync(settingsPath, 'utf8')) as {
      statusLine?: {command?: string};
    };
    expect(parsed.statusLine?.command).toBe(CANONICAL_STATUSLINE_COMMAND);
  });
});

describe('init wire-statusline CLI', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('--mode project produces a deterministic merge against fixture', () => {
    sandbox = setupSandbox(true);

    const exit = run(['--mode', 'project'], {
      cwd: sandbox.root,
      home: sandbox.home,
    });
    expect(exit).toBe(0);
    expect(stdio.errors.join('')).toBe('');

    const after = readFileSync(
      path.join(sandbox.root, '.claude', 'settings.json'),
      'utf8'
    );
    const expected = `${JSON.stringify(
      {
        env: {EXAMPLE: '1'},
        permissions: {allow: ['Bash(pnpm test:ci)'], deny: []},
        statusLine: {
          command: CANONICAL_STATUSLINE_COMMAND,
          type: 'command',
        },
      },
      null,
      2
    )}\n`;
    expect(after).toBe(expected);

    const state = readState(sandbox.root);
    expect(state.step_args['wire-statusline']).toEqual({mode: 'project'});
  });

  test('--mode global writes to a temp $HOME', () => {
    sandbox = setupSandbox(false);

    const exit = run(['--mode', 'global'], {
      cwd: sandbox.root,
      home: sandbox.home,
    });
    expect(exit).toBe(0);

    const target = path.join(sandbox.home, '.claude', 'settings.json');
    expect(existsSync(target)).toBe(true);
    const parsed = JSON.parse(readFileSync(target, 'utf8')) as {
      statusLine?: {command?: string};
    };
    expect(parsed.statusLine?.command).toBe(CANONICAL_STATUSLINE_COMMAND);
  });

  test('--mode skip records state without touching settings', () => {
    sandbox = setupSandbox(true);
    const before = readFileSync(
      path.join(sandbox.root, '.claude', 'settings.json'),
      'utf8'
    );

    const exit = run(['--mode', 'skip'], {
      cwd: sandbox.root,
      home: sandbox.home,
    });
    expect(exit).toBe(0);

    const after = readFileSync(
      path.join(sandbox.root, '.claude', 'settings.json'),
      'utf8'
    );
    expect(after).toBe(before);

    const state = readState(sandbox.root);
    expect(state.step_args['wire-statusline']).toEqual({mode: 'skip'});
  });

  test('idempotent: re-running --mode project leaves the file byte-stable', () => {
    sandbox = setupSandbox(true);
    run(['--mode', 'project'], {cwd: sandbox.root, home: sandbox.home});
    const first = readFileSync(
      path.join(sandbox.root, '.claude', 'settings.json'),
      'utf8'
    );
    const second = run(['--mode', 'project'], {
      cwd: sandbox.root,
      home: sandbox.home,
    });
    expect(second).toBe(0);
    const after = readFileSync(
      path.join(sandbox.root, '.claude', 'settings.json'),
      'utf8'
    );
    expect(after).toBe(first);
  });

  test('exit 1 on invalid mode', () => {
    sandbox = setupSandbox(true);
    const exit = run(['--mode', 'bogus'], {
      cwd: sandbox.root,
      home: sandbox.home,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--mode must be');
  });

  test('exit 1 when --mode missing', () => {
    sandbox = setupSandbox(true);
    const exit = run([], {cwd: sandbox.root, home: sandbox.home});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--mode is required');
  });

  test('exit 1 when project settings.json is malformed', () => {
    sandbox = setupSandbox(false);
    mkdirSync(path.join(sandbox.root, '.claude'), {recursive: true});
    writeFileSync(
      path.join(sandbox.root, '.claude', 'settings.json'),
      '{ broken',
      'utf8'
    );

    const exit = run(['--mode', 'project'], {
      cwd: sandbox.root,
      home: sandbox.home,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('settings_malformed');
  });
});
