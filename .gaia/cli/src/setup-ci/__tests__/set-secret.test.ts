import {Readable} from 'node:stream';
import {readFileSync} from 'node:fs';
import {afterEach, beforeEach, describe, expect, it, vi} from 'vitest';
import {run} from '../set-secret.js';
import {setupSandbox, type Sandbox} from './sandbox.js';

const SECRET_VALUE = 'sk-this-is-the-secret-payload-do-not-leak-12345';

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

const stdinFromString = (value: string): NodeJS.ReadableStream =>
  Readable.from([Buffer.from(value, 'utf8')]);

describe('setup-ci set-secret', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;
  let restore: (() => void) | undefined;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-ci-set-secret-');
    stdio = captureStdio();
  });

  afterEach(() => {
    restore?.();
    restore = undefined;
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  it('passes the secret name on argv but never the secret value', async () => {
    const handle = sandbox.installGhShim({exitCode: 0});
    restore = handle.restore;

    const exit = await run(
      ['CLAUDE_CODE_OAUTH_TOKEN'],
      {cwd: sandbox.root, stdin: stdinFromString(SECRET_VALUE)}
    );
    expect(exit).toBe(0);

    const recorded = JSON.parse(readFileSync(sandbox.ghArgvPath, 'utf8')) as string[][];
    expect(recorded[0]).toEqual(['secret', 'set', 'CLAUDE_CODE_OAUTH_TOKEN']);

    // Critical: the secret VALUE never appears anywhere in argv.
    expect(JSON.stringify(recorded)).not.toContain(SECRET_VALUE);
  });

  it('pipes the secret to gh stdin', async () => {
    const handle = sandbox.installGhShim({exitCode: 0});
    restore = handle.restore;

    const exit = await run(
      ['CLAUDE_CODE_OAUTH_TOKEN'],
      {cwd: sandbox.root, stdin: stdinFromString(SECRET_VALUE)}
    );
    expect(exit).toBe(0);

    const stdinBytes = readFileSync(sandbox.ghStdinPath, 'utf8');
    expect(stdinBytes).toBe(SECRET_VALUE);
  });

  it('trims trailing newlines defensively', async () => {
    const handle = sandbox.installGhShim({exitCode: 0});
    restore = handle.restore;

    await run(
      ['CLAUDE_CODE_OAUTH_TOKEN'],
      {cwd: sandbox.root, stdin: stdinFromString(`${SECRET_VALUE}\n`)}
    );

    const stdinBytes = readFileSync(sandbox.ghStdinPath, 'utf8');
    expect(stdinBytes).toBe(SECRET_VALUE);
  });

  it('does NOT echo the secret to stdout or stderr on happy path', async () => {
    const handle = sandbox.installGhShim({exitCode: 0});
    restore = handle.restore;

    await run(
      ['CLAUDE_CODE_OAUTH_TOKEN'],
      {cwd: sandbox.root, stdin: stdinFromString(SECRET_VALUE)}
    );

    expect(stdio.out.join('')).not.toContain(SECRET_VALUE);
    expect(stdio.err.join('')).not.toContain(SECRET_VALUE);
  });

  it('does NOT echo the secret on gh failure path', async () => {
    const handle = sandbox.installGhShim({exitCode: 1});
    restore = handle.restore;

    const exit = await run(
      ['CLAUDE_CODE_OAUTH_TOKEN'],
      {cwd: sandbox.root, stdin: stdinFromString(SECRET_VALUE)}
    );
    expect(exit).not.toBe(0);

    const allOutput = stdio.out.join('') + stdio.err.join('');
    expect(allOutput).not.toContain(SECRET_VALUE);

    // The structured error/payload must use a generic message.
    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;
    expect(parsed.set).toBe(false);
    expect(parsed.error).toBe('gh_failure');
  });

  it('does NOT echo the secret when gh emits it in its own stderr', async () => {
    // Defense-in-depth: even if a future `gh` build leaks the captured
    // secret to its own stderr, the handler must suppress it and emit a
    // generic `gh_failure` instead of forwarding the raw stderr.
    const handle = sandbox.installGhShim({
      exitCode: 1,
      stderrQueue: [`gh: api error: token=${SECRET_VALUE} rejected`],
    });
    restore = handle.restore;

    const exit = await run(
      ['CLAUDE_CODE_OAUTH_TOKEN'],
      {cwd: sandbox.root, stdin: stdinFromString(SECRET_VALUE)}
    );
    expect(exit).not.toBe(0);

    const allOutput = stdio.out.join('') + stdio.err.join('');
    expect(allOutput).not.toContain(SECRET_VALUE);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;
    expect(parsed.set).toBe(false);
    expect(parsed.error).toBe('gh_failure');
  });

  it('exits unknown_secret_name on unsupported names', async () => {
    const exit = await run(
      ['NOT_A_REAL_SECRET'],
      {cwd: sandbox.root, stdin: stdinFromString(SECRET_VALUE)}
    );
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('unknown_secret_name');
  });

  it('exits empty_secret on empty stdin', async () => {
    const handle = sandbox.installGhShim({exitCode: 0});
    restore = handle.restore;

    const exit = await run(
      ['CLAUDE_CODE_OAUTH_TOKEN'],
      {cwd: sandbox.root, stdin: stdinFromString('')}
    );
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('empty_secret');
  });

  it('exits empty_secret when stdin is only newlines', async () => {
    const handle = sandbox.installGhShim({exitCode: 0});
    restore = handle.restore;

    const exit = await run(
      ['CLAUDE_CODE_OAUTH_TOKEN'],
      {cwd: sandbox.root, stdin: stdinFromString('\n\n')}
    );
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('empty_secret');
  });

  it('accepts ANTHROPIC_API_KEY as a supported name', async () => {
    const handle = sandbox.installGhShim({exitCode: 0});
    restore = handle.restore;

    const exit = await run(
      ['ANTHROPIC_API_KEY'],
      {cwd: sandbox.root, stdin: stdinFromString('sk-ant-12345')}
    );
    expect(exit).toBe(0);

    const recorded = JSON.parse(readFileSync(sandbox.ghArgvPath, 'utf8')) as string[][];
    expect(recorded[0]).toEqual(['secret', 'set', 'ANTHROPIC_API_KEY']);
  });

  it('--help exits 0', async () => {
    const exit = await run(['--help'], {
      cwd: sandbox.root,
      stdin: stdinFromString(''),
    });
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('Usage:');
  });
});
