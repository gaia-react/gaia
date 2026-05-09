/**
 * UAT-019 integration scenarios.
 *
 * The both-predicates rule (label `gaia-ci` AND author
 * `github-actions[bot]`) is enforced server-side by the `gh pr list`
 * filter; the CLI's job is to ALWAYS pass both predicates and surface
 * the response. These tests verify:
 *
 *  1. argv to `gh pr list` always contains both `--label` and
 *     `--author` (false-positive guard).
 *  2. decision: "skip" only when the mocked response has an entry.
 *  3. decision: "proceed" on `[]`.
 *  4. exit non-zero on `gh` failure.
 *  5. custom `--author` is passed through.
 */
import {afterEach, beforeEach, describe, expect, it, vi} from 'vitest';
import {run} from '../../src/ci/stale-check.js';
import {installGhMock, type GhMock} from './gh-mock.js';
import {captureStdio, setupSandbox, type Sandbox} from './sandbox.js';

describe('UAT-019 — stale-PR pre-run skip', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;
  let mock: GhMock;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-stale-check-fixture-');
    stdio = captureStdio();
  });

  afterEach(() => {
    mock?.restore();
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  it('decision: "skip" when both predicates match an open PR', () => {
    mock = installGhMock({
      gh: [
        {
          match: 'pr list',
          response: {
            exitCode: 0,
            stderr: '',
            stdout: JSON.stringify([
              {
                createdAt: '2026-05-09T03:00:00Z',
                headRefName: 'gaia-ci/wiki/2026-05-09',
                number: 42,
              },
            ]),
          },
        },
      ],
    });

    const exit = run(
      ['--label', 'gaia-ci', '--base', 'main', '--json'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(0);

    const printed = JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;
    expect(printed.decision).toBe('skip');
    expect(printed.open_pr_number).toBe(42);

    const argv = mock.ghCalls[0]?.argv ?? [];
    // Both predicates appear, exactly once each.
    expect(argv.filter((a) => a === '--label').length).toBe(1);
    expect(argv.filter((a) => a === '--author').length).toBe(1);
    const labelIdx = argv.indexOf('--label');
    const authorIdx = argv.indexOf('--author');
    expect(argv[labelIdx + 1]).toBe('gaia-ci');
    expect(argv[authorIdx + 1]).toBe('github-actions[bot]');
  });

  it('decision: "proceed" when gh returns []', () => {
    mock = installGhMock({
      gh: [{match: 'pr list', response: {exitCode: 0, stderr: '', stdout: '[]'}}],
    });

    const exit = run(
      ['--label', 'gaia-ci', '--base', 'main', '--json'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(0);

    const printed = JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;
    expect(printed.decision).toBe('proceed');
    expect(printed.open_pr_number).toBeNull();
    expect(printed.open_pr_branch).toBeNull();
    expect(printed.skip_log_line).toBeNull();
  });

  it('explicit --author is passed through verbatim', () => {
    mock = installGhMock({
      gh: [{match: 'pr list', response: {exitCode: 0, stderr: '', stdout: '[]'}}],
    });

    run(
      [
        '--label',
        'gaia-ci',
        '--base',
        'main',
        '--author',
        'someone-else',
        '--json',
      ],
      {cwd: sandbox.root}
    );

    const argv = mock.ghCalls[0]?.argv ?? [];
    const authorIdx = argv.indexOf('--author');
    expect(argv[authorIdx + 1]).toBe('someone-else');
  });

  it('exits non-zero with structured error on gh failure', () => {
    mock = installGhMock({
      gh: [
        {
          match: 'pr list',
          response: {exitCode: 4, stderr: 'gh: not authenticated', stdout: ''},
        },
      ],
    });

    const exit = run(
      ['--label', 'gaia-ci', '--base', 'main', '--json'],
      {cwd: sandbox.root}
    );
    expect(exit).not.toBe(0);

    const errors = stdio.err.join('');
    expect(errors).toContain('gh_invocation_failed');

    const stdout = stdio.out.join('').trim();
    expect(stdout).toContain('gh_invocation_failed');
  });

  it('false-positive guard: even when only label "looks right", we ALWAYS pass both flags', () => {
    // The "false-positive guard" the SPEC requires is that the CLI
    // never tries to filter responses client-side; the predicates are
    // server-side. So the only thing to assert here is that both flags
    // appear in argv on every invocation. Already covered by the first
    // test; this one re-confirms with a different label/base.
    mock = installGhMock({
      gh: [{match: 'pr list', response: {exitCode: 0, stderr: '', stdout: '[]'}}],
    });

    run(
      ['--label', 'gaia-ci', '--base', 'master', '--json'],
      {cwd: sandbox.root}
    );

    const argv = mock.ghCalls[0]?.argv ?? [];
    expect(argv).toContain('--label');
    expect(argv).toContain('--author');
    expect(argv).toContain('--base');
    expect(argv).toContain('master');
  });
});
