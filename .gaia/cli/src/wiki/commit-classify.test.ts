import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for `gaia wiki commit-classify`.
 *
 * Strategy: build a sandbox repo, commit a deterministic series of changes,
 * then ask the handler to classify them since the initial baseline. We
 * snapshot the suggestion + reason for each commit and assert against it.
 */
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from './commit-classify.js';
import type {CommitClassification} from './commit-classify.js';

type Sandbox = {
  cleanup: () => void;
  commit: (message: string, files: Record<string, string>) => string;
  initialSha: string;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-classify-'));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  execFileSync('git', ['config', 'user.email', 'test@example.com'], {
    cwd: root,
  });
  execFileSync('git', ['config', 'user.name', 'Test'], {cwd: root});
  execFileSync('git', ['config', 'commit.gpgsign', 'false'], {cwd: root});

  const commit = (message: string, files: Record<string, string>): string => {
    for (const [relativePath, contents] of Object.entries(files)) {
      const absPath = path.join(root, relativePath);
      mkdirSync(path.dirname(absPath), {recursive: true});
      writeFileSync(absPath, contents, 'utf8');
    }
    execFileSync('git', ['add', '-A'], {cwd: root});
    execFileSync('git', ['commit', '-q', '-m', message], {cwd: root});

    return execFileSync('git', ['rev-parse', 'HEAD'], {
      cwd: root,
      encoding: 'utf8',
    }).trim();
  };

  // Initial baseline commit.
  const initialSha = commit('initial commit', {'README.md': '# repo\n'});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    commit,
    initialSha,
    root,
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

const classify = (sandbox: Sandbox): CommitClassification => {
  let out = '';
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      out += typeof chunk === 'string' ? chunk : String(chunk);

      return true;
    });
  const exit = run(['--since', sandbox.initialSha, '--json'], {
    cwd: sandbox.root,
  });
  stdoutSpy.mockRestore();
  expect(exit).toBe(0);

  return JSON.parse(out.trim()) as CommitClassification;
};

