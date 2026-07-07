import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {coveredClassesFromRules} from '../covered-classes.js';
import {markerComment} from '../marker.js';

describe('coveredClassesFromRules', () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(path.join(tmpdir(), 'gaia-rules-'));
  });

  afterEach(() => {
    rmSync(dir, {force: true, recursive: true});
  });

  test('reads the promoted finding_class from a provenance-marked rule', () => {
    writeFileSync(
      path.join(dir, 'switch-statement.md'),
      [
        '---',
        'paths: app/**/*.ts',
        '---',
        markerComment('rule/switch-statement'),
        '',
        '# Rule body',
      ].join('\n')
    );

    expect(coveredClassesFromRules(dir).has('rule/switch-statement')).toBe(
      true
    );
  });

  test('returns an empty set for a directory with no marked rules', () => {
    writeFileSync(path.join(dir, 'plain.md'), '# Just a rule\nno marker here');
    expect(coveredClassesFromRules(dir).size).toBe(0);
  });

  test('returns an empty set when the directory does not exist', () => {
    expect(coveredClassesFromRules(path.join(dir, 'nope')).size).toBe(0);
  });

  test('collects markers across multiple rule files', () => {
    // Deliberate abbreviated tail: the binder is prefix-bound / tail-agnostic,
    // so a copy that keeps the frozen prefix but shortens the tail still binds.
    // This is the ONE fixture that proves tail-agnosticism on purpose; every
    // other fixture uses markerComment(...) so it cannot silently drift.
    writeFileSync(
      path.join(dir, 'a.md'),
      '<!-- gaia-harden: promoted from recurring finding_class axe/color-contrast; never for non-recurrence -->'
    );
    writeFileSync(path.join(dir, 'b.md'), markerComment('knip/exports'));

    const covered = coveredClassesFromRules(dir);
    expect(covered.has('axe/color-contrast')).toBe(true);
    expect(covered.has('knip/exports')).toBe(true);
  });
});
