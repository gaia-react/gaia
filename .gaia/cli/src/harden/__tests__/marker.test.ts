/**
 * Guard for the frozen provenance marker (`marker.ts`).
 *
 * The marker is hand-copied into three doc surfaces (`harden.md`, `audit.md`,
 * and the Policy-Memory Loop wiki page) and matched by two independent binders
 * (`covered-classes.ts` prefix-bound, `/gaia-audit` full-text). This guard binds
 * every copy plus the regex to `markerComment(...)` so a drifted copy fails the
 * suite instead of silently breaking one binder.
 */
import {describe, expect, test} from 'vitest';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';
import {coveredClassesFromRules} from '../covered-classes.js';
import {MARKER_PREFIX, markerComment} from '../marker.js';

const REPO_ROOT = resolveRepoRootFromImportMeta(import.meta.url);

const readRepoFile = (relative: string): string =>
  readFileSync(path.join(REPO_ROOT, relative), 'utf8');

const occurrences = (haystack: string, needle: string): number =>
  haystack.split(needle).length - 1;

describe('provenance marker constant', () => {
  test('MARKER_PREFIX is the stable head of markerComment for any class', () => {
    const literal = markerComment('anything');
    expect(literal.startsWith(`<!-- ${MARKER_PREFIX} `)).toBe(true);
    expect(literal).toContain(MARKER_PREFIX);
  });

  test('the covered-classes binder matches the marker and captures the class', () => {
    const dir = mkdtempSync(path.join(tmpdir(), 'gaia-marker-'));

    try {
      writeFileSync(
        path.join(dir, 'rule.md'),
        markerComment('rule/switch-statement')
      );

      expect(coveredClassesFromRules(dir).has('rule/switch-statement')).toBe(
        true
      );
    } finally {
      rmSync(dir, {force: true, recursive: true});
    }
  });

  describe('every doc copy reproduces markerComment verbatim', () => {
    const literal = markerComment('<class>');

    test('harden.md carries it at the template site and the frozen-marker section', () => {
      const body = readRepoFile('.claude/skills/gaia/references/harden.md');
      expect(occurrences(body, literal)).toBeGreaterThanOrEqual(2);
    });

    test('audit.md carries it', () => {
      expect(readRepoFile('.claude/skills/gaia/references/audit.md')).toContain(
        literal
      );
    });

    test('the Policy-Memory Loop wiki page carries it', () => {
      expect(readRepoFile('wiki/concepts/Policy-Memory Loop.md')).toContain(
        literal
      );
    });
  });
});
