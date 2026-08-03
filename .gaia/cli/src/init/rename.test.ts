import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
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
import {resolveRepoRootFromImportMeta} from '../util/repo-root-fixture.js';
import {claudeMdHasH1, run} from './rename.js';
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
  mkdirSync(path.join(root, 'app', 'languages', 'en', 'pages'), {
    recursive: true,
  });
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
    expect(page.match(/title: 'Hello World'/gu)?.length).toBeGreaterThanOrEqual(
      2
    );

    const state = readState(sandbox.root);
    expect(state.completed_steps).toContain('rename');
    expect(state.step_args.rename).toEqual({
      kebab: 'hello-world',
      title: 'Hello World',
    });
  });

  test('idempotent: re-running with same args is a no-op', () => {
    sandbox = setupSandbox();
    run(['--title', 'Hello World', '--kebab', 'hello-world'], {
      cwd: sandbox.root,
    });
    const claudeFirst = readFileSync(
      path.join(sandbox.root, 'CLAUDE.md'),
      'utf8'
    );
    const pageFirst = readFileSync(
      path.join(sandbox.root, 'app', 'languages', 'en', 'pages', '_index.ts'),
      'utf8'
    );

    const second = run(['--title', 'Hello World', '--kebab', 'hello-world'], {
      cwd: sandbox.root,
    });
    expect(second).toBe(0);

    expect(readFileSync(path.join(sandbox.root, 'CLAUDE.md'), 'utf8')).toBe(
      claudeFirst
    );
    expect(
      readFileSync(
        path.join(sandbox.root, 'app', 'languages', 'en', 'pages', '_index.ts'),
        'utf8'
      )
    ).toBe(pageFirst);
  });

  test('does not clobber unrelated `title` properties in diverged _index.ts', () => {
    sandbox = setupSandbox();
    // Simulate a user whose _index.ts has diverged from the seed: extra
    // route data with its own nested `title` properties that are NOT the
    // project title and must be preserved verbatim.
    const diverged = `export default {
  heroTitle: 'Start with something solid.',
  meta: {
    description: 'Description of the index page',
    title: 'Index Page',
  },
  title: 'Old Title',
  routes: {
    about: {
      title: 'About Us',
    },
    contact: {
      title: 'Contact',
    },
  },
};
`;
    writeFileSync(
      path.join(sandbox.root, 'app', 'languages', 'en', 'pages', '_index.ts'),
      diverged,
      'utf8'
    );

    const exit = run(['--title', 'Hello World', '--kebab', 'hello-world'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const page = readFileSync(
      path.join(sandbox.root, 'app', 'languages', 'en', 'pages', '_index.ts'),
      'utf8'
    );
    // Seed identity keys rewritten.
    expect(page).toContain("heroTitle: 'Hello World'");
    expect(page).toContain("title: 'Hello World'");
    // meta.title rewritten.
    const helloMatches = page.match(/title: 'Hello World'/gu)?.length ?? 0;
    expect(helloMatches).toBe(2);
    // Unrelated route titles preserved.
    expect(page).toContain("title: 'About Us'");
    expect(page).toContain("title: 'Contact'");
  });

  test.each([
    ['first heading is an `##`', '## Response style\n\nBody\n'],
    // `# ` opens a bash comment as well as a heading, so a scan blind to
    // fences finds one here, reports success with no title written, and
    // rewrites a line of the adopter's own shell example.
    [
      'the only `# ` line is inside a fence',
      '## Setup\n\n```bash\n# install deps\npnpm install\n```\n',
    ],
    // Scanned per line, so the `\s` after `#` cannot match the line ending
    // and pull the blank line below into the rewrite.
    ['a bare `#` with nothing after it', '#\n\nBody\n'],
  ])('exit 1 when CLAUDE.md has no usable H1: %s', (_label, content) => {
    sandbox = setupSandbox();
    writeFileSync(path.join(sandbox.root, 'CLAUDE.md'), content, 'utf8');

    const exit = run(['--title', 'Hello World', '--kebab', 'hello-world'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('claude_md_heading_missing');
    expect(readFileSync(path.join(sandbox.root, 'CLAUDE.md'), 'utf8')).toBe(
      content
    );
    // The precondition is checked before the first write, so nothing else was
    // renamed either, and the step is not recorded as completed. Recovery is
    // to add a heading and re-run this command; `gaia init resume` cannot
    // replay it, because the args it would need are recorded only on success.
    const pkg = JSON.parse(
      readFileSync(path.join(sandbox.root, 'package.json'), 'utf8')
    ) as {name: string};
    expect(pkg.name).toBe('gaia');
    expect(readState(sandbox.root).completed_steps).not.toContain('rename');
  });

  test('rewrites an H1 that sits below a fenced code block', () => {
    sandbox = setupSandbox();
    const content = '```sh\n# not a heading\n```\n\n# GAIA React\n\nBody\n';
    writeFileSync(path.join(sandbox.root, 'CLAUDE.md'), content, 'utf8');

    expect(
      run(['--title', 'Hello World', '--kebab', 'hello-world'], {
        cwd: sandbox.root,
      })
    ).toBe(0);

    expect(readFileSync(path.join(sandbox.root, 'CLAUDE.md'), 'utf8')).toBe(
      '```sh\n# not a heading\n```\n\n# Hello World\n\nBody\n'
    );
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
    const exit = run(['--title', 'X', '--kebab', 'NotKebab'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--kebab must be');
  });

  test('exit 1 on missing flags', () => {
    sandbox = setupSandbox();
    expect(run(['--title', 'X'], {cwd: sandbox.root})).toBe(1);
    expect(run(['--kebab', 'x'], {cwd: sandbox.root})).toBe(1);
  });
});

/**
 * `gaia init rename` refuses when `CLAUDE.md` carries no heading, so the
 * shipped template has to carry one or every adopter scaffold fails the
 * step. Nothing that runs on a CLAUDE.md-only change asserts that, which is
 * how the heading was dropped unnoticed.
 *
 * Asserted through `claudeMdHasH1`, the predicate the step itself uses, so
 * tightening the production rule cannot leave this pinning the older, looser
 * shape.
 *
 * Its own `describe`: the suite above tears down a sandbox after every test
 * and this one allocates none.
 */
describe('CLAUDE.md template invariant', () => {
  test('the shipped CLAUDE.md carries an H1 for rename to rewrite', () => {
    const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
    const claudeMd = readFileSync(path.join(repoRoot, 'CLAUDE.md'), 'utf8');

    expect(claudeMdHasH1(claudeMd)).toBe(true);
  });
});
