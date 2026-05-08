/**
 * Tests for `gaia-maintainer release changelog`.
 */
import {execFileSync, type SpawnSyncReturns} from 'node:child_process';
import {
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  type CommandRunner,
  graduateChangelog,
  groupCommits,
  renderBlock,
  run,
} from './changelog.js';

const okResult = (stdout = ''): SpawnSyncReturns<string> => ({
  output: ['', stdout, ''] as never,
  pid: 0,
  signal: null,
  status: 0,
  stderr: '',
  stdout,
});

const failResult = (status: number): SpawnSyncReturns<string> => ({
  output: ['', '', ''] as never,
  pid: 0,
  signal: null,
  status,
  stderr: '',
  stdout: '',
});

const buildLogOutput = (commits: Array<{subject: string; body?: string}>): string => {
  const RECORD_SEPARATOR = '---END-COMMIT---';

  return commits
    .map((commit) => `${commit.subject}\n${commit.body ?? ''}\n${RECORD_SEPARATOR}\n`)
    .join('');
};

const buildRunner = (commits: Array<{subject: string; body?: string}>): CommandRunner =>
  (command, args) => {
    if (command === 'git' && args[0] === 'describe') {
      return failResult(128);
    }

    if (command === 'git' && args[0] === 'log') {
      return okResult(buildLogOutput(commits));
    }

    return okResult('');
  };

describe('groupCommits', () => {
  test('routes feat → Added, fix → Fixed, refactor/perf/docs → Changed', () => {
    const grouped = groupCommits([
      {body: '', subject: 'feat: shiny'},
      {body: '', subject: 'fix: leak'},
      {body: '', subject: 'refactor: clean'},
      {body: '', subject: 'perf: tighten'},
      {body: '', subject: 'docs: update'},
      {body: '', subject: 'chore: bump'}, // omitted
      {body: '', subject: 'random commit'}, // omitted
    ]);
    expect(grouped.Added).toEqual(['shiny']);
    expect(grouped.Fixed).toEqual(['leak']);
    expect(grouped.Changed).toEqual(['clean', 'tighten', 'update']);
  });

  test('strips scope from subject', () => {
    const grouped = groupCommits([{body: '', subject: 'feat(auth): rotate tokens'}]);
    expect(grouped.Added).toEqual(['rotate tokens']);
  });
});

describe('renderBlock', () => {
  test('omits empty sections', () => {
    const block = renderBlock({Added: ['a', 'b'], Changed: [], Fixed: []});
    expect(block).toContain('### Added');
    expect(block).toContain('- a');
    expect(block).toContain('- b');
    expect(block).not.toContain('### Changed');
    expect(block).not.toContain('### Fixed');
  });

  test('orders Added → Changed → Fixed', () => {
    const block = renderBlock({Added: ['a'], Changed: ['c'], Fixed: ['f']});
    const addedIdx = block.indexOf('### Added');
    const changedIdx = block.indexOf('### Changed');
    const fixedIdx = block.indexOf('### Fixed');
    expect(addedIdx).toBeLessThan(changedIdx);
    expect(changedIdx).toBeLessThan(fixedIdx);
  });
});

describe('graduateChangelog', () => {
  const TEMPLATE = `# Changelog

## [Unreleased]

## [1.0.0] — 2026-01-01

- Old entry
`;

  test('inserts dated heading and fresh Unreleased above', () => {
    const block = '### Added\n\n- new thing\n';
    const outcome = graduateChangelog(TEMPLATE, '1.1.0', block, '2026-05-07');
    expect(outcome.kind).toBe('ok');

    if (outcome.kind !== 'ok') return;
    expect(outcome.updated).toContain('## [Unreleased]');
    expect(outcome.updated).toContain('## [1.1.0] — 2026-05-07');
    const unreleasedIdx = outcome.updated.indexOf('## [Unreleased]');
    const datedIdx = outcome.updated.indexOf('## [1.1.0]');
    expect(unreleasedIdx).toBeLessThan(datedIdx);
    expect(outcome.updated).toContain('- new thing');
  });

  test('returns duplicate when version already present', () => {
    const block = '### Added\n\n- foo\n';
    const outcome = graduateChangelog(TEMPLATE, '1.0.0', block, '2026-05-07');
    expect(outcome.kind).toBe('duplicate');
  });

  test('returns no-unreleased when heading missing', () => {
    const minimal = '# Changelog\n\n## [1.0.0] — 2026-01-01\n';
    const outcome = graduateChangelog(minimal, '1.1.0', '### Added\n- x\n', '2026-05-07');
    expect(outcome.kind).toBe('no-unreleased');
  });
});

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (currentVersion: string): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-release-changelog-'));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  writeFileSync(
    path.join(root, 'package.json'),
    `${JSON.stringify({name: 'gaia', version: currentVersion}, null, 2)}\n`,
    'utf8'
  );
  writeFileSync(
    path.join(root, 'CHANGELOG.md'),
    `# Changelog\n\n## [Unreleased]\n\n## [1.0.0] — 2026-01-01\n\n- old\n`,
    'utf8'
  );

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
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

