import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for `gaia init configure-automation`.
 */
import assert from 'node:assert/strict';
import {existsSync, mkdtempSync, readFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {automationConfigPath} from '../automation/paths.js';
import {
  AutomationConfigSchema,
  readAutomationConfig,
} from '../schemas/automation-config.js';
import {writeAutomationConfig} from '../setup-ci/util/automation-write.js';
import {run} from './configure-automation.js';
import {readState} from './util/state.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(
    path.join(tmpdir(), 'gaia-init-configure-automation-')
  );

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
  '--update-deps',
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
      stale_branches: {mode: 'ci', schedule: 'monthly'},
      update_deps: {mode: 'ci', schedule: 'weekly'},
      update_gaia: {mode: 'local'},
      version: 1,
      wiki: {mode: 'ci'},
    });

    const state = readState(sandbox.root);
    expect(state.completed_steps).toContain('configure-automation');
    expect(state.step_args['configure-automation']).toEqual({
      pnpm_audit: 'ci',
      stale_branches: 'ci',
      update_deps: 'ci',
      wiki: 'ci',
    });
  });

  test('happy path: mixed values are recorded faithfully', () => {
    sandbox = setupSandbox();

    const exit = run(
      [
        '--wiki',
        'local',
        '--update-deps',
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
    expect(parsed.update_deps.mode).toBe('off');
    expect(parsed.pnpm_audit.mode).toBe('ci');
    expect(parsed.stale_branches.mode).toBe('ci');
    expect(parsed.update_gaia.mode).toBe('local');
    expect(parsed.setup_complete).toBe(false);
    expect(parsed.setup_opted_out).toBe(false);
  });

  test('--sandbox-recommended true writes sandbox_recommended: true', () => {
    sandbox = setupSandbox();

    const exit = run([...allCiArgs, '--sandbox-recommended', 'true'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const raw = readFileSync(automationConfigPath(sandbox.root), 'utf8');
    const parsed = AutomationConfigSchema.parse(JSON.parse(raw));
    expect(parsed.sandbox_recommended).toBe(true);
  });

  test('--sandbox-recommended false writes sandbox_recommended: false', () => {
    sandbox = setupSandbox();

    const exit = run([...allCiArgs, '--sandbox-recommended', 'false'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const raw = readFileSync(automationConfigPath(sandbox.root), 'utf8');
    const parsed = AutomationConfigSchema.parse(JSON.parse(raw));
    expect(parsed.sandbox_recommended).toBe(false);
  });

  test('omitting --sandbox-recommended omits the key entirely', () => {
    sandbox = setupSandbox();

    const exit = run(allCiArgs, {cwd: sandbox.root});
    expect(exit).toBe(0);

    const raw = readFileSync(automationConfigPath(sandbox.root), 'utf8');
    const written: Record<string, unknown> = JSON.parse(raw);
    expect('sandbox_recommended' in written).toBe(false);

    const result = readAutomationConfig(sandbox.root);
    expect(result.status).toBe('ok');
  });

  test('round-trip: readAutomationConfig -> writeAutomationConfig preserves a present sandbox_recommended', () => {
    sandbox = setupSandbox();

    const exit = run([...allCiArgs, '--sandbox-recommended', 'true'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const result = readAutomationConfig(sandbox.root);
    expect(result.status).toBe('ok');
    assert.ok(result.status === 'ok');

    writeAutomationConfig(sandbox.root, result.config);

    const raw = readFileSync(automationConfigPath(sandbox.root), 'utf8');
    const parsed = AutomationConfigSchema.parse(JSON.parse(raw));
    expect(parsed.sandbox_recommended).toBe(true);
  });

  test('exit 1 when --sandbox-recommended value is invalid', () => {
    sandbox = setupSandbox();

    const exit = run([...allCiArgs, '--sandbox-recommended', 'maybe'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain(
      '--sandbox-recommended must be one of: true, false'
    );
    expect(existsSync(automationConfigPath(sandbox.root))).toBe(false);
  });

  test.each(['always-worktree', 'prefer-branch', 'prefer-worktree'] as const)(
    '--isolation-policy %s writes isolation_policy: %s',
    (policy) => {
      sandbox = setupSandbox();

      const exit = run([...allCiArgs, '--isolation-policy', policy], {
        cwd: sandbox.root,
      });
      expect(exit).toBe(0);

      const raw = readFileSync(automationConfigPath(sandbox.root), 'utf8');
      const parsed = AutomationConfigSchema.parse(JSON.parse(raw));
      expect(parsed.isolation_policy).toBe(policy);
    }
  );

  test('omitting --isolation-policy omits the key entirely', () => {
    sandbox = setupSandbox();

    const exit = run(allCiArgs, {cwd: sandbox.root});
    expect(exit).toBe(0);

    const raw = readFileSync(automationConfigPath(sandbox.root), 'utf8');
    const written: Record<string, unknown> = JSON.parse(raw);
    expect('isolation_policy' in written).toBe(false);

    const result = readAutomationConfig(sandbox.root);
    expect(result.status).toBe('ok');
  });

  test('exit 1 when --isolation-policy value is invalid', () => {
    sandbox = setupSandbox();

    const exit = run([...allCiArgs, '--isolation-policy', 'bogus'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain(
      '--isolation-policy must be one of: always-worktree, prefer-branch, prefer-worktree'
    );
    expect(existsSync(automationConfigPath(sandbox.root))).toBe(false);
  });

  test('configure-automation writes complete config with all-local modes (CI-declined derivation)', () => {
    sandbox = setupSandbox();

    const exit = run(
      [
        '--wiki',
        'local',
        '--update-deps',
        'local',
        '--pnpm-audit',
        'local',
        '--stale-branches',
        'local',
      ],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toBe('');
    expect(stdio.errors.join('')).toBe('');

    const raw = readFileSync(automationConfigPath(sandbox.root), 'utf8');
    const parsed = AutomationConfigSchema.parse(JSON.parse(raw));
    expect(parsed).toEqual({
      pnpm_audit: {mode: 'local', schedule: 'daily'},
      setup_complete: false,
      setup_opted_out: false,
      stale_branches: {mode: 'local', schedule: 'monthly'},
      update_deps: {mode: 'local', schedule: 'weekly'},
      update_gaia: {mode: 'local'},
      version: 1,
      wiki: {mode: 'local'},
    });

    const state = readState(sandbox.root);
    expect(state.completed_steps).toContain('configure-automation');
    expect(state.step_args['configure-automation']).toEqual({
      pnpm_audit: 'local',
      stale_branches: 'local',
      update_deps: 'local',
      wiki: 'local',
    });
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
      ['--update-deps', 'ci', '--pnpm-audit', 'ci', '--stale-branches', 'ci'],
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

  test('exit 1 when --update-deps missing', () => {
    sandbox = setupSandbox();
    const exit = run(
      ['--wiki', 'ci', '--pnpm-audit', 'ci', '--stale-branches', 'ci'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--update-deps is required');
  });

  test('exit 1 when --pnpm-audit missing', () => {
    sandbox = setupSandbox();
    const exit = run(
      ['--wiki', 'ci', '--update-deps', 'ci', '--stale-branches', 'ci'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--pnpm-audit is required');
  });

  test('exit 1 when --stale-branches missing', () => {
    sandbox = setupSandbox();
    const exit = run(
      ['--wiki', 'ci', '--update-deps', 'ci', '--pnpm-audit', 'ci'],
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
        '--update-deps',
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
        '--update-deps',
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
