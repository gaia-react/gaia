import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {chmodSync, readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {
  assertNotOk,
  assertOk,
  setupSandbox,
} from '../setup-ci/__tests__/sandbox.js';
import type {Sandbox} from '../setup-ci/__tests__/sandbox.js';
import {defaultRunner, runGhAsync, runGit} from './run-process.js';

describe('runGhAsync wrapper', () => {
  let sandbox: Sandbox;
  let restore: (() => void) | undefined;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-ci-gh-');
  });

  afterEach(() => {
    restore?.();
    restore = undefined;
    sandbox.cleanup();
  });

  test('spawns gh and resolves stdout on exit code 0', async () => {
    const handle = sandbox.installGhShim({
      exitCode: 0,
      stdoutQueue: ['hello world\n'],
    });
    restore = handle.restore;

    const result = await runGhAsync({args: ['version']});
    expect(result.ok).toBe(true);
    assertOk(result);

    expect(result.stdout).toBe('hello world\n');
  });

  test('returns ok: false with stderr on non-zero exit', async () => {
    const handle = sandbox.installGhShim({exitCode: 7});
    restore = handle.restore;

    const result = await runGhAsync({args: ['version']});
    expect(result.ok).toBe(false);
    assertNotOk(result);

    expect(result.exitCode).toBe(7);
  });

  test('a gh that never exits settles as timed out once timeoutMs elapses, and is killed', async () => {
    const pidFile = path.join(sandbox.root, 'gh.pid');
    const shimPath = path.join(sandbox.binDir, 'gh');

    writeFileSync(
      shimPath,
      `#!/bin/sh\n[ -n "$GH_SHIM_WARMUP" ] && exit 0\necho $$ > '${pidFile}'\nexec sleep 30\n`,
      'utf8'
    );
    chmodSync(shimPath, 0o755);

    // The first exec of a freshly written executable can stall past the 200ms
    // budget on macOS, killing the shim before it records its pid. Pay that
    // cost here, outside the timed call.
    execFileSync(shimPath, {env: {...process.env, GH_SHIM_WARMUP: '1'}});

    const started = Date.now();
    const result = await runGhAsync({
      args: ['api', 'repos/acme/widgets'],
      env: {
        ...process.env,
        PATH: `${sandbox.binDir}:${process.env.PATH ?? ''}`,
      },
      timeoutMs: 200,
    });

    expect(Date.now() - started).toBeLessThan(1000);
    expect(result).toStrictEqual({
      exitCode: -1,
      ok: false,
      stderr: '',
      timedOut: true,
    });

    const pid = Number.parseInt(readFileSync(pidFile, 'utf8'), 10);

    // A killed child can linger as a zombie until Node reaps it, and a signal
    // probe still reaches a zombie, so poll until the process is gone.
    await vi.waitFor(
      () => {
        expect(() => process.kill(pid, 0)).toThrow(/ESRCH/u);
      },
      {interval: 20, timeout: 1000}
    );
  });
});

describe('runGit', () => {
  test('returns stdout and exit code 0 on success', () => {
    const result = runGit(['--version']);

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toMatch(/^git version/u);
  });

  test('returns a non-zero exit code and stderr instead of throwing', () => {
    const result = runGit(['definitely-not-a-git-subcommand']);

    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).not.toBe('');
  });
});

describe('defaultRunner', () => {
  // Asserted against a child that writes past Node's 1 MiB spawnSync default
  // rather than against the constant, so the test fails if the bound is
  // removed by any means.
  test('reads child stdout past the 1 MiB spawnSync default', () => {
    const size = 2 * 1024 * 1024;

    const result = defaultRunner(
      process.execPath,
      ['-e', `process.stdout.write('x'.repeat(${size}))`],
      {cwd: process.cwd()}
    );

    expect(result.error).toBeUndefined();
    expect(result.stdout).toHaveLength(size);
  });
});
