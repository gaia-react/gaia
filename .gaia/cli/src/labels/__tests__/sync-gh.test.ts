/**
 * Strategy: the sibling `sync.test.ts` covers `planSync` and its pure
 * companions and never touches `gh`. This file covers the two seams that are
 * impure by construction, counting a blocked label's carriers and deciding
 * which `gh` refusal degraded the run, by stubbing `runGh` and driving `run`
 * end to end. Neither decision is reachable from a pure function, and each is
 * destructive or misleading when it goes the wrong way: the first gates a
 * label delete, the second decides what the manual command list is a list of.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import type {ProcessResult} from '../../ci/util/run-process.js';
import {runGh} from '../../ci/util/run-process.js';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';
import type {DegradeSource, SyncReport} from '../sync.js';
import {DEGRADED_LINE, run} from '../sync.js';

vi.mock('../../ci/util/run-process.js', () => ({runGh: vi.fn()}));

const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);

const BLOCKED = 'good first issue';

const ALL_FEATURES = [
  '--feature',
  'tech-debt',
  '--feature',
  'gaia-ci',
  '--feature',
  'forensics',
];

const ok = (stdout: string): ProcessResult => ({
  exitCode: 0,
  stderr: '',
  stdout,
});

const REFUSED: ProcessResult = {
  exitCode: 1,
  stderr: 'HTTP 403: Resource not accessible by integration',
  stdout: '',
};

const FAILED: ProcessResult = {
  exitCode: 1,
  stderr: 'HTTP 500: server error',
  stdout: '',
};

type Responses = {
  issues?: ProcessResult;
  labelList?: ProcessResult;
  mutation?: ProcessResult;
  pulls?: ProcessResult;
};

/** Routes a stubbed `gh` invocation to the response its surface owns. */
const stubGh = (responses: Responses): void => {
  vi.mocked(runGh).mockImplementation((argv: readonly string[]) => {
    if (argv[0] === 'issue') return responses.issues ?? ok('[]');
    if (argv[0] === 'pr') return responses.pulls ?? ok('[]');
    if (argv[1] === 'list') return responses.labelList ?? ok('[]');

    return responses.mutation ?? ok('');
  });
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

let stdio: ReturnType<typeof captureStdio>;

beforeEach(() => {
  vi.mocked(runGh).mockReset();
  stdio = captureStdio();
});

afterEach(() => {
  stdio.restore();
});

const enforce = (): number =>
  run([
    '--dry-run',
    '--enforce-blocked',
    '--audience',
    'maintainer',
    '--repo-root',
    repoRoot,
    ...ALL_FEATURES,
  ]);

const stdout = (): string => stdio.outputs.join('');

const ghQueries = (surface: string): readonly (readonly string[])[] =>
  vi
    .mocked(runGh)
    .mock.calls.map(([argv]) => argv)
    .filter((argv) => argv[0] === surface && argv[1] === 'list');

describe('labels/sync carrier counting', () => {
  const blockedLive = ok(
    JSON.stringify([
      {color: '7057ff', description: 'Good for newcomers', name: BLOCKED},
    ])
  );

  test('a blocked label carried only by a pull request is never deleted', () => {
    stubGh({
      issues: ok('[]'),
      labelList: blockedLive,
      pulls: ok(JSON.stringify([{number: 192}])),
    });

    enforce();

    expect(stdout()).toContain(
      `blocked but present: ${BLOCKED} (carried by 1 issues and pull requests)`
    );
    expect(stdout()).not.toContain(`blocked removed: ${BLOCKED}`);
  });

  test('both surfaces are queried, so the count is not issue-only', () => {
    stubGh({labelList: blockedLive});

    enforce();

    expect(ghQueries('issue')).toHaveLength(1);
    expect(ghQueries('pr')).toHaveLength(1);
    expect(ghQueries('pr')[0]).toContain('--label');
    expect(ghQueries('pr')[0]).toContain(BLOCKED);
  });

  test('a label carried on neither surface is still removed', () => {
    stubGh({issues: ok('[]'), labelList: blockedLive, pulls: ok('[]')});

    enforce();

    expect(stdout()).toContain(`blocked removed: ${BLOCKED}`);
  });

  test('an uncountable pull-request surface refuses the delete, and says so', () => {
    stubGh({issues: ok('[]'), labelList: blockedLive, pulls: FAILED});

    enforce();

    expect(stdout()).toContain(
      `blocked but present: ${BLOCKED} (carrier count unavailable, so it was not removed)`
    );
    expect(stdout()).not.toContain(`blocked removed: ${BLOCKED}`);
  });

  test('an uncountable issue surface refuses the delete, and says so', () => {
    stubGh({issues: FAILED, labelList: blockedLive, pulls: ok('[]')});

    enforce();

    expect(stdout()).toContain(
      `blocked but present: ${BLOCKED} (carrier count unavailable, so it was not removed)`
    );
    expect(stdout()).not.toContain(`blocked removed: ${BLOCKED}`);
  });

  test('a run that never enforces is distinguishable from one that could not count', () => {
    stubGh({issues: FAILED, labelList: blockedLive, pulls: ok('[]')});
    run([
      '--dry-run',
      '--audience',
      'maintainer',
      '--repo-root',
      repoRoot,
      ...ALL_FEATURES,
    ]);

    expect(stdout()).toContain(`blocked but present: ${BLOCKED}.`);
    expect(stdout()).not.toContain('carrier count unavailable');
  });
});

const jsonRun = (responses: Responses): SyncReport => {
  stubGh(responses);
  run([
    '--json',
    '--audience',
    'adopter',
    '--repo-root',
    repoRoot,
    ...ALL_FEATURES,
  ]);

  return JSON.parse(stdout()) as SyncReport;
};

const plainRun = (responses: Responses): string => {
  stubGh(responses);
  run(['--audience', 'adopter', '--repo-root', repoRoot, ...ALL_FEATURES]);

  return stdout();
};

describe('labels/sync degrade source', () => {
  test('a refused read is reported as a read degrade', () => {
    expect(jsonRun({labelList: REFUSED}).degradedAt).toBe<DegradeSource>(
      'read'
    );
  });

  test('a refused write is reported as a write degrade', () => {
    expect(
      jsonRun({labelList: ok('[]'), mutation: REFUSED}).degradedAt
    ).toBe<DegradeSource>('write');
  });

  test('a run that writes everything degrades nowhere', () => {
    const report = jsonRun({labelList: ok('[]'), mutation: ok('')});

    expect(report.degradedAt).toBeNull();
    expect(stdio.errors.join('')).not.toContain(DEGRADED_LINE);
  });

  test('a read degrade says the list is the whole registry', () => {
    const printed = plainRun({labelList: REFUSED});

    expect(printed).toContain(DEGRADED_LINE);
    expect(printed).toContain('the whole registry, not the work remaining');
  });

  test('a write degrade says the list is the mutations still owed', () => {
    const printed = plainRun({labelList: ok('[]'), mutation: REFUSED});

    expect(printed).toContain(DEGRADED_LINE);
    expect(printed).toContain('the mutations still owed');
    expect(printed).not.toContain('the whole registry');
  });
});