describe('release changelog CLI', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('--draft prints rendered block to stdout', () => {
    sandbox = setupSandbox('1.1.0');
    const runner = buildRunner([
      {subject: 'feat: a'},
      {subject: 'fix: b'},
      {subject: 'docs: c'},
    ]);

    const exit = run(['--draft'], {cwd: sandbox.root, runner});
    expect(exit).toBe(0);
    const out = stdio.outputs.join('');
    expect(out).toContain('### Added');
    expect(out).toContain('- a');
    expect(out).toContain('### Fixed');
    expect(out).toContain('- b');
    expect(out).toContain('### Changed');
    expect(out).toContain('- c');

    // Did NOT modify CHANGELOG
    const changelog = readFileSync(path.join(sandbox.root, 'CHANGELOG.md'), 'utf8');
    expect(changelog).not.toContain('## [1.1.0]');
  });

  test('without --draft graduates the Unreleased heading', () => {
    sandbox = setupSandbox('1.1.0');
    const runner = buildRunner([{subject: 'feat: shiny'}]);

    const exit = run([], {cwd: sandbox.root, runner, today: '2026-05-07'});
    expect(exit).toBe(0);

    const changelog = readFileSync(path.join(sandbox.root, 'CHANGELOG.md'), 'utf8');
    expect(changelog).toContain('## [1.1.0] — 2026-05-07');
    expect(changelog).toContain('## [Unreleased]');
    expect(changelog).toContain('- shiny');
  });

  test('idempotent: re-running with the same version is a no-op', () => {
    sandbox = setupSandbox('1.1.0');
    const runner = buildRunner([{subject: 'feat: shiny'}]);

    const first = run([], {cwd: sandbox.root, runner, today: '2026-05-07'});
    expect(first).toBe(0);
    const afterFirst = readFileSync(
      path.join(sandbox.root, 'CHANGELOG.md'),
      'utf8'
    );

    const second = run([], {cwd: sandbox.root, runner, today: '2026-05-08'});
    expect(second).toBe(0);
    const afterSecond = readFileSync(
      path.join(sandbox.root, 'CHANGELOG.md'),
      'utf8'
    );
    expect(afterSecond).toBe(afterFirst);
  });

  test('exits 1 when no Unreleased heading present', () => {
    sandbox = setupSandbox('1.1.0');
    writeFileSync(
      path.join(sandbox.root, 'CHANGELOG.md'),
      '# Changelog\n\n## [1.0.0] — 2026-01-01\n',
      'utf8'
    );
    const runner = buildRunner([{subject: 'feat: shiny'}]);

    const exit = run([], {cwd: sandbox.root, runner, today: '2026-05-07'});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('no_unreleased_section');
  });

  test('rejects unknown flags', () => {
    sandbox = setupSandbox('1.1.0');
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });

  test('--version overrides package.json version', () => {
    sandbox = setupSandbox('1.0.0');
    const runner = buildRunner([{subject: 'feat: shiny'}]);

    const exit = run(['--version', '2.0.0'], {
      cwd: sandbox.root,
      runner,
      today: '2026-05-07',
    });
    expect(exit).toBe(0);
    const changelog = readFileSync(path.join(sandbox.root, 'CHANGELOG.md'), 'utf8');
    expect(changelog).toContain('## [2.0.0] — 2026-05-07');
  });
});
