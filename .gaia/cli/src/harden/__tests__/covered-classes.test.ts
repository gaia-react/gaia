import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, it} from 'vitest';
import {coveredClassesFromRules} from '../covered-classes.js';

describe('coveredClassesFromRules', () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(path.join(tmpdir(), 'gaia-rules-'));
  });

  afterEach(() => {
    rmSync(dir, {force: true, recursive: true});
  });

  it('reads the promoted finding_class from a provenance-marked rule', () => {
    writeFileSync(
      path.join(dir, 'switch-statement.md'),
      [
        '---',
        'paths: app/**/*.ts',
        '---',
        '<!-- gaia-harden: promoted from recurring finding_class rule/switch-statement; pruned by /gaia-audit on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->',
        '',
        '# Rule body',
      ].join('\n')
    );

    expect(coveredClassesFromRules(dir).has('rule/switch-statement')).toBe(true);
  });

  it('returns an empty set for a directory with no marked rules', () => {
    writeFileSync(path.join(dir, 'plain.md'), '# Just a rule\nno marker here');
    expect(coveredClassesFromRules(dir).size).toBe(0);
  });

  it('returns an empty set when the directory does not exist', () => {
    expect(coveredClassesFromRules(path.join(dir, 'nope')).size).toBe(0);
  });

  it('collects markers across multiple rule files', () => {
    writeFileSync(
      path.join(dir, 'a.md'),
      '<!-- gaia-harden: promoted from recurring finding_class axe/color-contrast; never for non-recurrence -->'
    );
    writeFileSync(
      path.join(dir, 'b.md'),
      '<!-- gaia-harden: promoted from recurring finding_class knip/exports; never for non-recurrence -->'
    );

    const covered = coveredClassesFromRules(dir);
    expect(covered.has('axe/color-contrast')).toBe(true);
    expect(covered.has('knip/exports')).toBe(true);
  });
});
