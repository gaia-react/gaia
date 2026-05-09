/**
 * UAT-009 + UAT-010 integration scenarios.
 *
 * Each test sets up:
 *   - a tmpdir sandbox with a real git repo (the revert handler calls
 *     `git rev-parse` to resolve the repo root)
 *   - the revert ledger pre-populated to a known state
 *   - the gh/git mock with scripted responses
 *
 * Then runs the CLI and asserts the ledger state, stdio, and the
 * exact argv the CLI shelled out with.
 *
 * Discriminating invariants:
 *   - UAT-009 hard cap: a second `ci-revert open` for the same PR
 *     exits 1 with `revert_already_opened` AND zero gh/git invocations.
 *   - UAT-010 escalation: `mark-failed` flips status to `failed`;
 *     `is-cap-reached` reports true; no second revert ever opens.
 */
import {readFileSync} from 'node:fs';
import {afterEach, beforeEach, describe, expect, it, vi} from 'vitest';
import {run} from '../../src/ci/revert.js';
import type {RevertLedger} from '../../src/schemas/revert-ledger.js';
import {installGhMock, type GhMock} from './gh-mock.js';
import {captureStdio, setupSandbox, type Sandbox} from './sandbox.js';

const MERGE_SHA = '0123456789abcdef0123456789abcdef01234567';
const ghViewMerged = JSON.stringify({
  baseRefName: 'main',
  headRefName: 'gaia-ci/wiki/2026-05-09',
  mergeCommit: {oid: MERGE_SHA},
  title: 'wiki: nightly run',
});
const ghViewUnmerged = JSON.stringify({
  baseRefName: 'main',
  headRefName: 'gaia-ci/wiki/2026-05-09',
  mergeCommit: null,
  title: 'wiki: pending',
});
const ghCreateUrlStandard = 'https://github.com/owner/repo/pull/137\n';
const ghCreateUrlWithBanner =
  'Creating pull request for revert -> main\nhttps://github.com/owner/repo/pull/137\n';

