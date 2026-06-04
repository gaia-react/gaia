/**
 * Tests for `inspectWorkingTree`.
 *
 * Focus: git's porcelain v1 output wraps paths containing spaces (and other
 * unusual characters) in double quotes. Nearly every GAIA wiki page has a
 * space in its filename, so the helper must strip that quoting before the
 * `wiki/` prefix check, otherwise a real wiki edit is misread as a non-wiki
 * change and `sync land` refuses to land it.
 */
import type {SpawnSyncReturns} from 'node:child_process';
import {describe, expect, test} from 'vitest';
import {inspectWorkingTree, type CommandRunner} from './branch.js';

const okResult = (stdout: string): SpawnSyncReturns<string> => ({
  output: ['', stdout, ''] as never,
  pid: 0,
  signal: null,
  status: 0,
  stderr: '',
  stdout,
});

const runnerReturning = (stdout: string): CommandRunner => () =>
  okResult(stdout);

describe('inspectWorkingTree', () => {
  test('strips git quoting from a spaced wiki path and classifies it as a wiki change', () => {
    const status = inspectWorkingTree(
      '/repo',
      runnerReturning(' M "wiki/concepts/Wiki Sync.md"\n')
    );

    expect(status.paths).toEqual(['wiki/concepts/Wiki Sync.md']);
    expect(status.hasWikiChanges).toBe(true);
    expect(status.hasNonWikiChanges).toBe(false);
  });

  test('handles an added (untracked) spaced wiki page', () => {
    const status = inspectWorkingTree(
      '/repo',
      runnerReturning('?? "wiki/decisions/TDD RED Verification.md"\n')
    );

    expect(status.paths).toEqual(['wiki/decisions/TDD RED Verification.md']);
    expect(status.hasWikiChanges).toBe(true);
  });

  test('leaves an unquoted path untouched', () => {
    const status = inspectWorkingTree(
      '/repo',
      runnerReturning(' M wiki/log.md\n')
    );

    expect(status.paths).toEqual(['wiki/log.md']);
    expect(status.hasWikiChanges).toBe(true);
    expect(status.hasNonWikiChanges).toBe(false);
  });

  test('strips quoting on a spaced non-wiki path and flags it as non-wiki', () => {
    const status = inspectWorkingTree(
      '/repo',
      runnerReturning(' M "app/some dir/a file.ts"\n')
    );

    expect(status.paths).toEqual(['app/some dir/a file.ts']);
    expect(status.hasNonWikiChanges).toBe(true);
    expect(status.hasWikiChanges).toBe(false);
  });

  test('still splits an unquoted rename into both halves', () => {
    const status = inspectWorkingTree(
      '/repo',
      runnerReturning('R  app/old.ts -> app/new.ts\n')
    );

    expect(status.paths).toEqual(['app/old.ts', 'app/new.ts']);
    expect(status.hasNonWikiChanges).toBe(true);
  });

  test('classifies a mix of a quoted wiki edit and a plain non-wiki edit', () => {
    const status = inspectWorkingTree(
      '/repo',
      runnerReturning(' M "wiki/concepts/Wiki Sync.md"\n M package.json\n')
    );

    expect(status.paths).toEqual(['wiki/concepts/Wiki Sync.md', 'package.json']);
    expect(status.hasWikiChanges).toBe(true);
    expect(status.hasNonWikiChanges).toBe(true);
  });
});
