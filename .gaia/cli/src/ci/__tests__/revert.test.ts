import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, it, vi} from 'vitest';
import type {RevertLedger} from '../../schemas/revert-ledger.js';
import {run} from '../revert.js';
import * as runProcess from '../util/run-process.js';
import type {ProcessResult} from '../util/run-process.js';

type RunFn = (
  args: readonly string[],
  options?: {cwd?: string; env?: NodeJS.ProcessEnv}
) => ProcessResult;

type Sandbox = {
  cleanup: () => void;
  ledgerPath: string;
  root: string;
  writeLedger: (ledger: RevertLedger) => void;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-ci-revert-'));
  // The handler calls resolveRepoRoot, so we need a real git repo.
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  execFileSync('git', ['config', 'user.email', 'test@example.com'], {cwd: root});
  execFileSync('git', ['config', 'user.name', 'Test'], {cwd: root});
  writeFileSync(path.join(root, 'README.md'), '# test\n', 'utf8');
  execFileSync('git', ['add', 'README.md'], {cwd: root});
  execFileSync('git', ['commit', '-q', '-m', 'initial'], {cwd: root});
  mkdirSync(path.join(root, '.gaia'), {recursive: true});

  const ledgerPath = path.join(root, '.gaia', 'automation.state-revert-attempts.json');

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    ledgerPath,
    root,
    writeLedger: (ledger) => {
      writeFileSync(ledgerPath, JSON.stringify(ledger), 'utf8');
    },
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

const ghViewMerged = JSON.stringify({
  baseRefName: 'main',
  headRefName: 'gaia-ci/wiki/2026-05-09',
  mergeCommit: {oid: '0123456789abcdef0123456789abcdef01234567'},
  title: 'wiki: nightly run',
});

const ghCreateUrl = 'https://github.com/owner/repo/pull/137\n';

describe('ci-revert', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;
  let ghSpy: ReturnType<typeof vi.spyOn> & {
    mock: {calls: Array<[readonly string[], unknown?]>};
    mockImplementation: (impl: RunFn) => unknown;
  };
  let gitSpy: ReturnType<typeof vi.spyOn> & {
    mock: {calls: Array<[readonly string[], unknown?]>};
    mockImplementation: (impl: RunFn) => unknown;
  };

  beforeEach(() => {
    sandbox = setupSandbox();
    stdio = captureStdio();

    const ghImpl: RunFn = (args) => {
      const [a, b] = args;

      if (a === 'pr' && b === 'view') {
        return {exitCode: 0, stderr: '', stdout: ghViewMerged};
      }

      if (a === 'pr' && b === 'create') {
        return {exitCode: 0, stderr: '', stdout: ghCreateUrl};
      }

      if (a === 'pr' && b === 'merge') {
        return {exitCode: 0, stderr: '', stdout: ''};
      }

      return {exitCode: 0, stderr: '', stdout: ''};
    };

    ghSpy = vi.spyOn(runProcess, 'runGh').mockImplementation(ghImpl) as typeof ghSpy;
    gitSpy = vi
      .spyOn(runProcess, 'runGit')
      .mockReturnValue({exitCode: 0, stderr: '', stdout: ''}) as typeof gitSpy;
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  describe('open', () => {
    it('opens the revert PR and writes the ledger', () => {
      const fixedNow = new Date('2026-05-09T05:00:00.000Z');
      const exit = run(
        ['open', '--pr', '99', '--label', 'gaia-ci', '--json'],
        {cwd: sandbox.root, now: () => fixedNow}
      );
      expect(exit).toBe(0);

      const success = JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;
      expect(success.revert_pr).toBe(137);
      expect(success.original_pr).toBe(99);
      expect(success.revert_branch).toBe(
        'gaia-ci/revert/gaia-ci/wiki/2026-05-09-0123456'
      );

      const ledger = JSON.parse(readFileSync(sandbox.ledgerPath, 'utf8')) as RevertLedger;
      expect(ledger.attempts['99']).toEqual({
        opened_at: '2026-05-09T05:00:00.000Z',
        original_pr: 99,
        revert_pr: 137,
        status: 'open',
      });

      // Verify all five external commands were called in order.
      const ghArgsList = ghSpy.mock.calls.map((call: [readonly string[], unknown?]) => call[0]);
      const gitArgsList = gitSpy.mock.calls.map((call: [readonly string[], unknown?]) => call[0]);

      expect(ghArgsList[0]?.slice(0, 3)).toEqual(['pr', 'view', '99']);
      expect(gitArgsList[0]).toEqual(['fetch', 'origin', 'main']);
      expect(gitArgsList[1]?.[0]).toBe('checkout');
      expect(gitArgsList[2]?.slice(0, 3)).toEqual([
        'revert',
        '--no-edit',
        '0123456789abcdef0123456789abcdef01234567',
      ]);
      expect(gitArgsList[3]).toEqual([
        'push',
        '-u',
        'origin',
        'gaia-ci/revert/gaia-ci/wiki/2026-05-09-0123456',
      ]);
      expect(ghArgsList[1]?.slice(0, 2)).toEqual(['pr', 'create']);
      expect(ghArgsList[2]).toEqual(['pr', 'merge', '137', '--auto', '--squash']);
    });

    it('refuses with revert_already_opened when an entry exists', () => {
      sandbox.writeLedger({
        attempts: {
          '99': {
            opened_at: '2026-05-08T00:00:00Z',
            original_pr: 99,
            revert_pr: 137,
            status: 'open',
          },
        },
        version: 1,
      });

      const exit = run(
        ['open', '--pr', '99', '--label', 'gaia-ci', '--json'],
        {cwd: sandbox.root}
      );
      expect(exit).not.toBe(0);

      // Hard cap: zero gh / git invocations.
      expect(ghSpy.mock.calls.length).toBe(0);
      expect(gitSpy.mock.calls.length).toBe(0);

      const printed = JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;
      expect(printed.error).toBe('revert_already_opened');
      expect(printed.existing_revert_pr).toBe(137);

      // Ledger byte-identical.
      const ledger = JSON.parse(readFileSync(sandbox.ledgerPath, 'utf8')) as RevertLedger;
      expect(ledger.attempts['99']?.status).toBe('open');
      expect(ledger.attempts['99']?.revert_pr).toBe(137);
    });

    it('exits with pr_not_merged when mergeCommit is null', () => {
      const impl: RunFn = (args) => {
        if (args[0] === 'pr' && args[1] === 'view') {
          return {
            exitCode: 0,
            stderr: '',
            stdout: JSON.stringify({
              baseRefName: 'main',
              headRefName: 'gaia-ci/wiki',
              mergeCommit: null,
              title: 'open PR',
            }),
          };
        }

        return {exitCode: 0, stderr: '', stdout: ''};
      };
      ghSpy.mockImplementation(impl);

      const exit = run(
        ['open', '--pr', '99', '--label', 'gaia-ci', '--json'],
        {cwd: sandbox.root}
      );
      expect(exit).not.toBe(0);

      // Only gh pr view was called; nothing else.
      expect(ghSpy.mock.calls.length).toBe(1);
      expect(gitSpy.mock.calls.length).toBe(0);

      const printed = JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;
      expect(printed.error).toBe('pr_not_merged');

      // Ledger never written.
      expect(() => readFileSync(sandbox.ledgerPath, 'utf8')).toThrow();
    });

    it('rejects when --pr is missing', () => {
      const exit = run(
        ['open', '--label', 'gaia-ci', '--json'],
        {cwd: sandbox.root}
      );
      expect(exit).not.toBe(0);
      expect(stdio.err.join('')).toContain('--pr');
    });

    it('rejects when --label is missing', () => {
      const exit = run(['open', '--pr', '99', '--json'], {cwd: sandbox.root});
      expect(exit).not.toBe(0);
      expect(stdio.err.join('')).toContain('--label');
    });

    it('emits revert_failed on git revert conflict', () => {
      const impl: RunFn = (args) => {
        if (args[0] === 'revert' && args[1] === '--no-edit') {
          return {exitCode: 1, stderr: 'CONFLICT (content)', stdout: ''};
        }

        return {exitCode: 0, stderr: '', stdout: ''};
      };
      gitSpy.mockImplementation(impl);

      const exit = run(
        ['open', '--pr', '99', '--label', 'gaia-ci', '--json'],
        {cwd: sandbox.root}
      );
      expect(exit).not.toBe(0);

      const printed = JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;
      expect(printed.error).toBe('revert_failed');
      expect(printed.step).toBe('git_revert');
    });

    it('parses the new PR number even with a banner line in stdout', () => {
      const impl: RunFn = (args) => {
        if (args[0] === 'pr' && args[1] === 'view') {
          return {exitCode: 0, stderr: '', stdout: ghViewMerged};
        }

        if (args[0] === 'pr' && args[1] === 'create') {
          return {
            exitCode: 0,
            stderr: '',
            stdout: 'Creating pull request for ...\nhttps://github.com/owner/repo/pull/137\n',
          };
        }

        return {exitCode: 0, stderr: '', stdout: ''};
      };
      ghSpy.mockImplementation(impl);

      const exit = run(
        ['open', '--pr', '99', '--label', 'gaia-ci', '--json'],
        {cwd: sandbox.root}
      );
      expect(exit).toBe(0);

      const ledger = JSON.parse(readFileSync(sandbox.ledgerPath, 'utf8')) as RevertLedger;
      expect(ledger.attempts['99']?.revert_pr).toBe(137);
    });
  });

  describe('mark-failed', () => {
    it('flips status to failed', () => {
      sandbox.writeLedger({
        attempts: {
          '99': {
            opened_at: '2026-05-08T00:00:00Z',
            original_pr: 99,
            revert_pr: 137,
            status: 'open',
          },
        },
        version: 1,
      });

      const exit = run(
        ['mark-failed', '--pr', '99', '--json'],
        {cwd: sandbox.root}
      );
      expect(exit).toBe(0);

      // mark-failed never invokes gh / git.
      expect(ghSpy.mock.calls.length).toBe(0);
      expect(gitSpy.mock.calls.length).toBe(0);

      const ledger = JSON.parse(readFileSync(sandbox.ledgerPath, 'utf8')) as RevertLedger;
      expect(ledger.attempts['99']?.status).toBe('failed');
      expect(ledger.attempts['99']?.revert_pr).toBe(137);
    });

    it('exits non-zero on missing attempt', () => {
      const exit = run(
        ['mark-failed', '--pr', '99', '--json'],
        {cwd: sandbox.root}
      );
      expect(exit).not.toBe(0);

      const printed = JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;
      expect(printed.error).toBe('no_revert_attempt');
    });

    it('rejects when --pr is missing', () => {
      const exit = run(['mark-failed'], {cwd: sandbox.root});
      expect(exit).not.toBe(0);
      expect(stdio.err.join('')).toContain('--pr');
    });
  });

  describe('is-cap-reached', () => {
    it('reports true for status: open', () => {
      sandbox.writeLedger({
        attempts: {
          '99': {
            opened_at: '2026-05-08T00:00:00Z',
            original_pr: 99,
            revert_pr: 137,
            status: 'open',
          },
        },
        version: 1,
      });

      const exit = run(
        ['is-cap-reached', '--pr', '99', '--json'],
        {cwd: sandbox.root}
      );
      expect(exit).toBe(0);

      const printed = JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;
      expect(printed.cap_reached).toBe(true);
      expect(printed.status).toBe('open');
    });

    it('reports true for status: failed', () => {
      sandbox.writeLedger({
        attempts: {
          '99': {
            opened_at: '2026-05-08T00:00:00Z',
            original_pr: 99,
            revert_pr: 137,
            status: 'failed',
          },
        },
        version: 1,
      });

      const exit = run(
        ['is-cap-reached', '--pr', '99', '--json'],
        {cwd: sandbox.root}
      );
      expect(exit).toBe(0);

      const printed = JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;
      expect(printed.cap_reached).toBe(true);
      expect(printed.status).toBe('failed');
    });

    it('reports false for status: merged', () => {
      sandbox.writeLedger({
        attempts: {
          '99': {
            opened_at: '2026-05-08T00:00:00Z',
            original_pr: 99,
            revert_pr: 137,
            status: 'merged',
          },
        },
        version: 1,
      });

      const exit = run(
        ['is-cap-reached', '--pr', '99', '--json'],
        {cwd: sandbox.root}
      );
      expect(exit).toBe(0);

      const printed = JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;
      expect(printed.cap_reached).toBe(false);
      expect(printed.status).toBe('merged');
    });

    it('reports false on missing entry', () => {
      const exit = run(
        ['is-cap-reached', '--pr', '99', '--json'],
        {cwd: sandbox.root}
      );
      expect(exit).toBe(0);

      const printed = JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;
      expect(printed.cap_reached).toBe(false);
      expect(printed.status).toBeNull();
    });
  });

  describe('help & dispatch', () => {
    it('prints help on no args', () => {
      const exit = run([], {cwd: sandbox.root});
      expect(exit).not.toBe(0);
      expect(stdio.out.join('')).toContain('Usage: gaia ci-revert');
    });

    it('prints help on --help and exits 0', () => {
      const exit = run(['--help'], {cwd: sandbox.root});
      expect(exit).toBe(0);
      expect(stdio.out.join('')).toContain('Usage: gaia ci-revert');
    });

    it('exits non-zero on unknown subcommand', () => {
      const exit = run(['unknown'], {cwd: sandbox.root});
      expect(exit).not.toBe(0);
      expect(stdio.err.join('')).toContain('unknown');
    });
  });
});
