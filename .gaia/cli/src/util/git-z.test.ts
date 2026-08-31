/**
 * Focus: the two properties a call site depends on and cannot see. `gitZArgs`
 * puts `-z` in a position every listing verb accepts, which is what leaves the
 * caller no position to omit it from; and `splitZStream` drops empty records
 * without trimming, because `-z` permits whitespace inside a path but leaves
 * no terminator to strip.
 *
 * The end-to-end property, that a real git invocation built this way returns a
 * non-ASCII path unquoted, is pinned by the canary suites beside each call
 * site rather than here, since it needs a git fixture.
 */
import {describe, expect, test} from 'vitest';
import {gitZArgs, splitZStream} from './git-z.js';

describe('gitZArgs', () => {
  test('puts -z immediately after the verb, ahead of the caller arguments', () => {
    expect(gitZArgs('ls-tree', ['-r', '-l', 'HEAD', '--', 'wiki/'])).toEqual([
      '-c',
      'core.quotepath=false',
      'ls-tree',
      '-z',
      '-r',
      '-l',
      'HEAD',
      '--',
      'wiki/',
    ]);
  });

  test('carries both flags for a verb that takes no further arguments', () => {
    expect(gitZArgs('ls-files')).toEqual([
      '-c',
      'core.quotepath=false',
      'ls-files',
      '-z',
    ]);
  });

  test('never lets a caller argument precede the flags it is given for', () => {
    const args = gitZArgs('diff-tree', ['--name-only', '-r', 'HEAD']);

    expect(args.indexOf('-z')).toBeLessThan(args.indexOf('--name-only'));
    expect(args.indexOf('core.quotepath=false')).toBeLessThan(
      args.indexOf('diff-tree')
    );
  });
});

describe('splitZStream', () => {
  test('drops the empty record a NUL-terminated stream ends with', () => {
    expect(splitZStream('wiki/a.md\0wiki/b.md\0')).toEqual([
      'wiki/a.md',
      'wiki/b.md',
    ]);
  });

  test('returns nothing for the empty stream a listing with no match emits', () => {
    expect(splitZStream('')).toEqual([]);
  });

  test('keeps a path holding a newline as one record', () => {
    expect(splitZStream('wiki/two\nnames.md\0')).toEqual([
      'wiki/two\nnames.md',
    ]);
  });

  test('never trims, since git permits whitespace at either end of a path', () => {
    expect(splitZStream(' wiki/padded.md \0')).toEqual([' wiki/padded.md ']);
  });

  test('never unquotes, since -z emits raw bytes a name may legally contain', () => {
    expect(splitZStream('wiki/"quoted".md\0')).toEqual(['wiki/"quoted".md']);
  });
});
