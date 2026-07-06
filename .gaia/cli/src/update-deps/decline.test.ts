import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {existsSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from './decline.js';
import {declinedLedgerPath, loadDeclines} from './declines.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
  writeSource: (name: string) => string;
};

// A two-group emitted payload: singleton:foo (Wave A) + react-router (Wave B,
// two members). Mirrors the shape `run --emit-updates` writes.
const SOURCE_PAYLOAD = {
  actionable_count: 3,
  generated_at: '2026-06-11T18:00:00.000Z',
  schema_version: 1,
  skipped: [],
  total_count: 3,
  wave_a: [
    {
      bucket: 'minor',
      current: '1.2.3',
      group: 'singleton:foo',
      is_pinned: false,
      kind: 'minor',
      latest: '1.3.0',
      name: 'foo',
      wanted: '1.3.0',
    },
  ],
  wave_b: [
    {
      group: 'react-router',
      packages: [
        {
          bucket: 'major',
          current: '6.30.0',
          is_pinned: false,
          kind: 'major',
          latest: '7.0.0',
          name: 'react-router',
          wanted: '6.30.0',
        },
        {
          bucket: 'major',
          current: '6.30.0',
          is_pinned: false,
          kind: 'major',
          latest: '7.0.0',
          name: '@react-router/serve',
          wanted: '6.30.0',
        },
      ],
    },
  ],
};

const NOW = (): Date => new Date('2026-06-11T18:00:00.000Z');

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

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-decline-'));

  return {
    cleanup: () => rmSync(root, {force: true, recursive: true}),
    root,
    writeSource: (name) => {
      const file = path.join(root, name);

      writeFileSync(file, JSON.stringify(SOURCE_PAYLOAD), 'utf8');

      return file;
    },
  };
};

describe('update-deps decline', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    sandbox = setupSandbox();
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('--help prints usage and exits 0', () => {
    const exit = run(['--help'], {cwd: sandbox.root, now: NOW});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('Usage: gaia update-deps decline');
  });

  test('--clear writes an empty ledger', () => {
    const exit = run(['--clear'], {cwd: sandbox.root, now: NOW});
    expect(exit).toBe(0);
    expect(loadDeclines(sandbox.root)).toEqual([]);
    expect(existsSync(declinedLedgerPath(sandbox.root))).toBe(true);
  });

  test('--skip a singleton snoozes just that group', () => {
    sandbox.writeSource('updates.json');
    const exit = run(['--source', 'updates.json', '--skip', 'foo'], {
      cwd: sandbox.root,
      now: NOW,
    });
    expect(exit).toBe(0);
    expect(loadDeclines(sandbox.root)).toEqual([
      {
        declined_at: NOW().toISOString(),
        group: 'singleton:foo',
        targets: {foo: '1.3.0'},
      },
    ]);
  });

  test('skipping one member snoozes the whole companion group', () => {
    sandbox.writeSource('updates.json');
    const exit = run(
      ['--source', 'updates.json', '--skip', '@react-router/serve'],
      {
        cwd: sandbox.root,
        now: NOW,
      }
    );
    expect(exit).toBe(0);
    const declined = loadDeclines(sandbox.root);
    expect(declined).toHaveLength(1);
    expect(declined[0]?.group).toBe('react-router');
    expect(declined[0]?.targets).toEqual({
      '@react-router/serve': '7.0.0',
      'react-router': '7.0.0',
    });
  });

  test('a name that is not outstanding is rejected and writes nothing', () => {
    sandbox.writeSource('updates.json');
    const exit = run(['--source', 'updates.json', '--skip', 'nope'], {
      cwd: sandbox.root,
      now: NOW,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown_package');
    expect(existsSync(declinedLedgerPath(sandbox.root))).toBe(false);
  });

  test('--skip without --source errors', () => {
    const exit = run(['--skip', 'foo'], {cwd: sandbox.root, now: NOW});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('invalid_arguments');
  });

  test('a missing source file errors', () => {
    const exit = run(['--source', 'absent.json', '--skip', 'foo'], {
      cwd: sandbox.root,
      now: NOW,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('source_unreadable');
  });
});
