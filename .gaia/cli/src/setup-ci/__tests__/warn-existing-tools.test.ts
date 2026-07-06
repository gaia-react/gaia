import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {mkdirSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {run} from '../warn-existing-tools.js';
import {setupSandbox} from './sandbox.js';
import type {Sandbox} from './sandbox.js';

const captureStdio = (): {
  err: string[];
  out: string[];
  restore: () => void;
} => {
  const out: string[] = [];
  const err: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      out.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      err.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    err,
    out,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

const writeFileAt = (root: string, relPath: string, content: string): void => {
  const target = path.join(root, relPath);
  mkdirSync(path.dirname(target), {recursive: true});
  writeFileSync(target, content, 'utf8');
};

describe('setup-ci warn-existing-tools', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-ci-warn-');
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('returns empty array on a clean repo', () => {
    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.found).toEqual([]);
  });

  test('detects .github/dependabot.yml', () => {
    writeFileAt(sandbox.root, '.github/dependabot.yml', 'version: 2\n');

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.found).toEqual(['dependabot']);
  });

  test('detects .github/dependabot.yaml', () => {
    writeFileAt(sandbox.root, '.github/dependabot.yaml', 'version: 2\n');

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.found).toEqual(['dependabot']);
  });

  test('detects renovate.json', () => {
    writeFileAt(sandbox.root, 'renovate.json', '{}\n');

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.found).toEqual(['renovate']);
  });

  test('detects .renovaterc.json and .github/renovate.json under same name', () => {
    writeFileAt(sandbox.root, '.renovaterc.json', '{}\n');
    writeFileAt(sandbox.root, '.github/renovate.json', '{}\n');

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.found).toEqual(['renovate']);
  });

  test('reports both when both exist', () => {
    writeFileAt(sandbox.root, '.github/dependabot.yml', 'version: 2\n');
    writeFileAt(sandbox.root, 'renovate.json', '{}\n');

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.found).toEqual(['dependabot', 'renovate']);
  });

  test('deduplicates when both .yml and .yaml exist', () => {
    writeFileAt(sandbox.root, '.github/dependabot.yml', 'version: 2\n');
    writeFileAt(sandbox.root, '.github/dependabot.yaml', 'version: 2\n');

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.found).toEqual(['dependabot']);
  });

  test('emits a human report without --json', () => {
    writeFileAt(sandbox.root, '.github/dependabot.yml', 'version: 2\n');

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('detected: dependabot');
  });

  test('rejects unknown flags', () => {
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('unknown flag');
  });

  test('--help exits 0', () => {
    const exit = run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('Usage:');
  });
});
