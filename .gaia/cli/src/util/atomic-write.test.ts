import {
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {atomicWriteFile, atomicWriteFileSync} from './atomic-write.js';

describe('atomic-write', () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(path.join(tmpdir(), 'gaia-atomic-'));
  });

  afterEach(() => {
    rmSync(dir, {force: true, recursive: true});
  });

  test('atomicWriteFileSync writes content to a new file', () => {
    const target = path.join(dir, 'out.txt');

    atomicWriteFileSync(target, 'hello');

    expect(readFileSync(target, 'utf8')).toBe('hello');
  });

  test('atomicWriteFileSync replaces an existing file', () => {
    const target = path.join(dir, 'out.txt');
    writeFileSync(target, 'old', 'utf8');

    atomicWriteFileSync(target, 'new');

    expect(readFileSync(target, 'utf8')).toBe('new');
  });

  test('atomicWriteFileSync leaves no temp files behind', () => {
    const target = path.join(dir, 'out.txt');

    atomicWriteFileSync(target, 'hello');

    expect(readdirSync(dir)).toEqual(['out.txt']);
  });

  test('atomicWriteFileSync applies the requested file mode', () => {
    const target = path.join(dir, 'secret.txt');

    atomicWriteFileSync(target, 'x', {mode: 0o600});

    expect(statSync(target).mode & 0o777).toBe(0o600);
  });

  test('atomicWriteFile (async) writes content and leaves no temp files', async () => {
    const target = path.join(dir, 'async.txt');

    await atomicWriteFile(target, 'async hello');

    expect(readFileSync(target, 'utf8')).toBe('async hello');
    expect(readdirSync(dir)).toEqual(['async.txt']);
  });
});
