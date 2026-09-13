import {afterEach, describe, expect, test, vi} from 'vitest';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import * as runProcess from '../../ci/util/run-process.js';
import type {ProcessResult} from '../../ci/util/run-process.js';
import * as gitEnvironment from '../../util/git-env.js';
import {fixtureProvider, liveProvider, resolveProvider} from '../corpus.js';

const okResult = (stdout: string): ProcessResult => ({
  exitCode: 0,
  stderr: '',
  stdout,
});
const failResult = (): ProcessResult => ({
  exitCode: 1,
  stderr: 'boom',
  stdout: '',
});
const execGaiaGitArgsFor = (prNumber: number): string =>
  `execGaiaGit ["fetch","--no-tags","--quiet","origin","refs/pull/${prNumber}/head"]`;

const prPage = (count: number, startNumber: number, mergedAt: string) =>
  Array.from({length: count}, (_, index) => ({
    body: '',
    headRefOid: 'sha',
    mergedAt,
    number: startNumber + index,
  }));

const makeFixtureDir = (files: Record<string, unknown>): string => {
  const dir = mkdtempSync(path.join(tmpdir(), 'gaia-residue-corpus-'));

  for (const [name, content] of Object.entries(files)) {
    writeFileSync(path.join(dir, name), JSON.stringify(content));
  }

  return dir;
};

describe('fixtureProvider', () => {
  const dirs: string[] = [];

  afterEach(() => {
    for (const dir of dirs.splice(0))
      rmSync(dir, {force: true, recursive: true});
  });

  test('a missing prs.json is a read failure', () => {
    const dir = makeFixtureDir({});

    dirs.push(dir);

    expect(fixtureProvider(dir).mergedPrs(null)).toEqual({ok: false});
  });

  test('a missing issues.json is a read failure', () => {
    const dir = makeFixtureDir({'prs.json': []});

    dirs.push(dir);

    expect(fixtureProvider(dir).techDebtIssues()).toEqual({ok: false});
  });

  test('a missing blobs.json makes every blobAt and blobAtHead call return null', () => {
    const dir = makeFixtureDir({'prs.json': []});

    dirs.push(dir);

    const provider = fixtureProvider(dir);

    expect(provider.blobAt('sha', 'app/x.ts', 1)).toBeNull();
    expect(provider.blobAtHead('app/x.ts')).toBeNull();
  });

  test('blobAt and blobAtHead read the sha-keyed and HEAD-keyed blob entries', () => {
    const dir = makeFixtureDir({
      'blobs.json': {
        'abc:app/x.ts': 'old text',
        'HEAD:app/x.ts': 'current text',
      },
      'prs.json': [],
    });

    dirs.push(dir);

    const provider = fixtureProvider(dir);

    expect(provider.blobAt('abc', 'app/x.ts', 1)).toBe('old text');
    expect(provider.blobAtHead('app/x.ts')).toBe('current text');
  });

  test('mergedPrs filters by sinceIso (inclusive) and returns every pull request unfiltered when sinceIso is null', () => {
    const dir = makeFixtureDir({
      'prs.json': [
        {
          body: '',
          headRefOid: 'a',
          mergedAt: '2026-01-01T00:00:00Z',
          number: 1,
        },
        {
          body: '',
          headRefOid: 'b',
          mergedAt: '2026-02-01T00:00:00Z',
          number: 2,
        },
      ],
    });

    dirs.push(dir);

    const provider = fixtureProvider(dir);

    expect(provider.mergedPrs(null)).toEqual({
      ok: true,
      prs: [
        {
          body: '',
          headRefOid: 'a',
          mergedAt: '2026-01-01T00:00:00Z',
          number: 1,
        },
        {
          body: '',
          headRefOid: 'b',
          mergedAt: '2026-02-01T00:00:00Z',
          number: 2,
        },
      ],
      truncated: false,
    });
    expect(provider.mergedPrs('2026-02-01T00:00:00Z')).toEqual({
      ok: true,
      prs: [
        {
          body: '',
          headRefOid: 'b',
          mergedAt: '2026-02-01T00:00:00Z',
          number: 2,
        },
      ],
      truncated: false,
    });
  });
});

