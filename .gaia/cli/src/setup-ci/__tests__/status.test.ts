import {mkdirSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, it, vi} from 'vitest';
import {localAutomationPath} from '../../automation/paths.js';
import {run} from '../status.js';
import {
  setupSandbox,
  VALID_BASE_CONFIG,
  type Sandbox,
} from './sandbox.js';

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

describe('setup-ci status', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-ci-status-');
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  it('returns configured: false when .gaia/automation.json is missing', () => {
    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;
    expect(parsed.configured).toBe(false);
    expect(parsed.tools_enabled).toEqual([]);
  });

  it('returns configured: true with full report when config is present', () => {
    sandbox.writeConfig({
      ...VALID_BASE_CONFIG,
      pnpm_audit: {mode: 'local', schedule: 'weekly'},
      setup_complete: false,
    });

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;
    expect(parsed.configured).toBe(true);
    expect(parsed.setup_complete).toBe(false);
    expect(parsed.setup_opted_out).toBe(false);
    // `pnpm_audit` is local, so only the other three are CI-mode.
    expect(parsed.tools_enabled).toEqual(['wiki', 'update-deps', 'stale-branches']);
  });

  it('reports nudge_dismissed from .gaia/local/automation.json when present', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);
    mkdirSync(path.dirname(localAutomationPath(sandbox.root)), {recursive: true});
    writeFileSync(
      localAutomationPath(sandbox.root),
      JSON.stringify({nudge_dismissed: true, version: 1}),
      'utf8'
    );

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;
    expect(parsed.nudge_dismissed).toBe(true);
  });

  it('exits non-zero when local file is malformed', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);
    mkdirSync(path.dirname(localAutomationPath(sandbox.root)), {recursive: true});
    writeFileSync(
      localAutomationPath(sandbox.root),
      JSON.stringify({nudge_dismissed: 'yes', version: 1}),
      'utf8'
    );

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('local_malformed');
  });

  it('exits non-zero when committed config is malformed', () => {
    sandbox.writeConfig({
      ...VALID_BASE_CONFIG,
      version: 99 as unknown as 1,
    });

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('config_malformed');
  });

  it('emits a human report without --json', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const out = stdio.out.join('');
    expect(out).toContain('configured: true');
    expect(out).toContain('tools_enabled:');
  });

  it('emits a missing-config human message when .gaia/automation.json absent', () => {
    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);

    expect(stdio.out.join('')).toContain('not configured');
  });

  it('rejects unknown flags', () => {
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('unknown flag');
  });

  it('--help exits 0', () => {
    const exit = run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('Usage:');
  });
});
