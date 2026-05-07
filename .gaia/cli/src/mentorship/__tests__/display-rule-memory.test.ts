/**
 * Tests for `display-rule-memory.ts`.
 *
 * Strategy: build a tmp homedir, derive StorageRoots from it, exercise
 * install/remove/assert against the memory directory.
 */
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {resolveStorageRoots} from '../../storage/index.js';
import type {StorageRoots} from '../../storage/index.js';
import {
  DISPLAY_RULE_BODY,
  DISPLAY_RULE_FILE_NAME,
  DISPLAY_RULE_INDEX_LINE,
} from '../display-rule.js';
import {
  assertDisplayRule,
  installDisplayRule,
  removeDisplayRule,
} from '../display-rule-memory.js';

type Sandbox = {
  cleanup: () => void;
  homeDirectory: string;
  repoRoot: string;
  roots: StorageRoots;
};

const setupSandbox = (): Sandbox => {
  const repoRoot = mkdtempSync(path.join(tmpdir(), 'gaia-display-rule-repo-'));
  const homeDirectory = mkdtempSync(
    path.join(tmpdir(), 'gaia-display-rule-home-')
  );
  const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});

  return {
    cleanup: () => {
      rmSync(repoRoot, {force: true, recursive: true});
      rmSync(homeDirectory, {force: true, recursive: true});
    },
    homeDirectory,
    repoRoot,
    roots,
  };
};

describe('installDisplayRule', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('creates the memory directory and writes both files', () => {
    expect(existsSync(sandbox.roots.memoryDir)).toBe(false);

    installDisplayRule(sandbox.roots);

    const bodyPath = path.join(sandbox.roots.memoryDir, DISPLAY_RULE_FILE_NAME);
    const indexPath = path.join(sandbox.roots.memoryDir, 'MEMORY.md');
    expect(existsSync(bodyPath)).toBe(true);
    expect(existsSync(indexPath)).toBe(true);
    expect(readFileSync(bodyPath, 'utf8')).toBe(DISPLAY_RULE_BODY);
    expect(readFileSync(indexPath, 'utf8')).toContain(DISPLAY_RULE_INDEX_LINE);
  });

  test('overwrites the body file with the canonical text on re-install', () => {
    installDisplayRule(sandbox.roots);
    const bodyPath = path.join(sandbox.roots.memoryDir, DISPLAY_RULE_FILE_NAME);

    // Tamper with the body file.
    writeFileSync(bodyPath, '# tampered\n', 'utf8');
    expect(readFileSync(bodyPath, 'utf8')).toBe('# tampered\n');

    installDisplayRule(sandbox.roots);

    expect(readFileSync(bodyPath, 'utf8')).toBe(DISPLAY_RULE_BODY);
  });

  test('does not duplicate the index line on re-install', () => {
    installDisplayRule(sandbox.roots);
    installDisplayRule(sandbox.roots);

    const indexPath = path.join(sandbox.roots.memoryDir, 'MEMORY.md');
    const body = readFileSync(indexPath, 'utf8');
    const occurrences = body.split(DISPLAY_RULE_INDEX_LINE).length - 1;
    expect(occurrences).toBe(1);
  });

  test('preserves existing MEMORY.md lines when adding the new entry', () => {
    mkdirSync(sandbox.roots.memoryDir, {recursive: true});
    const indexPath = path.join(sandbox.roots.memoryDir, 'MEMORY.md');
    const existing = '- [Some other rule](other.md) — keeps doing X\n';
    writeFileSync(indexPath, existing, 'utf8');

    installDisplayRule(sandbox.roots);

    const body = readFileSync(indexPath, 'utf8');
    expect(body).toContain('- [Some other rule](other.md) — keeps doing X');
    expect(body).toContain(DISPLAY_RULE_INDEX_LINE);
  });
});

describe('removeDisplayRule', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('deletes the body file and removes the index line', () => {
    installDisplayRule(sandbox.roots);
    removeDisplayRule(sandbox.roots);

    const bodyPath = path.join(sandbox.roots.memoryDir, DISPLAY_RULE_FILE_NAME);
    const indexPath = path.join(sandbox.roots.memoryDir, 'MEMORY.md');

    expect(existsSync(bodyPath)).toBe(false);
    // Index file should be gone too if it had only the rule line.
    expect(existsSync(indexPath)).toBe(false);
  });

  test('preserves sibling lines and keeps the index file when others remain', () => {
    mkdirSync(sandbox.roots.memoryDir, {recursive: true});
    const indexPath = path.join(sandbox.roots.memoryDir, 'MEMORY.md');
    writeFileSync(
      indexPath,
      `- [Other rule A](a.md) — A\n- [Other rule B](b.md) — B\n`,
      'utf8'
    );

    installDisplayRule(sandbox.roots);
    removeDisplayRule(sandbox.roots);

    const body = readFileSync(indexPath, 'utf8');
    expect(body).toContain('- [Other rule A](a.md) — A');
    expect(body).toContain('- [Other rule B](b.md) — B');
    expect(body).not.toContain(DISPLAY_RULE_INDEX_LINE);
  });

  test('is idempotent on a never-installed memory dir', () => {
    expect(existsSync(sandbox.roots.memoryDir)).toBe(false);
    expect(() => {
      removeDisplayRule(sandbox.roots);
    }).not.toThrow();
    expect(existsSync(sandbox.roots.memoryDir)).toBe(false);
  });

  test('is idempotent on a second invocation', () => {
    installDisplayRule(sandbox.roots);
    removeDisplayRule(sandbox.roots);

    expect(() => {
      removeDisplayRule(sandbox.roots);
    }).not.toThrow();
  });
});

describe('assertDisplayRule', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('returns flags reporting first-time install', () => {
    const outcome = assertDisplayRule(sandbox.roots);
    expect(outcome).toEqual({body_written: true, index_line_added: true});
  });

  test('returns false flags when the rule is already in place', () => {
    installDisplayRule(sandbox.roots);
    const outcome = assertDisplayRule(sandbox.roots);
    expect(outcome).toEqual({body_written: false, index_line_added: false});
  });

  test('rewrites the body when it has been tampered', () => {
    installDisplayRule(sandbox.roots);
    const bodyPath = path.join(sandbox.roots.memoryDir, DISPLAY_RULE_FILE_NAME);
    writeFileSync(bodyPath, '# tampered\n', 'utf8');

    const outcome = assertDisplayRule(sandbox.roots);
    expect(outcome.body_written).toBe(true);
    expect(outcome.index_line_added).toBe(false);
    expect(readFileSync(bodyPath, 'utf8')).toBe(DISPLAY_RULE_BODY);
  });

  test('re-adds the index line when only the index has been tampered', () => {
    installDisplayRule(sandbox.roots);
    const indexPath = path.join(sandbox.roots.memoryDir, 'MEMORY.md');
    writeFileSync(indexPath, '- [Some other](x.md) — note\n', 'utf8');

    const outcome = assertDisplayRule(sandbox.roots);
    expect(outcome.body_written).toBe(false);
    expect(outcome.index_line_added).toBe(true);
    const body = readFileSync(indexPath, 'utf8');
    expect(body).toContain('- [Some other](x.md) — note');
    expect(body).toContain(DISPLAY_RULE_INDEX_LINE);
  });
});
