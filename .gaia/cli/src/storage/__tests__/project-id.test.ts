/* eslint-disable no-bitwise -- POSIX file modes are bitfields; `& 0o777`
   is the standard idiom for masking off the permission bits. */
import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {existsSync, mkdtempSync, readFileSync, rmSync, statSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import type {StorageRoots} from '../paths.js';
import {readOrCreateProjectId} from '../project-id.js';

const UUID_V4_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;

/**
 * The roots for a given repo root, built directly rather than through
 * `resolveStorageRoots`. These tests exercise the id writer — derivation,
 * idempotence, mode, parent creation — not the resolution that decides which
 * checkout owns the file; that is `paths.test.ts`, which needs real git
 * sandboxes. Keeping them separate lets these run against a plain temp dir.
 */
const rootsFor = (repoRoot: string): StorageRoots => ({
  mainRoot: repoRoot,
  projectIdPath: path.join(repoRoot, '.gaia', 'local', '.project-id'),
});

describe('readOrCreateProjectId', () => {
  let repoRoot: string;

  beforeEach(() => {
    repoRoot = mkdtempSync(path.join(tmpdir(), 'gaia-pid-repo-'));
  });

  afterEach(() => {
    rmSync(repoRoot, {force: true, recursive: true});
  });

  test('writes a UUIDv4-shaped id with mode 644 on first call', () => {
    const roots = rootsFor(repoRoot);

    const id = readOrCreateProjectId(roots);

    expect(id).toMatch(UUID_V4_RE);
    expect(existsSync(roots.projectIdPath)).toBe(true);
    expect(statSync(roots.projectIdPath).mode & 0o777).toBe(0o644);
    expect(readFileSync(roots.projectIdPath, 'utf8').trim()).toBe(id);
  });

  test('returns the same id on subsequent calls (idempotent)', () => {
    const roots = rootsFor(repoRoot);

    const first = readOrCreateProjectId(roots);
    const second = readOrCreateProjectId(roots);

    expect(second).toBe(first);
  });

  test('derives a stable id from the repo root path (same input -> same output)', () => {
    const repoA = mkdtempSync(path.join(tmpdir(), 'gaia-pid-stable-A-'));

    try {
      const rootsA1 = rootsFor(repoA);
      const idA1 = readOrCreateProjectId(rootsA1);
      // Wipe the file; recompute from scratch.
      rmSync(rootsA1.projectIdPath, {force: true});
      const idA2 = readOrCreateProjectId(rootsA1);
      expect(idA2).toBe(idA1);
    } finally {
      rmSync(repoA, {force: true, recursive: true});
    }
  });

  test('different repo roots derive different ids', () => {
    const repoA = mkdtempSync(path.join(tmpdir(), 'gaia-pid-distinct-A-'));
    const repoB = mkdtempSync(path.join(tmpdir(), 'gaia-pid-distinct-B-'));

    try {
      const rootsA = rootsFor(repoA);
      const rootsB = rootsFor(repoB);
      const idA = readOrCreateProjectId(rootsA);
      const idB = readOrCreateProjectId(rootsB);
      expect(idA).not.toBe(idB);
    } finally {
      rmSync(repoA, {force: true, recursive: true});
      rmSync(repoB, {force: true, recursive: true});
    }
  });

  test("the derived id depends only on mainRoot, not on projectIdPath's own location (change 2: hash target is mainRoot)", () => {
    // Two StorageRoots that share a mainRoot but point at different
    // projectIdPath locations must derive the SAME id: both hash the same
    // mainRoot string, and nothing else.
    const mainRoot = path.join(repoRoot, 'shared-main-root');
    const projectIdPathA = path.join(
      repoRoot,
      'a',
      '.gaia',
      'local',
      '.project-id'
    );
    const projectIdPathB = path.join(
      repoRoot,
      'b',
      '.gaia',
      'local',
      '.project-id'
    );

    const idA = readOrCreateProjectId({
      mainRoot,
      projectIdPath: projectIdPathA,
    });
    const idB = readOrCreateProjectId({
      mainRoot,
      projectIdPath: projectIdPathB,
    });

    expect(idA).toBe(idB);
  });

  test('creates the parent .gaia/local/ directory if absent', () => {
    const roots = rootsFor(repoRoot);

    expect(existsSync(path.dirname(roots.projectIdPath))).toBe(false);

    const id = readOrCreateProjectId(roots);

    expect(existsSync(path.dirname(roots.projectIdPath))).toBe(true);
    expect(id).toMatch(UUID_V4_RE);
  });
});
