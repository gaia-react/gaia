import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {findDeadPaths, run} from './dead-paths.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
  writeFile: (relativePath: string, contents: string) => void;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-dead-paths-'));
  execFileSync('git', ['init', '-q'], {cwd: root});
  mkdirSync(path.join(root, 'wiki'), {recursive: true});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
    writeFile: (relativePath, contents) => {
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

describe('wiki dead-paths', () => {
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

  test('flags backticked paths to deleted .claude/ files', () => {
    sandbox.writeFile(
      'wiki/concepts/Hooks.md',
      '# Hooks\n\nSee `.claude/hooks/wiki-stop-safety-net.sh` for the safety net.\n'
    );

    const dead = findDeadPaths(sandbox.root);
    expect(dead).toEqual([
      {
        filePath: 'wiki/concepts/Hooks.md',
        line: 3,
        path: '.claude/hooks/wiki-stop-safety-net.sh',
      },
    ]);
  });

  test('ignores paths that exist on disk', () => {
    sandbox.writeFile('.claude/hooks/wiki-session-stop.sh', '#!/bin/bash\n');
    sandbox.writeFile(
      'wiki/concepts/Hooks.md',
      '# Hooks\n\nSee `.claude/hooks/wiki-session-stop.sh`.\n'
    );

    expect(findDeadPaths(sandbox.root)).toEqual([]);
  });

  test('ignores wikilinks and non-path backticks', () => {
    sandbox.writeFile(
      'wiki/concepts/Page.md',
      '# Page\n\nLinks [[Other]] and code `let x = 1;` and constants `FOO_BAR`.\n'
    );

    expect(findDeadPaths(sandbox.root)).toEqual([]);
  });

  test('ignores placeholders like `<path>` and globs', () => {
    sandbox.writeFile(
      'wiki/concepts/Page.md',
      '# Page\n\nUse `.claude/hooks/<name>.sh` and `.gaia/cli/src/**/*.ts`.\n'
    );

    expect(findDeadPaths(sandbox.root)).toEqual([]);
  });

  test('ignores convention placeholders like SPEC-NNN.md and XXX-XXX.ts', () => {
    sandbox.writeFile(
      'wiki/concepts/Specs.md',
      '# Specs\n\nLives at `.gaia/local/specs/SPEC-NNN.md`. Or `.claude/foo/XXX-bar.ts`.\n'
    );

    expect(findDeadPaths(sandbox.root)).toEqual([]);
  });

  test('ignores gitignored runtime paths under .gaia/local', () => {
    sandbox.writeFile(
      'wiki/concepts/Runtime.md',
      '# Runtime\n\nCache at `.gaia/local/cache/shared/coaching-active.txt` and `.gaia/local/i18n.json`.\n'
    );

    expect(findDeadPaths(sandbox.root)).toEqual([]);
  });

  test('ignores explicit historical-record bullets in decision pages', () => {
    sandbox.writeFile(
      'wiki/decisions/Some Refactor.md',
      [
        '# Some Refactor',
        '',
        '## What changed',
        '',
        '- **Removed** `app/state/theme.tsx`, `app/sessions.server/theme.ts`.',
        '- **Renamed** `app/old/path.ts` → `app/new/path.ts`.',
        '- **Migrated** `app/legacy/foo.ts` to the new location.',
        '',
      ].join('\n')
    );

    expect(findDeadPaths(sandbox.root)).toEqual([]);
  });

  test('skips wiki/log.md and wiki/meta/** by design', () => {
    sandbox.writeFile(
      'wiki/log.md',
      '# Log\n\nDeleted `.claude/hooks/old.sh` (historical record).\n'
    );
    sandbox.writeFile(
      'wiki/meta/lint-report.md',
      '# Lint Report\n\nReferences historical `.claude/hooks/gone.sh`.\n'
    );

    expect(findDeadPaths(sandbox.root)).toEqual([]);
  });

  test('detects dead paths under .gaia/ and app/ as well as .claude/', () => {
    sandbox.writeFile(
      'wiki/concepts/A.md',
      '# A\n\nSee `.gaia/cli/src/missing/index.ts`.\n'
    );
    sandbox.writeFile(
      'wiki/concepts/B.md',
      '# B\n\nSee `app/components/Removed/index.tsx`.\n'
    );

    const dead = findDeadPaths(sandbox.root);
    expect(dead).toHaveLength(2);
    expect(dead.map((d) => d.path).sort()).toEqual([
      '.gaia/cli/src/missing/index.ts',
      'app/components/Removed/index.tsx',
    ]);
  });

  test('flags sibling-monorepo paths (studio/, website/) regardless of disk', () => {
    sandbox.writeFile(
      'wiki/concepts/Sibling.md',
      '# Sibling\n\nSee `studio/decisions/foo.md`.\nAlso `../../../studio/strategy/bar.md`.\nAnd `website/src/sections/baz.md`.\n'
    );

    const dead = findDeadPaths(sandbox.root);
    expect(dead.map((d) => d.path).sort()).toEqual([
      '../../../studio/strategy/bar.md',
      'studio/decisions/foo.md',
      'website/src/sections/baz.md',
    ]);
  });

  test('CLI prints `path:line  dead-path` lines on stdout', () => {
    sandbox.writeFile(
      'wiki/concepts/Hooks.md',
      '# Hooks\n\nSee `.claude/hooks/gone.sh`.\n'
    );

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('').trim()).toBe(
      'wiki/concepts/Hooks.md:3  .claude/hooks/gone.sh'
    );
  });

  test('CLI emits zero stdout when no dead paths', () => {
    sandbox.writeFile('wiki/concepts/Page.md', '# Page\n\nNothing.\n');

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toBe('');
  });

  test('--json emits structured object', () => {
    sandbox.writeFile(
      'wiki/concepts/Hooks.md',
      '# Hooks\n\n`.claude/hooks/gone.sh`\n'
    );

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.outputs.join('')) as {
      dead: readonly {filePath: string; line: number; path: string}[];
    };
    expect(parsed.dead).toHaveLength(1);
    expect(parsed.dead[0]?.path).toBe('.claude/hooks/gone.sh');
  });

  test('rejects unknown flags', () => {
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });

  test('exits 0 when there is no wiki/ directory', () => {
    rmSync(path.join(sandbox.root, 'wiki'), {force: true, recursive: true});

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toBe('');
  });
});
