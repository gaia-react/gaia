import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for `gaia ping` argument parsing and per-event payload shape.
 */
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from '../index.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-ping-index-'));

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
  };
};

const captureStdio = (): {
  errors: string[];
  restore: () => void;
} => {
  const errors: string[] = [];
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      errors.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    errors,
    restore: () => {
      stderrSpy.mockRestore();
    },
  };
};

describe('gaia ping', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;
  let fetchSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    sandbox = setupSandbox();
    stdio = captureStdio();
    fetchSpy = vi.fn().mockResolvedValue(new Response(null, {status: 204}));
    vi.stubGlobal('fetch', fetchSpy);
    vi.stubEnv('GAIA_TELEMETRY_PING_DISABLE', '');
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
  });

  const parsedBody = (): Record<string, unknown> => {
    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit];

    return JSON.parse(init.body as string) as Record<string, unknown>;
  };

  test('init event: sends mode, i18n (as a number), and ci', async () => {
    const exit = await run(
      [
        '--event',
        'init',
        '--mode',
        'interactive',
        '--i18n',
        '2',
        '--ci',
        'custom',
      ],
      {cwd: sandbox.root}
    );

    expect(exit).toBe(0);
    expect(parsedBody()).toMatchObject({
      ci: 'custom',
      event: 'init',
      i18n: 2,
      mode: 'interactive',
    });
  });

  test('setup event: sends all four setup fields', async () => {
    const exit = await run(
      [
        '--event',
        'setup',
        '--type',
        'clone',
        '--repo',
        'adopt',
        '--ci',
        'on',
        '--audit',
        'local',
      ],
      {cwd: sandbox.root}
    );

    expect(exit).toBe(0);
    expect(parsedBody()).toMatchObject({
      audit: 'local',
      ci: 'on',
      event: 'setup',
      repo: 'adopt',
      type: 'clone',
    });
  });

  test('setup event: only provided fields appear in the body', async () => {
    const exit = await run(['--event', 'setup', '--type', 'init'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(0);
    const body = parsedBody();
    expect(body.type).toBe('init');
    expect(body.repo).toBeUndefined();
    expect(body.ci).toBeUndefined();
    expect(body.audit).toBeUndefined();
  });

  test('update event: sends from and to as free-form strings', async () => {
    const exit = await run(
      ['--event', 'update', '--from', '1.6.1', '--to', '1.7.0'],
      {cwd: sandbox.root}
    );

    expect(exit).toBe(0);
    expect(parsedBody()).toMatchObject({
      event: 'update',
      from: '1.6.1',
      to: '1.7.0',
    });
  });

  test('missing --event exits 1 and does not send', async () => {
    const exit = await run(['--mode', 'interactive'], {cwd: sandbox.root});

    expect(exit).toBe(1);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  test('--event with a value outside the enum exits 1', async () => {
    const exit = await run(['--event', 'bogus'], {cwd: sandbox.root});

    expect(exit).toBe(1);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  test('--i18n that is not an integer exits 1', async () => {
    const exit = await run(['--event', 'init', '--i18n', 'abc'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(1);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  test('an enum field with a value outside its set exits 1 (--mode)', async () => {
    const exit = await run(['--event', 'init', '--mode', 'sideways'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(1);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  test('an unknown flag exits 1', async () => {
    const exit = await run(['--event', 'update', '--bogus', 'x'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(1);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  test('--ci enums are per-event distinct: init rejects setup-only value "on"', async () => {
    const exit = await run(['--event', 'init', '--ci', 'on'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(1);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  test('--ci enums are per-event distinct: setup rejects init-only value "custom"', async () => {
    const exit = await run(['--event', 'setup', '--ci', 'custom'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(1);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  test('setup event: --sandbox on is accepted', async () => {
    const exit = await run(['--event', 'setup', '--sandbox', 'on'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(0);
    expect(parsedBody()).toMatchObject({event: 'setup', sandbox: 'on'});
  });

  test('setup event: --sandbox off is accepted', async () => {
    const exit = await run(['--event', 'setup', '--sandbox', 'off'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(0);
    expect(parsedBody()).toMatchObject({event: 'setup', sandbox: 'off'});
  });

  test('setup event: --sandbox composes with the existing setup fields', async () => {
    const exit = await run(
      ['--event', 'setup', '--sandbox', 'on', '--type', 'clone'],
      {cwd: sandbox.root}
    );

    expect(exit).toBe(0);
    expect(parsedBody()).toMatchObject({
      event: 'setup',
      sandbox: 'on',
      type: 'clone',
    });
  });

  test('setup event: --sandbox outside on|off exits 1 naming the allowed values', async () => {
    const exit = await run(['--event', 'setup', '--sandbox', 'yes'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(1);
    expect(fetchSpy).not.toHaveBeenCalled();
    const error = stdio.errors.join('');
    expect(error).toContain('invalid_arguments');
    expect(error).toContain('on, off');
  });

  test('init event: --sandbox is rejected as an unknown flag (scoped to setup only)', async () => {
    const exit = await run(['--event', 'init', '--sandbox', 'on'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(1);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  test('setup event: POSTs to PING_URL', async () => {
    const exit = await run(['--event', 'setup', '--type', 'init'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(0);
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://telemetry.gaiareact.com/ping');
    expect(init.method).toBe('POST');
  });

  test('setup event: the payload carries no mentorship key', async () => {
    const exit = await run(['--event', 'setup', '--type', 'init'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(0);
    expect(Object.hasOwn(parsedBody(), 'mentorship')).toBe(false);
  });

  test('setup event: --mentorship is rejected as an unknown flag', async () => {
    const exit = await run(['--event', 'setup', '--mentorship', 'on'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(1);
    expect(fetchSpy).not.toHaveBeenCalled();
    const error = stdio.errors.join('');
    expect(error).toContain('unknown flag for event setup: --mentorship');
  });

  test('honors GAIA_TELEMETRY_PING_DISABLE=1: no fetch, exit 0', async () => {
    vi.stubEnv('GAIA_TELEMETRY_PING_DISABLE', '1');

    const exit = await run(
      ['--event', 'update', '--from', '1.0.0', '--to', '1.1.0'],
      {
        cwd: sandbox.root,
      }
    );

    expect(exit).toBe(0);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  test('--help prints usage and exits 0', async () => {
    const outputs: string[] = [];
    const stdoutSpy = vi
      .spyOn(process.stdout, 'write')
      .mockImplementation((chunk: unknown) => {
        outputs.push(typeof chunk === 'string' ? chunk : String(chunk));

        return true;
      });

    const exit = await run(['--help'], {cwd: sandbox.root});

    expect(exit).toBe(0);
    expect(outputs.join('')).toContain('Usage: gaia ping');
    expect(outputs.join('')).toContain('--sandbox <on|off>');
    stdoutSpy.mockRestore();
  });
});
