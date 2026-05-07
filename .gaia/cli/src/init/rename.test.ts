/**
 * Tests for `gaia init rename`.
 */
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {run} from './rename.js';
import {readState} from './util/state.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const PACKAGE_JSON = JSON.stringify({name: 'gaia', version: '1.0.0'}, null, 2);

const CLAUDE_MD = `# GAIA React

When reporting information to me, be extremely concise.

## Section

Body
`;

const COMMON_TS = `export default {
  meta: {
    siteName: 'GAIA',
  },
  someOtherKey: 'untouched',
};
`;

const PAGE_INDEX_TS = `export default {
  heroTitle: 'Start with something solid.',
  meta: {
    description: 'Description of the index page',
    title: 'Index Page',
  },
  title: 'Old Title',
};
`;

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-init-rename-'));
  writeFileSync(path.join(root, 'package.json'), `${PACKAGE_JSON}\n`, 'utf8');
  writeFileSync(path.join(root, 'CLAUDE.md'), CLAUDE_MD, 'utf8');
  mkdirSync(path.join(root, 'app', 'languages', 'en', 'pages'), {recursive: true});
  writeFileSync(
    path.join(root, 'app', 'languages', 'en', 'common.ts'),
    COMMON_TS,
    'utf8'
  );
  writeFileSync(
    path.join(root, 'app', 'languages', 'en', 'pages', '_index.ts'),
    PAGE_INDEX_TS,
    'utf8'
  );

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
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

describe('init rename', () => {
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

  test('rewrites package.json + CLAUDE.md heading + locale strings', () => {
    sandbox = setupSandbox();

    const exit = run(['--title', 'Hello World', '--kebab', 'hello-world'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const pkg = JSON.parse(
      readFileSync(path.join(sandbox.root, 'package.json'), 'utf8')
    ) as {name: string};
    expect(pkg.name).toBe('hello-world');

    const claude = readFileSync(path.join(sandbox.root, 'CLAUDE.md'), 'utf8');
    expect(claude.startsWith('# Hello World\n')).toBe(true);
    expect(claude).toContain('When reporting information');

    const common = readFileSync(
      path.join(sandbox.root, 'app', 'languages', 'en', 'common.ts'),
      'utf8'
    );
    expect(common).toContain("siteName: 'Hello World'");
    expect(common).toContain("someOtherKey: 'untouched'");

    const page = readFileSync(
      path.join(sandbox.root, 'app', 'languages', 'en', 'pages', '_index.ts'),
      'utf8'
    );
    expect(page).toContain("heroTitle: 'Hello World'");
    expect(page).toContain("title: 'Hello World'");
    // The nested meta.title was rewritten too.
    expect(page.match(/title: 'Hello World'/gu)?.length).toBeGreaterThanOrEqual(2);

    const state = readState(sandbox.root);
    expect(state.completed_steps).toContain('rename');
    expect(state.step_args['rename']).toEqual({
      kebab: 'hello-world',
      title: 'Hello World',
    });
  });

  test('idempotent: re-running with same args is a no-op', () => {
    sandbox = setupSandbox();
    run(['--title', 'Hello World', '--kebab', 'hello-world'], {cwd: sandbox.root});
    const claudeFirst = readFileSync(path.join(sandbox.root, 'CLAUDE.md'), 'utf8');
    const pageFirst = readFileSync(
      path.join(sandbox.root, 'app', 'languages', 'en', 'pages', '_index.ts'),
      'utf8'
    );

    const second = run(['--title', 'Hello World', '--kebab', 'hello-world'], {
      cwd: sandbox.root,
    });
    expect(second).toBe(0);

    expect(readFileSync(path.join(sandbox.root, 'CLAUDE.md'), 'utf8')).toBe(claudeFirst);
    expect(
      readFileSync(
        path.join(sandbox.root, 'app', 'languages', 'en', 'pages', '_index.ts'),
        'utf8'
      )
    ).toBe(pageFirst);
  });

  test('exit 1 when package.json missing', () => {
    sandbox = setupSandbox();
    rmSync(path.join(sandbox.root, 'package.json'));

    const exit = run(['--title', 'X', '--kebab', 'x'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('package_json_missing');
  });

  test('exit 1 on invalid kebab', () => {
    sandbox = setupSandbox();
    const exit = run(['--title', 'X', '--kebab', 'NotKebab'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--kebab must be');
  });

  test('exit 1 on missing flags', () => {
    sandbox = setupSandbox();
    expect(run(['--title', 'X'], {cwd: sandbox.root})).toBe(1);
    expect(run(['--kebab', 'x'], {cwd: sandbox.root})).toBe(1);
  });
});
