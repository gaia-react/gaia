/**
 * Focus: the two hazards that make `-z` load-bearing rather than a formatting
 * preference. Under the default (non-`-z`) output git applies C-style quoting,
 * so a path carrying a space, a quote, or a non-ASCII byte arrives wrapped in
 * `"` with its bytes escaped, and a rename arrives as one ambiguous
 * `old -> new` payload. Under `-z` neither happens, so the parser's whole job
 * is the rename lookahead: a rename or copy record is followed by a bare
 * origin-path record carrying no status prefix.
 */
import {describe, expect, test} from 'vitest';
import {porcelainZPaths} from './git-status.js';

describe('porcelainZPaths', () => {
  test('returns the path of a modified record without its status columns', () => {
    expect(porcelainZPaths(' M wiki/log.md\0')).toEqual(['wiki/log.md']);
  });

  test('takes a rename origin record whole, since it carries no status prefix', () => {
    expect(porcelainZPaths('R  app/new.ts\0app/old.ts\0')).toEqual([
      'app/new.ts',
      'app/old.ts',
    ]);
  });

  test('takes a copy origin record whole, exactly as a rename origin', () => {
    expect(porcelainZPaths('C  app/new.ts\0app/old.ts\0')).toEqual([
      'app/new.ts',
      'app/old.ts',
    ]);
  });

  test('does not read an origin path beginning with R or C as a status record', () => {
    expect(
      porcelainZPaths('R  Config/new\0Config/old\0 M package.json\0')
    ).toEqual(['Config/new', 'Config/old', 'package.json']);
  });

  test('never unquotes, since -z emits raw bytes and a quote can be part of a name', () => {
    expect(porcelainZPaths(' M wiki/Café Notes.md\0')).toEqual([
      'wiki/Café Notes.md',
    ]);
    expect(porcelainZPaths('?? wiki/"quoted" page.md\0')).toEqual([
      'wiki/"quoted" page.md',
    ]);
  });

  test('reports no paths for a clean tree', () => {
    expect(porcelainZPaths('')).toEqual([]);
  });
});
