import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {assertNotOk, assertOk, setupSandbox} from '../../__tests__/sandbox.js';
import type {Sandbox} from '../../__tests__/sandbox.js';
import {runGh} from '../gh.js';

describe('runGh wrapper', () => {
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

    const result = await runGh({args: ['version']});
    expect(result.ok).toBe(true);
    assertOk(result);

    expect(result.stdout).toBe('hello world\n');
  });

  test('returns ok: false with stderr on non-zero exit', async () => {
    const handle = sandbox.installGhShim({exitCode: 7});
    restore = handle.restore;

    const result = await runGh({args: ['version']});
    expect(result.ok).toBe(false);
    assertNotOk(result);

    expect(result.exitCode).toBe(7);
  });
});
