import {describe, expect, test} from 'vitest';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {
  appendRecords,
  DEFAULT_KEEP_WINDOW_DAYS,
  hasCoordinateRecord,
  readKeepWindowDays,
  readStore,
  STORE_RELATIVE_PATH,
  storeSuppression,
} from '../store.js';
import type {StoreRecord} from '../store.js';

// .gaia/cli/src/residue/__tests__ -> repo root is five levels up.
const REPO_ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../../../../'
);

const DAY_MS = 24 * 60 * 60 * 1000;

const storeFilePath = (root: string): string =>
  path.join(root, ...STORE_RELATIVE_PATH.split('/'));

const baseRecord = (overrides: Partial<StoreRecord> = {}): StoreRecord => ({
  cited_line_text: 'const a = 1;',
  class: 'holistic/unclassified',
  date: '2026-09-01T00:00:00Z',
  disposition: 'dismissed',
  line: 42,
  path: 'app/services/foo.ts',
  reason: 'not applicable here',
  schema: 'v1',
  source_pr: 1234,
  ...overrides,
});

type Sandbox = {cleanup: () => void; root: string};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-residue-store-'));
  mkdirSync(path.join(root, '.gaia'), {recursive: true});

  return {cleanup: () => rmSync(root, {force: true, recursive: true}), root};
};

const isoDaysAgo = (now: Date, days: number): string =>
  new Date(now.getTime() - days * DAY_MS).toISOString();

const containsExclusionLine = (filePath: string): boolean =>
  readFileSync(filePath, 'utf8')
    .split('\n')
    .some((line) => line.trim() === STORE_RELATIVE_PATH);

const expectRefusalLeavesStoreUnchanged = (
  root: string,
  badRecord: StoreRecord,
  fieldNamePattern: RegExp
): void => {
  appendRecords(root, [baseRecord({line: 1, reason: 'seed record'})]);
  const before = readFileSync(storeFilePath(root));

  expect(() => appendRecords(root, [badRecord])).toThrow(fieldNamePattern);

  const after = readFileSync(storeFilePath(root));
  expect(after.equals(before)).toBe(true);
};

