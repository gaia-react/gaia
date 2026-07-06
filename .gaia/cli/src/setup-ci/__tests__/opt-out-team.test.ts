import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {writeFileSync} from 'node:fs';
import {automationConfigPath} from '../../automation/paths.js';
import {readAutomationConfig} from '../../schemas/automation-config.js';
import {run} from '../opt-out-team.js';
import {setupSandbox, VALID_BASE_CONFIG} from './sandbox.js';
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

describe('setup-ci opt-out-team', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-ci-opt-out-team-');
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('flips setup_opted_out=true preserving other fields', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const result = readAutomationConfig(sandbox.root);
    expect(result.status).toBe('ok');

    if (result.status === 'ok') {
      expect(result.config.setup_opted_out).toBe(true);
      // Other fields preserved.
      expect(result.config.wiki.mode).toBe('ci');
      expect(result.config.update_gaia.mode).toBe('local');
    }
  });

  test('exits config_missing when .gaia/automation.json is absent', () => {
    const exit = run([], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('config_missing');
  });

  test('exits config_malformed when config fails schema validation', () => {
    writeFileSync(
      automationConfigPath(sandbox.root),
      JSON.stringify({...VALID_BASE_CONFIG, version: 99}),
      'utf8'
    );

    const exit = run([], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('config_malformed');
  });

  test('emits opted_out: true JSON on success', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.opted_out).toBe(true);
  });

  test('rejects unexpected arguments', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);

    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('unexpected argument');
  });

  test('--help exits 0', () => {
    const exit = run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('Usage:');
  });
});
