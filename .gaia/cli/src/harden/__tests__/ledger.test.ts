import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../../exit.js';
import {declineLedgerPath} from '../../schemas/decline-ledger.js';
import type {DeclineLedger} from '../../schemas/decline-ledger.js';
import {run} from '../ledger.js';

type Sandbox = {
  cleanup: () => void;
  ledgerPath: string;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-harden-ledger-'));
  // The handler calls resolveRepoRoot, so we need a real git repo.
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    ledgerPath: declineLedgerPath(root),
    root,
  };
};

const captureStdio = () => {
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

const readLedger = (ledgerPath: string): DeclineLedger =>
  JSON.parse(readFileSync(ledgerPath, 'utf8')) as DeclineLedger;

const FIXED_NOW = new Date('2026-06-05T14:32:00.000Z');

describe('harden-ledger', () => {
  let sandbox: Sandbox;
  let io: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    sandbox = setupSandbox();
    io = captureStdio();
  });

  afterEach(() => {
    io.restore();
    sandbox.cleanup();
  });

  describe('list', () => {
    test('prints the empty ledger and exits 0 on a fresh repo', () => {
      const code = run(['list'], {cwd: sandbox.root});

      expect(code).toBe(EXIT_CODES.OK);
      expect(io.out.join('')).toBe('{"version":1,"declines":[]}\n');
    });
  });

  describe('record', () => {
    test('creates exactly one entry with an ISO timestamp and pr count', () => {
      const code = run(
        [
          'record',
          '--finding-class',
          'react-doctor/no-generic-handler-names',
          '--pr-count',
          '7',
        ],
        {cwd: sandbox.root, now: () => FIXED_NOW}
      );

      expect(code).toBe(EXIT_CODES.OK);

      const ledger = readLedger(sandbox.ledgerPath);
      expect(ledger.declines).toHaveLength(1);
      expect(ledger.declines[0]).toEqual({
        declined_at: '2026-06-05T14:32:00.000Z',
        declined_at_pr_count: 7,
        finding_class: 'react-doctor/no-generic-handler-names',
      });
    });

    test('upserts: re-recording the same class overwrites count and timestamp', () => {
      run(
        ['record', '--finding-class', 'axe/color-contrast', '--pr-count', '7'],
        {
          cwd: sandbox.root,
          now: () => new Date('2026-06-01T00:00:00.000Z'),
        }
      );
      run(
        ['record', '--finding-class', 'axe/color-contrast', '--pr-count', '9'],
        {
          cwd: sandbox.root,
          now: () => new Date('2026-06-05T00:00:00.000Z'),
        }
      );

      const ledger = readLedger(sandbox.ledgerPath);
      expect(ledger.declines).toHaveLength(1);
      expect(ledger.declines[0]).toEqual({
        declined_at: '2026-06-05T00:00:00.000Z',
        declined_at_pr_count: 9,
        finding_class: 'axe/color-contrast',
      });
    });

    test('keeps distinct classes as separate entries', () => {
      run(['record', '--finding-class', 'knip/exports', '--pr-count', '3'], {
        cwd: sandbox.root,
      });
      run(['record', '--finding-class', 'cve/1098765', '--pr-count', '5'], {
        cwd: sandbox.root,
      });

      const ledger = readLedger(sandbox.ledgerPath);
      expect(ledger.declines).toHaveLength(2);
    });

    test('creates the harden dir with mode 755', () => {
      run(['record', '--finding-class', 'knip/types', '--pr-count', '1'], {
        cwd: sandbox.root,
      });

      const mode = statSync(path.dirname(sandbox.ledgerPath)).mode & 0o777;
      expect(mode).toBe(0o755);
    });

    test('exits non-zero when --finding-class is missing', () => {
      const code = run(['record', '--pr-count', '7'], {cwd: sandbox.root});

      expect(code).not.toBe(EXIT_CODES.OK);
    });

    test('exits non-zero when --pr-count is missing', () => {
      const code = run(['record', '--finding-class', 'knip/exports'], {
        cwd: sandbox.root,
      });

      expect(code).not.toBe(EXIT_CODES.OK);
    });
  });

  describe('is-suppressed', () => {
    beforeEach(() => {
      run(
        [
          'record',
          '--finding-class',
          'rule/switch-statement',
          '--pr-count',
          '7',
        ],
        {
          cwd: sandbox.root,
          now: () => FIXED_NOW,
        }
      );
    });

    test('exits 0 when below the re-surface threshold', () => {
      const code = run(
        [
          'is-suppressed',
          '--finding-class',
          'rule/switch-statement',
          '--current-pr-count',
          '8',
        ],
        {cwd: sandbox.root}
      );

      expect(code).toBe(EXIT_CODES.OK);
    });

    test('exits non-zero at the re-surface threshold (>= 3)', () => {
      const code = run(
        [
          'is-suppressed',
          '--finding-class',
          'rule/switch-statement',
          '--current-pr-count',
          '10',
        ],
        {cwd: sandbox.root}
      );

      expect(code).not.toBe(EXIT_CODES.OK);
    });

    test('exits non-zero for an unknown class', () => {
      const code = run(
        [
          'is-suppressed',
          '--finding-class',
          'holistic/n-plus-one',
          '--current-pr-count',
          '99',
        ],
        {cwd: sandbox.root}
      );

      expect(code).not.toBe(EXIT_CODES.OK);
    });
  });

  describe('prune', () => {
    beforeEach(() => {
      run(['record', '--finding-class', 'knip/exports', '--pr-count', '3'], {
        cwd: sandbox.root,
      });
      run(['record', '--finding-class', 'knip/types', '--pr-count', '4'], {
        cwd: sandbox.root,
      });
    });

    test('removes entries not in the window-classes set, keeps those in it', () => {
      const code = run(['prune', '--window-classes', 'knip/exports'], {
        cwd: sandbox.root,
      });

      expect(code).toBe(EXIT_CODES.OK);

      const ledger = readLedger(sandbox.ledgerPath);
      expect(ledger.declines).toHaveLength(1);
      expect(ledger.declines[0]?.finding_class).toBe('knip/exports');
    });

    test('is idempotent: a second prune with the same set is a no-op', () => {
      run(['prune', '--window-classes', 'knip/exports'], {cwd: sandbox.root});
      const code = run(['prune', '--window-classes', 'knip/exports'], {
        cwd: sandbox.root,
      });

      expect(code).toBe(EXIT_CODES.OK);

      const ledger = readLedger(sandbox.ledgerPath);
      expect(ledger.declines).toHaveLength(1);
    });

    test('prunes all entries when given an empty set', () => {
      const code = run(['prune', '--window-classes', ''], {cwd: sandbox.root});

      expect(code).toBe(EXIT_CODES.OK);

      const ledger = readLedger(sandbox.ledgerPath);
      expect(ledger.declines).toHaveLength(0);
    });
  });

  describe('corrupt file', () => {
    test('list fails loud (non-zero, structured error) rather than treating as empty', () => {
      run(['record', '--finding-class', 'knip/exports', '--pr-count', '1'], {
        cwd: sandbox.root,
      });
      writeFileSync(sandbox.ledgerPath, '{ not valid json', 'utf8');

      const code = run(['list'], {cwd: sandbox.root});

      expect(code).not.toBe(EXIT_CODES.OK);
      expect(io.err.join('')).toContain('malformed_ledger');
    });

    test('is-suppressed fails loud rather than re-surfacing a declined class', () => {
      // Seed a valid entry first so the harden dir exists, then corrupt it.
      run(['record', '--finding-class', 'knip/exports', '--pr-count', '1'], {
        cwd: sandbox.root,
      });
      writeFileSync(
        sandbox.ledgerPath,
        JSON.stringify({declines: 'nope', version: 2}),
        'utf8'
      );

      const code = run(
        [
          'is-suppressed',
          '--finding-class',
          'knip/exports',
          '--current-pr-count',
          '1',
        ],
        {cwd: sandbox.root}
      );

      expect(code).not.toBe(EXIT_CODES.OK);
      expect(io.err.join('')).toContain('malformed_ledger');
    });
  });

  describe('unknown subcommand', () => {
    test('exits non-zero', () => {
      const code = run(['frobnicate'], {cwd: sandbox.root});

      expect(code).not.toBe(EXIT_CODES.OK);
    });
  });
});
