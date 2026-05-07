import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {ensureDir, writeFileIfAbsent} from './fs.js';

type Sandbox = {
  cleanup: () => void;
  dir: string;
};

const setupSandbox = (): Sandbox => {
  const dir = mkdtempSync(path.join(tmpdir(), 'gaia-scaffold-fs-'));

  return {
    cleanup: () => {
      rmSync(dir, {force: true, recursive: true});
    },
    dir,
  };
};

describe('ensureDir', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('creates a deep directory chain when absent', () => {
    const target = path.join(sandbox.dir, 'a', 'b', 'c');

    ensureDir(target);

    expect(existsSync(target)).toBe(true);
    expect(statSync(target).isDirectory()).toBe(true);
  });

  test('is a no-op when the directory already exists', () => {
    const target = path.join(sandbox.dir, 'already');
    ensureDir(target);

    expect(() => {
      ensureDir(target);
    }).not.toThrow();
    expect(existsSync(target)).toBe(true);
  });
});

describe('writeFileIfAbsent', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('writes a new file when absent and returns {written: true}', () => {
    const target = path.join(sandbox.dir, 'new-file.txt');

    const result = writeFileIfAbsent(target, 'hello');

    expect(result).toEqual({written: true});
    expect(readFileSync(target, 'utf8')).toBe('hello');
  });

  test('returns {written: false} when file exists with identical contents', () => {
    const target = path.join(sandbox.dir, 'identical.txt');
    writeFileSync(target, 'same', 'utf8');

    const result = writeFileIfAbsent(target, 'same');

    expect(result).toEqual({written: false});
    expect(readFileSync(target, 'utf8')).toBe('same');
  });

  test('throws when file exists with different contents', () => {
    const target = path.join(sandbox.dir, 'diff.txt');
    writeFileSync(target, 'original', 'utf8');

    expect(() => {
      writeFileIfAbsent(target, 'replacement');
    }).toThrow(/refusing to overwrite/u);
    // File should remain untouched.
    expect(readFileSync(target, 'utf8')).toBe('original');
  });

  test('creates parent directories when needed', () => {
    const target = path.join(sandbox.dir, 'deep', 'nested', 'file.txt');

    const result = writeFileIfAbsent(target, 'contents');

    expect(result).toEqual({written: true});
    expect(readFileSync(target, 'utf8')).toBe('contents');
  });
});
