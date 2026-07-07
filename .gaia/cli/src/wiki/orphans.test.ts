import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for `gaia wiki orphans`.
 */
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from './orphans.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
  writePage: (relativePath: string, contents: string) => void;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-orphans-'));
  execFileSync('git', ['init', '-q'], {cwd: root});
  mkdirSync(path.join(root, 'wiki'), {recursive: true});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
    writePage: (relativePath, contents) => {
      const absPath = path.join(root, relativePath);
      mkdirSync(path.dirname(absPath), {recursive: true});
      writeFileSync(absPath, contents, 'utf8');
    },
  };
};

const captureStdio = (): {
  errors: string[];
  outputs: string[];
  restore: () => void;
} => {
  const outputs: string[] = [];
  const errors: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      outputs.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      errors.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    errors,
    outputs,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

describe('wiki orphans', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupSandbox();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('prints zero-inbound paths only', () => {
    sandbox.writePage(
      'wiki/concepts/Hub.md',
      '---\ntype: concept\n---\n\n# Hub\n\nLinks to [[Spoke]].\n'
    );
    sandbox.writePage(
      'wiki/concepts/Spoke.md',
      '---\ntype: concept\n---\n\n# Spoke\n\nMentions [[Hub]].\n'
    );
    sandbox.writePage(
      'wiki/concepts/Lonely.md',
      '---\ntype: concept\n---\n\n# Lonely\n\nNo references in or out.\n'
    );

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const out = stdio.outputs.join('').trim().split('\n');
    expect(out).toEqual(['wiki/concepts/Lonely.md']);
  });

  test('prints nothing when every page has at least one inbound link', () => {
    sandbox.writePage(
      'wiki/concepts/A.md',
      '---\ntype: concept\n---\n\n# A\n\n[[B]]\n'
    );
    sandbox.writePage(
      'wiki/concepts/B.md',
      '---\ntype: concept\n---\n\n# B\n\n[[A]]\n'
    );

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toBe('');
  });

  test('exit 0 when there are no wiki pages', () => {
    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toBe('');
  });

  test('rejects unknown flags', () => {
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });

  test('skips wiki/meta/ and wiki/entities/ pages with no inbound links', () => {
    sandbox.writePage(
      'wiki/concepts/Hub.md',
      '---\ntype: concept\n---\n\n# Hub\n\nLinks to [[Spoke]].\n'
    );
    sandbox.writePage(
      'wiki/concepts/Spoke.md',
      '---\ntype: concept\n---\n\n# Spoke\n\nMentions [[Hub]].\n'
    );
    sandbox.writePage(
      'wiki/meta/lint-report-2026-05-07.md',
      '---\ntype: report\n---\n\n# Lint Report\n\nStandalone audit artifact.\n'
    );
    sandbox.writePage(
      'wiki/entities/SomeProject.md',
      '---\ntype: entity\n---\n\n# Some Project\n\nMaintainer-only entity page.\n'
    );

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toBe('');
  });

  test('--json enriches each orphan with title and domain', () => {
    sandbox.writePage(
      'wiki/concepts/Hub.md',
      '---\ntype: concept\n---\n\n# Hub\n\nLinks to [[Spoke]].\n'
    );
    sandbox.writePage(
      'wiki/concepts/Spoke.md',
      '---\ntype: concept\n---\n\n# Spoke\n\nMentions [[Hub]].\n'
    );
    sandbox.writePage(
      'wiki/concepts/Lonely.md',
      '---\ntype: concept\n---\n\n# Release Notes\n\nNo references in or out.\n'
    );

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.outputs.join('')) as {
      orphans: readonly {domain: string; path: string; title: string}[];
    };
    expect(parsed.orphans).toEqual([
      {
        domain: 'concepts',
        path: 'wiki/concepts/Lonely.md',
        title: 'Release Notes',
      },
    ]);
  });

  test('--json emits an empty orphans array when there are none', () => {
    sandbox.writePage(
      'wiki/concepts/A.md',
      '---\ntype: concept\n---\n\n# A\n\n[[B]]\n'
    );
    sandbox.writePage(
      'wiki/concepts/B.md',
      '---\ntype: concept\n---\n\n# B\n\n[[A]]\n'
    );

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.outputs.join('')) as {orphans: unknown[]};
    expect(parsed.orphans).toEqual([]);
  });
});
