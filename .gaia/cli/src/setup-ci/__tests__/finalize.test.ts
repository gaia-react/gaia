import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {writeFileSync} from 'node:fs';
import {automationConfigPath} from '../../automation/paths.js';
import {readAutomationConfig} from '../../schemas/automation-config.js';
import {run} from '../finalize.js';
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

describe('setup-ci finalize', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-ci-finalize-');
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('flips setup_complete=true on a pending config', () => {
    sandbox.writeConfig({...VALID_BASE_CONFIG, setup_complete: false});

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const result = readAutomationConfig(sandbox.root);
    expect(result.status).toBe('ok');

    if (result.status === 'ok') {
      expect(result.config.setup_complete).toBe(true);
    }

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.finalized).toBe(true);
    expect(parsed.already_finalized).toBe(false);
  });

  test('returns already_finalized: true when config is already finalized', () => {
    sandbox.writeConfig({...VALID_BASE_CONFIG, setup_complete: true});

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.finalized).toBe(true);
    expect(parsed.already_finalized).toBe(true);
  });

  test('exits config_missing when config is absent', () => {
    const exit = run([], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('config_missing');
  });

  test('exits config_malformed for malformed config', () => {
    writeFileSync(
      automationConfigPath(sandbox.root),
      JSON.stringify({...VALID_BASE_CONFIG, version: 99}),
      'utf8'
    );

    const exit = run([], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('config_malformed');
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
