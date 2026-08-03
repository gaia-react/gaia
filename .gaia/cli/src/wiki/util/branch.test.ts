import {describe, expect, test} from 'vitest';
/**
 * Tests for `inspectWorkingTree`.
 *
 * Focus: the classification is only as trustworthy as the parse behind it.
 * Both callers refuse to act on a working tree carrying non-wiki changes, so a
 * path git reports in a shape the parse mishandles does not merely print
 * wrong, it takes the wrong branch. Under `-z` git emits raw bytes and gives a
 * rename origin its own record, which is what keeps a spaced or non-ASCII
 * wiki page (nearly every GAIA wiki page has a space in its filename) on the
 * wiki side of the split.
 */
import type {SpawnSyncReturns} from 'node:child_process';
import {inspectWorkingTree} from './branch.js';
import type {CommandRunner} from './branch.js';

const okResult = (stdout: string): SpawnSyncReturns<string> => ({
  output: ['', stdout, ''] as never,
  pid: 0,
  signal: null,
  status: 0,
  stderr: '',
  stdout,
});

const runnerReturning =
  (stdout: string): CommandRunner =>
  () =>
    okResult(stdout);

describe('inspectWorkingTree', () => {
  test('asks git for NUL-delimited records, which the parse depends on', () => {
    const seen: string[][] = [];

    inspectWorkingTree('/repo', (_command, args) => {
      seen.push([...args]);

      return okResult('');
    });

    expect(seen).toEqual([['status', '--porcelain=v1', '-z', '-uall']]);
  });

  test('classifies a spaced wiki path as a wiki change', () => {
    const status = inspectWorkingTree(
      '/repo',
      runnerReturning(' M wiki/concepts/Wiki Sync.md\0')
    );

    expect(status.paths).toEqual(['wiki/concepts/Wiki Sync.md']);
    expect(status.hasWikiChanges).toBe(true);
    expect(status.hasNonWikiChanges).toBe(false);
  });

  test('handles an added (untracked) spaced wiki page', () => {
    const status = inspectWorkingTree(
      '/repo',
      runnerReturning('?? wiki/decisions/TDD RED Verification.md\0')
    );

    expect(status.paths).toEqual(['wiki/decisions/TDD RED Verification.md']);
    expect(status.hasWikiChanges).toBe(true);
  });

  test('flags a spaced non-wiki path as a non-wiki change', () => {
    const status = inspectWorkingTree(
      '/repo',
      runnerReturning(' M app/some dir/a file.ts\0')
    );

    expect(status.paths).toEqual(['app/some dir/a file.ts']);
    expect(status.hasNonWikiChanges).toBe(true);
    expect(status.hasWikiChanges).toBe(false);
  });

  test('reports both halves of a rename', () => {
    const status = inspectWorkingTree(
      '/repo',
      runnerReturning('R  app/new.ts\0app/old.ts\0')
    );

    expect(status.paths).toEqual(['app/new.ts', 'app/old.ts']);
    expect(status.hasNonWikiChanges).toBe(true);
  });

  test('keeps a non-ASCII wiki rename on the wiki side of the split', () => {
    const status = inspectWorkingTree(
      '/repo',
      runnerReturning(
        'R  wiki/concepts/Café Notes.md\0wiki/concepts/Cafe Notes.md\0'
      )
    );

    expect(status.paths).toEqual([
      'wiki/concepts/Café Notes.md',
      'wiki/concepts/Cafe Notes.md',
    ]);
    expect(status.hasWikiChanges).toBe(true);
    expect(status.hasNonWikiChanges).toBe(false);
  });

  test('classifies a mix of a wiki edit and a non-wiki edit', () => {
    const status = inspectWorkingTree(
      '/repo',
      runnerReturning(' M wiki/concepts/Wiki Sync.md\0 M package.json\0')
    );

    expect(status.paths).toEqual([
      'wiki/concepts/Wiki Sync.md',
      'package.json',
    ]);
    expect(status.hasWikiChanges).toBe(true);
    expect(status.hasNonWikiChanges).toBe(true);
  });

  test('reports a clean tree as neither wiki nor non-wiki', () => {
    const status = inspectWorkingTree('/repo', runnerReturning(''));

    expect(status.paths).toEqual([]);
    expect(status.hasWikiChanges).toBe(false);
    expect(status.hasNonWikiChanges).toBe(false);
  });
});
