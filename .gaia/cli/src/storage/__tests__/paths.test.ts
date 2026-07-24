import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, realpathSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {resolveStorageRoots} from '../paths.js';

const git = (cwd: string, args: string[]): void => {
  execFileSync('git', args, {cwd, stdio: ['ignore', 'ignore', 'pipe']});
};

/**
 * A real main checkout with one commit. The temp root is `realpathSync`d
 * because `os.tmpdir()` is a symlinked path on macOS (`/var/folders/…` ->
 * `/private/var/folders/…`) and git canonicalizes the path it records for a
 * linked worktree while returning a caller-relative `.git` from the main
 * checkout. Canonicalizing here is the concurrency harness's own convention
 * (`gaia_mk_tmp` uses `pwd -P`) and keeps these tests measuring main-anchoring
 * rather than path form; the resolver's lack of physical resolution is filed
 * separately as F-3.11-tsresolver.
 */
const newMainCheckout = (): string => {
  const root = realpathSync(mkdtempSync(path.join(tmpdir(), 'gaia-storage-')));
  git(root, ['init', '-q', '--initial-branch=main']);
  git(root, ['config', 'user.email', 'test@example.com']);
  git(root, ['config', 'user.name', 'Test']);
  git(root, ['config', 'commit.gpgsign', 'false']);
  git(root, ['commit', '-q', '--allow-empty', '-m', 'init']);

  return root;
};

const projectIdPathUnder = (root: string): string =>
  path.join(root, '.gaia', 'local', '.project-id');

describe('resolveStorageRoots', () => {
  let mainRoot: string;
  let scratch: string[];

  beforeEach(() => {
    mainRoot = newMainCheckout();
    scratch = [mainRoot];
  });

  afterEach(() => {
    for (const dir of scratch) rmSync(dir, {force: true, recursive: true});
  });

  test('resolves the project-id path under the main checkout', () => {
    const roots = resolveStorageRoots({repoRoot: mainRoot});

    expect(roots.projectIdPath).toBe(projectIdPathUnder(mainRoot));
  });

  test('resolves to the MAIN checkout from inside a linked worktree', () => {
    // The C3-05 property: one clone, one identity. A worktree that resolves to
    // its own root mints a second `.project-id`, so one adopter counts as N.
    const worktree = realpathSync(
      mkdtempSync(path.join(tmpdir(), 'gaia-storage-wt-'))
    );
    rmSync(worktree, {force: true, recursive: true});
    git(mainRoot, ['worktree', 'add', '-q', '-b', 'treeB', worktree]);
    scratch.push(worktree);

    const roots = resolveStorageRoots({repoRoot: worktree});

    expect(roots.projectIdPath).toBe(projectIdPathUnder(mainRoot));
  });

  test('resolves to the repo root from a subdirectory of the checkout', () => {
    // Without resolution the id file lands at `<subdir>/.gaia/local/`, a stray
    // state directory inside the working tree.
    const nested = path.join(mainRoot, 'app', 'components');
    mkdirSync(nested, {recursive: true});

    const roots = resolveStorageRoots({repoRoot: nested});

    expect(roots.projectIdPath).toBe(projectIdPathUnder(mainRoot));
  });

  test('throws rather than falling back when the cwd is not in a repository', () => {
    // Refuse, never fall back: a fallback to the acting directory is what mints
    // the wrong identity. `ping/send.ts` catches this and omits `projectId`.
    const notARepo = realpathSync(
      mkdtempSync(path.join(tmpdir(), 'gaia-storage-bare-'))
    );
    scratch.push(notARepo);

    expect(() => resolveStorageRoots({repoRoot: notARepo})).toThrow(
      /not a git repository/iu
    );
  });
});
