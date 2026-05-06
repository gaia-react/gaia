/* eslint-disable no-bitwise -- POSIX file modes are bitfields; `& 0o777`
   is the standard idiom for masking off the permission bits. */
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
import {readOrCreateInstallId} from '../install-id.js';
import {
  ensureMentorshipDirs as ensureMentorshipDirectories,
  resolveStorageRoots,
} from '../paths.js';

describe('readOrCreateInstallId', () => {
  let repoRoot: string;
  let homeDirectory: string;

  beforeEach(async () => {
    repoRoot = mkdtempSync(path.join(tmpdir(), 'gaia-iid-repo-'));
    homeDirectory = mkdtempSync(path.join(tmpdir(), 'gaia-iid-home-'));
    const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});
    await ensureMentorshipDirectories(roots);
  });

  afterEach(() => {
    rmSync(repoRoot, {force: true, recursive: true});
    rmSync(homeDirectory, {force: true, recursive: true});
  });

  test('writes a 26-char ULID with mode 600 on first call', () => {
    const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});

    const id = readOrCreateInstallId(roots);

    expect(id).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/u);
    expect(existsSync(roots.installIdPath)).toBe(true);
    expect(statSync(roots.installIdPath).mode & 0o777).toBe(0o600);
    expect(readFileSync(roots.installIdPath, 'utf8').trim()).toBe(id);
  });

  test('returns the same ULID without rewriting on second call', () => {
    const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});

    const first = readOrCreateInstallId(roots);
    const second = readOrCreateInstallId(roots);

    expect(second).toBe(first);
    expect(readFileSync(roots.installIdPath, 'utf8').trim()).toBe(first);
  });

  test('regenerates if the file is malformed (wrong length)', () => {
    const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});
    writeFileSync(roots.installIdPath, 'truncated\n', {mode: 0o600});

    const id = readOrCreateInstallId(roots);

    expect(id).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/u);
    expect(readFileSync(roots.installIdPath, 'utf8').trim()).toBe(id);
  });
});
