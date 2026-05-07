/**
 * Tests for `gaia release scrub-wiki`.
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
import {renderHotMd, renderLogMd, run} from './scrub-wiki.js';

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
  writeFileSync(path.join(root, 'wiki', 'hot.md'), '# stale\n', 'utf8');
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

describe('renderHotMd / renderLogMd', () => {
  test('frontmatter contains required keys', () => {
    const hot = renderHotMd('2.0.0', '2026-05-07');
    expect(hot).toContain('type: meta');
    expect(hot).toContain('title: Hot Cache');
    expect(hot).toContain('status: active');
    expect(hot).toContain('created: 2026-05-07');
    expect(hot).toContain('updated: 2026-05-07');
    expect(hot).toContain('tags: [meta, cache]');
    expect(hot).toContain('Released as GAIA v2.0.0');

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

  test('overwrites hot.md and log.md, no stdout on success', () => {
    sandbox = setupSandbox('1.5.0');

    const exit = run([], {cwd: sandbox.root, today: '2026-05-07'});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toBe('');
    expect(stdio.errors.join('')).toBe('');

    const hot = readFileSync(path.join(sandbox.root, 'wiki', 'hot.md'), 'utf8');
    expect(hot).toContain('Released as GAIA v1.5.0');
    expect(hot).not.toContain('# stale');

    const log = readFileSync(path.join(sandbox.root, 'wiki', 'log.md'), 'utf8');
    expect(log).toContain('## [v1.5.0] 2026-05-07 | Released');
    expect(log).not.toContain('# stale log');
  });

  test('--version overrides package.json', () => {
    sandbox = setupSandbox('1.0.0');

    const exit = run(['--version', '3.0.0'], {
      cwd: sandbox.root,
      today: '2026-05-07',
    });
    expect(exit).toBe(0);

    const hot = readFileSync(path.join(sandbox.root, 'wiki', 'hot.md'), 'utf8');
    expect(hot).toContain('Released as GAIA v3.0.0');
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
