import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {computeDiffSize, run} from './diff-size.js';

type Sandbox = {
  cleanup: () => void;
  commitAll: (message: string) => void;
  removeFile: (relativePath: string) => void;
  root: string;
  writeFile: (relativePath: string, contents: string) => void;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-diff-size-'));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  execFileSync('git', ['config', 'user.email', 'test@example.com'], {
    cwd: root,
  });
  execFileSync('git', ['config', 'user.name', 'Test'], {cwd: root});
  execFileSync('git', ['config', 'commit.gpgsign', 'false'], {cwd: root});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    commitAll: (message) => {
      execFileSync('git', ['add', '-A'], {cwd: root});
      execFileSync('git', ['commit', '-q', '--allow-empty', '-m', message], {
        cwd: root,
      });
    },
    removeFile: (relativePath) => {
      rmSync(path.join(root, relativePath), {force: true});
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

const fillLines = (count: number, content: string): string =>
  `${Array.from({length: count}, () => content).join('\n')}\n`;

describe('wiki diff-size', () => {
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

  test('returns ok when wiki/ is unchanged between base and HEAD', () => {
    sandbox.writeFile('wiki/concepts/Page.md', fillLines(100, 'line'));
    sandbox.commitAll('base');
    sandbox.writeFile('README.md', 'unrelated change\n');
    sandbox.commitAll('non-wiki edit');

    const result = computeDiffSize({cwd: sandbox.root, thresholdPct: 25});
    expect(result.decision).toBe('ok');
    expect(result.changedLines).toBe(0);
    expect(result.baseLines).toBe(100);
  });

  test('returns exceeded when changed-lines ratio exceeds threshold', () => {
    sandbox.writeFile('wiki/concepts/A.md', fillLines(100, 'line'));
    sandbox.commitAll('base');
    // Append 50 new lines: 50 inserted, 0 removed. ratio = 50/100 = 50%.
    sandbox.writeFile(
      'wiki/concepts/A.md',
      fillLines(100, 'line') + fillLines(50, 'extra')
    );
    sandbox.commitAll('append 50 lines');

    const result = computeDiffSize({cwd: sandbox.root, thresholdPct: 25});
    expect(result.decision).toBe('exceeded');
    expect(result.baseLines).toBe(100);
    expect(result.changedLines).toBe(50);
    expect(result.ratioPct).toBe(50);
  });

  test('returns ok for a small edit well under the threshold', () => {
    sandbox.writeFile('wiki/concepts/A.md', fillLines(1000, 'line'));
    sandbox.commitAll('base');
    // Change exactly 5 lines in place: numstat reports 5 added + 5 removed.
    const before = fillLines(1000, 'line').split('\n');
    for (let index = 100; index < 105; index += 1) before[index] = 'edited';
    sandbox.writeFile('wiki/concepts/A.md', before.join('\n'));
    sandbox.commitAll('5-line edit');

    const result = computeDiffSize({cwd: sandbox.root, thresholdPct: 25});
    expect(result.decision).toBe('ok');
    expect(result.baseLines).toBe(1000);
    expect(result.changedLines).toBe(10);
    expect(result.ratioPct).toBe(1);
  });

  test('counts an added file by its full line count', () => {
    sandbox.writeFile('wiki/existing.md', fillLines(1000, 'line'));
    sandbox.commitAll('base');
    sandbox.writeFile('wiki/added.md', fillLines(20, 'new'));
    sandbox.commitAll('add small page');

    const result = computeDiffSize({cwd: sandbox.root, thresholdPct: 25});
    expect(result.changedLines).toBe(20);
    expect(result.decision).toBe('ok');
  });

  test('counts a deleted file by its full base line count', () => {
    sandbox.writeFile('wiki/keeps.md', fillLines(1000, 'keep'));
    sandbox.writeFile('wiki/goes.md', fillLines(200, 'go'));
    sandbox.commitAll('base');
    sandbox.removeFile('wiki/goes.md');
    sandbox.commitAll('delete goes');

    const result = computeDiffSize({cwd: sandbox.root, thresholdPct: 25});
    expect(result.baseLines).toBe(1200);
    expect(result.changedLines).toBe(200);
    expect(result.decision).toBe('ok');
  });

  test('returns ok when wiki/ does not exist at base or HEAD', () => {
    sandbox.writeFile('README.md', 'no wiki\n');
    sandbox.commitAll('base');
    sandbox.writeFile('README.md', 'still no wiki\n');
    sandbox.commitAll('non-wiki edit');

    const result = computeDiffSize({cwd: sandbox.root, thresholdPct: 25});
    expect(result.decision).toBe('ok');
    expect(result.baseLines).toBe(0);
    expect(result.changedLines).toBe(0);
  });

  test('returns exceeded when wiki/ is empty at base but content is added', () => {
    sandbox.writeFile('README.md', 'no wiki yet\n');
    sandbox.commitAll('base');
    sandbox.writeFile('wiki/new.md', 'first line\n');
    sandbox.commitAll('first wiki page');

    const result = computeDiffSize({cwd: sandbox.root, thresholdPct: 25});
    expect(result.decision).toBe('exceeded');
    expect(result.baseLines).toBe(0);
    expect(result.changedLines).toBe(1);
  });

  test('honours --base override against an explicit ref', () => {
    sandbox.writeFile('wiki/page.md', fillLines(100, 'a'));
    sandbox.commitAll('first');
    execFileSync('git', ['tag', 'v1'], {cwd: sandbox.root});
    sandbox.writeFile('wiki/page.md', fillLines(150, 'a'));
    sandbox.commitAll('grow');
    sandbox.writeFile('wiki/page.md', fillLines(200, 'a'));
    sandbox.commitAll('grow more');

    const versusV1 = computeDiffSize({
      base: 'v1',
      cwd: sandbox.root,
      thresholdPct: 25,
    });
    // 100→200: numstat for an append is +100 added, 0 removed.
    expect(versusV1.changedLines).toBe(100);
    expect(versusV1.decision).toBe('exceeded');
  }, 30_000);

  test('CLI prints "exceeded" on a large wiki change', () => {
    sandbox.writeFile('wiki/page.md', fillLines(100, 'a'));
    sandbox.commitAll('base');
    sandbox.writeFile('wiki/page.md', fillLines(200, 'a'));
    sandbox.commitAll('grow');

    const exit = run(['--threshold-pct', '25'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('').trim()).toBe('exceeded');
  });

  test('CLI prints "ok" when under threshold', () => {
    sandbox.writeFile('wiki/page.md', fillLines(1000, 'a'));
    sandbox.commitAll('base');
    sandbox.writeFile('wiki/page.md', `${fillLines(1000, 'a')}tail\n`);
    sandbox.commitAll('append 1 line');

    const exit = run(['--threshold-pct', '25'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('').trim()).toBe('ok');
  });

  test('--json emits structured object with all counters', () => {
    sandbox.writeFile('wiki/page.md', fillLines(100, 'a'));
    sandbox.commitAll('base');
    sandbox.writeFile('wiki/page.md', fillLines(200, 'a'));
    sandbox.commitAll('grow');

    const exit = run(['--threshold-pct', '25', '--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.outputs.join('')) as {
      base_lines: number;
      changed_lines: number;
      decision: string;
      ratio_pct: number;
      threshold_pct: number;
    };
    expect(parsed.decision).toBe('exceeded');
    expect(parsed.threshold_pct).toBe(25);
    expect(parsed.base_lines).toBe(100);
    expect(parsed.changed_lines).toBe(100);
    expect(parsed.ratio_pct).toBe(100);
  });

  test('rejects missing --threshold-pct', () => {
    sandbox.writeFile('wiki/page.md', 'a\n');
    sandbox.commitAll('base');

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--threshold-pct');
  });

  test('rejects non-numeric --threshold-pct', () => {
    const exit = run(['--threshold-pct', 'abc'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--threshold-pct');
  });

  test('rejects unknown flags', () => {
    const exit = run(['--threshold-pct', '25', '--bogus'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });

  test('--help prints usage and exits 0', () => {
    const exit = run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('Usage: gaia wiki diff-size');
  });
});
