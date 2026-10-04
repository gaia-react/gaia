/* eslint-disable unicorn/prevent-abbreviations -- the module under test is named dev-ports */
import {afterEach, describe, expect, test} from 'vitest';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const frontendDirectory = path.resolve(import.meta.dirname, '..');
const FORBIDDEN_LITERALS = [/\b5173\b/, /\b6006\b/];

const explicitFiles = [
  'vite.config.ts',
  'playwright.config.ts',
  'package.json',
  'dev-ports-vite-plugin.ts',
  'dev-ports-reuse.ts',
];

const listTypeScriptFiles = (directory: string): string[] =>
  fs
    .readdirSync(directory, {recursive: true, withFileTypes: true})
    .filter((entry) => entry.isFile() && entry.name.endsWith('.ts'))
    .map((entry) => path.join(entry.parentPath, entry.name))
    .filter((file) => !file.includes(`${path.sep}output${path.sep}`));

const scannedFiles = (): string[] => [
  ...explicitFiles.map((file) => path.join(frontendDirectory, file)),
  ...listTypeScriptFiles(path.join(frontendDirectory, '.playwright')),
  ...listTypeScriptFiles(path.join(frontendDirectory, '.storybook')),
];

const findLiterals = (files: string[]): string[] =>
  files.flatMap((file) => {
    const text = fs.readFileSync(file, 'utf8');

    return FORBIDDEN_LITERALS.filter((literal) => literal.test(text)).map(
      (literal) => `${file}: ${literal.source}`
    );
  });

let scratchDirectory: string | undefined;

afterEach(() => {
  if (scratchDirectory !== undefined) {
    fs.rmSync(scratchDirectory, {force: true, recursive: true});
    scratchDirectory = undefined;
  }
});

describe('port literals in config files', () => {
  test('the scanned set is the expected non-empty set and every file exists', () => {
    const files = scannedFiles();

    for (const file of explicitFiles) {
      expect(files).toContain(path.join(frontendDirectory, file));
      expect(fs.existsSync(path.join(frontendDirectory, file))).toBe(true);
    }
    expect(
      files.some((file) =>
        file.endsWith(path.join('.playwright', 'global-setup.ts'))
      )
    ).toBe(true);
    expect(
      files.some((file) => file.endsWith(path.join('.storybook', 'main.ts')))
    ).toBe(true);
  });

  test('a scratch file holding a hardcoded dev url is caught (the check can fail)', () => {
    scratchDirectory = fs.mkdtempSync(
      path.join(os.tmpdir(), 'dev-ports-static-')
    );
    const scratchFile = path.join(scratchDirectory, 'bad.ts');
    fs.writeFileSync(
      scratchFile,
      "export const url = 'http://localhost:5173';\n"
    );

    expect(findLiterals([scratchFile])).toHaveLength(1);
  });

  test('a scratch file holding a hardcoded Storybook port is caught', () => {
    scratchDirectory = fs.mkdtempSync(
      path.join(os.tmpdir(), 'dev-ports-static-')
    );
    const scratchFile = path.join(scratchDirectory, 'bad.json');
    fs.writeFileSync(scratchFile, '{"storybook": "storybook dev -p 6006"}\n');

    expect(findLiterals([scratchFile])).toHaveLength(1);
  });

  test('no scanned config file carries a 5173 or 6006 literal', () => {
    expect(findLiterals(scannedFiles())).toEqual([]);
  });
});
