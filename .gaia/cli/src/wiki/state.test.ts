/**
 * Tests for `gaia wiki state`.
 */
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {run} from './state.js';

type Sandbox = {
  cleanup: () => void;
  commit: (message: string, files: Record<string, string>) => string;
  // Creates N empty commits in a single `git fast-import` spawn. The
  // sandbox `commit()` helper (write, add, commit, rev-parse) costs
  // 3-4 Node→git spawns per call; under full-suite contention each
  // spawn slows from ~50ms to several hundred ms, so 21 sequential
  // invocations easily blow past a 30s per-test timeout. fast-import
  // creates the whole chain in one process — single startup, all
  // commits assembled in-memory, no per-commit pack overhead.
  commitEmptyChain: (count: number) => void;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-state-'));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  execFileSync('git', ['config', 'user.email', 'test@example.com'], {
    cwd: root,
  });
  execFileSync('git', ['config', 'user.name', 'Test'], {cwd: root});
  execFileSync('git', ['config', 'commit.gpgsign', 'false'], {cwd: root});
  mkdirSync(path.join(root, 'wiki'), {recursive: true});

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

  const commitEmptyChain = (count: number): void => {
    if (count <= 0) return;
    const lines: string[] = [];
    for (let i = 0; i < count; i += 1) {
      lines.push(
        'commit refs/heads/main',
        `mark :${i + 1}`,
        `committer Test <test@example.com> ${1_700_000_000 + i} +0000`,
        'data <<COMMITMSG',
        `feat: change ${i}`,
        'COMMITMSG',
        i === 0 ? 'from refs/heads/main^0' : `from :${i}`,
        ''
      );
    }
    lines.push('done', '');
    execFileSync('git', ['fast-import', '--quiet'], {
      cwd: root,
      input: lines.join('\n'),
      stdio: ['pipe', 'ignore', 'pipe'],
    });
  };

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    commit,
    commitEmptyChain,
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

const writeStateFile = (root: string, sha: string): void => {
  writeFileSync(
    path.join(root, 'wiki', '.state.json'),
    `${JSON.stringify({version: 1, last_evaluated_sha: sha}, null, 2)}\n`,
    'utf8'
  );
};

describe('wiki state', () => {
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

  test('reports drift_severity none when state matches HEAD', () => {
    const sha = sandbox.commit('initial', {'README.md': '# repo\n'});
    writeStateFile(sandbox.root, sha);
    // Re-write state file (now untracked); commit it so HEAD is unchanged.
    // Actually: the state-file write is untracked, so HEAD === sha still. Good.

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const json = JSON.parse(stdio.outputs.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(json.commits_ahead).toBe(0);
    expect(json.drift_severity).toBe('none');
    expect(json.reachable).toBe(true);
    expect(typeof json.head_short).toBe('string');
    expect((json.head_short as string).length).toBe(7);
  });

  test('reports drift_severity low for 1-5 commits ahead', () => {
    const baseSha = sandbox.commit('initial', {'README.md': '# repo\n'});
    writeStateFile(sandbox.root, baseSha);
    sandbox.commit('feat: add a thing', {
      'app/foo.ts': 'export const x = 1;\n',
    });

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const json = JSON.parse(stdio.outputs.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(json.commits_ahead).toBe(1);
    expect(json.drift_severity).toBe('low');
    expect(Array.isArray(json.recent_commits)).toBe(true);
    expect((json.recent_commits as unknown[]).length).toBe(1);
  }, 15_000);

  test('reports drift_severity medium for 6-20 commits ahead', () => {
    const baseSha = sandbox.commit('initial', {'README.md': '# repo\n'});
    writeStateFile(sandbox.root, baseSha);
    for (let i = 0; i < 6; i += 1) {
      sandbox.commit(`feat: change ${i}`, {[`app/foo${i}.ts`]: 'x\n'});
    }

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const json = JSON.parse(stdio.outputs.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(json.commits_ahead).toBe(6);
    expect(json.drift_severity).toBe('medium');
  }, 15_000);

  test('reports drift_severity high for 21+ commits', () => {
    const baseSha = sandbox.commit('initial', {'README.md': '# repo\n'});
    writeStateFile(sandbox.root, baseSha);
    sandbox.commitEmptyChain(21);

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const json = JSON.parse(stdio.outputs.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(json.commits_ahead).toBe(21);
    expect(json.drift_severity).toBe('high');
  }, 60_000);

  test('marks reachable=false when state SHA is not an ancestor of HEAD', () => {
    sandbox.commit('initial', {'README.md': '# repo\n'});
    // Synthetic state SHA that is not in repo history.
    writeStateFile(sandbox.root, 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef');

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const json = JSON.parse(stdio.outputs.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(json.reachable).toBe(false);
    expect(json.commits_ahead).toBe(0);
  });

  test('returns per_domain_page_counts shaped object', () => {
    const sha = sandbox.commit('initial', {
      'wiki/concepts/Foo.md': '# Foo\n',
      'wiki/concepts/Bar.md': '# Bar\n',
      'wiki/decisions/Baz.md': '# Baz\n',
    });
    writeStateFile(sandbox.root, sha);

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const json = JSON.parse(stdio.outputs.join('').trim()) as Record<
      string,
      unknown
    >;
    const counts = json.per_domain_page_counts as Record<string, number>;
    expect(counts.concepts).toBe(2);
    expect(counts.decisions).toBe(1);
    expect(counts.modules).toBe(0);
  }, 15_000);

  test('rejects unknown flags', () => {
    sandbox.commit('initial', {'README.md': '# repo\n'});

    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });

  test('without --json, prints a human-readable block', () => {
    const sha = sandbox.commit('initial', {'README.md': '# repo\n'});
    writeStateFile(sandbox.root, sha);

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const out = stdio.outputs.join('');
    expect(out).toContain('Wiki state');
    expect(out).toContain('Drift:');
  });

  test('routes output to an injected write sink, not process.stdout', () => {
    const sha = sandbox.commit('initial', {'README.md': '# repo\n'});
    writeStateFile(sandbox.root, sha);

    const chunks: string[] = [];
    const exit = run(['--json'], {
      cwd: sandbox.root,
      write: (chunk) => {
        chunks.push(chunk);
      },
    });
    expect(exit).toBe(0);

    // The injected sink receives the payload; the global stdout spy does not.
    const json = JSON.parse(chunks.join('').trim()) as Record<string, unknown>;
    expect(json.commits_ahead).toBe(0);
    expect(stdio.outputs.join('')).toBe('');
  });
});
