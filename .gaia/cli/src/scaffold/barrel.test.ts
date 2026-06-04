import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {insertIntoBarrel} from './barrel.js';

type Sandbox = {
  cleanup: () => void;
  dir: string;
};

const setupSandbox = (): Sandbox => {
  const dir = mkdtempSync(path.join(tmpdir(), 'gaia-barrel-'));

  return {
    cleanup: () => {
      rmSync(dir, {force: true, recursive: true});
    },
    dir,
  };
};

const writeBarrel = (dir: string, body: string): string => {
  const filePath = path.join(dir, 'index.ts');
  writeFileSync(filePath, body, 'utf8');

  return filePath;
};

const read = (filePath: string): string => readFileSync(filePath, 'utf8');

describe('insertIntoBarrel', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('inserts a new export at the alphabetically correct position', () => {
    const filePath = writeBarrel(
      sandbox.dir,
      [
        "export * from './alpha';",
        "export * from './charlie';",
        "export * from './delta';",
        '',
      ].join('\n')
    );

    insertIntoBarrel(filePath, "export * from './bravo';");

    expect(read(filePath)).toBe(
      [
        "export * from './alpha';",
        "export * from './bravo';",
        "export * from './charlie';",
        "export * from './delta';",
        '',
      ].join('\n')
    );
  });

  test('is idempotent: second call with same line is a no-op', () => {
    const filePath = writeBarrel(
      sandbox.dir,
      ["export * from './alpha';", "export * from './charlie';", ''].join('\n')
    );

    insertIntoBarrel(filePath, "export * from './bravo';");
    const afterFirst = read(filePath);
    insertIntoBarrel(filePath, "export * from './bravo';");
    const afterSecond = read(filePath);

    expect(afterFirst).toBe(afterSecond);
    // Verify only one occurrence of the inserted line.
    const matches = afterSecond.match(/export \* from '\.\/bravo';/gu);
    expect(matches).not.toBeNull();
    expect(matches).toHaveLength(1);
  });

  test('inserts before lexicographically-larger first entry', () => {
    const filePath = writeBarrel(
      sandbox.dir,
      ["export * from './charlie';", "export * from './delta';", ''].join('\n')
    );

    insertIntoBarrel(filePath, "export * from './bravo';");

    expect(read(filePath)).toBe(
      [
        "export * from './bravo';",
        "export * from './charlie';",
        "export * from './delta';",
        '',
      ].join('\n')
    );
  });

  test('appends after lexicographically-smaller last entry', () => {
    const filePath = writeBarrel(
      sandbox.dir,
      ["export * from './alpha';", "export * from './bravo';", ''].join('\n')
    );

    insertIntoBarrel(filePath, "export * from './charlie';");

    expect(read(filePath)).toBe(
      [
        "export * from './alpha';",
        "export * from './bravo';",
        "export * from './charlie';",
        '',
      ].join('\n')
    );
  });

  test('preserves leading comments and blank lines', () => {
    const filePath = writeBarrel(
      sandbox.dir,
      [
        '// barrel for the foo namespace',
        '',
        "export * from './alpha';",
        "export * from './charlie';",
        '',
      ].join('\n')
    );

    insertIntoBarrel(filePath, "export * from './bravo';");

    expect(read(filePath)).toBe(
      [
        '// barrel for the foo namespace',
        '',
        "export * from './alpha';",
        "export * from './bravo';",
        "export * from './charlie';",
        '',
      ].join('\n')
    );
  });

  test('preserves trailing newline at EOF', () => {
    const filePath = writeBarrel(
      sandbox.dir,
      ["export * from './alpha';", ''].join('\n')
    );

    insertIntoBarrel(filePath, "export * from './bravo';");

    expect(read(filePath).endsWith('\n')).toBe(true);
  });

  test('preserves absent trailing newline at EOF', () => {
    const filePath = writeBarrel(
      sandbox.dir,
      ["export * from './alpha';", "export * from './charlie';"].join('\n')
    );

    insertIntoBarrel(filePath, "export * from './bravo';");

    expect(read(filePath).endsWith('\n')).toBe(false);
  });

  test('handles named-export form (export {Foo} from)', () => {
    const filePath = writeBarrel(
      sandbox.dir,
      [
        "export {Alpha} from './alpha';",
        "export {Charlie} from './charlie';",
        '',
      ].join('\n')
    );

    insertIntoBarrel(filePath, "export {Bravo} from './bravo';");

    expect(read(filePath)).toBe(
      [
        "export {Alpha} from './alpha';",
        "export {Bravo} from './bravo';",
        "export {Charlie} from './charlie';",
        '',
      ].join('\n')
    );
  });

  test('appends to a file with no existing export-from lines', () => {
    const filePath = writeBarrel(
      sandbox.dir,
      ['// placeholder barrel', ''].join('\n')
    );

    insertIntoBarrel(filePath, "export * from './alpha';");

    const after = read(filePath);
    expect(after).toContain("export * from './alpha';");
    expect(after.endsWith('\n')).toBe(true);
  });
});
