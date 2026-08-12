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
 * A `NAME[` read of a `const NAME` whose declared type is a string-keyed
 * `Record`, anywhere outside the line that owns the `Object.hasOwn` check.
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

/** `const NAME: …Record<string, …` — the string-keyed tables only. */
const STRING_KEYED_TABLE =
  /^const ([A-Za-z_]\w*)\s*:[^=]*Record<\s*string\s*,/u;

const sourceFiles = (): string[] =>
  (readdirSync(CLI_SRC, {recursive: true}) as string[])
    .filter((name) => name.endsWith('.ts') && !name.endsWith('.test.ts'))
    .filter((name) => !name.includes('__tests__'))
    .toSorted((left, right) => left.localeCompare(right));

const offendersIn = (relative: string): string[] => {
  const lines = readFileSync(path.join(CLI_SRC, relative), 'utf8').split('\n');
  const tables = lines.flatMap((line) => {
    const match = STRING_KEYED_TABLE.exec(line);

    return match?.[1] === undefined ? [] : [match[1]];
  });

  return lines.flatMap((line, index) =>
    tables
      .filter(
        (table) => line.includes(`${table}[`) && !line.includes('Object.hasOwn')
      )
      .map((table) => `${relative}:${index + 1} ${table}[…]`)
  );
};

describe('string-keyed lookup tables are read through lookupOwn', () => {
  test.runIf(existsSync(CLI_SRC))('no bare index remains', () => {
    const offenders = sourceFiles().flatMap((file) => offendersIn(file));

    expect(offenders).toEqual([]);
  });

  test.runIf(existsSync(CLI_SRC))('the scan reaches the sources', () => {
    expect(sourceFiles().length).toBeGreaterThan(100);
  });

  test.runIf(existsSync(CLI_SRC))('the pattern matches a known table', () => {
    expect(
      STRING_KEYED_TABLE.exec(
        'const SUBCOMMAND_HANDLERS: Readonly<Partial<Record<string, Handler>>> = {'
      )?.[1]
    ).toBe('SUBCOMMAND_HANDLERS');
  });

  test.runIf(existsSync(CLI_SRC))(
    'the pattern skips a union-keyed table',
    () => {
      expect(
        STRING_KEYED_TABLE.exec(
          'const TOOL_ID_TO_CONFIG_KEY: Readonly<Record<ToolId, ToolConfigKey>> = {'
        )
      ).toBeNull();
    }
  );
});
