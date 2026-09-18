/**
 * Pins the tally's counting semantics (AUDIT directive 14): the audited-PR
 * predicate, per-auditor merge, and window PR-selection loop (`tally.ts`),
 * the collapse/aggregate/class-disposition pass that also derives the
 * audited-PR denominator (`compute-tally.ts`), and the findings-block
 * acceptance logic (`parse-findings-block.ts`). Each is wrapped in a
 * `// tally-semantics:start` / `// tally-semantics:end` region; this test
 * hashes the three regions together (comments stripped, whitespace
 * normalized) and pins the hash alongside the three constants that also
 * decide what counts as a candidate. A change to any of the six must bump
 * `TALLY_SCHEMA_VERSION` (`material-rise.ts`) and re-pin this test in the
 * same change, since a schema-version bump is what tells a stale review
 * snapshot to stop trusting its own counts (`triggers.ts`, rule 3).
 */
import {describe, expect, test} from 'vitest';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {RECURRENCE_THRESHOLD} from '../compute-tally.js';
import {TALLY_SCHEMA_VERSION} from '../material-rise.js';
import {WINDOW_DAYS} from '../tally.js';

const START_MARKER = '// tally-semantics:start';
const END_MARKER = '// tally-semantics:end';

const HERE = path.dirname(fileURLToPath(import.meta.url));

const SOURCE_FILES = [
  path.join(HERE, '..', 'tally.ts'),
  path.join(HERE, '..', 'compute-tally.ts'),
  path.join(HERE, '..', 'parse-findings-block.ts'),
];

/**
 * Extracts every tally-semantics region from `source`, marker lines
 * excluded. Throws when an `end` marker has no open `start`, when a `start`
 * is left open at end of file, or when the source carries no region at all.
 */
const extractRegions = (source: string): string[] => {
  const regions: string[] = [];
  let buffer: null | string[] = null;

  for (const line of source.split('\n')) {
    if (line.includes(START_MARKER)) {
      if (buffer !== null) {
        throw new Error('tally-semantics:start nested inside another region');
      }
      buffer = [];
    } else if (line.includes(END_MARKER)) {
      if (buffer === null) {
        throw new Error('tally-semantics:end with no open start');
      }
      regions.push(buffer.join('\n'));
      buffer = null;
    } else if (buffer !== null) {
      buffer.push(line);
    }
  }

  if (buffer !== null) {
    throw new Error('tally-semantics:start with no matching end');
  }

  if (regions.length === 0) throw new Error('no tally-semantics region found');

  return regions;
};

// Removes every `/* ... */` block comment with a manual scan rather than a
// regex, so nothing here relies on backtracking over an unbounded body.
const stripBlockComments = (text: string): string => {
  let result = '';
  let index = 0;

  while (index < text.length) {
    if (text.startsWith('/*', index)) {
      const end = text.indexOf('*/', index + 2);

      index = end === -1 ? text.length : end + 2;
    } else {
      result += text[index];
      index += 1;
    }
  }

  return result;
};

// Strips a `//` line comment from each line with a plain index scan (no
// regex backtracking risk), so a reworded or added `//` remark never moves
// the hash. A plain text pass: it would also strip a `//` inside a string
// literal, harmless here because no tally-semantics region holds one, and it
// is applied identically every run.
const stripLineComments = (text: string): string =>
  text
    .split('\n')
    .map((line) => {
      const index = line.indexOf('//');

      return index === -1 ? line : line.slice(0, index);
    })
    .join('\n');

// Strips `//` line comments and `/* ... */` block comments (JSDoc included),
// then collapses whitespace runs to one space and trims, so a reworded or
// added comment inside a region never moves the hash.
const normalizeForFingerprint = (text: string): string =>
  stripLineComments(stripBlockComments(text)).replaceAll(/\s+/g, ' ').trim();

const hashRegions = (regions: readonly string[]): string =>
  createHash('sha256')
    .update(regions.map(normalizeForFingerprint).join('\n'))
    .digest('hex');

describe('tally counting-semantics fingerprint', () => {
  test('21: the pinned fingerprint passes on the finished tree, with exactly three regions found', () => {
    const allRegions = SOURCE_FILES.flatMap((file) =>
      extractRegions(readFileSync(file, 'utf8'))
    );

    expect(allRegions).toHaveLength(3);

    expect({
      hash: hashRegions(allRegions),
      recurrenceThreshold: RECURRENCE_THRESHOLD,
      tallySchemaVersion: TALLY_SCHEMA_VERSION,
      windowDays: WINDOW_DAYS,
    }).toEqual({
      hash: '3f4231eb6ba66cccecad9cc4bdf8e40a0182d17b49b2f0be25e1d29e053d67d7',
      recurrenceThreshold: 3,
      tallySchemaVersion: 1,
      windowDays: 90,
    });
  });

  test('22: refusal — the hash moves on a code change, and the extractor throws on a missing start, a missing end, or zero regions', () => {
    const original = [
      'const x = 1;',
      START_MARKER,
      'const y = 2;',
      END_MARKER,
      '',
    ].join('\n');
    const changed = original.replace('const y = 2;', 'const y = 3;');

    expect(hashRegions(extractRegions(original))).not.toBe(
      hashRegions(extractRegions(changed))
    );

    expect(() => extractRegions(`const y = 2;\n${END_MARKER}\n`)).toThrow(
      'tally-semantics:end with no open start'
    );
    expect(() => extractRegions(`${START_MARKER}\nconst y = 2;\n`)).toThrow(
      'tally-semantics:start with no matching end'
    );
    expect(() => extractRegions('const y = 2;\n')).toThrow(
      'no tally-semantics region found'
    );
  });

  test('23: comment tolerance — an added, reworded, or block comment inside a region hashes identically to the original', () => {
    const base = [START_MARKER, 'const y = 2; // keep', END_MARKER, ''].join(
      '\n'
    );
    const withAddedLineComment = [
      START_MARKER,
      '// a new remark',
      'const y = 2; // keep',
      END_MARKER,
      '',
    ].join('\n');
    const withReworded = [
      START_MARKER,
      'const y = 2; // reworded remark',
      END_MARKER,
      '',
    ].join('\n');
    const withBlockComment = [
      START_MARKER,
      '/**',
      ' * A block comment.',
      ' */',
      'const y = 2; // keep',
      END_MARKER,
      '',
    ].join('\n');

    const baseHash = hashRegions(extractRegions(base));

    expect(hashRegions(extractRegions(withAddedLineComment))).toBe(baseHash);
    expect(hashRegions(extractRegions(withReworded))).toBe(baseHash);
    expect(hashRegions(extractRegions(withBlockComment))).toBe(baseHash);
  });
});