describe('resolveProvider', () => {
  test('resolves to the fixture provider when GAIA_RESIDUE_FIXTURE_DIR names a non-empty string', () => {
    const dir = mkdtempSync(path.join(tmpdir(), 'gaia-residue-corpus-'));

    writeFileSync(path.join(dir, 'prs.json'), '[]');

    const provider = resolveProvider('/repo', {GAIA_RESIDUE_FIXTURE_DIR: dir});

    expect(provider.mergedPrs(null)).toEqual({
      ok: true,
      prs: [],
      truncated: false,
    });
    rmSync(dir, {force: true, recursive: true});
  });

  test('falls back to the live provider when the variable is unset or empty', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(failResult());

    const unsetProvider = resolveProvider('/repo', {});
    const emptyProvider = resolveProvider('/repo', {
      GAIA_RESIDUE_FIXTURE_DIR: '',
    });

    // A live-provider read failure proves it actually shelled out via runGh
    // (a fixture provider reading a nonexistent dir would also fail, so the
    // spy assertion below is what distinguishes the two).
    expect(unsetProvider.mergedPrs(null)).toEqual({ok: false});
    expect(emptyProvider.mergedPrs(null)).toEqual({ok: false});
    expect(runProcess.runGh).toHaveBeenCalledWith(
      expect.any(Array),
      expect.any(Object)
    );

    vi.restoreAllMocks();
  });
});

describe('liveProvider.mergedPrs, the window walk', () => {
  afterEach(() => vi.restoreAllMocks());

  test('a page below the ceiling completes in one read', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      okResult(JSON.stringify(prPage(3, 1, '2026-01-01T00:00:00Z')))
    );

    const result = liveProvider('/repo').mergedPrs(null);

    expect(result).toEqual({
      ok: true,
      prs: prPage(3, 1, '2026-01-01T00:00:00Z'),
      truncated: false,
    });
    expect(runProcess.runGh).toHaveBeenCalledTimes(1);
  });

  test('two full pages followed by a short one merge, dedup by number, and report truncated: false', () => {
    const ceiling = 1000;
    const firstPage = prPage(ceiling, 1, '2026-01-10T00:00:00Z');
    const secondPage = prPage(ceiling, ceiling + 1, '2026-01-05T00:00:00Z');
    const thirdPage = prPage(5, 2 * ceiling + 1, '2026-01-01T00:00:00Z');

    vi.spyOn(runProcess, 'runGh')
      .mockReturnValueOnce(okResult(JSON.stringify(firstPage)))
      .mockReturnValueOnce(okResult(JSON.stringify(secondPage)))
      .mockReturnValueOnce(okResult(JSON.stringify(thirdPage)));

    const result = liveProvider('/repo').mergedPrs(null);

    expect(result.ok).toBe(true);
    expect(result.ok && result.truncated).toBe(false);
    expect(result.ok && result.prs).toHaveLength(2 * ceiling + 5);
    expect(runProcess.runGh).toHaveBeenCalledTimes(3);
  });

  test('the ceiling on every call stops at the iteration bound and reports truncated: true', () => {
    vi.spyOn(runProcess, 'runGh').mockImplementation(() => {
      const call = (runProcess.runGh as ReturnType<typeof vi.fn>).mock.calls
        .length;

      return okResult(
        JSON.stringify(prPage(1000, call * 1000 + 1, '2026-01-01T00:00:00Z'))
      );
    });

    const result = liveProvider('/repo').mergedPrs(null);

    expect(result).toEqual(
      expect.objectContaining({ok: true, truncated: true})
    );
    expect(runProcess.runGh).toHaveBeenCalledTimes(20);
  });

  test('a non-zero exit is a read failure', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(failResult());

    expect(liveProvider('/repo').mergedPrs(null)).toEqual({ok: false});
  });

  test('unparseable JSON is a read failure', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(okResult('not json'));

    expect(liveProvider('/repo').mergedPrs(null)).toEqual({ok: false});
  });

  test('a well-formed non-array response is a read failure', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(okResult('{}'));

    expect(liveProvider('/repo').mergedPrs(null)).toEqual({ok: false});
  });
});

