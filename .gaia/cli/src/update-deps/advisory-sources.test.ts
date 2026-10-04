import {describe, expect, test} from 'vitest';
import type {GhOptions, GhResult} from '../setup-ci/util/gh.js';
import {
  fetchDependabotAlerts,
  ghFailureReason,
  parseAlertPages,
  resolveGithubRepository,
  runPnpmAudit,
} from './advisory-sources.js';

const failure = (
  stderr: string,
  exitCode = 1
): Extract<GhResult, {ok: false}> => ({exitCode, ok: false, stderr});

describe('parseAlertPages', () => {
  test('reads every page of concatenated JSON arrays', () => {
    expect(
      parseAlertPages('[{"number":1}][{"number":2},{"number":3}]\n')
    ).toHaveLength(3);
  });

  test('tolerates brackets inside strings', () => {
    expect(parseAlertPages('[{"a":"]["}]\n[]')).toStrictEqual([{a: ']['}]);
  });

  test.each([
    ['empty output', ''],
    ['a truncated page', '[{"number":1}'],
    ['an object instead of an array', '{"message":"x"}'],
    ['trailing text', '[] oops'],
  ])('throws on %s', (_label, stdout) => {
    expect(() => parseAlertPages(stdout)).toThrow(/alerts/u);
  });
});

describe('ghFailureReason', () => {
  test.each([
    [failure('spawn gh ENOENT', -1), 'gh-missing'],
    [failure('', 4), 'gh-unauthenticated'],
    [
      failure('You are not logged into any GitHub hosts. Run gh auth login'),
      'gh-unauthenticated',
    ],
    [
      failure(
        'gh: Dependabot alerts are disabled for this repository. (HTTP 403)'
      ),
      'alerts-disabled',
    ],
    [
      failure(
        'gh: Dependabot alerts are disabled for this repository. (HTTP 404)'
      ),
      'alerts-disabled',
    ],
    [
      failure('gh: Resource not accessible by integration (HTTP 403)'),
      'forbidden',
    ],
    [failure('gh: Not Found (HTTP 404)'), 'alerts-request-failed'],
    [
      {...failure(''), exitCode: -1, timedOut: true as const},
      'alerts-request-failed',
    ],
  ])('maps a failure to its reason token (%#)', (result, token) => {
    expect(ghFailureReason(result)).toBe(token);
  });
});

describe('resolveGithubRepository', () => {
  test('parses a github.com origin', () => {
    expect(
      resolveGithubRepository('/repo', () => 'git@github.com:acme/widgets.git')
    ).toStrictEqual({ok: true, owner: 'acme', repo: 'widgets'});
  });

  test('refuses a non-GitHub host and a missing origin', () => {
    expect(
      resolveGithubRepository('/repo', () => 'git@gitlab.com:acme/widgets.git')
    ).toStrictEqual({ok: false, reason: 'non-github-remote'});
    expect(resolveGithubRepository('/repo', () => null)).toStrictEqual({
      ok: false,
      reason: 'no-remote',
    });
  });
});

describe('fetchDependabotAlerts', () => {
  test('passes a 60 second timeout and never the gh placeholder', async () => {
    const calls: GhOptions[] = [];
    const result = await fetchDependabotAlerts({
      cwd: '/repo',
      env: {},
      ghRunner: async (options) => {
        calls.push(options);

        return {ok: true, stdout: '[]'};
      },
      includeDismissed: true,
      owner: 'acme',
      repo: 'widgets',
    });

    expect(result.ok).toBe(true);
    expect(calls.map((call) => call.args[2])).toStrictEqual([
      'repos/acme/widgets/dependabot/alerts?state=open&ecosystem=npm&per_page=100',
      'repos/acme/widgets/dependabot/alerts?state=dismissed,auto_dismissed&ecosystem=npm&per_page=100',
    ]);
    expect(calls.every((call) => call.timeoutMs === 60_000)).toBe(true);
  });
});

describe('runPnpmAudit', () => {
  test('a non-zero exit with an advisories object is a success', () => {
    const result = runPnpmAudit({
      cwd: '/repo',
      pnpmRunner: () => ({status: 1, stderr: '', stdout: '{"advisories":{}}'}),
    });

    expect(result.ok).toBe(true);
  });

  test.each([
    ['output that is not JSON', {status: 1, stderr: '', stdout: 'boom'}],
    [
      'output without advisories',
      {status: 0, stderr: '', stdout: '{"error":{}}'},
    ],
    ['a spawn that timed out', {status: null, stderr: '', stdout: ''}],
  ])('fails on %s', (_label, response) => {
    expect(runPnpmAudit({cwd: '/repo', pnpmRunner: () => response}).ok).toBe(
      false
    );
  });
});
