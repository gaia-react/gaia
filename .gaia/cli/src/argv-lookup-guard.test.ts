/**
 * Maintainer guard: a string-keyed lookup table is never read by a bare index.
 *
 * A bare index into a `Record<string, …>` resolves every `Object.prototype`
 * member, so a table read with an externally-supplied key returns a truthy
 * inherited value for `constructor`, `toString`, `__proto__`, and the rest.
 * The value then survives the caller's `=== undefined` check and is dispatched
 * or consumed as though it named a real entry.
 *
 * # Why this needs a guard rather than a sweep
 *
 * The class recreates itself out of ordinary editing. A new subcommand domain
 * is written by copying an existing `index.ts`, and whether the copy carries
 * the guard depends on which file was copied: ten dispatchers were unguarded
 * against three that were, all from the same template. Nothing reported it,
 * because the wrong behavior only shows for argv tokens nobody types by
 * accident, and two of the outcomes are a silent exit 0.
 *
 * Routing every read through `util/argv.ts`'s `lookupOwn` is what makes the
 * guard non-optional; this test is what keeps a future bare index from
 * quietly reintroducing the class.
 *
 * # What counts as an offense
 *
 * A `NAME[`, `NAME?.[`, or `NAME [` read of a `const NAME` whose declared type
 * is a string-keyed `Record`, unless that same line guards it with
 * `Object.hasOwn(NAME,`. The exemption names the table rather than the line, so
 * a guard on one table never excuses a bare read of another beside it.
 *
 * The declared type is read from the joined declaration head, not the opening
 * line: every dispatcher spells its table across three lines, and a single-line
 * test matched none of them while reporting the tree clean.
 *
 * Union-keyed tables (`Record<ToolId, …>`) are exempt: the compiler already
 * proves the key is a member, so no prototype key can reach them.
 *
 * Repair, when this goes red: read through `lookupOwn(TABLE, key)`.
 *
 * Maintainer-only by construction: `.gaia/cli/src` is release-excluded, so an
 * adopter clone carries neither these sources nor this test, and the suite
 * skips there. Mirrors `command-reachability.test.ts`.
 */
