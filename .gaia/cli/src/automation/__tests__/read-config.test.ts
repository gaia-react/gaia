import {afterEach, beforeEach, describe, expect, it, vi} from 'vitest';
import {run} from '../read-config.js';
import {VALID_BASE_CONFIG, setupSandbox, type Sandbox} from './sandbox.js';

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

describe('automation read-config', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupSandbox('gaia-automation-read-config-');
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  it('emits JSON with --json', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);
    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const out = stdio.outputs.join('');
    const parsed = JSON.parse(out) as Record<string, unknown>;
    expect(parsed.version).toBe(1);
    expect((parsed.wiki as Record<string, string>).mode).toBe('ci');
  });

  it('emits a human report without --json', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);
    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const out = stdio.outputs.join('');
    expect(out).toContain('wiki: mode=ci');
    expect(out).toContain('schedule=daily');
  });

  it('exits non-zero with config_missing when the file does not exist', () => {
    const exit = run([], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.errors.join('')).toContain('config_missing');
  });

  it('exits non-zero with config_malformed for malformed JSON', () => {
    sandbox.writeConfig({...VALID_BASE_CONFIG, version: 2 as unknown as 1});
    const exit = run([], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.errors.join('')).toContain('config_malformed');
  });

  it('rejects unknown flags', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.errors.join('')).toContain('unknown argument');
  });

  it('--help exits 0', () => {
    const exit = run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('Usage:');
  });
});
