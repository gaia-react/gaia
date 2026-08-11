/**
 * Focus: `mergePollAttempts` is the single source of truth for the poll
 * count, `MERGE_WAIT_BUDGET_MS` is the single source of truth for the sleep
 * budget, and the worst-case invariant that ties the whole blocking path to
 * the 600 s Bash `timeout` ceiling is a literal assertion, not reviewer
 * judgment. `cleanupAfterMerge` must stay reusable (exported, callable with
 * an injected runner) and singly-defined across the repository.
 */
import {describe, expect, test} from 'vitest';
import type {SpawnSyncReturns} from 'node:child_process';
import type {CommandRunner} from './branch.js';
import {
  CLEANUP_CEILING_MS,
  cleanupAfterMerge,
  GH_CALL_CEILING_MS,
  MAX_SLICE_MS,
  MERGE_POLL_INTERVAL_MS,
  MERGE_WAIT_BUDGET_MS,
  mergePollAttempts,
} from './land.js';

const okResult = (): SpawnSyncReturns<string> => ({
  output: ['', '', ''] as never,
  pid: 0,
  signal: null,
  status: 0,
  stderr: '',
  stdout: '',
});

describe('mergePollAttempts', () => {
  test('derives 9 attempts from the default 240s budget and 30s interval', () => {
    expect(mergePollAttempts()).toBe(9);
  });

  test('derives attempts for an arbitrary budget/interval pair', () => {
    expect(mergePollAttempts(120_000, 30_000)).toBe(5);
  });

  test('the sleep budget identity holds: (attempts - 1) x interval === the budget', () => {
    expect((mergePollAttempts() - 1) * MERGE_POLL_INTERVAL_MS).toBe(
      MERGE_WAIT_BUDGET_MS
    );
  });

  test('the worst-case blocking path stays under MAX_SLICE_MS, which stays under the 600s Bash cap', () => {
    const worstCase =
      MERGE_WAIT_BUDGET_MS +
      mergePollAttempts() * GH_CALL_CEILING_MS +
      CLEANUP_CEILING_MS;

    expect(worstCase).toBeLessThanOrEqual(MAX_SLICE_MS);
    expect(MAX_SLICE_MS).toBeLessThan(600_000);
  });
});

describe('cleanupAfterMerge', () => {
  test('issues checkout, pull, branch -D, fetch --prune in order against an injected runner', () => {
    const seen: {args: readonly string[]; command: string}[] = [];

    const runner: CommandRunner = (command, args) => {
      seen.push({args, command});

      return okResult();
    };

    cleanupAfterMerge({
      base: 'main',
      branch: 'wiki-sync/x',
      cwd: '/repo',
      runner,
    });

    expect(seen).toEqual([
      {args: ['checkout', '--end-of-options', 'main'], command: 'git'},
      {args: ['pull', '--ff-only', 'origin', 'main'], command: 'git'},
      {args: ['branch', '-D', '--', 'wiki-sync/x'], command: 'git'},
      {args: ['fetch', '--prune', 'origin'], command: 'git'},
    ]);
  });
});
