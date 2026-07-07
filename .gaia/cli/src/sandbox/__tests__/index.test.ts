import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for the `gaia sandbox` CLI surface (detect/seed/apply/record/status).
 *
 * Strategy: tmp git repo per test (apply/record/status resolve repoRoot via
 * `resolveMainWorktreeRoot`, which shells `git`), exercise the verbs against
 * `.claude/settings.local.json` and `.gaia/local/sandbox.json`.
 */
import {execFileSync} from 'node:child_process';
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from '../index.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-sandbox-cli-'));
  execFileSync('git', ['init', '-q'], {cwd: root});

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

describe('gaia sandbox detect', () => {
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    vi.restoreAllMocks();
  });

  test('fully-injected darwin input is ready, printed as JSON', () => {
    const exit = run(['detect', '--platform', 'darwin', '--json']);

    expect(exit).toBe(0);
    const parsed = JSON.parse(stdio.outputs.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.capability).toBe('ready');
  });

  test('fully-injected linux without deps is needs-deps', () => {
    const exit = run([
      'detect',
      '--platform',
      'linux',
      '--has-bwrap',
      'false',
      '--has-socat',
      'false',
      '--json',
    ]);

    expect(exit).toBe(0);
    const parsed = JSON.parse(stdio.outputs.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.capability).toBe('needs-deps');
    expect(parsed.installCommand).toBe('sudo apt-get install bubblewrap socat');
  });

  test('win32 is unsupported', () => {
    const exit = run(['detect', '--platform', 'win32', '--json']);

    expect(exit).toBe(0);
    const parsed = JSON.parse(stdio.outputs.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.capability).toBe('unsupported');
  });

  test('an invalid --platform value exits non-zero', () => {
    const exit = run(['detect', '--platform', 'bogus']);

    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--platform must be one of');
  });

  test('--help prints usage and exits 0', () => {
    const exit = run(['detect', '--help']);

    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('Usage: gaia sandbox detect');
  });
});

describe('gaia sandbox seed', () => {
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    vi.restoreAllMocks();
  });

  test('default registry, docker absent: allowedDomains defaults and excludedCommands is absent', () => {
    const exit = run([
      'seed',
      '--registry',
      '',
      '--docker-present',
      'false',
      '--json',
    ]);

    expect(exit).toBe(0);
    const parsed = JSON.parse(stdio.outputs.join('').trim()) as {
      sandbox: {
        excludedCommands?: string[];
        network: {allowedDomains: string[]};
      };
    };
    expect(parsed.sandbox.network.allowedDomains).toEqual([
      'registry.npmjs.org',
    ]);
    expect(parsed.sandbox.excludedCommands).toBeUndefined();
  });

  test('docker present: excludedCommands contains docker *', () => {
    const exit = run([
      'seed',
      '--registry',
      'https://registry.npmjs.org/',
      '--docker-present',
      'true',
      '--json',
    ]);

    expect(exit).toBe(0);
    const parsed = JSON.parse(stdio.outputs.join('').trim()) as {
      sandbox: {excludedCommands?: string[]};
    };
    expect(parsed.sandbox.excludedCommands).toContain('docker *');
  });

  test('missing --registry exits non-zero', () => {
    const exit = run(['seed', '--docker-present', 'true']);

    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--registry is required');
  });
});

describe('gaia sandbox apply', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupSandbox();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('writes settings, preserves unrelated keys, and leaves an enabled marker', () => {
    const settingsPath = path.join(sandbox.root, 'settings.local.json');
    writeFileSync(settingsPath, JSON.stringify({someOtherKey: true}), 'utf8');

    const exit = run(
      [
        'apply',
        '--registry',
        'https://registry.npmjs.org/',
        '--docker-present',
        'true',
        '--settings-path',
        settingsPath,
      ],
      {cwd: sandbox.root}
    );

    expect(exit).toBe(0);

    const written = JSON.parse(readFileSync(settingsPath, 'utf8')) as {
      sandbox: {
        enabled: boolean;
        excludedCommands: string[];
        network: {allowedDomains: string[]};
      };
      someOtherKey: boolean;
    };
    expect(written.sandbox.enabled).toBe(true);
    expect(written.sandbox.network.allowedDomains).toEqual([
      'registry.npmjs.org',
    ]);
    expect(written.sandbox.excludedCommands).toContain('docker *');
    expect(written.someOtherKey).toBe(true);

    const markerPath = path.join(
      sandbox.root,
      '.gaia',
      'local',
      'sandbox.json'
    );
    expect(existsSync(markerPath)).toBe(true);
    const marker = JSON.parse(readFileSync(markerPath, 'utf8')) as {
      outcome: string;
    };
    expect(marker.outcome).toBe('enabled');
  });

  test('creates the settings file as {} when absent, then merges into it', () => {
    const settingsPath = path.join(
      sandbox.root,
      'nested',
      'settings.local.json'
    );

    const exit = run(
      [
        'apply',
        '--registry',
        'https://registry.npmjs.org/',
        '--docker-present',
        'false',
        '--settings-path',
        settingsPath,
      ],
      {cwd: sandbox.root}
    );

    expect(exit).toBe(0);
    expect(existsSync(settingsPath)).toBe(true);
  });

  test('missing --docker-present exits non-zero', () => {
    const exit = run(['apply', '--registry', 'https://registry.npmjs.org/'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--docker-present is required');
  });
});

describe('gaia sandbox record + status', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupSandbox();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('status reports resolved:false before any decision', () => {
    const exit = run(['status', '--json'], {cwd: sandbox.root});

    expect(exit).toBe(0);
    const parsed = JSON.parse(stdio.outputs.join('').trim()) as {
      resolved: boolean;
    };
    expect(parsed.resolved).toBe(false);
  });

  test('record declined then status reports it (UAT-012 mechanism), no settings file', () => {
    const recordExit = run(
      ['record', '--outcome', 'declined', '--capability', 'ready'],
      {cwd: sandbox.root}
    );

    expect(recordExit).toBe(0);
    expect(
      existsSync(path.join(sandbox.root, '.claude', 'settings.local.json'))
    ).toBe(false);

    stdio.outputs.length = 0;
    const statusExit = run(['status', '--json'], {cwd: sandbox.root});

    expect(statusExit).toBe(0);
    const parsed = JSON.parse(stdio.outputs.join('').trim()) as {
      capability: string;
      outcome: string;
      resolved: boolean;
    };
    expect(parsed.resolved).toBe(true);
    expect(parsed.outcome).toBe('declined');
    expect(parsed.capability).toBe('ready');
  });

  test('record with an invalid --outcome exits non-zero', () => {
    const exit = run(
      ['record', '--outcome', 'bogus', '--capability', 'ready'],
      {cwd: sandbox.root}
    );

    expect(exit).toBe(1);
  });
});
