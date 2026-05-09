/**
 * Tests for `gaia init configure-automation`.
 */
import {existsSync, mkdtempSync, readFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {automationConfigPath} from '../automation/paths.js';
import {AutomationConfigSchema} from '../schemas/automation-config.js';
import {run} from './configure-automation.js';
import {readState} from './util/state.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-init-configure-automation-'));

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
  };
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

const allCiArgs = [
  '--wiki',
  'ci',
  '--sharpen',
  'ci',
  '--pnpm-audit',
  'ci',
  '--stale-branches',
  'ci',
];

describe('init configure-automation', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('happy path: all four flags ci writes schema-valid config', () => {
    sandbox = setupSandbox();

    const exit = run(allCiArgs, {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toBe('');
    expect(stdio.errors.join('')).toBe('');

    const target = automationConfigPath(sandbox.root);
    expect(existsSync(target)).toBe(true);

    const raw = readFileSync(target, 'utf8');
    expect(raw.endsWith('\n')).toBe(true);

    const parsed = AutomationConfigSchema.parse(JSON.parse(raw));
    expect(parsed).toEqual({
      pnpm_audit: {mode: 'ci', schedule: 'daily'},
      setup_complete: false,
      setup_opted_out: false,
      sharpen: {mode: 'ci', schedule: 'weekly'},
      stale_branches: {mode: 'ci', schedule: 'monthly'},
      update_gaia: {mode: 'local'},
      version: 1,
      wiki: {mode: 'ci'},
    });

    const state = readState(sandbox.root);
    expect(state.completed_steps).toContain('configure-automation');
    expect(state.step_args['configure-automation']).toEqual({
      pnpm_audit: 'ci',
      sharpen: 'ci',
      stale_branches: 'ci',
      wiki: 'ci',
    });
  });

  test('happy path: mixed values are recorded faithfully', () => {
    sandbox = setupSandbox();

    const exit = run(
      [
        '--wiki',
        'local',
        '--sharpen',
        'off',
        '--pnpm-audit',
        'ci',
        '--stale-branches',
        'ci',
      ],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(0);

    const raw = readFileSync(automationConfigPath(sandbox.root), 'utf8');
    const parsed = AutomationConfigSchema.parse(JSON.parse(raw));
    expect(parsed.wiki.mode).toBe('local');
    expect(parsed.sharpen.mode).toBe('off');
    expect(parsed.pnpm_audit.mode).toBe('ci');
    expect(parsed.stale_branches.mode).toBe('ci');
    expect(parsed.update_gaia.mode).toBe('local');
    expect(parsed.setup_complete).toBe(false);
    expect(parsed.setup_opted_out).toBe(false);
  });

  test('idempotent: re-running with same flags writes byte-identical content', () => {
    sandbox = setupSandbox();

    const first = run(allCiArgs, {cwd: sandbox.root});
    expect(first).toBe(0);
    const target = automationConfigPath(sandbox.root);
    const firstContent = readFileSync(target, 'utf8');

    const second = run(allCiArgs, {cwd: sandbox.root});
    expect(second).toBe(0);
    const secondContent = readFileSync(target, 'utf8');
    expect(secondContent).toBe(firstContent);

    const state = readState(sandbox.root);
    const count = state.completed_steps.filter(
      (step) => step === 'configure-automation'
    ).length;
    expect(count).toBe(1);
  });

  test('exit 1 when --wiki missing', () => {
    sandbox = setupSandbox();
    const exit = run(
      ['--sharpen', 'ci', '--pnpm-audit', 'ci', '--stale-branches', 'ci'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(1);
    expect(existsSync(automationConfigPath(sandbox.root))).toBe(false);
    const state = readState(sandbox.root);
    expect(state.completed_steps).not.toContain('configure-automation');

    const errLine = stdio.errors.join('');
    expect(errLine).toContain('--wiki is required');
    expect(errLine).toContain('"subcommand":"init configure-automation"');
    expect(errLine).toContain('"code":"invalid_arguments"');
  });

  test('exit 1 when --sharpen missing', () => {
    sandbox = setupSandbox();
    const exit = run(
      ['--wiki', 'ci', '--pnpm-audit', 'ci', '--stale-branches', 'ci'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--sharpen is required');
  });

  test('exit 1 when --pnpm-audit missing', () => {
    sandbox = setupSandbox();
    const exit = run(
      ['--wiki', 'ci', '--sharpen', 'ci', '--stale-branches', 'ci'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--pnpm-audit is required');
  });

  test('exit 1 when --stale-branches missing', () => {
    sandbox = setupSandbox();
    const exit = run(
      ['--wiki', 'ci', '--sharpen', 'ci', '--pnpm-audit', 'ci'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--stale-branches is required');
  });

  test('exit 1 when --wiki value invalid', () => {
    sandbox = setupSandbox();
    const exit = run(
      [
        '--wiki',
        'bogus',
        '--sharpen',
        'ci',
        '--pnpm-audit',
        'ci',
        '--stale-branches',
        'ci',
      ],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain(
      '--wiki must be one of: ci, local, off'
    );
    expect(existsSync(automationConfigPath(sandbox.root))).toBe(false);
  });

  test('exit 1 when --wiki specified twice', () => {
    sandbox = setupSandbox();
    const exit = run(
      [
        '--wiki',
        'ci',
        '--wiki',
        'local',
        '--sharpen',
        'ci',
        '--pnpm-audit',
        'ci',
        '--stale-branches',
        'ci',
      ],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--wiki specified twice');
  });

  test('exit 1 on unknown flag', () => {
    sandbox = setupSandbox();
    const exit = run([...allCiArgs, '--bogus', 'value'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag: --bogus');
  });

  test('--help exits 0 with HELP_TEXT, no file written', () => {
    sandbox = setupSandbox();
    const exit = run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('configure-automation');
    expect(stdio.errors.join('')).toBe('');
    expect(existsSync(automationConfigPath(sandbox.root))).toBe(false);
  });

  test('-h exits 0 with HELP_TEXT', () => {
    sandbox = setupSandbox();
    const exit = run(['-h'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('configure-automation');
  });

  test('help token exits 0 with HELP_TEXT', () => {
    sandbox = setupSandbox();
    const exit = run(['help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('configure-automation');
  });
});
