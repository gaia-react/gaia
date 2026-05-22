import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, it} from 'vitest';
import {appChangedSince} from '../source-changed.js';

type Sandbox = {
  cleanup: () => void;
  commit: (relPath: string, content: string) => string;
  initialSha: string;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-source-changed-'));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  execFileSync('git', ['config', 'user.email', 'test@example.com'], {
    cwd: root,
  });
  execFileSync('git', ['config', 'user.name', 'Test'], {cwd: root});
  writeFileSync(path.join(root, 'README.md'), '# x\n', 'utf8');
  execFileSync('git', ['add', 'README.md'], {cwd: root});
  execFileSync('git', ['commit', '-q', '-m', 'initial'], {cwd: root});
  const initialSha = execFileSync('git', ['rev-parse', 'HEAD'], {
    cwd: root,
    encoding: 'utf8',
  })
    .toString()
    .trim();

  const commit = (relPath: string, content: string): string => {
    const target = path.join(root, relPath);
    mkdirSync(path.dirname(target), {recursive: true});
    writeFileSync(target, content, 'utf8');
    execFileSync('git', ['add', relPath], {cwd: root});
    execFileSync('git', ['commit', '-q', '-m', `add ${relPath}`], {cwd: root});

    return execFileSync('git', ['rev-parse', 'HEAD'], {
      cwd: root,
      encoding: 'utf8',
    })
      .toString()
      .trim();
  };

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    commit,
    initialSha,
    root,
  };
};

describe('appChangedSince', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  it('returns false when there are no commits since the sha', () => {
    expect(appChangedSince(sandbox.root, sandbox.initialSha)).toBe(false);
  });

  it('returns false when commits touched files outside app/', () => {
    sandbox.commit('docs/CHANGELOG.md', '# x\n');
    expect(appChangedSince(sandbox.root, sandbox.initialSha)).toBe(false);
  });

  it('returns true when a commit touched app/**', () => {
    sandbox.commit('app/foo.ts', 'export const x = 1;\n');
    expect(appChangedSince(sandbox.root, sandbox.initialSha)).toBe(true);
  });

  it('returns true if any of multiple commits touched app/**', () => {
    sandbox.commit('docs/CHANGELOG.md', '# x\n');
    sandbox.commit('app/bar.ts', 'export const y = 1;\n');
    expect(appChangedSince(sandbox.root, sandbox.initialSha)).toBe(true);
  });

  it('returns false when the sha is unreachable', () => {
    expect(appChangedSince(sandbox.root, 'a'.repeat(40))).toBe(false);
  });
});