describe('UAT-009 — auto-revert on post-merge failure', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;
  let mock: GhMock;

  beforeEach(() => {
    sandbox = setupSandbox();
    stdio = captureStdio();
  });

  afterEach(() => {
    mock?.restore();
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  it('happy path: empty ledger → revert opens and ledger records the entry', () => {
    mock = installGhMock({
      gh: [
        {match: 'pr view', response: {exitCode: 0, stderr: '', stdout: ghViewMerged}},
        {match: 'pr create', response: {exitCode: 0, stderr: '', stdout: ghCreateUrlStandard}},
        {match: 'pr merge', response: {exitCode: 0, stderr: '', stdout: ''}},
      ],
      git: [
        // git revert returns 0 → success
      ],
    });

    const fixedNow = new Date('2026-05-09T05:00:00.000Z');
    const exit = run(
      ['open', '--pr', '99', '--label', 'gaia-ci', '--json'],
      {cwd: sandbox.root, now: () => fixedNow}
    );

    expect(exit).toBe(0);

    const stdout = stdio.out.join('').trim();
    expect(stdout).toMatch(/"revert_pr":\s*137/u);

    const ledger = JSON.parse(readFileSync(sandbox.ledgerPath, 'utf8')) as RevertLedger;
    expect(ledger.attempts['99']).toEqual({
      opened_at: '2026-05-09T05:00:00.000Z',
      original_pr: 99,
      revert_pr: 137,
      status: 'open',
    });

    // Verify the call sequence: gh pr view → git fetch/checkout/revert/push
    // → gh pr create → gh pr merge --auto.
    expect(mock.ghCalls.length).toBe(3);
    expect(mock.gitCalls.length).toBe(4);
    expect(mock.ghCalls[0]?.argv.slice(0, 3)).toEqual(['pr', 'view', '99']);
    expect(mock.gitCalls[0]?.argv).toEqual(['fetch', 'origin', 'main']);
    expect(mock.gitCalls[1]?.argv[0]).toBe('checkout');
    expect(mock.gitCalls[2]?.argv).toEqual(['revert', '--no-edit', MERGE_SHA]);
    expect(mock.gitCalls[3]?.argv).toEqual([
      'push',
      '-u',
      'origin',
      'gaia-ci/revert/gaia-ci/wiki/2026-05-09-0123456',
    ]);
    expect(mock.ghCalls[2]?.argv).toEqual(['pr', 'merge', '137', '--auto', '--squash']);
  });

  it('hard cap: ledger pre-populated → second open exits 1 with revert_already_opened and zero external calls', () => {
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

    mock = installGhMock({});

    const exit = run(
      ['open', '--pr', '99', '--label', 'gaia-ci', '--json'],
      {cwd: sandbox.root}
    );

    expect(exit).not.toBe(0);
    expect(mock.ghCalls.length).toBe(0);
    expect(mock.gitCalls.length).toBe(0);

    const stdout = stdio.out.join('').trim();
    const printed = JSON.parse(stdout) as Record<string, unknown>;
    expect(printed.error).toBe('revert_already_opened');
    expect(printed.existing_revert_pr).toBe(137);

    // Ledger byte-identical: attempt remains as written.
    const ledger = JSON.parse(readFileSync(sandbox.ledgerPath, 'utf8')) as RevertLedger;
    expect(ledger.attempts['99']?.revert_pr).toBe(137);
    expect(ledger.attempts['99']?.status).toBe('open');
  });

  it('refuses to revert an unmerged PR', () => {
    mock = installGhMock({
      gh: [
        {match: 'pr view', response: {exitCode: 0, stderr: '', stdout: ghViewUnmerged}},
      ],
    });

    const exit = run(
      ['open', '--pr', '99', '--label', 'gaia-ci', '--json'],
      {cwd: sandbox.root}
    );

    expect(exit).not.toBe(0);
    expect(mock.ghCalls.length).toBe(1); // only `gh pr view`
    expect(mock.gitCalls.length).toBe(0);

    const stdout = stdio.out.join('').trim();
    const printed = JSON.parse(stdout) as Record<string, unknown>;
    expect(printed.error).toBe('pr_not_merged');

    expect(() => readFileSync(sandbox.ledgerPath, 'utf8')).toThrow();
  });

  it('parses the new PR number even when stdout has a banner line', () => {
    mock = installGhMock({
      gh: [
        {match: 'pr view', response: {exitCode: 0, stderr: '', stdout: ghViewMerged}},
        {match: 'pr create', response: {exitCode: 0, stderr: '', stdout: ghCreateUrlWithBanner}},
        {match: 'pr merge', response: {exitCode: 0, stderr: '', stdout: ''}},
      ],
    });

    const exit = run(
      ['open', '--pr', '99', '--label', 'gaia-ci', '--json'],
      {cwd: sandbox.root, now: () => new Date('2026-05-09T05:00:00Z')}
    );
    expect(exit).toBe(0);

    const ledger = JSON.parse(readFileSync(sandbox.ledgerPath, 'utf8')) as RevertLedger;
    expect(ledger.attempts['99']?.revert_pr).toBe(137);
  });
});

describe('UAT-010 — hard-cap escalation', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;
  let mock: GhMock;

  beforeEach(() => {
    sandbox = setupSandbox();
    stdio = captureStdio();
    mock = installGhMock({});
  });

  afterEach(() => {
    mock.restore();
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  it('mark-failed flips status to failed and does no external work', () => {
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

    const exit = run(['mark-failed', '--pr', '99', '--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(mock.ghCalls.length).toBe(0);
    expect(mock.gitCalls.length).toBe(0);

    const ledger = JSON.parse(readFileSync(sandbox.ledgerPath, 'utf8')) as RevertLedger;
    expect(ledger.attempts['99']?.status).toBe('failed');
    expect(ledger.attempts['99']?.revert_pr).toBe(137);
  });

  it('is-cap-reached returns true after mark-failed', () => {
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

    const exit = run(['is-cap-reached', '--pr', '99', '--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const stdout = stdio.out.join('').trim();
    const printed = JSON.parse(stdout) as Record<string, unknown>;
    expect(printed.cap_reached).toBe(true);
    expect(printed.status).toBe('failed');
  });

  it('is-cap-reached returns false on missing entry', () => {
    const exit = run(['is-cap-reached', '--pr', '99', '--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const stdout = stdio.out.join('').trim();
    const printed = JSON.parse(stdout) as Record<string, unknown>;
    expect(printed.cap_reached).toBe(false);
    expect(printed.status).toBeNull();
  });

  it('mark-failed on missing attempt exits non-zero', () => {
    const exit = run(['mark-failed', '--pr', '99', '--json'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);

    const stdout = stdio.out.join('').trim();
    const printed = JSON.parse(stdout) as Record<string, unknown>;
    expect(printed.error).toBe('no_revert_attempt');
  });

  it('after mark-failed, a second ci-revert open is still blocked (the cap is sealed)', () => {
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
      ['open', '--pr', '99', '--label', 'gaia-ci', '--json'],
      {cwd: sandbox.root}
    );

    expect(exit).not.toBe(0);
    expect(mock.ghCalls.length).toBe(0);
    expect(mock.gitCalls.length).toBe(0);

    const stdout = stdio.out.join('').trim();
    const printed = JSON.parse(stdout) as Record<string, unknown>;
    expect(printed.error).toBe('revert_already_opened');
  });
});
