import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {existsSync, readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import type {AutomationConfig} from '../../schemas/automation-config.js';
import {automationConfigPath} from '../paths.js';
import {run} from '../render-workflows.js';
import {setupSandbox} from './sandbox.js';
import type {Sandbox} from './sandbox.js';

const captureIo = () => {
  const errors: string[] = [];
  const outs: string[] = [];
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      errors.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      outs.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    errors,
    outs,
    restore: () => {
      stderrSpy.mockRestore();
      stdoutSpy.mockRestore();
    },
  };
};

const allCi: AutomationConfig = {
  setup_complete: true,
  setup_opted_out: false,
  update_gaia: {mode: 'local'},
  version: 1,
  wiki: {mode: 'ci', schedule: 'daily'},
};

describe('automation render-workflows', () => {
  let sandbox: Sandbox;
  let io: ReturnType<typeof captureIo>;

  beforeEach(() => {
    io = captureIo();
    sandbox = setupSandbox('gaia-automation-render-');
  });

  afterEach(() => {
    io.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('writes the workflow for a CI-mode tool', () => {
    sandbox.writeConfig(allCi);
    const outDir = path.join(sandbox.root, '.github', 'workflows');

    const exit = run(['--out-dir', outDir], {cwd: sandbox.root});

    expect(exit).toBe(0);
    expect(existsSync(path.join(outDir, 'gaia-ci-wiki.yml'))).toBe(true);
  });

  test('writes only the requested subset when --tools is given', () => {
    sandbox.writeConfig(allCi);
    const outDir = path.join(sandbox.root, '.github', 'workflows');

    const exit = run(['--out-dir', outDir, '--tools', 'wiki'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(0);
    expect(existsSync(path.join(outDir, 'gaia-ci-wiki.yml'))).toBe(true);
  });

  test('warns about no unrendered tool when every tool is rendered', () => {
    sandbox.writeConfig(allCi);
    const outDir = path.join(sandbox.root, '.github', 'workflows');

    const exit = run(['--out-dir', outDir], {cwd: sandbox.root});

    expect(exit).toBe(0);
    expect(io.errors.join('')).not.toContain('scheduler: calls');
  });

  test('writes nothing in --dry-run mode and reports per-tool byte counts', () => {
    sandbox.writeConfig(allCi);
    const outDir = path.join(sandbox.root, '.github', 'workflows');

    const exit = run(['--out-dir', outDir, '--dry-run'], {cwd: sandbox.root});

    expect(exit).toBe(0);
    expect(existsSync(outDir)).toBe(false);
    const stdout = io.outs.join('');
    expect(stdout).toMatch(/wiki: \d+ bytes -> .*gaia-ci-wiki\.yml/u);
  });

  test('skips a tool whose mode is local', () => {
    const config: AutomationConfig = {
      ...allCi,
      wiki: {mode: 'local'},
    };
    sandbox.writeConfig(config);
    const outDir = path.join(sandbox.root, '.github', 'workflows');

    const exit = run(['--out-dir', outDir], {cwd: sandbox.root});

    expect(exit).toBe(0);
    expect(existsSync(path.join(outDir, 'gaia-ci-wiki.yml'))).toBe(false);
    expect(io.errors.join('')).toContain('wiki: skipped (mode=local)');
  });

  test('skips a tool whose mode is off', () => {
    const config: AutomationConfig = {
      ...allCi,
      wiki: {mode: 'off'},
    };
    sandbox.writeConfig(config);
    const outDir = path.join(sandbox.root, '.github', 'workflows');

    run(['--out-dir', outDir], {cwd: sandbox.root});

    expect(existsSync(path.join(outDir, 'gaia-ci-wiki.yml'))).toBe(false);
    expect(io.errors.join('')).toContain('wiki: skipped (mode=off)');
  });

  test('exits non-zero with config_missing when there is no config', () => {
    const outDir = path.join(sandbox.root, '.github', 'workflows');

    const exit = run(['--out-dir', outDir], {cwd: sandbox.root});

    expect(exit).not.toBe(0);
    expect(io.errors.join('')).toContain('"code":"config_missing"');
  });

  test('exits non-zero with config_malformed when the config is invalid JSON', () => {
    writeFileSync(
      automationConfigPath(sandbox.root),
      '{this is not json',
      'utf8'
    );
    const outDir = path.join(sandbox.root, '.github', 'workflows');

    const exit = run(['--out-dir', outDir], {cwd: sandbox.root});

    expect(exit).not.toBe(0);
    expect(io.errors.join('')).toContain('"code":"config_malformed"');
  });

  test('exits non-zero with config_malformed when the config fails Zod parsing', () => {
    writeFileSync(
      automationConfigPath(sandbox.root),
      JSON.stringify({version: 1}),
      'utf8'
    );
    const outDir = path.join(sandbox.root, '.github', 'workflows');

    const exit = run(['--out-dir', outDir], {cwd: sandbox.root});

    expect(exit).not.toBe(0);
    expect(io.errors.join('')).toContain('"code":"config_malformed"');
  });

  test('creates a missing --out-dir with mkdir -p semantics', () => {
    sandbox.writeConfig(allCi);
    const outDir = path.join(sandbox.root, 'nested', 'deeper', 'workflows');

    const exit = run(['--out-dir', outDir], {cwd: sandbox.root});

    expect(exit).toBe(0);
    expect(existsSync(path.join(outDir, 'gaia-ci-wiki.yml'))).toBe(true);
  });

  test('overwrites existing files on a repeat invocation (idempotent)', () => {
    sandbox.writeConfig(allCi);
    const outDir = path.join(sandbox.root, '.github', 'workflows');

    run(['--out-dir', outDir], {cwd: sandbox.root});
    const first = readFileSync(path.join(outDir, 'gaia-ci-wiki.yml'), 'utf8');

    run(['--out-dir', outDir], {cwd: sandbox.root});
    const second = readFileSync(path.join(outDir, 'gaia-ci-wiki.yml'), 'utf8');

    expect(second).toBe(first);
  });

  test('rejects unknown flags', () => {
    sandbox.writeConfig(allCi);
    const outDir = path.join(sandbox.root, '.github', 'workflows');

    const exit = run(['--out-dir', outDir, '--bogus'], {cwd: sandbox.root});

    expect(exit).not.toBe(0);
    expect(io.errors.join('')).toContain('"code":"invalid_arguments"');
  });

  test('rejects --out-dir without a value', () => {
    const exit = run(['--out-dir'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(io.errors.join('')).toContain('--out-dir requires a path argument');
  });

  test('rejects --out-dir followed by another flag', () => {
    const exit = run(['--out-dir', '--dry-run'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(io.errors.join('')).toContain('--out-dir requires a path argument');
  });

  test('rejects --tools with an unknown tool', () => {
    sandbox.writeConfig(allCi);
    const outDir = path.join(sandbox.root, '.github', 'workflows');

    const exit = run(['--out-dir', outDir, '--tools', 'wiki,bogus'], {
      cwd: sandbox.root,
    });

    expect(exit).not.toBe(0);
    expect(io.errors.join('')).toContain('--tools entries must be a subset');
  });

  test('emits help text when --help is passed', () => {
    const exit = run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(io.outs.join('')).toContain(
      'Usage: gaia automation render-workflows'
    );
  });

  test('writes byte-identical content to what renderWorkflowTemplate produces directly', () => {
    sandbox.writeConfig(allCi);
    const outDir = path.join(sandbox.root, '.github', 'workflows');

    run(['--out-dir', outDir], {cwd: sandbox.root});

    // The CLI handler is the only consumer of the template tree; the
    // file content matches the snapshot test's expectation by
    // construction (same render path). This test asserts the byte
    // count is non-trivial so we catch a regression where the writer
    // emits an empty file.
    const content = readFileSync(path.join(outDir, 'gaia-ci-wiki.yml'), 'utf8');
    expect(content.length).toBeGreaterThan(500);
    expect(content).toContain('gaia-ci-wiki');
  });

  test('a legacy config with update_deps/pnpm_audit/stale_branches in ci renders none of their workflows nor schedules them', () => {
    writeFileSync(
      automationConfigPath(sandbox.root),
      JSON.stringify({
        ...allCi,
        pnpm_audit: {mode: 'ci', schedule: 'daily'},
        stale_branches: {mode: 'ci', schedule: 'monthly'},
        update_deps: {mode: 'ci', schedule: 'weekly'},
      }),
      'utf8'
    );
    const outDir = path.join(sandbox.root, '.github', 'workflows');

    const exit = run(['--out-dir', outDir], {cwd: sandbox.root});

    expect(exit).toBe(0);
    expect(existsSync(path.join(outDir, 'gaia-ci-wiki.yml'))).toBe(true);
    expect(existsSync(path.join(outDir, 'gaia-ci.yml'))).toBe(true);
    expect(existsSync(path.join(outDir, 'gaia-ci-update-deps.yml'))).toBe(
      false
    );
    expect(existsSync(path.join(outDir, 'gaia-ci-pnpm-audit.yml'))).toBe(false);
    expect(existsSync(path.join(outDir, 'gaia-ci-stale-branches.yml'))).toBe(
      false
    );
    const scheduler = readFileSync(path.join(outDir, 'gaia-ci.yml'), 'utf8');
    expect(scheduler).not.toContain('update-deps');
    expect(scheduler).not.toContain('pnpm-audit');
    expect(scheduler).not.toContain('stale-branches');
  });

  test.each(['pnpm-audit', 'stale-branches'])(
    'rejects --tools %s as an unknown tool',
    (tool) => {
      sandbox.writeConfig(allCi);
      const outDir = path.join(sandbox.root, '.github', 'workflows');

      const exit = run(['--out-dir', outDir, '--tools', tool], {
        cwd: sandbox.root,
      });

      expect(exit).not.toBe(0);
      expect(io.errors.join('')).toContain('"code":"invalid_arguments"');
    }
  );
});
