import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {readFileSync, writeFileSync} from 'node:fs';
import {automationConfigPath} from '../../automation/paths.js';
import {EXIT_CODES} from '../../exit.js';
import {
  ISOLATION_POLICIES,
  readAutomationConfig,
} from '../../schemas/automation-config.js';
import {run} from '../write-isolation-policy.js';
import {assertStatusOk, setupSandbox, VALID_BASE_CONFIG} from './sandbox.js';
import type {Sandbox} from './sandbox.js';

const captureStdio = (): {
  err: string[];
  out: string[];
  restore: () => void;
} => {
  const out: string[] = [];
  const err: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      out.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      err.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    err,
    out,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

const readRaw = (root: string): Record<string, unknown> =>
  JSON.parse(readFileSync(automationConfigPath(root), 'utf8')) as Record<
    string,
    unknown
  >;

describe('setup-ci write-isolation-policy', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-ci-write-isolation-policy-');
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('read-merge preservation: an unknown key a newer binary wrote survives (UAT-019)', () => {
    writeFileSync(
      automationConfigPath(sandbox.root),
      JSON.stringify({...VALID_BASE_CONFIG, some_future_key: 'x'}),
      'utf8'
    );

    const exit = run(['prefer-worktree'], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.OK);

    const written = readRaw(sandbox.root);
    expect(written.some_future_key).toBe('x');
    expect(written.isolation_policy).toBe('prefer-worktree');

    for (const [key, value] of Object.entries(VALID_BASE_CONFIG)) {
      expect(written[key]).toEqual(value);
    }
  });

  test.each(ISOLATION_POLICIES)('writes isolation_policy: %s', (policy) => {
    sandbox.writeConfig(VALID_BASE_CONFIG);

    const exit = run([policy], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.OK);

    const result = readAutomationConfig(sandbox.root);
    expect(result.status).toBe('ok');
    assertStatusOk(result);
    expect(result.config.isolation_policy).toBe(policy);
  });

  test('overwrites an existing isolation_policy (the --reconfigure path)', () => {
    writeFileSync(
      automationConfigPath(sandbox.root),
      JSON.stringify({
        ...VALID_BASE_CONFIG,
        isolation_policy: 'always-worktree',
      }),
      'utf8'
    );

    const exit = run(['prefer-branch'], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.OK);

    const result = readAutomationConfig(sandbox.root);
    expect(result.status).toBe('ok');
    assertStatusOk(result);
    expect(result.config.isolation_policy).toBe('prefer-branch');
  });

  test('emits {isolation_policy} JSON on success', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);

    const exit = run(['always-worktree'], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.OK);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.isolation_policy).toBe('always-worktree');
  });

  test('exits CONFIG_INVALID and writes nothing when config is missing', () => {
    const exit = run(['prefer-branch'], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.CONFIG_INVALID);
    expect(stdio.err.join('')).toContain('config_missing');

    const result = readAutomationConfig(sandbox.root);
    expect(result.status).toBe('missing');
  });

  test('exits CONFIG_INVALID and writes nothing when config is malformed', () => {
    writeFileSync(
      automationConfigPath(sandbox.root),
      JSON.stringify({...VALID_BASE_CONFIG, setup_complete: 'not-a-boolean'}),
      'utf8'
    );

    const exit = run(['prefer-branch'], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.CONFIG_INVALID);
    expect(stdio.err.join('')).toContain('config_malformed');

    const written = readRaw(sandbox.root);
    expect(written.setup_complete).toBe('not-a-boolean');
  });

  test('exits 1 on an unrecognized value and writes nothing', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);

    const exit = run(['always-wortree'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.err.join('')).toContain('unrecognized isolation policy');

    const result = readAutomationConfig(sandbox.root);
    expect(result.status).toBe('ok');
    assertStatusOk(result);
    expect(result.config.isolation_policy).toBeUndefined();
  });

  test('version is untouched', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);

    const exit = run(['prefer-worktree'], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.OK);

    const result = readAutomationConfig(sandbox.root);
    expect(result.status).toBe('ok');
    assertStatusOk(result);
    expect(result.config.version).toBe(1);
  });

  test('rejects unexpected extra arguments', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);

    const exit = run(['prefer-branch', '--bogus'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('unexpected argument');
  });

  test('--help exits 0', () => {
    const exit = run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('Usage:');
  });
});
