import {chmodSync, readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, it} from 'vitest';
import {setupSandbox, type Sandbox} from '../../__tests__/sandbox.js';
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

  it('spawns gh and resolves stdout on exit code 0', async () => {
    const handle = sandbox.installGhShim({
      exitCode: 0,
      stdoutQueue: ['hello world\n'],
    });
    restore = handle.restore;

    const result = await runGh({args: ['version']});
    expect(result.ok).toBe(true);

    if (result.ok) {
      expect(result.stdout).toBe('hello world\n');
    }
  });

  it('records argv exactly without appending stdin to args', async () => {
    const handle = sandbox.installGhShim({exitCode: 0});
    restore = handle.restore;

    await runGh({
      args: ['secret', 'set', 'TOKEN_NAME'],
      stdin: 'super-secret-payload-12345',
    });

    const recorded = JSON.parse(
      readFileSync(sandbox.ghArgvPath, 'utf8')
    ) as string[][];
    expect(recorded).toHaveLength(1);
    expect(recorded[0]).toEqual(['secret', 'set', 'TOKEN_NAME']);

    // The secret MUST NOT appear anywhere in argv.
    const flat = JSON.stringify(recorded);
    expect(flat).not.toContain('super-secret-payload-12345');
  });

  it('pipes stdin to the child process', async () => {
    const handle = sandbox.installGhShim({exitCode: 0});
    restore = handle.restore;

    await runGh({args: ['secret', 'set', 'NAME'], stdin: 'piped-value'});

    const stdinBytes = readFileSync(sandbox.ghStdinPath, 'utf8');
    expect(stdinBytes).toBe('piped-value');
  });

  it('returns ok: false with stderr on non-zero exit', async () => {
    const handle = sandbox.installGhShim({exitCode: 7});
    restore = handle.restore;

    const result = await runGh({args: ['version']});
    expect(result.ok).toBe(false);

    if (!result.ok) {
      expect(result.exitCode).toBe(7);
    }
  });

  it('does not crash on EPIPE when the child closes stdin early', async () => {
    // Install a shim that exits immediately WITHOUT draining stdin, so a
    // large payload fills the pipe buffer and the wrapper's write/end
    // hits EPIPE. Without an `error` handler this would be an unhandled
    // stream error that aborts the process.
    const handle = sandbox.installGhShim({exitCode: 0});
    restore = handle.restore;

    const shimPath = path.join(sandbox.binDir, 'gh');
    writeFileSync(
      shimPath,
      '#!/usr/bin/env node\n' +
        '// Exit at once; never read stdin.\n' +
        'process.exit(0);\n',
      'utf8'
    );
    chmodSync(shimPath, 0o755);

    // Payload larger than a typical 64KiB pipe buffer.
    const result = await runGh({
      args: ['secret', 'set', 'NAME'],
      stdin: 'x'.repeat(256 * 1024),
    });

    // The wrapper must resolve (via the child's `close`) rather than throw.
    expect(result.ok).toBe(true);
  });
});