describe('residue/store', () => {
  describe('round trip and shape', () => {
    test('appending two records and reading them back returns both, in order, fields preserved', () => {
      const sandbox = setupSandbox();

      try {
        const first = baseRecord({line: 1, path: 'a.ts', reason: 'one'});
        const second = baseRecord({
          disposition: 'kept',
          line: 2,
          path: 'b.ts',
          reason: 'two',
        });

        appendRecords(sandbox.root, [first, second]);

        const {records, skipped} = readStore(sandbox.root);

        expect(skipped).toEqual([]);
        expect(records).toHaveLength(2);
        expect(records[0]).toEqual(first);
        expect(records[1]).toEqual(second);
        expect(records[0]?.schema).toBe('v1');
        expect(records[1]?.schema).toBe('v1');
      } finally {
        sandbox.cleanup();
      }
    });

    test("a record's serialized line parses as JSON with exactly the nine contracted keys", () => {
      const sandbox = setupSandbox();

      try {
        appendRecords(sandbox.root, [baseRecord()]);

        const line = readFileSync(storeFilePath(sandbox.root), 'utf8')
          .trim()
          .split('\n', 1)[0];
        const parsed = JSON.parse(line ?? '{}') as Record<string, unknown>;

        expect(new Set(Object.keys(parsed))).toEqual(
          new Set([
            'cited_line_text',
            'class',
            'date',
            'disposition',
            'line',
            'path',
            'reason',
            'schema',
            'source_pr',
          ])
        );
      } finally {
        sandbox.cleanup();
      }
    });

    test('appending to a missing file creates it; appending again does not rewrite earlier lines', () => {
      const sandbox = setupSandbox();

      try {
        const filePath = storeFilePath(sandbox.root);

        appendRecords(sandbox.root, [baseRecord({line: 1})]);
        const firstContent = readFileSync(filePath, 'utf8');

        appendRecords(sandbox.root, [baseRecord({line: 2})]);
        const secondContent = readFileSync(filePath, 'utf8');

        expect(secondContent.startsWith(firstContent)).toBe(true);
        expect(secondContent.length).toBeGreaterThan(firstContent.length);
      } finally {
        sandbox.cleanup();
      }
    });

    test('a missing store reads as empty with no skipped entries and no throw', () => {
      const sandbox = setupSandbox();

      try {
        expect(() => readStore(sandbox.root)).not.toThrow();
        expect(readStore(sandbox.root)).toEqual({records: [], skipped: []});
      } finally {
        sandbox.cleanup();
      }
    });
  });

  describe('refusals', () => {
    test(// eslint-disable-next-line unicorn/prefer-string-raw -- vitest/valid-title requires a plain string title, not a tagged template
    'a record whose reason carries \\n is refused, and the store file is left unchanged', () => {
      const sandbox = setupSandbox();

      try {
        expectRefusalLeavesStoreUnchanged(
          sandbox.root,
          baseRecord({line: 2, reason: 'line one\nline two'}),
          /reason/
        );
      } finally {
        sandbox.cleanup();
      }
    });

    test(// eslint-disable-next-line unicorn/prefer-string-raw -- vitest/valid-title requires a plain string title, not a tagged template
    'a record whose cited_line_text carries \\n is refused, and the store file is left unchanged', () => {
      const sandbox = setupSandbox();

      try {
        expectRefusalLeavesStoreUnchanged(
          sandbox.root,
          baseRecord({
            cited_line_text: 'const a = 1;\nconst b = 2;',
            line: 2,
          }),
          /cited_line_text/
        );
      } finally {
        sandbox.cleanup();
      }
    });

    test(// eslint-disable-next-line unicorn/prefer-string-raw -- vitest/valid-title requires a plain string title, not a tagged template
    'a record whose class carries \\n is refused, and the store file is left unchanged', () => {
      const sandbox = setupSandbox();

      try {
        expectRefusalLeavesStoreUnchanged(
          sandbox.root,
          baseRecord({class: 'holistic/foo\nbar', line: 2}),
          /class/
        );
      } finally {
        sandbox.cleanup();
      }
    });

    test(// eslint-disable-next-line unicorn/prefer-string-raw -- vitest/valid-title requires a plain string title, not a tagged template
    'a record whose path carries \\n is refused, and the store file is left unchanged', () => {
      const sandbox = setupSandbox();

      try {
        expectRefusalLeavesStoreUnchanged(
          sandbox.root,
          baseRecord({line: 2, path: 'app/foo.ts\napp/bar.ts'}),
          /path/
        );
      } finally {
        sandbox.cleanup();
      }
    });

    test(// eslint-disable-next-line unicorn/prefer-string-raw -- vitest/valid-title requires a plain string title, not a tagged template
    'a record carrying \\r is refused the same way', () => {
      const sandbox = setupSandbox();

      try {
        expectRefusalLeavesStoreUnchanged(
          sandbox.root,
          baseRecord({line: 2, reason: 'line one\rline two'}),
          /reason/
        );
      } finally {
        sandbox.cleanup();
      }
    });

    test('a reason with a quote, a backslash, and a tab is accepted and round-trips byte-identically', () => {
      const sandbox = setupSandbox();

      try {
        const tricky = 'has "quotes", a \\backslash\\, and a\ttab';
        const record = baseRecord({reason: tricky});

        expect(() => appendRecords(sandbox.root, [record])).not.toThrow();

        const {records} = readStore(sandbox.root);
        expect(records[0]?.reason).toBe(tricky);
      } finally {
        sandbox.cleanup();
      }
    });
  });

  describe('degradation', () => {
    test('a second-line JSON parse failure is reported in skipped; the first and third records still read', () => {
      const sandbox = setupSandbox();

      try {
        const first = baseRecord({line: 1, path: 'a.ts'});
        const third = baseRecord({line: 3, path: 'c.ts'});
        const content = `${JSON.stringify(first)}\n{not json\n${JSON.stringify(third)}\n`;

        writeFileSync(storeFilePath(sandbox.root), content);

        const {records, skipped} = readStore(sandbox.root);

        expect(records).toHaveLength(2);
        expect(records[0]?.path).toBe('a.ts');
        expect(records[1]?.path).toBe('c.ts');
        expect(skipped).toHaveLength(1);
        expect(skipped[0]?.line_number).toBe(2);
        expect(skipped[0]?.reason.length).toBeGreaterThan(0);
      } finally {
        sandbox.cleanup();
      }
    });

    test('a record at an unknown schema is reported in skipped and excluded from records', () => {
      const sandbox = setupSandbox();

      try {
        const record = {...baseRecord(), schema: 'v2'};
        writeFileSync(
          storeFilePath(sandbox.root),
          `${JSON.stringify(record)}\n`
        );

        const {records, skipped} = readStore(sandbox.root);

        expect(records).toEqual([]);
        expect(skipped).toHaveLength(1);
        expect(skipped[0]?.line_number).toBe(1);
      } finally {
        sandbox.cleanup();
      }
    });

    test('a record carrying an unknown key is read, kept in records, and the key survives', () => {
      const sandbox = setupSandbox();

      try {
        const record = {...baseRecord(), future_field: 1};
        writeFileSync(
          storeFilePath(sandbox.root),
          `${JSON.stringify(record)}\n`
        );

        const {records, skipped} = readStore(sandbox.root);

        expect(skipped).toEqual([]);
        expect(records).toHaveLength(1);
        expect(
          (records[0] as unknown as Record<string, unknown>).future_field
        ).toBe(1);
      } finally {
        sandbox.cleanup();
      }
    });

    test('an unrecognized disposition is reported in skipped and still suppresses its coordinate', () => {
      const sandbox = setupSandbox();

      try {
        const record = {...baseRecord(), disposition: 'quarantined'};
        writeFileSync(
          storeFilePath(sandbox.root),
          `${JSON.stringify(record)}\n`
        );

        const {records, skipped} = readStore(sandbox.root);

        expect(records).toHaveLength(1);
        expect(skipped).toHaveLength(1);
        expect(skipped[0]?.reason).toMatch(/quarantined/);

        const verdict = storeSuppression(
          records,
          {
            cited_line_text: record.cited_line_text,
            line: record.line,
            path: record.path,
          },
          new Date(),
          DEFAULT_KEEP_WINDOW_DAYS,
          'content-bound'
        );

        expect(verdict).toEqual({
          record: records[0],
          suppressed: true,
          until: null,
        });
      } finally {
        sandbox.cleanup();
      }
    });
  });

  describe('suppression', () => {
    test('a dismissed record suppresses its coordinate with until: null, under both modes', () => {
      const record = baseRecord({disposition: 'dismissed'});
      const candidate = {
        cited_line_text: record.cited_line_text,
        line: record.line,
        path: record.path,
      };

      for (const mode of ['content-bound', 'coordinate-only'] as const) {
        const verdict = storeSuppression(
          [record],
          candidate,
          new Date(),
          DEFAULT_KEEP_WINDOW_DAYS,
          mode
        );

        expect(verdict).toEqual({record, suppressed: true, until: null});
      }
    });

    test('a kept record 3 days old suppresses with a non-null until; the same record 20 days old does not', () => {
      const now = new Date('2026-09-13T00:00:00Z');
      const candidate = {
        cited_line_text: 'const a = 1;',
        line: 42,
        path: 'app/services/foo.ts',
      };

      const recentlyKept = baseRecord({
        date: isoDaysAgo(now, 3),
        disposition: 'kept',
      });
      const recentVerdict = storeSuppression(
        [recentlyKept],
        candidate,
        now,
        DEFAULT_KEEP_WINDOW_DAYS,
        'content-bound'
      );

      expect(recentVerdict.suppressed).toBe(true);
      expect(recentVerdict.suppressed && recentVerdict.until).not.toBeNull();

      const staleKept = baseRecord({
        date: isoDaysAgo(now, 20),
        disposition: 'kept',
      });
      const staleVerdict = storeSuppression(
        [staleKept],
        candidate,
        now,
        DEFAULT_KEEP_WINDOW_DAYS,
        'content-bound'
      );

      expect(staleVerdict).toEqual({suppressed: false});
    });

    test('readKeepWindowDays parses GAIA_RESIDUE_KEEP_DAYS, falling back to the default', () => {
      expect(readKeepWindowDays({GAIA_RESIDUE_KEEP_DAYS: '30'})).toBe(30);
      expect(readKeepWindowDays({GAIA_RESIDUE_KEEP_DAYS: ''})).toBe(
        DEFAULT_KEEP_WINDOW_DAYS
      );
      expect(readKeepWindowDays({GAIA_RESIDUE_KEEP_DAYS: '0'})).toBe(
        DEFAULT_KEEP_WINDOW_DAYS
      );
      expect(readKeepWindowDays({GAIA_RESIDUE_KEEP_DAYS: '-1'})).toBe(
        DEFAULT_KEEP_WINDOW_DAYS
      );
      expect(readKeepWindowDays({GAIA_RESIDUE_KEEP_DAYS: 'abc'})).toBe(
        DEFAULT_KEEP_WINDOW_DAYS
      );
      expect(readKeepWindowDays({})).toBe(DEFAULT_KEEP_WINDOW_DAYS);
      expect(DEFAULT_KEEP_WINDOW_DAYS).toBe(14);
    });

    test('a record matching on path and line but with a different class still suppresses, under both modes', () => {
      const record = baseRecord({
        class: 'holistic/one',
        disposition: 'dismissed',
      });
      const candidate = {
        cited_line_text: record.cited_line_text,
        line: record.line,
        path: record.path,
      };

      for (const mode of ['content-bound', 'coordinate-only'] as const) {
        const verdict = storeSuppression(
          [{...record, class: 'holistic/different'}],
          candidate,
          new Date(),
          DEFAULT_KEEP_WINDOW_DAYS,
          mode
        );

        expect(verdict.suppressed).toBe(true);
      }
    });

    test('the mode split: content-bound honors the RD-007 bind, coordinate-only ignores it', () => {
      const record = baseRecord({
        cited_line_text: 'const a = 1;',
        disposition: 'dismissed',
      });
      const mismatchedCandidate = {
        cited_line_text: 'const a = 2;',
        line: record.line,
        path: record.path,
      };
      const matchedCandidate = {
        cited_line_text: 'const a = 1;',
        line: record.line,
        path: record.path,
      };

      expect(
        storeSuppression(
          [record],
          mismatchedCandidate,
          new Date(),
          DEFAULT_KEEP_WINDOW_DAYS,
          'content-bound'
        )
      ).toEqual({suppressed: false});

      expect(
        storeSuppression(
          [record],
          mismatchedCandidate,
          new Date(),
          DEFAULT_KEEP_WINDOW_DAYS,
          'coordinate-only'
        ).suppressed
      ).toBe(true);

      expect(
        storeSuppression(
          [record],
          matchedCandidate,
          new Date(),
          DEFAULT_KEEP_WINDOW_DAYS,
          'content-bound'
        ).suppressed
      ).toBe(true);
      expect(
        storeSuppression(
          [record],
          matchedCandidate,
          new Date(),
          DEFAULT_KEEP_WINDOW_DAYS,
          'coordinate-only'
        ).suppressed
      ).toBe(true);
    });

    test('hasCoordinateRecord is content-blind: true for any record at the coordinate, false otherwise', () => {
      const record = baseRecord({
        cited_line_text: 'this could not possibly match anything',
        line: 42,
        path: 'app/services/foo.ts',
      });

      expect(
        hasCoordinateRecord([record], {line: 42, path: 'app/services/foo.ts'})
      ).toBe(true);
      expect(
        hasCoordinateRecord([record], {line: 99, path: 'app/services/foo.ts'})
      ).toBe(false);
      expect(
        hasCoordinateRecord([record], {line: 42, path: 'app/other.ts'})
      ).toBe(false);
    });

    test('two records on one coordinate resolve on the last: an expired kept after an earlier dismissed is not suppressed', () => {
      const now = new Date('2026-09-13T00:00:00Z');
      const earlierDismissed = baseRecord({
        date: isoDaysAgo(now, 25),
        disposition: 'dismissed',
      });
      const laterExpiredKeep = baseRecord({
        date: isoDaysAgo(now, 20),
        disposition: 'kept',
      });
      const candidate = {
        cited_line_text: earlierDismissed.cited_line_text,
        line: earlierDismissed.line,
        path: earlierDismissed.path,
      };

      const verdict = storeSuppression(
        [earlierDismissed, laterExpiredKeep],
        candidate,
        now,
        DEFAULT_KEEP_WINDOW_DAYS,
        'content-bound'
      );

      expect(verdict).toEqual({suppressed: false});
    });
  });

  describe('distribution', () => {
    test("the repository's real release-exclude carries the store's exclusion line", () => {
      const realExcludePath = path.join(REPO_ROOT, '.gaia', 'release-exclude');

      expect(containsExclusionLine(realExcludePath)).toBe(true);
    });

    test('a scratch copy with the line removed reads red', () => {
      const sandbox = setupSandbox();

      try {
        const realExcludePath = path.join(
          REPO_ROOT,
          '.gaia',
          'release-exclude'
        );
        const withoutLine = readFileSync(realExcludePath, 'utf8')
          .split('\n')
          .filter((line) => line.trim() !== STORE_RELATIVE_PATH)
          .join('\n');
        const scratchPath = path.join(sandbox.root, 'release-exclude');

        writeFileSync(scratchPath, withoutLine);

        expect(containsExclusionLine(scratchPath)).toBe(false);
      } finally {
        sandbox.cleanup();
      }
    });
  });
});
