import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {writeFileSync} from 'node:fs';
import {automationConfigPath} from '../../automation/paths.js';
import {readAutomationConfig} from '../../schemas/automation-config.js';
import {run} from '../write-tool-mode.js';
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

describe('setup-ci write-tool-mode', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-ci-write-tool-mode-');
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('flips a tool mode to off and preserves schedule', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);

    const exit = run(['stale-branches', 'off'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const result = readAutomationConfig(sandbox.root);
    expect(result.status).toBe('ok');
    assertStatusOk(result);

    expect(result.config.stale_branches.mode).toBe('off');
    // Schedule preserved.
    expect(result.config.stale_branches.schedule).toBe('monthly');
  });

  test('writes mode without schedule when existing slot has none', () => {
    sandbox.writeConfig({
      ...VALID_BASE_CONFIG,
      update_deps: {mode: 'ci'},
    });

    const exit = run(['update-deps', 'local'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const result = readAutomationConfig(sandbox.root);
    expect(result.status).toBe('ok');
    assertStatusOk(result);

    expect(result.config.update_deps.mode).toBe('local');
    expect(result.config.update_deps.schedule).toBeUndefined();
  });

  test('emits {tool, mode} JSON on success', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);

    const exit = run(['wiki', 'local'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.tool).toBe('wiki');
    expect(parsed.mode).toBe('local');
  });

  test('exits invalid_arguments on unknown tool', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);

    const exit = run(['bogus-tool', 'off'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('unknown tool');
  });

  test('exits invalid_arguments on unknown mode', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);

    const exit = run(['wiki', 'bogus'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('invalid mode');
  });

  test('exits config_missing when config absent', () => {
    const exit = run(['wiki', 'off'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('config_missing');
  });

  test('exits config_malformed when config fails schema', () => {
    writeFileSync(
      automationConfigPath(sandbox.root),
      JSON.stringify({...VALID_BASE_CONFIG, version: 99}),
      'utf8'
    );

    const exit = run(['wiki', 'off'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('config_malformed');
  });

  test('exits missing_required_arg when mode missing', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);

    const exit = run(['wiki'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('missing_required_arg');
  });

  test('--help exits 0', () => {
    const exit = run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('Usage:');
  });
});