import {describe, expect, test} from 'vitest';
import {existsSync, readdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from './util/repo-root-fixture.js';

const CLI_SRC = path.join(
  resolveRepoRootFromImportMeta(import.meta.url),
  '.gaia/cli/src'
);

/**
 * A declaration opener. The type annotation is read from the joined head
 * below, never from this line alone: every dispatcher in the tree spells its
 * table across three lines, so a single-line test sees none of them.
 */
const TABLE_OPENER = /^(?:export )?const ([A-Za-z_]\w*)\s*:/u;

/** The string-keyed annotation, tested against a joined declaration head. */
const STRING_KEYED = /Record<\s*string\s*,/u;

/** How many lines a declaration head may span before `= `. */
const HEAD_WINDOW = 8;

/**
 * The dispatchers whose bare index this guard exists to catch. Named rather
 * than discovered: a scan that finds its own subjects reports success when it
 * finds none, which is the failure this list makes impossible.
 */
const DISPATCHERS = [
  'automation/index.ts',
  'fitness/index.ts',
  'index.maintainer.ts',
  'index.ts',
  'init/index.ts',
  'react-perf/index.ts',
  'release/index.ts',
  'sandbox/index.ts',
  'setup-ci/index.ts',
  'setup/index.ts',
  'update-deps/index.ts',
  'update/index.ts',
  'wiki/index.ts',
];

const sourceFiles = (): string[] =>
  (readdirSync(CLI_SRC, {recursive: true}) as string[])
    .filter((name) => name.endsWith('.ts') && !name.endsWith('.test.ts'))
    .filter((name) => !name.includes('__tests__'))
    .toSorted((left, right) => left.localeCompare(right));

/** The declaration head at `start`: everything up to and including the `=`. */
const headAt = (lines: readonly string[], start: number): string => {
  const window = lines.slice(start, start + HEAD_WINDOW);
  const end = window.findIndex((line) => line.includes('='));

  return (end === -1 ? window : window.slice(0, end + 1)).join(' ');
};

export const tablesIn = (lines: readonly string[]): string[] =>
  lines.flatMap((line, index) => {
    const name = TABLE_OPENER.exec(line)?.[1];

    return name !== undefined && STRING_KEYED.test(headAt(lines, index)) ?
        [name]
      : [];
  });

/** `TABLE[key]`, `TABLE?.[key]`, and `TABLE [key]` all read the same way. */
const readsBare = (line: string, table: string): boolean =>
  new RegExp(String.raw`\b${table}\s*(?:\?\.)?\[`, 'u').test(line) &&
  !line.includes(`Object.hasOwn(${table},`);

export const offendersInLines = (
  lines: readonly string[],
  relative: string
): string[] => {
  const tables = tablesIn(lines);

  return lines.flatMap((line, index) =>
    tables
      .filter((table) => readsBare(line, table))
      .map((table) => `${relative}:${index + 1} ${table}[…]`)
  );
};

const offendersIn = (relative: string): string[] =>
  offendersInLines(
    readFileSync(path.join(CLI_SRC, relative), 'utf8').split('\n'),
    relative
  );

describe('string-keyed lookup tables are read through lookupOwn', () => {
  test.runIf(existsSync(CLI_SRC))('no bare index remains', () => {
    const offenders = sourceFiles().flatMap((file) => offendersIn(file));

    expect(offenders).toEqual([]);
  });

  test.runIf(existsSync(CLI_SRC))('the scan reaches the sources', () => {
    expect(sourceFiles().length).toBeGreaterThan(100);
  });

  test.runIf(existsSync(CLI_SRC))('every dispatcher table is seen', () => {
    const seen = DISPATCHERS.map((file) => ({
      file,
      tables: tablesIn(
        readFileSync(path.join(CLI_SRC, file), 'utf8').split('\n')
      ),
    }));

    expect(seen).toEqual(
      DISPATCHERS.map((file) => ({file, tables: ['SUBCOMMAND_HANDLERS']}))
    );
  });

  test.each(DISPATCHERS)('a bare index in %s is reported', (file) => {
    const reverted = readFileSync(path.join(CLI_SRC, file), 'utf8')
      .replace(
        'lookupOwn(SUBCOMMAND_HANDLERS, subcommand)',
        'SUBCOMMAND_HANDLERS[subcommand]'
      )
      .split('\n');

    expect(offendersInLines(reverted, file)).toHaveLength(1);
  });

  test('the multi-line declaration form is matched', () => {
    expect(
      tablesIn([
        'const SUBCOMMAND_HANDLERS: Readonly<',
        '  Partial<Record<string, SubcommandHandler>>',
        '> = {',
      ])
    ).toEqual(['SUBCOMMAND_HANDLERS']);
  });

  test('an exported table is matched', () => {
    expect(
      tablesIn(['export const A: Readonly<Record<string, string>> = {};'])
    ).toEqual(['A']);
  });

  test('a union-keyed table is skipped', () => {
    expect(
      tablesIn([
        'const TOOL_ID_TO_CONFIG_KEY: Readonly<Record<ToolId, ToolConfigKey>> = {',
      ])
    ).toEqual([]);
  });

  test.each(['A[key]', 'A?.[key]', 'A [key]'])('%s reads bare', (line) => {
    expect(
      offendersInLines(
        ['const A: Readonly<Record<string, string>> = {};', line],
        'f.ts'
      )
    ).toEqual(['f.ts:2 A[…]']);
  });

  test('a guarded read of the same table is exempt', () => {
    expect(
      offendersInLines(
        [
          'const A: Readonly<Record<string, string>> = {};',
          'Object.hasOwn(A, k) ? A[k] : undefined;',
        ],
        'f.ts'
      )
    ).toEqual([]);
  });

  test('a guard on a different table does not exempt the read', () => {
    expect(
      offendersInLines(
        [
          'const A: Readonly<Record<string, string>> = {};',
          'Object.hasOwn(B, k) ? A[k] : undefined;',
        ],
        'f.ts'
      )
    ).toEqual(['f.ts:2 A[…]']);
  });
});