describe('liveProvider.blobAt, fetch-before-show and the git-env chokepoint', () => {
  afterEach(() => vi.restoreAllMocks());

  test('issues the refs/pull/<n>/head fetch before the git show, both through git-env, never runGit', () => {
    const calls: string[] = [];

    vi.spyOn(gitEnvironment, 'execGaiaGit').mockImplementation((args) => {
      calls.push(`execGaiaGit ${JSON.stringify(args)}`);

      return '';
    });
    vi.spyOn(gitEnvironment, 'execGaiaGitRaw').mockImplementation((args) => {
      calls.push(`execGaiaGitRaw ${JSON.stringify(args)}`);

      return 'the file text';
    });
    const runGitSpy = vi.spyOn(runProcess, 'runGit');

    const result = liveProvider('/repo').blobAt('deadbeef', 'app/x.ts', 42);

    expect(result).toBe('the file text');
    expect(calls[0]).toBe(execGaiaGitArgsFor(42));
    expect(calls[1]).toBe('execGaiaGitRaw ["show","deadbeef:app/x.ts"]');
    expect(runGitSpy).not.toHaveBeenCalled();
  });

  test('a path carrying a semicolon, a command-substitution shape, and a space reaches git show as one inert argv element', () => {
    let observedArgs: string[] = [];

    vi.spyOn(gitEnvironment, 'execGaiaGit').mockReturnValue('');
    vi.spyOn(gitEnvironment, 'execGaiaGitRaw').mockImplementation((args) => {
      observedArgs = args;

      return 'text';
    });

    const dangerousPath = 'app/$(rm -rf /); danger path.ts';

    liveProvider('/repo').blobAt('sha', dangerousPath, 1);

    expect(observedArgs).toEqual(['show', `sha:${dangerousPath}`]);
  });

  test('a failed fetch still attempts git show, and a failed show falls back to the gh api', () => {
    vi.spyOn(gitEnvironment, 'execGaiaGit').mockImplementation(() => {
      throw new Error('fetch failed');
    });
    vi.spyOn(gitEnvironment, 'execGaiaGitRaw').mockImplementation(() => {
      throw new Error('object not found');
    });
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      okResult(Buffer.from('api content').toString('base64'))
    );

    const result = liveProvider('/repo').blobAt('sha', 'app/x.ts', 7);

    expect(result).toBe('api content');
    expect(runProcess.runGh).toHaveBeenCalledWith(
      expect.arrayContaining(['api', 'repos/{owner}/{repo}/contents/app/x.ts']),
      expect.anything()
    );
  });

  test('when fetch, show, and the api all fail, blobAt returns null', () => {
    vi.spyOn(gitEnvironment, 'execGaiaGit').mockImplementation(() => {
      throw new Error('fetch failed');
    });
    vi.spyOn(gitEnvironment, 'execGaiaGitRaw').mockImplementation(() => {
      throw new Error('object not found');
    });
    vi.spyOn(runProcess, 'runGh').mockReturnValue(failResult());

    expect(liveProvider('/repo').blobAt('sha', 'app/x.ts', 7)).toBeNull();
  });

  test('blobAtHead reads HEAD:<path> and returns null on a throw', () => {
    vi.spyOn(gitEnvironment, 'execGaiaGitRaw').mockReturnValueOnce('head text');

    expect(liveProvider('/repo').blobAtHead('app/x.ts')).toBe('head text');

    vi.spyOn(gitEnvironment, 'execGaiaGitRaw').mockImplementationOnce(() => {
      throw new Error('nope');
    });

    expect(liveProvider('/repo').blobAtHead('app/x.ts')).toBeNull();
  });
});

describe('liveProvider.techDebtIssues', () => {
  afterEach(() => vi.restoreAllMocks());

  test('merges open and closed issues from two gh calls', () => {
    vi.spyOn(runProcess, 'runGh')
      .mockReturnValueOnce(
        okResult(
          JSON.stringify([
            {body: '', labels: [], number: 1, state: 'OPEN', stateReason: null},
          ])
        )
      )
      .mockReturnValueOnce(
        okResult(
          JSON.stringify([
            {
              body: '',
              labels: [],
              number: 2,
              state: 'CLOSED',
              stateReason: null,
            },
          ])
        )
      );

    const result = liveProvider('/repo').techDebtIssues();

    expect(result).toEqual({
      issues: [
        {body: '', labels: [], number: 1, state: 'OPEN', stateReason: null},
        {body: '', labels: [], number: 2, state: 'CLOSED', stateReason: null},
      ],
      ok: true,
    });
  });

  test('either call failing makes the whole read a failure', () => {
    vi.spyOn(runProcess, 'runGh')
      .mockReturnValueOnce(okResult('[]'))
      .mockReturnValueOnce(failResult());

    expect(liveProvider('/repo').techDebtIssues()).toEqual({ok: false});
  });
});