describe('wiki commit-classify', () => {
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

  test('chore(deps): bumps without architecture body → SKIP', () => {
    sandbox.commit('chore(deps): bump foo from 1.0.0 to 1.0.1', {
      'package.json': '{"version": "1.0.1"}\n',
    });

    const json = classify(sandbox);
    expect(json.commits).toHaveLength(1);
    expect(json.commits[0]?.suggestion).toBe('SKIP');
    expect(json.commits[0]?.suggestion_reason).toContain('chore(deps)');
  });

  test('chore(deps): with BREAKING CHANGE body → WORTHY', () => {
    sandbox.commit(
      'chore(deps): swap axios for ofetch\n\nBREAKING CHANGE: server-side fetch surface changed',
      {'package.json': '{"version": "2.0.0"}\n'}
    );

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('WORTHY');
  });

  test('feat: touching app/** non-test → WORTHY', () => {
    sandbox.commit('feat: add new module', {
      'app/foo.ts': 'export const x = 1;\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('WORTHY');
    expect(json.commits[0]?.suggestion_reason).toContain('app/**');
  });

  test('feat: only inventory paths without decision keywords → SKIP', () => {
    sandbox.commit('feat: add Button variant', {
      'app/components/Button/index.tsx': 'export const Button = () => null;\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('SKIP');
    expect(json.commits[0]?.suggestion_reason).toContain('inventory');
  });

  test('test: prefix → SKIP', () => {
    sandbox.commit('test: add coverage', {'app/foo.test.ts': 'test ...\n'});

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('SKIP');
  });

  test('docs(decision): → WORTHY', () => {
    sandbox.commit('docs(decision): adopt zod', {
      'docs/decisions/zod.md': '# zod\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('WORTHY');
    expect(json.commits[0]?.suggestion_reason).toContain('ADR');
  });

  test('Merge pull request → SKIP', () => {
    sandbox.commit('Merge pull request #42 from feature/foo', {
      'README.md': '# repo updated\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('SKIP');
  });

  test('chore(release): → SKIP', () => {
    sandbox.commit('chore(release): 1.0.0', {'CHANGELOG.md': '# 1.0.0\n'});

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('SKIP');
  });

  test('touching app/middleware → WORTHY (flows-relevant)', () => {
    sandbox.commit('feat: middleware tweak', {
      'app/middleware/foo.ts': 'export const foo = () => null;\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('WORTHY');
    expect(json.commits[0]?.suggestion_reason).toContain('flows');
  });

  test('touching wiki/concepts/ → WORTHY', () => {
    sandbox.commit('chore: rewrite concept', {
      'wiki/concepts/Foo.md': '# Foo\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('WORTHY');
    expect(json.commits[0]?.suggestion_reason).toContain('wiki-heavy');
  });

  // This repo writes scoped subjects (`fix(hooks):`) essentially exclusively.
  // A rule table that only matches the unscoped form is unreachable in
  // practice: every commit falls through to the fail-open default and the
  // first-pass filter stops filtering. Parity is the property that catches it.
  describe('scoped subjects reach the same decision as unscoped', () => {
    const parityCases = [
      {path: 'app/foo.ts', type: 'feat'},
      {path: 'app/foo.ts', type: 'fix'},
      {path: 'app/foo.ts', type: 'refactor'},
      {path: 'app/foo.ts', type: 'debt'},
      {path: 'app/foo.ts', type: 'style'},
      {path: 'app/foo.test.ts', type: 'test'},
      {path: 'docs/guide.md', type: 'docs'},
      {path: 'tooling/thing.cfg', type: 'chore'},
    ];

    test.each(parityCases)(
      '$type: and $type(scope): agree',
      ({path: filePath, type}) => {
        sandbox.commit(`${type}: unscoped subject`, {[filePath]: 'unscoped\n'});
        sandbox.commit(`${type}(scope): scoped subject`, {
          [filePath]: 'scoped\n',
        });

        const {commits} = classify(sandbox);
        expect(commits).toHaveLength(2);
        expect(commits[1]?.suggestion).toBe(commits[0]?.suggestion);
        expect(commits[1]?.suggestion_reason).toBe(
          commits[0]?.suggestion_reason
        );
      }
    );
  });

  test('feat(scope)!: → WORTHY (breaking)', () => {
    sandbox.commit('feat(api)!: drop the legacy endpoint', {
      'app/api.ts': 'export const api = null;\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('WORTHY');
    expect(json.commits[0]?.suggestion_reason).toContain('breaking');
  });

  // Once every rule matches breaking-agnostically, the `!` no longer breaks a
  // prefix match by accident, so a breaking subject on a SKIP-rule type would
  // be silently skipped unless rule 2 claims it first.
  test.each([
    'chore(cli)!: drop the legacy flag',
    'refactor(components)!: rename the exported prop',
    'fix(hooks)!: change the return shape',
  ])('%s → WORTHY (breaking beats every SKIP rule)', (subject) => {
    sandbox.commit(subject, {'app/components/Thing/index.tsx': 'export {};\n'});

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('WORTHY');
    expect(json.commits[0]?.suggestion_reason).toContain('breaking');
  });

  // Rule 1 is deliberately "SKIP regardless", ahead of the breaking signal:
  // both its categories are mechanical, so a `!` on them is either
  // meaningless (formatting cannot break a contract) or still just plumbing.
  test.each(['style!: reformat everything', 'chore(release)!: 2.0.0'])(
    '%s → SKIP (rule 1 outranks the breaking marker)',
    (subject) => {
      sandbox.commit(subject, {'app/foo.ts': 'export const x = 1;\n'});

      const json = classify(sandbox);
      expect(json.commits[0]?.suggestion).toBe('SKIP');
    }
  );

  test.each(['docs(decision): adopt zod', 'docs(decisions): adopt zod'])(
    '%s → WORTHY (ADR signal outside a wiki-heavy path)',
    (subject) => {
      // Deliberately outside wiki/{decisions,concepts,...}, so rule 3 cannot
      // rescue it and the ADR rule is the only thing standing between this
      // commit and rule 8's `docs: prose-only` SKIP.
      sandbox.commit(subject, {'.claude/rules/zod.md': '# zod\n'});

      const json = classify(sandbox);
      expect(json.commits[0]?.suggestion).toBe('WORTHY');
      expect(json.commits[0]?.suggestion_reason).toContain('ADR');
    }
  );

  test('scoped chore(deps): still beats the generic chore rule', () => {
    sandbox.commit('chore(deps): bump foo from 1.0.0 to 1.0.1', {
      'package.json': '{"version": "1.0.1"}\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('SKIP');
    expect(json.commits[0]?.suggestion_reason).toContain('chore(deps)');
  });

  test('debt: touching app/** non-test → WORTHY', () => {
    sandbox.commit('debt(cli): remove the dead telemetry write', {
      'app/foo.ts': 'export const x = 1;\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('WORTHY');
    expect(json.commits[0]?.suggestion_reason).toContain('app/**');
  });

  test('debt: tests-only → SKIP', () => {
    sandbox.commit('debt(shell-lint): drop the redundant case', {
      'app/foo.test.ts': 'test ...\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('SKIP');
    expect(json.commits[0]?.suggestion_reason).toContain('tests-only');
  });

  test('ci: without an architecture body → SKIP', () => {
    sandbox.commit('ci(release): add the distribution gate', {
      '.github/workflows/release.yml': 'on: push\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('SKIP');
    expect(json.commits[0]?.suggestion_reason).toContain('ci');
  });

  test('ci: with an architecture body → WORTHY', () => {
    sandbox.commit(
      'ci(gaia): run the bats gate under bash 5\n\nRecords the decision to pin the CI shell.',
      {'.github/workflows/tests.yml': 'on: push\n'}
    );

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('WORTHY');
  });

  test('build: without an architecture body → SKIP', () => {
    sandbox.commit('build(cli): rebundle the gaia binary', {
      'dist/gaia': 'binary\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('SKIP');
    expect(json.commits[0]?.suggestion_reason).toContain('build');
  });

  test('a non-conforming subject still defers to human review', () => {
    sandbox.commit('Harden the Code Audit Team merge gate (#793)', {
      'app/gate.ts': 'export const gate = null;\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('WORTHY');
    expect(json.commits[0]?.suggestion_reason).toContain('no matching prefix');
  });

  test('exits 1 when --since missing', () => {
    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--since');
  });

  test('returns empty list when no commits exist after the baseline', () => {
    const json = classify(sandbox);
    expect(json.commits).toEqual([]);
  });

  test('without --json, prints a tabular summary', () => {
    sandbox.commit('feat: real feature', {'app/foo.ts': 'x\n'});
    const exit = run(['--since', sandbox.initialSha], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('Classified');
    expect(stdio.outputs.join('')).toContain('WORTHY');
  });
});
