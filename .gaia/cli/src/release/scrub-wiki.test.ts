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
import {renderLogMd, run} from './scrub-wiki.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (currentVersion: string): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-release-scrub-'));
  mkdirSync(path.join(root, 'wiki'), {recursive: true});
  writeFileSync(
    path.join(root, 'package.json'),
    `${JSON.stringify({name: 'gaia', version: currentVersion}, null, 2)}\n`,
    'utf8'
  );
  // Pre-existing content the scrubber must overwrite.
  writeFileSync(path.join(root, 'wiki', 'log.md'), '# stale log\n', 'utf8');

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

const writeScrubbed = (root: string, version: string, date: string): void => {
  writeFileSync(
    path.join(root, 'wiki', 'log.md'),
    renderLogMd(version, date),
    'utf8'
  );
};

describe('renderLogMd', () => {
  test('frontmatter contains required keys', () => {
    const log = renderLogMd('2.0.0', '2026-05-07');
    expect(log).toContain('type: meta');
    expect(log).toContain('title: Log');
    expect(log).toContain('status: active');
    expect(log).toContain('created: 2026-05-07');
    expect(log).toContain('tags: [meta, log]');
    expect(log).toContain('## [v2.0.0] 2026-05-07 | Released');
  });
});

describe('release scrub-wiki CLI', () => {
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

  test('overwrites log.md, no stdout on success', () => {
    sandbox = setupSandbox('1.5.0');

    const exit = run([], {cwd: sandbox.root, today: '2026-05-07'});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toBe('');
    expect(stdio.errors.join('')).toBe('');

    const log = readFileSync(path.join(sandbox.root, 'wiki', 'log.md'), 'utf8');
    expect(log).toContain('## [v1.5.0] 2026-05-07 | Released');
    expect(log).not.toContain('# stale log');
  });

  test('leaves an existing hot.md byte-identical', () => {
    sandbox = setupSandbox('1.5.0');
    const hotPath = path.join(sandbox.root, 'wiki', 'hot.md');
    writeFileSync(hotPath, '# stale hot\n', 'utf8');

    const exit = run([], {cwd: sandbox.root, today: '2026-05-07'});
    expect(exit).toBe(0);
    expect(readFileSync(hotPath, 'utf8')).toBe('# stale hot\n');
    expect(
      readFileSync(path.join(sandbox.root, 'wiki', 'log.md'), 'utf8')
    ).toContain('## [v1.5.0] 2026-05-07 | Released');
  });

  test('does not create hot.md when absent', () => {
    sandbox = setupSandbox('1.5.0');

    expect(run([], {cwd: sandbox.root, today: '2026-05-07'})).toBe(0);
    expect(existsSync(path.join(sandbox.root, 'wiki', 'hot.md'))).toBe(false);
  });

  test('--version overrides package.json', () => {
    sandbox = setupSandbox('1.0.0');

    const exit = run(['--version', '3.0.0'], {
      cwd: sandbox.root,
      today: '2026-05-07',
    });
    expect(exit).toBe(0);

    const log = readFileSync(path.join(sandbox.root, 'wiki', 'log.md'), 'utf8');
    expect(log).toContain('## [v3.0.0] 2026-05-07 | Released');
  });

  test('exits 1 when wiki/ is missing', () => {
    sandbox = setupSandbox('1.0.0');
    rmSync(path.join(sandbox.root, 'wiki'), {force: true, recursive: true});

    const exit = run([], {cwd: sandbox.root, today: '2026-05-07'});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('wiki_dir_missing');
  });

  test('rejects unknown flags', () => {
    sandbox = setupSandbox('1.0.0');
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });
});

describe('release scrub-wiki --check', () => {
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

  test('passes on freshly-scrubbed files and writes nothing', () => {
    sandbox = setupSandbox('1.5.0');
    writeScrubbed(sandbox.root, '1.5.0', '2026-05-07');
    const logBefore = readFileSync(
      path.join(sandbox.root, 'wiki', 'log.md'),
      'utf8'
    );

    const exit = run(['--check'], {cwd: sandbox.root, today: '2026-07-21'});
    expect(exit).toBe(0);
    expect(stdio.errors.join('')).toBe('');
    // Rendered nothing: the committed file is byte-identical to before.
    expect(
      readFileSync(path.join(sandbox.root, 'wiki', 'log.md'), 'utf8')
    ).toBe(logBefore);
  });

  test('passes even when the committed scrub date differs from today', () => {
    // The scrub date is non-deterministic relative to the CI run date (the tag
    // can be pushed a day after the scrub commit), so the check normalizes
    // dates out. A same-structure file for a different day still passes.
    sandbox = setupSandbox('1.5.0');
    writeScrubbed(sandbox.root, '1.5.0', '2026-05-07');

    const exit = run(['--check'], {cwd: sandbox.root, today: '2027-01-01'});
    expect(exit).toBe(0);
  });

  test('passes with a fresh log.md and no hot.md', () => {
    sandbox = setupSandbox('1.5.0');
    writeScrubbed(sandbox.root, '1.5.0', '2026-05-07');
    expect(existsSync(path.join(sandbox.root, 'wiki', 'hot.md'))).toBe(false);

    const exit = run(['--check'], {cwd: sandbox.root, today: '2026-05-07'});
    expect(exit).toBe(0);
    expect(stdio.errors.join('')).toBe('');
  });

  test('detects a stale (unscrubbed) log.md', () => {
    sandbox = setupSandbox('1.5.0');

    const exit = run(['--check'], {cwd: sandbox.root, today: '2026-05-07'});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('wiki/log.md');
  });

  test('detects drift when committed files were scrubbed for another version', () => {
    // package.json says 1.5.0 but the committed wiki files claim v1.4.0: a
    // version bump landed without a re-scrub. Structure matches, version does
    // not, so it must still flag.
    sandbox = setupSandbox('1.5.0');
    writeScrubbed(sandbox.root, '1.4.0', '2026-05-07');

    const exit = run(['--check'], {cwd: sandbox.root, today: '2026-05-07'});
    expect(exit).toBe(1);
  });

  test('writes nothing even when drift is detected', () => {
    sandbox = setupSandbox('1.5.0');
    // log.md is the pre-existing stale dev content from setupSandbox.
    const logBefore = readFileSync(
      path.join(sandbox.root, 'wiki', 'log.md'),
      'utf8'
    );

    const exit = run(['--check'], {cwd: sandbox.root, today: '2026-05-07'});
    expect(exit).toBe(1);
    expect(
      readFileSync(path.join(sandbox.root, 'wiki', 'log.md'), 'utf8')
    ).toBe(logBefore);
  });

  test('exits 1 when log.md is missing entirely', () => {
    sandbox = setupSandbox('1.5.0');
    rmSync(path.join(sandbox.root, 'wiki', 'log.md'), {force: true});

    const exit = run(['--check'], {cwd: sandbox.root, today: '2026-05-07'});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('wiki/log.md');
  });
});
